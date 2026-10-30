-- Provenance and accounts (supabase/migrations/20261030030000_provenance_and_accounts.sql):
-- private profile columns and my_account, terms, suspension, the 150-friend
-- cap, the word filter (QR003), who added a quote (creator and edited-from,
-- server-owned on insert and update, kept through Undo, never forgeable),
-- retired usernames, add_catalog_quotes, save_from_favorite and
-- friend_favorites with favorites_visibility, and the publishing gate.
-- Review fixes: the word filter reads look-alike spellings (fullwidth and
-- styled letters, invisible characters, accents, Cyrillic and Greek
-- look-alikes, any separator inside a phrase) through one pattern for the
-- whole list; the friend cap is counted after the policies, so a refused
-- insert tells nothing; a verified favorite is saved without a creator; a
-- suspended account's favorites are hidden; quotes typed before choosing a
-- username are credited when the profile arrives; Undo tombstones cannot be
-- replaced by someone re-using the id, are capped at 200 per owner, purged
-- daily and lose a deleted account's name.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(120);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'd' then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    when 'e' then 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    when 'f' then 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    when 'h' then '44444444-4444-4444-8444-444444444444'
  end)::uuid
$$;

-- Target n (1-160): a user with the profile target_00n (the friend cap).
create function tests.target(n int) returns uuid language sql immutable as $$
  select ('10000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.create_user(id uuid, email text) returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
          email, '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now())
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

-- Back to the test runner's role (bypasses RLS) to inspect state.
create function tests.clear_authentication() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- The user has accepted the current terms (social writes need them).
create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- A quote's provenance as origin|creator|edited from ('-' for none), read with
-- definer rights so it works from any role.
create function tests.prov(n int) returns text language sql stable security definer as $$
  select origin || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
  from public.quotes where id = tests.qid(n)
$$;

-- The friend_favorites handle `viewer` gets for quote n.
create function tests.handle(n int, viewer text) returns uuid language sql immutable as $$
  select md5(tests.qid(n)::text || ':' || tests.uid(viewer)::text)::uuid
$$;

-- Everything a client can learn from a failed statement, as one string.
create function tests.error_of(statement text) returns text language plpgsql as $$
declare
  v_state text; v_message text; v_detail text; v_hint text; v_constraint text;
begin
  execute statement;
  return 'no error';
exception when others then
  get stacked diagnostics
    v_state = returned_sqlstate, v_message = message_text, v_detail = pg_exception_detail,
    v_hint = pg_exception_hint, v_constraint = constraint_name;
  return concat_ws(' | ', nullif(v_state, ''), nullif(v_message, ''), nullif(v_detail, ''),
                   nullif(v_hint, ''), nullif(v_constraint, ''));
end
$$;
-- ---------------------------------------------------------------------------

-- a, b, d, e and h have accepted the terms; c has a profile but no terms; f
-- has no profile. A and B are friends.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'h']) w;
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'),
  (tests.uid('d'), 'dan'), (tests.uid('e'), 'eve'), (tests.uid('h'), 'hal');
select tests.accept_terms(w) from unnest(array['a', 'b', 'd', 'e', 'h']) w;
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('a'), tests.uid('b'), 'accepted');

-- ---- profiles: only the public face is readable ---------------------------
select tests.authenticate_as('a');

select throws_ok($$ select last_active_at from public.profiles where id = tests.uid('a') $$,
  '42501', 'permission denied for table profiles', 'no client can read last_active_at, not even their own');
select throws_ok($$ select purge_exempt from public.profiles where id = tests.uid('a') $$,
  '42501', null, 'no client can read purge_exempt');
select throws_ok($$ select favorites_visibility from public.profiles where id = tests.uid('b') $$,
  '42501', null, 'no client can read a profile''s favorites_visibility');
select throws_ok($$ select terms_version, terms_accepted_at from public.profiles where id = tests.uid('a') $$,
  '42501', null, 'no client can read the terms columns');
select throws_ok($$ select * from public.profiles $$,
  '42501', null, 'select * on profiles is refused');

select results_eq(
  $$ select id, username, display_name, accepts_text_messages from public.profiles order by username $$,
  $$ values (tests.uid('a'), 'alice'::text, null::text, true), (tests.uid('b'), 'bob', null, true) $$,
  'the public columns of your own and linked profiles stay readable'
);

select results_eq(
  $$ select id, username, accepts_text_messages, favorites_visibility, terms_version, terms_accepted_at = now(),
            current_terms_version, is_suspended, can_publish
     from public.my_account() $$,
  $$ values (tests.uid('a'), 'alice'::text, true, 'private'::text, 1::smallint, true, 1::smallint, false, false) $$,
  'my_account returns the caller''s own private fields'
);

select is(
  (select string_agg(x, ',') from unnest((select proargnames from pg_proc where oid = 'public.my_account()'::regprocedure)) x),
  'id,username,display_name,accepts_text_messages,favorites_visibility,terms_version,terms_accepted_at,current_terms_version,is_suspended,can_publish',
  'my_account has exactly these columns (never last_active_at or purge_exempt)'
);

select results_eq(
  $$ update public.profiles set favorites_visibility = 'friends', accepts_text_messages = false
     where id = tests.uid('a') returning accepts_text_messages $$,
  $$ values (false) $$,
  'the owner can change favorites_visibility and accepts_text_messages'
);
select results_eq(
  $$ select favorites_visibility, accepts_text_messages from public.my_account() $$,
  $$ values ('friends'::text, false) $$,
  'and my_account shows the change'
);
update public.profiles set accepts_text_messages = true where id = tests.uid('a');

select throws_ok(
  $$ update public.profiles set favorites_visibility = 'public' where id = tests.uid('a') $$,
  '23514', null,
  'favorites are never public'
);

select throws_ok(
  $$ update public.profiles set terms_version = 1, terms_accepted_at = now() where id = tests.uid('a') $$,
  '42501', null,
  'a client cannot write the terms columns'
);

select tests.authenticate_as('f');
select is_empty($$ select * from public.my_account() $$, 'my_account is empty without a profile');
select throws_ok($$ select public.accept_terms(1::smallint) $$, 'P0002', null,
  'accepting the terms needs a profile');

-- ---- terms ----------------------------------------------------------------
select tests.clear_authentication();
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('e'), tests.uid('c'));
select tests.authenticate_as('a');
insert into public.friendships (addressee_id) values (tests.uid('c'));
select tests.authenticate_as('c');

select results_eq(
  $$ select terms_version, terms_accepted_at from public.my_account() $$,
  $$ values (null::smallint, null::timestamptz) $$,
  'a new account has not accepted the terms'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('d')) $$,
  '42501', 'Accept the Terms of use first.',
  'a friend request needs accepted terms'
);

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.uid('e')) $$),
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.uid('d')) $$),
  'without terms, a request to someone who blocked you fails exactly like any other'
);

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values ('99999999-9999-4999-8999-999999999999') $$),
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.uid('d')) $$),
  'and like one to an unknown user'
);

select throws_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('a') $$,
  '42501', 'Accept the Terms of use first.',
  'accepting a request needs accepted terms'
);

select throws_ok($$ select public.accept_terms(2::smallint) $$, '22023', 'Unknown terms version.',
  'only the current terms version can be accepted');

select lives_ok($$ select public.accept_terms(1::smallint) $$, 'C accepts the terms');

select results_eq(
  $$ select terms_version, terms_accepted_at = now() from public.my_account() $$,
  $$ values (1::smallint, true) $$,
  'accept_terms records the version and the server time'
);

select results_eq(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('a') returning status $$,
  $$ values ('accepted'::text) $$,
  'with terms accepted, C can accept'
);

select tests.clear_authentication();
select is((select (private.has_accepted_terms())), false, 'has_accepted_terms is false without a signed-in caller');

-- ---- suspension -----------------------------------------------------------
insert into private.suspensions (user_id, reason) values (tests.uid('c'), 'Spam in display names');
select tests.authenticate_as('d');
insert into public.friendships (addressee_id) values (tests.uid('c'));
select tests.authenticate_as('c');

select is((select is_suspended from public.my_account()), true, 'my_account tells a suspended user');

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('h')) $$,
  '42501', 'This account is suspended.',
  'a suspended account cannot send friend requests'
);

select throws_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('d') $$,
  '42501', 'This account is suspended.',
  'nor accept them'
);

select tests.clear_authentication();
select results_eq(
  $$ select has_table_privilege('authenticated', 'private.suspensions', 'select'),
            has_table_privilege('service_role', 'private.suspensions', 'select') $$,
  $$ values (false, false) $$,
  'no API role can read the suspensions'
);
delete from private.suspensions where user_id = tests.uid('c');

-- ---- 150 accepted friends (QR002) ------------------------------------------
-- H has 149 friends; targets 150 and 151 are waiting for H's answer.
select tests.create_user(tests.target(n), 'target' || n || '@test.quoted.invalid') from generate_series(1, 152) n;
insert into public.profiles (id, username)
  select tests.target(n), 'target_' || lpad(n::text, 3, '0') from generate_series(1, 152) n;
insert into public.friendships (requester_id, addressee_id, status)
  select tests.target(n), tests.uid('h'), 'accepted' from generate_series(1, 149) n;
insert into public.friendships (requester_id, addressee_id)
  values (tests.target(150), tests.uid('h')), (tests.target(151), tests.uid('h'));
-- E waits for an answer from H... the other way round: H asked E.
insert into public.friendships (requester_id, addressee_id) values (tests.uid('h'), tests.uid('e'));
select tests.authenticate_as('h');

select lives_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.target(150) $$,
  'H accepts their 150th friend'
);

select throws_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.target(151) $$,
  'QR002', 'Quoted keeps circles to 150 friends.',
  'a 151st accepted friend is refused with QR002'
);

select tests.authenticate_as('e');
select throws_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('h') $$,
  'QR002', 'Quoted keeps circles to 150 friends.',
  'accepting someone whose circle is full is refused too'
);

select tests.clear_authentication();
select throws_ok(
  $$ insert into public.friendships (requester_id, addressee_id, status) values (tests.target(152), tests.uid('h'), 'accepted') $$,
  'QR002', null,
  'the cap applies to the table owner too'
);

delete from public.friendships where requester_id = tests.target(1);
select tests.authenticate_as('h');
select lives_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.target(151) $$,
  'after an unfriend there is room again'
);
select tests.authenticate_as('d');
select throws_ok(
  $$ insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('d'), tests.uid('h'), 'accepted') $$,
  '42501', 'new row violates row-level security policy for table "friendships"',
  'an accepted-row insert the policy refuses is refused before the cap is counted: it tells nothing about H''s 150'
);

-- ---- word filter (QR003) ------------------------------------------------------
select tests.clear_authentication();
insert into private.blocked_terms (term) values ('darn'), ('heck no'), ('feathers');

select results_eq(
  $$ select t, private.has_blocked_term(t)
     from unnest(array['Darn it', 'well, DARN.', 'darning socks', 'undarn', 'oh heck no!', 'heck  no', 'heck-no',
                       'a_darn_name', '']) t $$,
  $$ values ('Darn it', true), ('well, DARN.', true), ('darning socks', false), ('undarn', false),
            ('oh heck no!', true), ('heck  no', true), ('heck-no', true), ('a_darn_name', true), ('', false) $$,
  'a blocked term matches as a whole word or phrase, in any case, never inside a longer word'
);
select is(private.has_blocked_term(null), false, 'null text holds no blocked term');
select results_eq(
  $$ select n::int, private.has_blocked_term(t)
     from unnest(array[
       U&'\FF24\FF41\FF52\FF4E it',
       U&'\+01D41D\+01D41A\+01D42B\+01D427',
       U&'da\200Brn it',
       U&'da\00ADrn',
       U&'d\200Darn',
       U&'d\0430rn',
       U&'D\00C1RN',
       U&'d\0301arn',
       U&'heck\00A0no',
       E'heck\nno',
       'heck - no',
       'heckno',
       'heck nothing',
       'dar n'
     ]) with ordinality as x (t, n) $$,
  $$ values (1, true), (2, true), (3, true), (4, true), (5, true), (6, true), (7, true), (8, true),
            (9, true), (10, true), (11, true), (12, true), (13, false), (14, false) $$,
  'look-alike spellings match: fullwidth and styled letters, zero-width and soft-hyphen characters, a Cyrillic a, accents, and any separator inside a phrase'
);
select is((select count(*)::int from private.blocked_term_pattern), 1, 'the whole list is kept as one pattern');
delete from private.blocked_terms where term = 'feathers';
select is(private.has_blocked_term('Hope is the thing with feathers'), false, 'the pattern follows the list when a term goes');
insert into private.blocked_terms (term) values ('feathers');
select is(private.has_blocked_term('Hope is the thing with feathers'), true, 'and when it comes back');

select throws_ok(
  $$ insert into private.blocked_terms (term) values ('Bad Word') $$,
  '23514', null,
  'blocked terms are stored lowercase'
);

select tests.authenticate_as('a');
select throws_ok(
  $$ update public.profiles set display_name = 'Darn Fan' where id = tests.uid('a') $$,
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'a display name with a blocked term is refused with QR003'
);
select throws_ok(
  $$ update public.profiles set display_name = U&'Da\200Brn Fan' where id = tests.uid('a') $$,
  'QR003', null,
  'so is one that hides it with a zero-width space'
);

select lives_ok(
  $$ insert into public.quotes (id, body) values (tests.qid(90), 'Darn it all, said nobody.') $$,
  'the private Library is never filtered'
);

select tests.authenticate_as('f');
select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('f'), 'darn_it') $$,
  'QR003', null,
  'a new username with a blocked term is refused'
);
select throws_ok(
  $$ insert into public.profiles (id, username, display_name) values (tests.uid('f'), 'fern', 'Oh heck no') $$,
  'QR003', null,
  'a new display name with a blocked term is refused'
);

-- A name the list catches later does not lock its owner out of other settings.
select tests.clear_authentication();
update public.profiles set display_name = 'Darn Bob' where id = tests.uid('b');
select tests.authenticate_as('b');
select lives_ok(
  $$ update public.profiles set accepts_text_messages = false where id = tests.uid('b') $$,
  'an unchanged display name is not re-checked, so privacy settings still change'
);
select tests.clear_authentication();
update public.profiles set display_name = null, accepts_text_messages = true where id = tests.uid('b');

-- ---- provenance on a direct insert --------------------------------------------
select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values
  (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(2), 'Beta', 'Ben'), (tests.qid(3), 'Gamma', 'Cy');
insert into public.quotes (id, body, origin) values (tests.qid(7), 'Pasted words', 'pasted');

select results_eq(
  $$ select tests.prov(1), tests.prov(7) $$,
  $$ values ('manual|alice|-', 'pasted|alice|-') $$,
  'a direct insert credits the caller, manual or pasted'
);

select throws_ok(
  $$ insert into public.quotes (body, origin) values ('From the catalog?', 'starter') $$,
  '42501', 'origin "starter" is set by the server',
  'a client cannot insert origin starter'
);
select throws_ok(
  $$ insert into public.quotes (body, origin) values ('From a friend?', 'shared') $$,
  '42501', 'origin "shared" is set by the server',
  'a client cannot insert origin shared'
);
select throws_ok(
  $$ insert into public.quotes (body, creator_id, creator_username) values ('Forged', tests.uid('b'), 'bob') $$,
  '42501', 'permission denied for table quotes',
  'a client cannot send a creator'
);
select throws_ok(
  $$ insert into public.quotes (body, edited_from_id, edited_from_username) values ('Forged', tests.uid('b'), 'bob') $$,
  '42501', null,
  'a client cannot send an edited-from'
);
select throws_ok(
  $$ insert into public.quotes (body, verified_starter_id) values ('Forged', 1) $$,
  '42501', null,
  'a client cannot send verified_starter_id'
);
select throws_ok(
  $$ update public.quotes set creator_id = tests.uid('b'), creator_username = 'bob' where id = tests.qid(1) $$,
  '42501', null,
  'a client cannot update the creator'
);
select throws_ok(
  $$ update public.quotes set edited_from_id = tests.uid('b'), edited_from_username = 'bob' where id = tests.qid(1) $$,
  '42501', null,
  'a client cannot update edited-from'
);
select throws_ok(
  $$ update public.quotes set origin = 'starter' where id = tests.qid(1) $$,
  '42501', null,
  'a client cannot update origin'
);

-- ---- friend_favorites and save_from_favorite ----------------------------------
-- A's favorites: 1-3 (A's own words), 4 (Dan's words, A holds a copy), 5 (the
-- catalog quote with "feathers", verified), 90 (unverified, blocked term).
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username)
  values (tests.qid(4), tests.uid('a'), 'Delta', 'shared', tests.uid('d'), 'dan');
select tests.authenticate_as('a');
select id from public.add_catalog_quotes(array[2]::integer[], array[tests.qid(5)]);
update public.quotes set is_favorite = true where id in (tests.qid(1), tests.qid(2), tests.qid(3), tests.qid(4), tests.qid(5), tests.qid(90));
select tests.authenticate_as('b');

select results_eq(
  $$ select body, verified_starter_id, creator_username, edited_from_username
     from public.friend_favorites(tests.uid('a')) order by body $$,
  $$ select body, verified_starter_id, creator_username, edited_from_username from (values
       ('Alpha'::text, null::integer, 'alice'::text, null::text), ('Beta', null, 'alice', null),
       ('Delta', null, 'dan', null), ('Gamma', null, 'alice', null),
       ((select body from public.starter_quotes where id = 2), 2::integer, null, null)
     ) v (body, verified_starter_id, creator_username, edited_from_username) order by body $$,
  'a friend sees creator usernames on unverified favorites, none on verified ones, and no unverified blocked term'
);

select results_eq(
  $$ select id, owner_id from public.save_from_favorite(tests.uid('a'), tests.handle(4, 'b'), tests.qid(41)) $$,
  $$ values (tests.qid(41), tests.uid('b')) $$,
  'B saves A''s favorite into B''s own Library'
);
select is(tests.prov(41), 'shared|dan|-', 'saving a favorite carries the creator, not the friend who favorited it');

select results_eq(
  $$ select id, (select count(*)::int from public.quotes where owner_id = tests.uid('b'))
     from public.save_from_favorite(tests.uid('a'), tests.handle(4, 'b'), tests.qid(41)) $$,
  $$ values (tests.qid(41), 1) $$,
  'a retry with the same id returns the saved quote and adds nothing'
);

select tests.clear_authentication();
insert into public.quotes (owner_id, body, rotation_position) values (tests.uid('b'), 'In reminders', 4);
select tests.authenticate_as('b');
select results_eq(
  $$ select rotation_position, verified_starter_id
     from public.save_from_favorite(tests.uid('a'), tests.handle(5, 'b'), tests.qid(42), true) $$,
  $$ values (5, 2::integer) $$,
  'p_in_reminders puts the saved quote at the end of the Reminders; a catalog favorite stays verified'
);

-- A typed catalog quote 1's exact wording (6): verified, and credited to A in
-- A's own Library. Saved by B, it is "Quoted Catalog" and names nobody.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source, is_favorite)
  select tests.qid(6), s.body, s.author, s.source, true from public.starter_quotes s where s.id = 1;
select tests.authenticate_as('b');
select results_eq(
  $$ select verified_starter_id, creator_id, edited_from_id
     from public.save_from_favorite(tests.uid('a'), tests.handle(6, 'b'), tests.qid(43)) $$,
  $$ values (1::integer, null::uuid, null::uuid) $$,
  'a verified favorite is saved with no creator: the name in A''s own row stays there'
);

select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(90, 'b')) $$,
  '42501', 'This quote is not available.',
  'a favorite friend_favorites hides (blocked term) cannot be saved'
);
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(4, 'c')) $$,
  '42501', 'This quote is not available.',
  'another viewer''s handle does not work'
);
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.qid(1)) $$,
  '42501', 'This quote is not available.',
  'the quote''s own id is not a handle'
);

select tests.authenticate_as('d');
select is((select count(*)::int from public.friend_favorites(tests.uid('a'))), 0, 'a non-friend sees no favorites');
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(1, 'd')) $$,
  '42501', 'This quote is not available.',
  'a non-friend cannot save a favorite'
);

select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'private' where id = tests.uid('a');
select tests.authenticate_as('b');
select is((select count(*)::int from public.friend_favorites(tests.uid('a'))), 0,
  'with favorites_visibility private a friend sees nothing');
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(1, 'b')) $$,
  '42501', 'This quote is not available.',
  'and cannot save one'
);
select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
select tests.clear_authentication();
insert into private.suspensions (user_id, reason) values (tests.uid('a'), 'test');
select tests.authenticate_as('b');
select is((select count(*)::int from public.friend_favorites(tests.uid('a'))), 0,
  'a suspended account''s favorites are held from friends, like its posts and playlists');
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(1, 'b')) $$,
  '42501', 'This quote is not available.',
  'and cannot be saved'
);
select tests.clear_authentication();
delete from private.suspensions where user_id = tests.uid('a');

-- ---- the edit rule -------------------------------------------------------------
select tests.authenticate_as('b');
select id from public.save_from_favorite(tests.uid('a'), tests.handle(1, 'b'), tests.qid(11));
select id from public.save_from_favorite(tests.uid('a'), tests.handle(2, 'b'), tests.qid(15));
select id from public.save_from_favorite(tests.uid('a'), tests.handle(3, 'b'), tests.qid(16));
select is(tests.prov(11), 'shared|alice|-', 'B''s saved copy is credited to A');

update public.quotes set body_format = '[{"start":0,"length":5,"bold":true}]' where id = tests.qid(11);
select is(tests.prov(11), 'shared|alice|-', 'a formatting-only edit keeps the creator');

update public.quotes set body = 'Alpha, my way' where id = tests.qid(11);
select is(tests.prov(11), 'shared|bob|alice', 'changing someone else''s words makes you the creator, edited from them');

update public.quotes set author = 'Anne' where id = tests.qid(11);
select is(tests.prov(11), 'shared|bob|alice', 'editing your own version changes nothing more');

select id from public.add_catalog_quotes(array[3]::integer[], array[tests.qid(12)]);
update public.quotes set author = 'M. Shelley' where id = tests.qid(12);
select is(tests.prov(12), 'starter|bob|-', 'editing a verified catalog quote makes you the creator with no edited-from');

select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, origin) values (tests.qid(13), tests.uid('b'), 'Old share', 'shared');
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username)
  values (tests.qid(14), tests.uid('b'), 'Upserted', 'shared', tests.uid('a'), 'alice');
select tests.authenticate_as('b');
update public.quotes set source = 'A letter' where id = tests.qid(13);
select is(tests.prov(13), 'shared|bob|-', 'editing a quote with an unknown creator makes you the creator');

insert into public.quotes (id, body) values (tests.qid(14), 'Upserted, changed')
  on conflict (id) do update set body = excluded.body;
select is(tests.prov(14), 'shared|bob|alice', 'an upsert that changes the words follows the same rule');

select tests.authenticate_as('a');
update public.quotes set body = 'Alpha!' where id = tests.qid(1);
select is(tests.prov(1), 'manual|alice|-', 'the creator editing their own quote changes nothing');

-- ---- Undo: tombstones -----------------------------------------------------------
select tests.authenticate_as('b');
delete from public.quotes where id = tests.qid(15);

select tests.authenticate_as('c');
select throws_ok(
  $$ insert into public.quotes (id, body, author, origin) values (tests.qid(15), 'Beta', 'Ben', 'shared') $$,
  '42501', 'origin "shared" is set by the server',
  'another user cannot take B''s tombstone'
);
insert into public.quotes (id, body, author) values (tests.qid(15), 'Beta', 'Ben');
select is(tests.prov(15), 'manual|cara|-', 'another user re-using the id gets only their own provenance');
select tests.clear_authentication();
select ok(exists (select 1 from private.quote_tombstones where id = tests.qid(15) and owner_id = tests.uid('b')),
  'B''s tombstone is untouched');
select tests.authenticate_as('c');
delete from public.quotes where id = tests.qid(15);
select tests.clear_authentication();
select results_eq(
  $$ select owner_id, origin, creator_username from private.quote_tombstones where id = tests.qid(15) $$,
  $$ values (tests.uid('b'), 'shared'::text, 'alice'::text) $$,
  'C deleting that id again leaves B''s tombstone in place: re-using a deleted id cannot spoil its owner''s Undo'
);

select tests.authenticate_as('b');
select lives_ok(
  $$ insert into public.quotes (id, body, author, origin, rotation_position, is_favorite)
     values (tests.qid(15), 'Beta', 'Ben', 'shared', null, false) $$,
  'B''s Undo re-inserts the quote with origin shared, as the app sends it'
);
select is(tests.prov(15), 'shared|alice|-', 'Undo (same id and words) restores origin and creator');
select is_empty($$ select 1 from public.quotes where id = tests.qid(15) and owner_id <> tests.uid('b') $$,
  'the restored row is B''s');

delete from public.quotes where id = tests.qid(16);
insert into public.quotes (id, body, author, origin) values (tests.qid(16), 'Words Alice never wrote', 'Cy', 'shared');
select is(tests.prov(16), 'shared|bob|alice',
  'an Undo with new words cannot put them under the old creator: it follows the edit rule');

select id from public.add_catalog_quotes(array[4]::integer[], array[tests.qid(18)]);
delete from public.quotes where id = tests.qid(18);
insert into public.quotes (id, body, author, origin)
  select tests.qid(18), body, 'Lucius Annaeus Seneca', 'starter' from public.starter_quotes where id = 4;
select is(tests.prov(18), 'starter|bob|-', 'an Undo with new words of a verified quote has no edited-from');

delete from public.quotes where id = tests.qid(41);
select tests.clear_authentication();
update private.quote_tombstones set deleted_at = now() - interval '25 hours' where id = tests.qid(41);
select tests.authenticate_as('b');
select throws_ok(
  $$ insert into public.quotes (id, body, origin) values (tests.qid(41), 'Delta', 'shared') $$,
  '42501', null,
  'a tombstone older than a day is not taken'
);

select tests.clear_authentication();
select is_empty($$ select 1 from private.quote_tombstones where id in (tests.qid(15), tests.qid(16), tests.qid(18)) $$,
  'a restore uses up its tombstone');
delete from public.quotes where id = tests.qid(42);
select is_empty($$ select 1 from private.quote_tombstones where id = tests.qid(42) $$,
  'a delete by the table owner (no signed-in owner) leaves no tombstone');

-- ---- tombstones: at most 200 per owner, purged daily ------------------------------
insert into public.quotes (id, owner_id, body)
  select ('20000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, tests.uid('e'), 'Churn ' || n
  from generate_series(1, 205) n;
select tests.authenticate_as('e');
delete from public.quotes where body like 'Churn %';
select tests.clear_authentication();
select is((select count(*)::int from private.quote_tombstones where owner_id = tests.uid('e')), 200,
  'an owner keeps at most 200 tombstones, however many quotes they delete');
update private.quote_tombstones set deleted_at = now() - interval '25 hours'
 where id in (select id from private.quote_tombstones where owner_id = tests.uid('e') order by id limit 150);
select private.purge_quote_tombstones();
select is((select count(*)::int from private.quote_tombstones where deleted_at <= now() - interval '1 day'), 0,
  'the daily purge leaves no tombstone older than a day');
select is((select count(*)::int from private.quote_tombstones where owner_id = tests.uid('e')), 50,
  'and keeps the recent ones');
select results_eq(
  $$ select jobname::text, schedule::text, command::text, active from cron.job where jobname = 'purge-quote-tombstones' $$,
  $$ values ('purge-quote-tombstones', '43 3 * * *', 'select private.purge_quote_tombstones()', true) $$,
  'pg_cron purges quote tombstones daily at 03:43'
);

-- ---- deleting the creator's account ---------------------------------------------
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username, edited_from_id, edited_from_username)
  values (tests.qid(19), tests.uid('b'), 'Eve''s words, edited', 'shared', tests.uid('b'), 'bob', tests.uid('e'), 'eve'),
         (tests.qid(20), tests.uid('b'), 'Eve''s words', 'shared', tests.uid('e'), 'eve', null, null),
         (tests.qid(21), tests.uid('b'), 'Eve''s other words', 'shared', tests.uid('e'), 'eve', null, null);
select tests.authenticate_as('b');
delete from public.quotes where id = tests.qid(21);
select tests.clear_authentication();
delete from auth.users where id = tests.uid('e');

select results_eq(
  $$ select id, creator_id, creator_username, edited_from_id, edited_from_username from public.quotes
     where id in (tests.qid(19), tests.qid(20)) order by id $$,
  $$ values (tests.qid(19), tests.uid('b'), 'bob'::text, null::uuid, null::text),
            (tests.qid(20), null, null, null, null) $$,
  'deleting an account clears both columns of its pair on everyone else''s copies'
);
select is((select body from public.quotes where id = tests.qid(20)), 'Eve''s words', 'the copy keeps its text');
select results_eq(
  $$ select creator_id, creator_username from private.quote_tombstones where id = tests.qid(21) $$,
  $$ values (null::uuid, null::text) $$,
  'and B''s Undo tombstone of a quote Eve added no longer names her'
);

-- ---- quotes typed before choosing a username ----------------------------------------
-- F has no profile yet: F's typed quote has no creator. A shared copy whose
-- creator is unknown (80, 81) stays that way when F's profile arrives.
select tests.authenticate_as('f');
insert into public.quotes (id, body) values (tests.qid(80), 'Typed before a name');
select is(tests.prov(80), 'manual|-|-', 'a quote typed before choosing a username has no creator yet');
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, origin) values (tests.qid(81), tests.uid('f'), 'Someone''s words', 'shared');

-- ---- retired usernames ------------------------------------------------------------
select ok(exists (select 1 from private.retired_usernames where username = 'eve'), 'a deleted profile retires its username');
select tests.authenticate_as('f');
select results_eq(
  $$ select public.is_username_available('eve'), public.is_username_available(' @EVE ') $$,
  $$ values (false, false) $$,
  'is_username_available says a retired name is not available'
);
select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('f'), 'eve') $$,
  '23505', 'username "eve" is reserved',
  'a retired username cannot be claimed (reported as taken)'
);
select tests.clear_authentication();
select lives_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('f'), 'eve') $$,
  'the founder can still give a retired name back from the SQL editor'
);
select results_eq(
  $$ select tests.prov(80), tests.prov(81) $$,
  $$ values ('manual|eve|-'::text, 'shared|-|-'::text) $$,
  'once F has a profile, the quotes F typed before are credited to F; a copy of someone else''s words is not'
);

-- ---- add_catalog_quotes -------------------------------------------------------------
select tests.authenticate_as('d');
insert into public.quotes (body, rotation_position) values ('Dan''s first', 0);

select results_eq(
  $$ select id, owner_id, origin, creator_id, verified_starter_id, rotation_position
     from public.add_catalog_quotes(array[1, 2]::integer[], array[tests.qid(31), tests.qid(32)], true) $$,
  $$ values (tests.qid(31), tests.uid('d'), 'starter'::text, null::uuid, 1::integer, 1),
            (tests.qid(32), tests.uid('d'), 'starter', null, 2::integer, 2) $$,
  'catalog quotes come back in order: origin starter, no creator, verified, at the end of the Reminders'
);

select results_eq(
  $$ select id, rotation_position from public.add_catalog_quotes(array[1, 2]::integer[], array[tests.qid(31), tests.qid(32)], true) $$,
  $$ values (tests.qid(31), 1), (tests.qid(32), 2) $$,
  'a retry with the same ids returns the same quotes'
);
select is((select count(*)::int from public.quotes), 3, 'and adds nothing');

select results_eq(
  $$ select origin, creator_id, rotation_position, verified_starter_id from public.add_catalog_quotes(array[3]::integer[]) $$,
  $$ values ('starter'::text, null::uuid, null::integer, 3::integer) $$,
  'without ids or reminders the server picks the id and leaves it out of the Reminders'
);

select throws_ok(
  $$ select * from public.add_catalog_quotes(array[32767]::integer[]) $$,
  '23503', null,
  'an unknown catalog id is refused with 23503'
);
select throws_ok(
  $$ select * from public.add_catalog_quotes(array[1, 2]::integer[], array[tests.qid(33)]) $$,
  '22023', null,
  'p_ids needs one id per catalog id'
);

select tests.authenticate_as('c');
select throws_ok(
  $$ select * from public.add_catalog_quotes(array[1]::integer[], array[tests.qid(31)]) $$,
  '23505', null,
  'an id that belongs to someone else fails like the primary key'
);
select throws_ok(
  $$ select public.save_from_favorite(tests.uid('a'), tests.handle(1, 'c'), tests.qid(31)) $$,
  '23505', null,
  'so does a save_from_favorite retry id'
);
select is_empty($$ select 1 from public.quotes where id = tests.qid(31) $$, 'and C still cannot read D''s quote');

select tests.clear_authentication();
set local role anon;
select throws_ok($$ select * from public.add_catalog_quotes(array[1]::integer[]) $$, '42501', null,
  'anon cannot add catalog quotes');
select tests.clear_authentication();

-- ---- the publishing gate ------------------------------------------------------------
select tests.authenticate_as('a');
select is((select can_publish from public.my_account()), false,
  'terms accepted but no Apple identity: cannot publish');
select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple'),
         ('apple-sub-cara', tests.uid('c'), '{}', 'apple');
select tests.authenticate_as('a');
select is((select can_publish from public.my_account()), true, 'with a linked Apple identity A can publish');
select tests.clear_authentication();
insert into private.suspensions (user_id, reason) values (tests.uid('c'), 'test');
select tests.authenticate_as('c');
select is((select can_publish from public.my_account()), false, 'a suspended account cannot publish');
select tests.authenticate_as('h');
select is((select can_publish from public.my_account()), false, 'nor one without an Apple identity');
select tests.clear_authentication();

-- ---- schema details ----------------------------------------------------------------
select results_eq(
  $$ select t.tgname::text collate "default", case when t.tgtype & 2 = 2 then 'BEFORE' else 'AFTER' end, p.prosecdef
     from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgname in ('quotes_set_provenance', 'quotes_apply_edit_rule', 'quotes_keep_tombstone',
                        'profiles_retire_username', 'profiles_credit_own_quotes', 'profiles_clear_tombstone_names',
                        'friendships_check_terms', 'friendships_enforce_friend_cap', 'blocked_terms_build_pattern')
     order by 1 $$,
  $$ values ('blocked_terms_build_pattern', 'AFTER', false),
            ('friendships_check_terms', 'BEFORE', false), ('friendships_enforce_friend_cap', 'AFTER', true),
            ('profiles_clear_tombstone_names', 'AFTER', true), ('profiles_credit_own_quotes', 'AFTER', true),
            ('profiles_retire_username', 'AFTER', true), ('quotes_apply_edit_rule', 'BEFORE', false),
            ('quotes_keep_tombstone', 'BEFORE', true), ('quotes_set_provenance', 'BEFORE', false) $$,
  'client-guard triggers run as the writer; the bookkeeping triggers have definer rights; the friend cap runs after the policies'
);

select results_eq(
  $$ select count(*)::int from private.blocked_terms where term not in ('darn', 'heck no', 'feathers') $$,
  $$ values (0) $$,
  'the word list ships empty (only this test''s terms are in it)'
);

select * from finish();
rollback;
