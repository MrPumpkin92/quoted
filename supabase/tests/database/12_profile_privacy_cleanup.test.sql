-- Profile privacy and account cleanup (supabase/migrations/20261021090000_abuse_limits_privacy_cleanup.sql):
-- profiles readable only when linked, exact lookup and availability RPCs,
-- reserved and immutable usernames, server-owned last_active_at and
-- purge_exempt, touch_activity, and the purge of abandoned anonymous accounts.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(69);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a'  then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b'  then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'f'  then 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    when 's'  then '55555555-5555-4555-8555-555555555555'
    when 'x'  then '88888888-8888-4888-8888-888888888888'
    when 'n'  then '11111111-1111-4111-8111-111111111111'
    when 'm'  then '22222222-2222-4222-8222-222222222222'
    when 'k'  then '33333333-3333-4333-8333-333333333333'
    when 'h'  then '44444444-4444-4444-8444-444444444444'
    when 'g1' then 'e0000000-0000-4000-8000-000000000001'
    when 'g2' then 'e0000000-0000-4000-8000-000000000002'
    when 'g3' then 'e0000000-0000-4000-8000-000000000003'
    when 'g4' then 'e0000000-0000-4000-8000-000000000004'
    when 'g5' then 'e0000000-0000-4000-8000-000000000005'
    when 'g6' then 'e0000000-0000-4000-8000-000000000006'
    when 'e1' then 'e1000000-0000-4000-8000-000000000001'
    when 'e2' then 'e1000000-0000-4000-8000-000000000002'
  end)::uuid
$$;

create function tests.test_users() returns uuid[] language sql immutable as $$
  select array_agg(tests.uid(w))
  from unnest(array['a', 'b', 'f', 's', 'x', 'n', 'm', 'k', 'h', 'g1', 'g2', 'g3', 'g4', 'g5', 'g6', 'e1', 'e2']) w
$$;

-- An email user, or an anonymous one (what signInAnonymously writes), created `age` ago.
create function tests.create_user(who text, anonymous boolean, age interval) returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, is_anonymous, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', tests.uid(who), 'authenticated', 'authenticated',
          case when anonymous then null else who || '@test.quoted.invalid' end, '',
          case when anonymous then null else now() end,
          case when anonymous then '{}'::jsonb else '{"provider":"email","providers":["email"]}'::jsonb end,
          '{}', anonymous, now() - age, now() - age)
  returning id
$$;

-- Act as a signed-in user: role authenticated plus JWT claims, transaction-local.
create function tests.authenticate_as(who text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(who), 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$$;

-- Back to the test runner's superuser role (bypasses RLS) to inspect state.
create function tests.clear_authentication() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- Matches among accounts this test did not create (a shared local stack may
-- hold some), so the purge counts below can be exact. Rules from the contract.
create function tests.other_matches(p_now timestamptz, out rule_a int, out rule_b int) language sql as $$
  select
    (select count(*)::int from auth.users u
     where u.is_anonymous and u.created_at < p_now - interval '7 days'
       and not exists (select 1 from public.profiles p where p.id = u.id)
       and u.id <> all (tests.test_users())),
    (select count(*)::int from auth.users u join public.profiles p on p.id = u.id
     where u.is_anonymous and p.last_active_at < p_now - interval '365 days' and not p.purge_exempt
       and u.id <> all (tests.test_users()))
$$;
-- ---------------------------------------------------------------------------

select tests.create_user(w, false, interval '0') from unnest(array['a', 'b', 'f', 's', 'x', 'n', 'm', 'k']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice'), (tests.uid('b'), 'bob', null), (tests.uid('f'), 'fred', 'Fred'),
  (tests.uid('s'), 'stella', 'Stella S.'), (tests.uid('x'), 'xena', null);

-- ---- schema and privileges ------------------------------------------------
select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles' and column_name in ('last_active_at', 'purge_exempt')
     order by ordinal_position $$,
  $$ values ('last_active_at', 'timestamp with time zone', 'NO', 'now()'),
            ('purge_exempt', 'boolean', 'NO', 'false') $$,
  'profiles has last_active_at (not null, now()) and purge_exempt (not null, false)'
);

select results_eq(
  $$ select f, has_function_privilege('anon', f, 'execute'), has_function_privilege('authenticated', f, 'execute'),
            has_function_privilege('service_role', f, 'execute')
     from unnest(array['public.find_profile(text)', 'public.is_username_available(text)', 'public.touch_activity()']) f $$,
  $$ values ('public.find_profile(text)', false, true, false),
            ('public.is_username_available(text)', false, true, false),
            ('public.touch_activity()', false, true, false) $$,
  'the three RPCs are executable by authenticated only'
);

select results_eq(
  $$ select p.oid::regprocedure::text collate "default", p.prosecdef
     from pg_proc p
     where p.proname in ('find_profile', 'is_username_available', 'touch_activity', 'purge_inactive_anonymous')
     order by p.pronamespace::regnamespace::text, 1 $$,
  $$ values ('private.find_profile(text)', true),
            ('private.is_username_available(text)', true),
            ('private.purge_inactive_anonymous(timestamp with time zone,integer)', true),
            ('private.touch_activity()', true),
            ('find_profile(text)', false),
            ('is_username_available(text)', false),
            ('touch_activity()', false) $$,
  'public wrappers are SECURITY INVOKER over private SECURITY DEFINER functions'
);

select is_empty(
  $$ select p.oid::regprocedure from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
       and p.proname in ('find_profile', 'is_username_available', 'touch_activity', 'purge_inactive_anonymous')
       and not coalesce(p.proconfig @> array['search_path=""'], false) $$,
  'every one of them pins search_path to empty'
);

select results_eq(
  $$ select has_function_privilege('anon', 'private.purge_inactive_anonymous(timestamptz, integer)', 'execute'),
            has_function_privilege('authenticated', 'private.purge_inactive_anonymous(timestamptz, integer)', 'execute'),
            has_function_privilege('service_role', 'private.purge_inactive_anonymous(timestamptz, integer)', 'execute'),
            has_table_privilege('authenticated', 'private.purge_runs', 'select'),
            has_table_privilege('service_role', 'private.purge_runs', 'select') $$,
  $$ values (false, false, false, false, false) $$,
  'no API role can run the purge or read its log'
);

select results_eq(
  $$ select jobname::text, schedule::text, command::text, active from cron.job where jobname = 'purge-inactive-anonymous' $$,
  $$ values ('purge-inactive-anonymous', '17 3 * * *', 'select private.purge_inactive_anonymous()', true) $$,
  'pg_cron runs the purge daily at 03:17'
);

-- ---- a stranger is not listable, but findable by exact name ---------------
select tests.authenticate_as('a');

select results_eq(
  $$ select username from public.profiles order by username $$,
  $$ values ('alice') $$,
  'with no friends, shares or blocks, A reads only their own profile'
);

select is_empty(
  $$ select 1 from public.profiles where id = tests.uid('s') or username = 'stella' $$,
  'A cannot read a stranger''s profile, even by id or username'
);

select results_eq(
  $$ select id, username, display_name from public.find_profile('stella') $$,
  $$ values (tests.uid('s'), 'stella', 'Stella S.') $$,
  'A finds the stranger by exact username'
);

select results_eq(
  $$ select username from public.find_profile(E' @Stella\n') $$,
  $$ values ('stella') $$,
  'the lookup trims, drops one leading @ and lowercases, like the app'
);

select is_empty($$ select 1 from public.find_profile('stel') $$, 'no prefix matches');
select is_empty($$ select 1 from public.find_profile('@@stella') $$, 'only one leading @ is dropped');
select is_empty($$ select 1 from public.find_profile('st%') $$, 'no pattern matches');
select is_empty($$ select 1 from public.find_profile('alice') $$, 'the lookup never returns yourself');
select is_empty($$ select 1 from public.find_profile(null) $$, 'null finds nothing');

-- ---- linked profiles are readable -----------------------------------------
select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('f')) $$,
  'A sends F a friend request'
);

select results_eq(
  $$ select r.username, ad.username
     from public.friendships fr
     left join public.profiles r on r.id = fr.requester_id
     left join public.profiles ad on ad.id = fr.addressee_id $$,
  $$ values ('alice', 'fred') $$,
  'a pending request links the pair: both profiles resolve for the requester'
);

select tests.authenticate_as('f');

select results_eq(
  $$ select username from public.profiles order by username $$,
  $$ values ('alice'), ('fred') $$,
  'the addressee reads the requester''s profile too, and nobody else''s'
);

select lives_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('a') $$,
  'F accepts'
);

select lives_ok(
  $$ insert into public.shares (recipient_id, body) values (tests.uid('a'), 'F to A') $$,
  'F shares a quote with A'
);

select lives_ok(
  $$ delete from public.friendships where tests.uid('a') in (requester_id, addressee_id) $$,
  'F unfriends A'
);

select results_eq(
  $$ select username from public.profiles where id = tests.uid('a') $$,
  $$ values ('alice') $$,
  'the share still links them: F (sender) reads A'
);

select tests.authenticate_as('a');

select results_eq(
  $$ select s.body, p.username from public.shares s left join public.profiles p on p.id = s.sender_id $$,
  $$ values ('F to A', 'fred') $$,
  'and A (recipient) reads F, so the inbox embed resolves'
);

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('s')) $$,
  'A blocks the stranger S'
);

select results_eq(
  $$ select b.blocked_id, p.username from public.blocks b left join public.profiles p on p.id = b.blocked_id $$,
  $$ values (tests.uid('s'), 'stella') $$,
  'a block A made links S for A, so the blocked list resolves'
);

select tests.authenticate_as('s');

select results_eq(
  $$ select username from public.profiles $$,
  $$ values ('stella') $$,
  'S (blocked) does not gain A''s profile'
);

-- ---- a blocked pair cannot find each other --------------------------------
select is_empty($$ select 1 from public.find_profile('alice') $$, 'S cannot find A, who blocked S');

select tests.authenticate_as('a');

select is_empty($$ select 1 from public.find_profile('stella') $$, 'A cannot find S, whom A blocked');

select results_eq(
  $$ select username from public.find_profile('xena') $$,
  $$ values ('xena') $$,
  'A still finds anyone else'
);

-- ---- availability -----------------------------------------------------------
select results_eq(
  $$ select n, public.is_username_available(n)
     from unnest(array['alice', 'Stella', 'fresh_name', ' @Fresh_Name ', 'admin', 'Admin', '@SUPPORT',
                       'quotedhelper', 'everyone', 'me', 'ab', 'has space', 'émile', repeat('x', 21), '']) n $$,
  $$ values ('alice', false), ('Stella', false), ('fresh_name', true), (' @Fresh_Name ', true),
            ('admin', false), ('Admin', false), ('@SUPPORT', false), ('quotedhelper', false),
            ('everyone', false), ('me', false), ('ab', false), ('has space', false), ('émile', false),
            (repeat('x', 21), false), ('', false) $$,
  'is_username_available: taken, free, reserved (any case) and invalid names'
);

select is(public.is_username_available(null), false, 'null is not available');

select is(
  public.is_username_available('stella'),
  false,
  'a taken name is unavailable even when its owner is blocked'
);

-- ---- reserved names ---------------------------------------------------------
select tests.authenticate_as('n');

select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('n'), 'admin') $$,
  '23505', 'username "admin" is reserved',
  'a client cannot claim a reserved username (reported as taken)'
);

select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('n'), 'quoted') $$,
  '23505', 'username "quoted" is reserved',
  'quoted is reserved'
);

-- The format check only allows lowercase, so reserved names are compared as typed.
select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('n'), 'you') $$,
  '23505', 'username "you" is reserved',
  'every name on the list is reserved'
);

select is(private.is_reserved_username('ModErator'), true, 'the reserved check ignores case');

select lives_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('n'), 'quoted_fan') $$,
  'a name that only contains a reserved word is allowed'
);

select tests.clear_authentication();
select tests.create_user('h', true, interval '0');

select lives_ok(
  $$ insert into public.profiles (id, username, purge_exempt) values (tests.uid('h'), 'quotedhelper', true) $$,
  'the founder (SQL editor) can give the helper account a reserved name and exempt it'
);

-- ---- usernames are immutable ------------------------------------------------
select tests.authenticate_as('a');

select throws_ok(
  $$ update public.profiles set username = 'alice_two' where id = tests.uid('a') $$,
  '42501', 'usernames cannot be changed once set',
  'a client cannot change their username'
);

select results_eq(
  $$ update public.profiles set display_name = 'Alice A.', username = 'alice' where id = tests.uid('a') returning display_name $$,
  $$ values ('Alice A.') $$,
  'the display name can still change (setting the same username is not a change)'
);

select tests.clear_authentication();

select throws_ok(
  $$ update public.profiles set username = 'alice_two' where id = tests.uid('a') $$,
  '42501', 'usernames cannot be changed once set',
  'not even the table owner can change a username'
);

set local role service_role;

select throws_ok(
  $$ update public.profiles set username = 'alice_two' where id = tests.uid('a') $$,
  '42501', 'usernames cannot be changed once set',
  'nor the secret key'
);

select tests.clear_authentication();

-- ---- last_active_at and purge_exempt are server-owned -----------------------
select tests.authenticate_as('m');

select results_eq(
  $$ insert into public.profiles (id, username, last_active_at, purge_exempt)
     values (tests.uid('m'), 'mona', '2000-01-01', true)
     returning last_active_at = now(), purge_exempt $$,
  $$ values (true, false) $$,
  'on insert a client''s last_active_at becomes now() and purge_exempt false'
);

select results_eq(
  $$ update public.profiles set last_active_at = '2000-01-01', purge_exempt = true where id = tests.uid('m')
     returning last_active_at = now(), purge_exempt $$,
  $$ values (true, false) $$,
  'a client cannot change last_active_at or purge_exempt later either'
);

select tests.clear_authentication();
set local role service_role;

select results_eq(
  $$ update public.profiles set purge_exempt = true where id = tests.uid('m') returning purge_exempt $$,
  $$ values (true) $$,
  'the secret key can set purge_exempt'
);

select tests.clear_authentication();

-- ---- touch_activity -----------------------------------------------------------
update public.profiles set last_active_at = now() - interval '11 hours' where id = tests.uid('a');
update public.profiles set last_active_at = now() - interval '13 hours' where id = tests.uid('b');
select tests.authenticate_as('a');

select lives_ok($$ select public.touch_activity() $$, 'A calls touch_activity');

select tests.clear_authentication();

select results_eq(
  $$ select id, last_active_at = now() - interval '11 hours' from public.profiles where id in (tests.uid('a'), tests.uid('b')) order by id $$,
  $$ values (tests.uid('a'), true), (tests.uid('b'), false) $$,
  'within 12 hours nothing is written, and another user''s row is never touched'
);

select is(
  (select last_active_at = now() - interval '13 hours' from public.profiles where id = tests.uid('b')),
  true,
  'B''s last_active_at is unchanged by A''s call'
);

update public.profiles set last_active_at = now() - interval '13 hours' where id = tests.uid('a');
select tests.authenticate_as('a');
select public.touch_activity();
select tests.clear_authentication();

select is(
  (select last_active_at from public.profiles where id = tests.uid('a')),
  now(),
  'after 12 hours touch_activity stamps now()'
);

select tests.authenticate_as('a');

select is_empty(
  $$ update public.profiles set display_name = 'Alice' where id = tests.uid('b') returning 1 $$,
  'a client still cannot write another user''s profile'
);

select tests.clear_authentication();

-- ---- purge of abandoned anonymous accounts ----------------------------------
--   g1  anonymous, no profile, 8 days old                 rule A now
--   g2  anonymous, no profile, 6 days old                 rule A in 70 days
--   g3  anonymous, inactive 400 days, with rows           rule B now
--   g4  anonymous, inactive 400 days, purge_exempt         never
--   g5  anonymous, inactive 300 days                       rule B in 70 days
--   g6  anonymous, no profile, exactly 7 days old          rule A only after 7 days
--   e1  email, no profile, 30 days old                     never
--   e2  email, inactive 1000 days                          never
select tests.create_user('g1', true, interval '8 days');
select tests.create_user('g2', true, interval '6 days');
select tests.create_user('g3', true, interval '500 days');
select tests.create_user('g4', true, interval '500 days');
select tests.create_user('g5', true, interval '400 days');
select tests.create_user('g6', true, interval '7 days');
select tests.create_user('e1', false, interval '30 days');
select tests.create_user('e2', false, interval '1100 days');
insert into public.profiles (id, username, last_active_at, purge_exempt) values
  (tests.uid('g3'), 'old_guest', now() - interval '400 days', false),
  (tests.uid('g4'), 'exempt_guest', now() - interval '400 days', true),
  (tests.uid('g5'), 'recent_guest', now() - interval '300 days', false),
  (tests.uid('e2'), 'old_email', now() - interval '1000 days', false);
-- g3 has a quote, a friendship and a share with B, and reported B.
insert into public.quotes (owner_id, body) values (tests.uid('g3'), 'G3 quote');
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('g3'), tests.uid('b'), 'accepted');
insert into public.shares (sender_id, recipient_id, body) values (tests.uid('g3'), tests.uid('b'), 'G3 to B');
insert into public.reports (id, reporter_id, reported_user_id, reason)
values ('7e000000-0000-4000-8000-000000000003', tests.uid('g3'), tests.uid('b'), 'spam');

create table tests.baseline as select (tests.other_matches(now())).*, 'now' as label;

-- An aborted run raises a WARNING for the cron log; keep it out of the TAP output.
set local client_min_messages = error;

select results_eq(
  $$ select rule_a_count, rule_b_count, aborted
     from private.purge_inactive_anonymous(now(), 1 + (select rule_a + rule_b from tests.baseline where label = 'now')) $$,
  $$ select 1 + rule_a, 1 + rule_b, true from tests.baseline where label = 'now' $$,
  'with more matches than the cap, the run is aborted'
);

select results_eq(
  $$ select count(*)::int from auth.users where id in (tests.uid('g1'), tests.uid('g3')) $$,
  $$ values (2) $$,
  'an aborted run deletes nothing'
);

select results_eq(
  $$ select rule_a_count, rule_b_count, aborted, ran_at = now() from private.purge_runs order by id desc limit 1 $$,
  $$ select 1 + rule_a, 1 + rule_b, true, true from tests.baseline where label = 'now' $$,
  'the aborted run is logged'
);

select results_eq(
  $$ select rule_a_count, rule_b_count, aborted from private.purge_inactive_anonymous() $$,
  $$ select 1 + rule_a, 1 + rule_b, false from tests.baseline where label = 'now' $$,
  'with the defaults (now, cap 500) the run deletes one account per rule'
);

select results_eq(
  $$ select w, exists (select 1 from auth.users where id = tests.uid(w))
     from unnest(array['g1', 'g2', 'g3', 'g4', 'g5', 'g6', 'e1', 'e2', 'h']) w $$,
  $$ values ('g1', false), ('g2', true), ('g3', false), ('g4', true), ('g5', true), ('g6', true),
            ('e1', true), ('e2', true), ('h', true) $$,
  'rule A took g1 (no profile after 7 days), rule B took g3 (inactive 365 days); the rest stay'
);

select results_eq(
  $$ select (select count(*)::int from public.profiles where id = tests.uid('g3')),
            (select count(*)::int from public.quotes where owner_id = tests.uid('g3')),
            (select count(*)::int from public.friendships where tests.uid('g3') in (requester_id, addressee_id)),
            (select count(*)::int from public.shares where sender_id = tests.uid('g3')) $$,
  $$ values (0, 0, 0, 0) $$,
  'g3''s profile, quotes, friendship and share went with the account'
);

select results_eq(
  $$ select reporter_id is null, reported_user_id, reported_username from public.reports
     where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values (true, tests.uid('b'), 'bob'::text) $$,
  'g3''s report is kept for moderation without g3''s id'
);

select tests.authenticate_as('k');

select is(public.is_username_available('old_guest'), true, 'the purged account''s username is free again');

select lives_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('k'), 'old_guest') $$,
  'and a new account can take it'
);

select tests.clear_authentication();
insert into tests.baseline select (tests.other_matches(now() + interval '70 days')).*, 'later';

select results_eq(
  $$ select rule_a_count, rule_b_count, aborted from private.purge_inactive_anonymous(now() + interval '70 days') $$,
  $$ select 2 + rule_a, 1 + rule_b, false from tests.baseline where label = 'later' $$,
  'with p_now 70 days ahead, g2 and g6 match rule A and g5 rule B'
);

select results_eq(
  $$ select w, exists (select 1 from auth.users where id = tests.uid(w))
     from unnest(array['g2', 'g4', 'g5', 'g6', 'e1', 'e2', 'h', 'k']) w $$,
  $$ values ('g2', false), ('g4', true), ('g5', false), ('g6', false), ('e1', true), ('e2', true),
            ('h', true), ('k', true) $$,
  'purge_exempt keeps g4, and email accounts (e1, e2) are never purged'
);

select results_eq(
  $$ select count(*)::int, count(*) filter (where aborted)::int from private.purge_runs
     where ran_at = now() $$,
  $$ values (3, 1) $$,
  'every run is logged, aborted or not'
);

select throws_ok(
  $$ select private.purge_inactive_anonymous(null) $$,
  '22023', null,
  'p_now is required'
);

select throws_ok(
  $$ select private.purge_inactive_anonymous(now(), -1) $$,
  '22023', null,
  'the cap cannot be negative'
);

select results_eq(
  $$ select rule_a_count, rule_b_count, aborted from private.purge_inactive_anonymous(now(), 0) $$,
  $$ select rule_a, rule_b, (rule_a + rule_b) > 0 from tests.other_matches(now()) $$,
  'a cap of 0 deletes nothing as soon as anything matches'
);

-- ---- the helper account is safe ---------------------------------------------
update public.profiles set last_active_at = now() - interval '500 days' where id = tests.uid('h');

select results_eq(
  $$ select rule_b_count from private.purge_inactive_anonymous(now(), 500) $$,
  $$ select rule_b from tests.other_matches(now()) $$,
  'an exempt anonymous account is never purged, however long it is inactive'
);

select ok(exists (select 1 from auth.users where id = tests.uid('h')), 'the helper account is still there');

-- ---- the purge keeps the anonymous-parity rule honest -----------------------
select is_empty(
  $$ select tablename, policyname from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ilike '%is_anonymous%' $$,
  'still no RLS policy mentions is_anonymous: anonymous accounts keep the same access'
);

select results_eq(
  $$ select p.oid::regprocedure::text from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
       and p.prosrc ilike '%is_anonymous%' $$,
  $$ values ('private.purge_inactive_anonymous(timestamp with time zone,integer)') $$,
  'the purge is the only function that tells anonymous accounts apart'
);

select * from finish();
rollback;
