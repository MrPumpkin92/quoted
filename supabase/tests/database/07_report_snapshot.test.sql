-- reports keep a copy of the reported content: copied from the target by
-- trigger (client values ignored, content_verified = true), kept as sent for a
-- profile report (content_verified = false), and still there after a block or
-- after the target is gone.
-- Ported to 20261030030300_conversations_and_messages: shares became messages
-- and reports.share_id became message_id; the trigger is now
-- reports_snapshot_target, which also fills content_note and covers posts,
-- playlists and Quoted Catalog quotes (wrong_wording) too.
-- Changed with the model:
--   * the trigger runs with definer rights (it was SECURITY INVOKER): a
--     member may report a message after the other member blocked them, and a
--     stranger a public post, neither of which they can read any more; the
--     insert policy still decides who may file the row, after the copy;
--   * a block deletes no message, so after it the report keeps message_id;
--     "a deleted share can no longer be referenced" now deletes the message
--     itself (the founder, in the SQL editor) first;
--   * reporters no longer read the server's copy back (column grants): it
--     may come from a message they can no longer read. The tests read it with
--     definer rights (tests.own_reports), and "B reads their own snapshots"
--     became "B's reports keep their snapshots" plus a 42501.
-- Removed: none. Added: content_note, and the snapshot and visibility rules of
-- post, playlist and catalog reports (the founder's queue and auto-hold are in
-- 20_reports_moderation).
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(50);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'd' then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
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

-- The caller's own reports with every column, read with definer rights:
-- reporters may not select the server's copy (20261030030300), so the tests
-- read it as the founder does.
create function tests.own_reports() returns setof public.reports language sql stable security definer as $$
  select * from public.reports where reporter_id = auth.uid()
$$;

-- A conversation between two users with both member rows, as the server makes it.
create function tests.converse(x text, y text) returns uuid language sql as $$
  with c as (
    insert into public.conversations (user_a, user_b)
    values (least(tests.uid(x), tests.uid(y)), greatest(tests.uid(x), tests.uid(y)))
    returning id
  ), m as (
    insert into public.conversation_members (conversation_id, user_id)
    select c.id, u from c, unnest(array[tests.uid(x), tests.uid(y)]) u
  )
  select id from c
$$;
-- ---------------------------------------------------------------------------

-- A and B are friends; A sent B five messages. C and D are strangers to the
-- pair. D sent C one message (for the service-role check). A also has a post
-- and two playlists.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted');
create table tests.ids as select tests.converse('a', 'b') as ab, tests.converse('c', 'd') as cd;
insert into public.playlists (id, owner_id, title, visibility) values
  ('91000000-0000-4000-8000-000000000001', tests.uid('a'), 'A''s mornings', 'friends'),
  ('91000000-0000-4000-8000-000000000002', tests.uid('a'), 'A''s secret', 'private');
-- Snapshots supplied by the server, as the move of shares wrote them.
insert into public.messages (id, conversation_id, sender_id, kind, body, author, source, note)
select v.id::uuid, (select ab from tests.ids), tests.uid('a'), 'quote', v.body, v.author, v.source, v.note
from (values
  ('5a000000-0000-4000-8000-000000000001', 'A quote', 'Ann', 'Notebook', 'for you'),
  ('5a000000-0000-4000-8000-000000000002', 'Plain quote', null, null, null),
  -- A third copy of message 1, because a reporter can file only one report
  -- per reported user and message (reports_reporter_reported_target_key).
  ('5a000000-0000-4000-8000-000000000003', 'A quote', 'Ann', 'Notebook', 'for you')
) v (id, body, author, source, note);
insert into public.messages (id, conversation_id, sender_id, kind, text) values
  ('5a000000-0000-4000-8000-000000000004', (select ab from tests.ids), tests.uid('a'), 'text', 'Hey, a text');
insert into public.messages (id, conversation_id, sender_id, kind, playlist_id) values
  ('5a000000-0000-4000-8000-000000000005', (select ab from tests.ids), tests.uid('a'), 'playlist',
   '91000000-0000-4000-8000-000000000001');
insert into public.messages (id, conversation_id, sender_id, kind, body, author) values
  ('5d000000-0000-4000-8000-000000000001', (select cd from tests.ids), tests.uid('d'), 'quote', 'D to C', 'Dee');
insert into public.quotes (id, owner_id, body) values ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'Posted words');
insert into public.posts (id, author_id, source_quote_id, caption) values
  ('80000000-0000-4000-8000-000000000001', tests.uid('a'), 'a0000000-0000-4000-8000-000000000001', 'My caption');

-- ---- schema ---------------------------------------------------------------
select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'reports' and column_name like 'content\_%'
     order by ordinal_position $$,
  $$ values
       ('content_body', 'text', 'YES', null::text),
       ('content_author', 'text', 'YES', null),
       ('content_source', 'text', 'YES', null),
       ('content_verified', 'boolean', 'NO', 'false'),
       ('content_note', 'text', 'YES', null) $$,
  'reports has nullable content_body, content_author, content_source and content_note, and content_verified'
);

select has_trigger('public', 'reports', 'reports_snapshot_target', 'reports has the snapshot trigger');

select is_definer(
  'private', 'reports_snapshot_target', array[]::text[],
  'the snapshot trigger runs with definer rights (a reporter may no longer read what they report)'
);

select results_eq(
  $$ select string_agg(privilege_type, ',' order by privilege_type)::text collate "default"
     from information_schema.role_table_grants
     where grantee = 'authenticated' and table_schema = 'public' and table_name = 'reports' $$,
  $$ values ('INSERT') $$,
  'authenticated inserts reports and reads them only column by column'
);

-- ---- snapshot copied from the message ---------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  'B reports a message from A without sending a snapshot'
);

select results_eq(
  $$ select content_body, content_author, content_source, content_note, content_verified from tests.own_reports()
     where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values ('A quote'::text, 'Ann'::text, 'Notebook'::text, 'for you'::text, true) $$,
  'the snapshot (and the note) is copied from the message and marked verified'
);

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason, content_body, content_author, content_source, content_note, content_verified)
     values ('7e000000-0000-4000-8000-000000000002', '5a000000-0000-4000-8000-000000000002', tests.uid('a'), 'harassment',
             'Something A never said', 'Mallory', 'Made up', 'Invented note', false) $$,
  'B reports a message from A with a forged snapshot'
);

select results_eq(
  $$ select content_body, content_author, content_source, content_note from tests.own_reports()
     where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values ('Plain quote'::text, null::text, null::text, null::text) $$,
  'forged content is overwritten with the message''s, including null author, source and note'
);

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason, content_body, content_author, content_source, content_note)
     values ('7e000000-0000-4000-8000-000000000003', '5a000000-0000-4000-8000-000000000003', tests.uid('a'), 'other',
             repeat('x', 5000), repeat('y', 500), repeat('z', 500), repeat('n', 2000)) $$,
  'an oversized client snapshot is replaced before the length checks run'
);

select results_eq(
  $$ select content_body, content_author, content_source from tests.own_reports()
     where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values ('A quote'::text, 'Ann'::text, 'Notebook'::text) $$,
  'the oversized snapshot became the message''s content'
);

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000008', '5a000000-0000-4000-8000-000000000004', tests.uid('a'), 'harassment') $$,
  'B reports a text message'
);

select results_eq(
  $$ select content_body, content_note, content_verified from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000008' $$,
  $$ values (null::text, 'Hey, a text'::text, true) $$,
  'a text message''s words go to content_note'
);

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000009', '5a000000-0000-4000-8000-000000000005', tests.uid('a'), 'spam') $$,
  'B reports a playlist message'
);

select results_eq(
  $$ select content_body, content_note, content_verified from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000009' $$,
  $$ values (null::text, 'A''s mornings'::text, true) $$,
  'a playlist message''s title goes to content_note'
);

-- ---- posts, playlists and catalog quotes ------------------------------------------
select lives_ok(
  $$ insert into public.reports (id, post_id, reported_user_id, reason, content_body)
     values ('7e000000-0000-4000-8000-00000000000a', '80000000-0000-4000-8000-000000000001', tests.uid('a'), 'copyright', 'forged') $$,
  'B reports A''s post (and copyright is a reason)'
);

select results_eq(
  $$ select content_body, content_note, content_verified from tests.own_reports() where id = '7e000000-0000-4000-8000-00000000000a' $$,
  $$ values ('Posted words'::text, 'My caption'::text, true) $$,
  'a post''s snapshot and caption are copied'
);

select is_empty(
  $$ select 1 from public.posts where id = '80000000-0000-4000-8000-000000000001' $$,
  'the reported post disappears for B'
);

select lives_ok(
  $$ insert into public.reports (id, playlist_id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-00000000000b', '91000000-0000-4000-8000-000000000001', tests.uid('a'), 'inappropriate') $$,
  'B reports A''s Friends playlist'
);

select results_eq(
  $$ select content_body, content_note, content_verified from tests.own_reports() where id = '7e000000-0000-4000-8000-00000000000b' $$,
  $$ values (null::text, 'A''s mornings'::text, true) $$,
  'a playlist''s title is copied'
);

select is(
  public.playlist_view('91000000-0000-4000-8000-000000000001'),
  null,
  'the reported playlist disappears for B'
);

select throws_ok(
  $$ insert into public.reports (playlist_id, reported_user_id, reason)
     values ('91000000-0000-4000-8000-000000000002', tests.uid('a'), 'spam') $$,
  '42501', null,
  'B cannot report A''s Only me playlist, which B cannot see'
);

select lives_ok(
  $$ insert into public.reports (id, starter_quote_id, reason, details)
     values ('7e000000-0000-4000-8000-00000000000c', 2, 'wrong_wording', 'A word is missing') $$,
  'B reports a Quoted Catalog quote''s wording'
);

select results_eq(
  $$ select r.reported_user_id, r.reported_username, r.content_body, r.content_author, r.content_verified
     from tests.own_reports() r where r.id = '7e000000-0000-4000-8000-00000000000c' $$,
  $$ select null::uuid, null::text, s.body, s.author, true from public.starter_quotes s where s.id = 2 $$,
  'a catalog report names nobody and copies the catalog row'
);

select throws_ok(
  $$ insert into public.reports (starter_quote_id, reason) values (2, 'other') $$,
  '23505', null,
  'one report per reporter and catalog quote'
);

select throws_ok(
  $$ insert into public.reports (starter_quote_id, reported_user_id, reason) values (3, tests.uid('a'), 'other') $$,
  '42501', null,
  'a catalog report cannot name a user'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'wrong_wording') $$,
  '23514', 'wrong_wording is only for Quoted Catalog quotes',
  'wrong_wording is for catalog quotes only'
);

select throws_ok(
  $$ insert into public.reports (message_id, post_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000003', '80000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '23514', null,
  'a report names at most one target'
);

-- ---- snapshot kept as sent for a profile report -------------------------------
-- About C, because B's one profile report about A is filed after the block below.
select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body, content_author, content_note, content_verified)
     values ('7e000000-0000-4000-8000-000000000004', tests.uid('c'), 'inappropriate', 'What B saw', 'Someone', 'B''s words', true) $$,
  'B reports C without a target but with a snapshot'
);

select results_eq(
  $$ select message_id is null, content_body, content_author, content_source, content_note, content_verified from tests.own_reports()
     where id = '7e000000-0000-4000-8000-000000000004' $$,
  $$ values (true, 'What B saw'::text, 'Someone'::text, null::text, 'B''s words'::text, false) $$,
  'without a target the client snapshot is kept, unverified even when the client claims otherwise'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000005', tests.uid('d'), 'other') $$,
  'a user report without a snapshot still works'
);

select results_eq(
  $$ select content_body is null and content_author is null and content_source is null and content_note is null
     from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000005' $$,
  $$ values (true) $$,
  'a user report has no snapshot'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_body) values (tests.uid('a'), 'spam', repeat('x', 2001)) $$,
  '23514', null,
  'content_body is at most 2000 characters'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_author) values (tests.uid('a'), 'spam', repeat('x', 201)) $$,
  '23514', null,
  'content_author is at most 200 characters'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_source) values (tests.uid('a'), 'spam', repeat('x', 201)) $$,
  '23514', null,
  'content_source is at most 200 characters'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.uid('a'), 'spam', repeat('x', 1001)) $$,
  '23514', null,
  'content_note is at most 1000 characters'
);

select throws_ok(
  $$ update public.reports set content_body = 'edited' $$,
  '42501', null,
  'the reporter cannot edit a snapshot'
);

-- ---- other users ------------------------------------------------------------
select tests.authenticate_as('c');

select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '42501', null,
  'C cannot report (and so copy) a message from a conversation C is not in'
);

select throws_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason)
     values ('80000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '42501', null,
  'nor a post of A''s, which a stranger cannot see'
);

select is_empty(
  $$ select 1 from public.reports $$,
  'C cannot read B''s reports or their snapshots'
);

select tests.authenticate_as('a');

select is_empty(
  $$ select 1 from public.reports $$,
  'A cannot read the reports about them, even as the message''s sender'
);

-- ---- the snapshot survives a block --------------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'B blocks A'
);

select tests.clear_authentication();

select results_eq(
  $$ select count(*)::int from public.messages where sender_id = tests.uid('a') $$,
  $$ values (5) $$,
  'the block deleted none of A''s messages'
);

select results_eq(
  $$ select id::text collate "default", message_id::text collate "default", content_body, content_author, content_source, content_verified
     from public.reports where reporter_id = tests.uid('b') and reported_user_id = tests.uid('a') and message_id is not null
       and id::text < '7e000000-0000-4000-8000-000000000004'
     order by id $$,
  $$ values
       ('7e000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001', 'A quote'::text, 'Ann'::text, 'Notebook'::text, true),
       ('7e000000-0000-4000-8000-000000000002', '5a000000-0000-4000-8000-000000000002', 'Plain quote', null, null, true),
       ('7e000000-0000-4000-8000-000000000003', '5a000000-0000-4000-8000-000000000003', 'A quote', 'Ann', 'Notebook', true) $$,
  'after the block, every report keeps its message, snapshot and verified flag'
);

-- A deleted message (here the founder deletes it) can no longer be named; the
-- app falls back to a profile report with the snapshot it holds.
delete from public.messages where id = '5a000000-0000-4000-8000-000000000003';
select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason, content_body)
     values ('5a000000-0000-4000-8000-000000000003', tests.uid('a'), 'spam', 'A quote') $$,
  '42501', null,
  'a deleted message can no longer be referenced'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body)
     values ('7e000000-0000-4000-8000-000000000006', tests.uid('a'), 'spam', 'Plain quote') $$,
  'B can still report A with the snapshot the app holds'
);

select results_eq(
  $$ select count(*)::int from tests.own_reports() where content_body is not null $$,
  $$ values (7) $$,
  'B''s reports keep their snapshots'
);
select throws_ok(
  $$ select content_body from public.reports $$,
  '42501', null,
  'but B cannot read the server''s copy back'
);

select tests.authenticate_as('a');

select is_empty(
  $$ select 1 from public.reports $$,
  'after the block, A still cannot read the reports or snapshots'
);

-- ---- the trigger applies to the secret key too ----------------------------
select tests.clear_authentication();
set local role service_role;

select lives_ok(
  $$ insert into public.reports (id, reporter_id, message_id, reported_user_id, reason, content_body, content_author)
     values ('7e000000-0000-4000-8000-000000000007', tests.uid('c'), '5d000000-0000-4000-8000-000000000001',
             tests.uid('d'), 'other', 'rewritten', 'nobody') $$,
  'service_role can file a report on a message'
);

select results_eq(
  $$ select content_body, content_author, content_source, content_verified from public.reports
     where id = '7e000000-0000-4000-8000-000000000007' $$,
  $$ values ('D to C'::text, 'Dee'::text, null::text, true) $$,
  'service_role cannot override the snapshot of a message either'
);

select tests.clear_authentication();

select * from finish();
rollback;
