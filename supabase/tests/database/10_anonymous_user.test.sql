-- An anonymous sign-in (what the app creates on first launch now that it has
-- no sign-in screen) gets exactly the access of an email account: every policy
-- keys on auth.uid() and the authenticated role, never on how the user signed
-- in. G is that user: an auth.users row with is_anonymous and no email, and a
-- JWT with is_anonymous true and amr "anonymous". B and C are email users.
-- The helpers say "guest" because "anon" means the anon role (see 04).
-- Social writes need accepted terms (20261030030000_provenance_and_accounts):
-- G accepts them through public.accept_terms like any account.
-- Ported to 20261030030300_conversations_and_messages: shares became messages
-- in a conversation G opens with open_conversation; B's share to G became a
-- text (clients no longer send snapshots), so the report keeps it in
-- content_note; "seen and saved" became G's read mark; a block now closes the
-- conversation and deletes no message. Reporters no longer read the server's
-- copy back (column grants), so G's report is read with definer rights
-- (tests.own_reports). Removed: none.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(46);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'g' then 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
  end)::uuid
$$;

create function tests.create_user(who text) returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', tests.uid(who), 'authenticated', 'authenticated',
          who || '@test.quoted.invalid', '', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now())
  returning id
$$;

-- The row Auth writes for signInAnonymously(): no email, no identity.
create function tests.create_guest_user() returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, is_anonymous, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', tests.uid('g'), 'authenticated', 'authenticated',
          null, '', null, '{}', '{}', true, now(), now())
  returning id
$$;

-- Act as a signed-in email user: role authenticated plus JWT claims, transaction-local.
create function tests.authenticate_as(who text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(who), 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$$;

-- Act as G with the claims of an anonymous session.
create function tests.authenticate_as_guest() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid('g'), 'role', 'authenticated', 'aud', 'authenticated',
                      'email', '', 'phone', '', 'is_anonymous', true,
                      'amr', json_build_array(json_build_object('method', 'anonymous',
                                                                'timestamp', extract(epoch from now())::bigint)),
                      'app_metadata', '{}'::json, 'user_metadata', '{}'::json)::text, true);
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

-- The caller's own reports with every column, read with definer rights:
-- reporters may not select the server's copy (20261030030300), so the tests
-- read it as the founder does.
create function tests.own_reports() returns setof public.reports language sql stable security definer as $$
  select * from public.reports where reporter_id = auth.uid()
$$;

-- The user has accepted the current terms (social writes need them).
create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;
-- G and B's conversation, read with definer rights.
create function tests.gb() returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid('g'), tests.uid('b')) and c.user_b = greatest(tests.uid('g'), tests.uid('b'))
$$;
-- ---------------------------------------------------------------------------

-- B has a profile and a quote in their Rotation. C has no profile yet. G has
-- nothing but the auth user.
select tests.create_user('b');
select tests.create_user('c');
select tests.create_guest_user();
insert into public.profiles (id, username) values (tests.uid('b'), 'bob');
select tests.accept_terms('b');
insert into public.quotes (id, owner_id, body, rotation_position)
values ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B quote', 0);

create table tests.starter_pack as select count(*)::int as size from public.starter_quotes;
grant select on tests.starter_pack to authenticated;
-- events are anonymous, so this test's rows are the ones above the current max id.
create table tests.baseline as select coalesce(max(id), 0) as max_event_id from public.events;

select results_eq(
  $$ select is_anonymous, email is null, aud::text, role::text from auth.users where id = tests.uid('g') $$,
  $$ values (true, true, 'authenticated', 'authenticated') $$,
  'G is an anonymous auth user with no email and the authenticated role'
);

-- ---- session and starter pack ---------------------------------------------
select tests.authenticate_as_guest();

select results_eq(
  $$ select auth.uid(), current_user::text collate "default", (auth.jwt() ->> 'is_anonymous')::boolean,
            auth.jwt() -> 'amr' -> 0 ->> 'method', auth.jwt() ->> 'email' $$,
  $$ values (tests.uid('g'), 'authenticated', true, 'anonymous', '') $$,
  'G''s session is an anonymous one running as authenticated'
);

select results_eq(
  $$ select (select count(*)::int from public.profiles where id = auth.uid()),
            (select count(*)::int from public.starter_quotes) $$,
  $$ select 0, size from tests.starter_pack $$,
  'with no profile yet, G reads the whole starter pack'
);

-- ---- profiles -------------------------------------------------------------
select lives_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('g'), 'quiet_reader') $$,
  'G can create their own profile'
);

select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('c'), 'not_cara') $$,
  '42501', null,
  'G cannot create a profile for another user id'
);

select results_eq(
  $$ update public.profiles set display_name = 'Quiet Reader' where id = tests.uid('g') returning display_name $$,
  $$ values ('Quiet Reader') $$,
  'G can update their own profile'
);

select is_empty(
  $$ update public.profiles set display_name = 'Hacked' where id = tests.uid('b') returning 1 $$,
  'G cannot update B''s profile'
);

-- ---- quotes and the Rotation ----------------------------------------------
select lives_ok(
  $$ insert into public.quotes (id, body, author, body_format) values
       ('e0000000-0000-4000-8000-000000000001', 'First', 'Gail', '[{"start":0,"length":5,"bold":true}]'),
       ('e0000000-0000-4000-8000-000000000002', 'Second', null, '[]') $$,
  'G can create quotes (owner_id defaults to auth.uid())'
);

select results_eq(
  $$ select count(*)::int, bool_and(owner_id = tests.uid('g')) from public.quotes $$,
  $$ values (2, true) $$,
  'G sees only their own quotes'
);

select results_eq(
  $$ update public.quotes set body = 'First, edited' where id = 'e0000000-0000-4000-8000-000000000001' returning body $$,
  $$ values ('First, edited') $$,
  'G can edit their own quote'
);

select results_eq(
  $$ select id, rotation_position
     from public.set_rotation(array['e0000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000001',
                                    'b0000000-0000-4000-8000-000000000001']::uuid[], '{}')
     order by rotation_position $$,
  $$ values ('e0000000-0000-4000-8000-000000000002'::uuid, 0), ('e0000000-0000-4000-8000-000000000001'::uuid, 1) $$,
  'G can set their Rotation; B''s id in the list is skipped'
);

select results_eq(
  $$ delete from public.quotes where id = 'e0000000-0000-4000-8000-000000000002' returning body $$,
  $$ values ('Second') $$,
  'G can delete their own quote'
);

select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('b') $$,
  'G cannot read B''s quotes'
);

select is_empty(
  $$ update public.quotes set body = 'Hacked' where id = 'b0000000-0000-4000-8000-000000000001' returning 1 $$,
  'G cannot update B''s quotes'
);

select throws_ok(
  $$ insert into public.quotes (owner_id, body) values (tests.uid('b'), 'planted') $$,
  '42501', null,
  'G cannot create a quote owned by B'
);

-- ---- friendship with an email user ----------------------------------------
select lives_ok(
  $$ select public.accept_terms(1::smallint) $$,
  'G accepts the terms of use'
);

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('b')) $$,
  'G can send B a friend request'
);

select tests.authenticate_as('b');

select results_eq(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('g')
     returning status, responded_at is not null $$,
  $$ values ('accepted', true) $$,
  'B accepts G''s request'
);

select results_eq(
  $$ select username, display_name from public.profiles where id = tests.uid('g') $$,
  $$ values ('quiet_reader', 'Quiet Reader') $$,
  'B can read G''s username and display name'
);

select tests.authenticate_as_guest();

select results_eq(
  $$ select requester_id, addressee_id, status from public.friendships $$,
  $$ values (tests.uid('g'), tests.uid('b'), 'accepted') $$,
  'G sees the accepted friendship'
);

-- ---- messages both ways -----------------------------------------------------
select public.open_conversation(tests.uid('b'));

select lives_ok(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id, note)
     values ('5e000000-0000-4000-8000-000000000001', tests.gb(), 'quote',
             'e0000000-0000-4000-8000-000000000001', 'for you') $$,
  'G can send their own quote to friend B'
);

select tests.authenticate_as('b');

select results_eq(
  $$ select sender_id, body, author, creator_username, note from public.messages where id = '5e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.uid('g'), 'First, edited'::text, 'Gail'::text, 'quiet_reader'::text, 'for you'::text) $$,
  'B sees the message from G, credited to G'
);

select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('g') $$,
  'receiving G''s quote does not expose G''s quotes to B'
);

select lives_ok(
  $$ insert into public.messages (id, conversation_id, kind, text)
     values ('5b000000-0000-4000-8000-000000000001', tests.gb(), 'text', 'From B') $$,
  'B can text G'
);

select tests.authenticate_as_guest();

select results_eq(
  $$ select sender_id, text from public.messages where sender_id <> tests.uid('g') $$,
  $$ values (tests.uid('b'), 'From B') $$,
  'G sees the text from B'
);

select results_eq(
  $$ update public.conversation_members set last_read_at = now()
     where conversation_id = tests.gb()
     returning user_id, last_read_at = now() $$,
  $$ values (tests.uid('g'), true) $$,
  'G can mark the conversation read'
);

-- ---- report and block -----------------------------------------------------
select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason, details)
     values ('7e000000-0000-4000-8000-000000000001', '5b000000-0000-4000-8000-000000000001', tests.uid('b'),
             'harassment', 'unwanted') $$,
  'G can report the text from B'
);

select results_eq(
  $$ select reporter_id, reported_username, content_note, content_verified
     from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.uid('g'), 'bob'::text, 'From B'::text, true) $$,
  'the report names G as reporter and keeps a verified copy of B''s text'
);

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('b')) $$,
  'G can block B'
);

select results_eq(
  $$ select blocker_id, blocked_id from public.blocks $$,
  $$ values (tests.uid('g'), tests.uid('b')) $$,
  'G sees their block'
);

select tests.clear_authentication();

select is_empty(
  $$ select 1 from public.friendships
     where least(requester_id, addressee_id) = least(tests.uid('g'), tests.uid('b'))
       and greatest(requester_id, addressee_id) = greatest(tests.uid('g'), tests.uid('b'))
     union all
     select 1 from public.conversations where id = tests.gb() and closed_at is null
     union all
     select 1 where (select count(*) from public.messages where conversation_id = tests.gb()) <> 2 $$,
  'the block removed the G-B friendship and closed the conversation, keeping both messages'
);

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('g')) $$,
  '23503', null,
  'B (blocked) cannot send G a request (it fails like an unknown username)'
);

select is_empty(
  $$ select 1 from public.blocks $$,
  'B cannot see that G blocked them'
);

select is_empty(
  $$ select 1 from public.reports $$,
  'B cannot read G''s report'
);

-- ---- events ---------------------------------------------------------------
select tests.authenticate_as_guest();

select lives_ok(
  $$ insert into public.events (name) values ('web_search_tap') $$,
  'G can log a web_search_tap event'
);

select tests.clear_authentication();

select is(
  (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)),
  1,
  'G''s event is stored'
);

-- ---- deleting G's auth user (delete account) ------------------------------
-- C joins as a friend of G with messages both ways, so every table has a G row.
insert into public.profiles (id, username) values (tests.uid('c'), 'cara');
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('c'), tests.uid('g'), 'accepted');
insert into public.conversations (id, user_a, user_b) values
  ('c0a00000-0000-4000-8000-0000000000cc', tests.uid('c'), tests.uid('g'));
insert into public.conversation_members (conversation_id, user_id) values
  ('c0a00000-0000-4000-8000-0000000000cc', tests.uid('c')), ('c0a00000-0000-4000-8000-0000000000cc', tests.uid('g'));
insert into public.messages (id, conversation_id, sender_id, kind, text) values
  ('5e000000-0000-4000-8000-000000000002', 'c0a00000-0000-4000-8000-0000000000cc', tests.uid('g'), 'text', 'G to C'),
  ('5c000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000cc', tests.uid('c'), 'text', 'C to G');

select lives_ok(
  $$ delete from auth.users where id = tests.uid('g') $$,
  'deleting G''s auth user succeeds'
);

select is_empty($$ select 1 from public.profiles where id = tests.uid('g') $$, 'G''s profile is gone');
select is_empty($$ select 1 from public.quotes where owner_id = tests.uid('g') $$, 'G''s quotes are gone');
select is_empty(
  $$ select 1 from public.friendships where tests.uid('g') in (requester_id, addressee_id) $$,
  'G''s friendships are gone'
);
select is_empty($$ select 1 from public.blocks where tests.uid('g') in (blocker_id, blocked_id) $$, 'G''s blocks are gone');
select is_empty(
  $$ select 1 from public.conversations where tests.uid('g') in (user_a, user_b)
     union all select 1 from public.messages where sender_id = tests.uid('g') or id = '5c000000-0000-4000-8000-000000000001' $$,
  'G''s conversations and every message in them are gone'
);

select results_eq(
  $$ select reporter_id is null, reported_user_id, content_note, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (true, tests.uid('b'), 'From B'::text, true) $$,
  'G''s report survives without G''s id, still about B and still verified'
);

select results_eq(
  $$ select (select count(*)::int from public.profiles where id in (tests.uid('b'), tests.uid('c'))),
            (select rotation_position from public.quotes where id = 'b0000000-0000-4000-8000-000000000001'),
            (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)) $$,
  $$ values (2, 0, 1) $$,
  'B and C keep their profiles, B''s quote keeps its Rotation place, and the event remains'
);

-- ---- no rule tells anonymous users apart ----------------------------------
-- Restricting anonymous accounts later must be a deliberate change to this test.
select is_empty(
  $$ select tablename, policyname from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ilike '%is_anonymous%' $$,
  'no RLS policy mentions is_anonymous'
);

-- The one deliberate exception is retention, not access: the daily purge of
-- abandoned anonymous accounts (council decision 2026-10-21, migration
-- 20261021090000), which no API role can execute (12_profile_privacy_cleanup).
select is_empty(
  $$ select p.oid::regprocedure from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
       and p.prosrc ilike '%is_anonymous%'
       and p.oid <> 'private.purge_inactive_anonymous(timestamptz, integer)'::regprocedure $$,
  'no public or private function mentions is_anonymous, apart from the anonymous-account purge'
);

select * from finish();
rollback;
