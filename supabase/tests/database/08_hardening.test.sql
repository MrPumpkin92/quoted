-- Hardening (supabase/migrations/20261019060000_hardening.sql): body_format
-- validation and byte cap, non-blank text, server-owned timestamps, reports
-- that record verification and stay reviewable, and the moderation queue view.
-- Since 20261029090000_provenance_and_accounts clients cannot send created_at
-- or updated_at for profiles and quotes at all (column grants, 42501); the
-- stamping triggers stay behind them.
-- Ported to 20261029090300_conversations_and_messages: shares became messages.
-- Clients cannot send a snapshot or a time any more (column grants), so the
-- body_format and created_at checks on messages run as the server; the blank
-- checks use a text message and a note; seen_at and saved_at became each
-- member's last_read_at and cleared_at (the server clock, never earlier than
-- the stored time, never cleared by a client: "first seen wins" became
-- "never moves back", and "saved_at can be cleared" became "a client cannot
-- clear last_read_at"); share_id became message_id. Reporters no longer read
-- the server's copy back (column grants), so the report checks read it with
-- definer rights (tests.own_reports). Removed: none.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(54);

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
-- reporters may not select the server's copy (20261029090300), so the tests
-- read it as the founder does.
create function tests.own_reports() returns setof public.reports language sql stable security definer as $$
  select * from public.reports where reporter_id = auth.uid()
$$;

-- The user has accepted the current terms (social writes need them).
create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- 200 runs; `flags` is merged into each {start, length} object.
create function tests.runs(first_start int, step int, run_length int, flags jsonb) returns jsonb
language sql immutable as $$
  select jsonb_agg(jsonb_build_object('start', first_start + step * i, 'length', run_length) || flags order by i)
  from generate_series(0, 199) i
$$;
-- ---------------------------------------------------------------------------

-- A and B are friends; C is a stranger. A sent B two quote messages.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice'), (tests.uid('b'), 'bob', null);
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted');
insert into public.quotes (id, owner_id, body) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'Seen long ago');
update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
 where id in (tests.uid('a'), tests.uid('b'));
insert into public.conversations (id, user_a, user_b) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), tests.uid('b'));
insert into public.conversation_members (conversation_id, user_id) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a')), ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('b'));
-- Message 1 is a snapshot the server supplied; message 2 was made from A's quote.
insert into public.messages (id, conversation_id, sender_id, kind, body) values
  ('5a000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'quote', 'A to B');
insert into public.messages (id, conversation_id, sender_id, kind, source_quote_id) values
  ('5a000000-0000-4000-8000-000000000002', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'quote',
   'a0000000-0000-4000-8000-000000000001');
update public.messages set created_at = '2001-01-01' where id = '5a000000-0000-4000-8000-000000000002';

-- ---- body_format ----------------------------------------------------------
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.quotes (body, body_format)
     values ('Every flag', '[{"start":0,"length":4000,"bold":true,"italic":false,"underline":true}]') $$,
  'a run with integer start and length and boolean flags is accepted'
);

select lives_ok(
  $$ insert into public.quotes (body, body_format)
     select 'Busy', tests.runs(1000, 15, 10, '{"bold":true,"italic":true,"underline":true}') $$,
  'the largest array the app can write (200 runs, every flag) fits the byte cap'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format)
     select 'Too big', tests.runs(4000, 0, 4000, '{"bold":false,"italic":false,"underline":false}') $$,
  '23514', null,
  'an array over 16384 bytes is rejected even when every run is well formed'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format)
     select 'x', jsonb_agg(jsonb_build_object('start', 0, 'length', 1, 'junk', repeat(md5(g::text), 3200)))
     from generate_series(1, 200) g $$,
  '23514', null,
  'the 20 MB junk payload from the review is rejected'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":0,"length":1,"bold":true,"color":"red"}]') $$,
  '23514', null,
  'runs cannot carry unknown keys'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[1]') $$,
  '23514', null,
  'every run must be an object'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":0,"bold":true}]') $$,
  '23514', null,
  'every run needs a length'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":0.5,"length":1,"bold":true}]') $$,
  '23514', null,
  'start must be an integer'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":-1,"length":1,"bold":true}]') $$,
  '23514', null,
  'start cannot be negative'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":0,"length":4001,"bold":true}]') $$,
  '23514', null,
  'length is at most 4000 (the UTF-16 size of a 2000-character body)'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":"0","length":1,"bold":true}]') $$,
  '23514', null,
  'start must be a JSON number, not a string'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '[{"start":0,"length":1,"bold":"yes"}]') $$,
  '23514', null,
  'flags must be booleans'
);

select tests.clear_authentication();

select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, body, body_format)
     values ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'quote', 'x', '[{"start":0,"length":1,"junk":1}]') $$,
  '23514', null,
  'messages validate body_format the same way (only the server can send one)'
);

select throws_ok(
  $$ insert into public.starter_quotes (id, body, body_format, author, sort_order, source_location, source_url)
     values (32767, 'x', '[{"start":0,"length":1,"junk":1}]', 'y', 32767, 'Chapter 1', 'https://example.org/text') $$,
  '23514', null,
  'starter_quotes validate body_format the same way'
);

-- ---- text that is only whitespace -----------------------------------------
select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.quotes (body) values (E' \n\t 　 ') $$,
  '23514', null,
  'a quote body of only whitespace (ASCII and Unicode) is rejected'
);

select lives_ok(
  $$ insert into public.quotes (body) values (E'​') $$,
  'a body the app keeps (U+200B is not whitespace to Swift) is accepted: the server is never stricter'
);

select throws_ok(
  $$ insert into public.quotes (body, author) values ('x', '   ') $$,
  '23514', null,
  'a blank author is rejected (the app sends null)'
);

select throws_ok(
  $$ insert into public.quotes (body, source) values ('x', E'\n') $$,
  '23514', null,
  'a blank source is rejected (the app sends null)'
);

select throws_ok(
  $$ update public.profiles set display_name = E'  \n' where id = tests.uid('a') $$,
  '23514', 'new row for relation "profiles" violates check constraint "profiles_display_name_not_blank"',
  'a blank display name is rejected, and the error names display_name'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values ('c0a00000-0000-4000-8000-0000000000ab', 'text', E'\t ') $$,
  '23514', null,
  'a blank text message is rejected'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id, note) values ('c0a00000-0000-4000-8000-0000000000ab', 'quote', 1, '  ') $$,
  '23514', null,
  'a blank note is rejected (the app sends null)'
);

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, details) values (tests.uid('a'), 'spam', ' ') $$,
  '23514', null,
  'blank report details are rejected (the app sends null)'
);

-- ---- server-owned timestamps ----------------------------------------------
select tests.authenticate_as('c');

select throws_ok(
  $$ insert into public.profiles (id, username, created_at) values (tests.uid('c'), 'cara', '1999-01-01') $$,
  '42501', null,
  'a client cannot send profiles.created_at'
);

insert into public.profiles (id, username) values (tests.uid('c'), 'cara');

select throws_ok(
  $$ update public.profiles set created_at = '1999-01-01' where id = tests.uid('c') $$,
  '42501', null,
  'profiles.created_at cannot be changed later'
);

select tests.clear_authentication();
select is((select created_at from public.profiles where id = tests.uid('c')), now(),
  'profiles.created_at is the server clock');
select tests.accept_terms('c');
select tests.authenticate_as('c');

select results_eq(
  $$ insert into public.friendships (addressee_id, created_at, responded_at) values (tests.uid('a'), '2099-01-01', '2099-01-01')
     returning created_at = now(), responded_at is null $$,
  $$ values (true, true) $$,
  'a friend request dated 2099 is stamped with the server clock'
);

select results_eq(
  $$ insert into public.blocks (blocked_id, created_at) values (tests.uid('b'), '2000-01-01') returning created_at = now() $$,
  $$ values (true) $$,
  'blocks.created_at is the server clock'
);

select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.quotes (body, created_at, updated_at) values ('Dated', '2099-01-01', '2099-01-01') $$,
  '42501', null,
  'a client cannot send quotes.created_at or updated_at'
);

select results_eq(
  $$ insert into public.quotes (body) values ('Dated') returning created_at = now(), updated_at = now() $$,
  $$ values (true, true) $$,
  'quotes.created_at and updated_at are the server clock on insert'
);

select tests.clear_authentication();

select results_eq(
  $$ insert into public.messages (id, conversation_id, sender_id, kind, text, created_at)
     values ('5a000000-0000-4000-8000-000000000003', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'text', 'Pinned?', '2099-01-01')
     returning created_at = now() $$,
  $$ values (true) $$,
  'a message dated 2099 is stamped with the server clock, even from the server, so it cannot pin itself to the top of the inbox'
);

select tests.authenticate_as('b');

select results_eq(
  $$ update public.conversation_members set last_read_at = '2099-01-01', cleared_at = '1999-01-01'
     where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab'
     returning last_read_at = now(), cleared_at = now() $$,
  $$ values (true, true) $$,
  'last_read_at and cleared_at take the server clock, not the client''s'
);

select tests.clear_authentication();
update public.conversation_members set last_read_at = '2099-01-01'
 where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab' and user_id = tests.uid('b');
select tests.authenticate_as('b');

select results_eq(
  $$ update public.conversation_members set last_read_at = '2000-01-01'
     where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab'
     returning last_read_at $$,
  $$ values ('2099-01-01'::timestamptz) $$,
  'last_read_at never moves back'
);

select results_eq(
  $$ update public.conversation_members set last_read_at = null
     where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab'
     returning last_read_at, cleared_at = now() $$,
  $$ values ('2099-01-01'::timestamptz, true) $$,
  'a client cannot clear last_read_at, and trying leaves cleared_at alone'
);

select tests.clear_authentication();
-- Deleting the source quote nulls messages.source_quote_id through the
-- foreign key, an UPDATE; it must leave the message's time alone.
delete from public.quotes where id = 'a0000000-0000-4000-8000-000000000001';

select results_eq(
  $$ select source_quote_id is null, created_at from public.messages where id = '5a000000-0000-4000-8000-000000000002' $$,
  $$ values (true, '2001-01-01'::timestamptz) $$,
  'a foreign-key update (quote deleted) leaves the message''s time alone'
);

-- ---- reports --------------------------------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason, created_at, reviewed_at, reported_username, content_verified)
     values ('7e000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'harassment',
             '2000-01-01', '2000-01-01', 'mallory', false) $$,
  'B reports A''s message, trying to set every server-owned column'
);

select results_eq(
  $$ select created_at = now(), reviewed_at is null, reported_username, content_verified, content_body
     from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (true, true, 'alice'::text, true, 'A to B'::text) $$,
  'created_at, reviewed_at, reported_username and content_verified are set by the server'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body, content_verified)
     values ('7e000000-0000-4000-8000-000000000002', tests.uid('c'), 'other', 'Made up', true) $$,
  'B can report a user without a target'
);

select results_eq(
  $$ select message_id is null, content_body, content_verified, reported_username
     from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values (true, 'Made up'::text, false, 'cara'::text) $$,
  'a report without a target keeps the client''s text but is marked unverified'
);

select throws_ok(
  $$ update public.reports set reviewed_at = now() $$,
  '42501', null,
  'clients cannot mark reports reviewed'
);

select throws_ok(
  $$ select * from private.reports_to_review $$,
  '42501', null,
  'clients cannot read the moderation queue'
);

select tests.clear_authentication();
set local role service_role;

select throws_ok(
  $$ insert into public.reports (reporter_id, reported_user_id, reason) values (tests.uid('b'), null, 'spam') $$,
  '23502', null,
  'a report needs a reported user, even with the secret key'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, reported_user_id, reason) values (null, tests.uid('a'), 'spam') $$,
  '23502', null,
  'a report needs a reporter, even with the secret key'
);

select lives_ok(
  $$ insert into public.reports (id, reporter_id, message_id, reported_user_id, reason, content_body)
     values ('7e000000-0000-4000-8000-000000000003', tests.uid('c'), '5a000000-0000-4000-8000-000000000001',
             tests.uid('a'), 'spam', 'Not what C saw') $$,
  'service_role can file a report naming a message from a conversation the reporter is not in'
);

select results_eq(
  $$ select content_body is null, content_verified from public.reports where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values (true, false) $$,
  'that report gets no snapshot and is not verified: only a member of the conversation verifies it'
);

select tests.clear_authentication();

-- ---- moderation queue -------------------------------------------------------
select results_eq(
  $$ select id::text collate "default", reported_username, reports_against_user::int, reporter_username, content_verified
     from private.reports_to_review where id::text like '7e000000-%' order by id $$,
  $$ values
       ('7e000000-0000-4000-8000-000000000001', 'alice'::text, 2, 'bob'::text, true),
       ('7e000000-0000-4000-8000-000000000002', 'cara', 1, 'bob', false),
       ('7e000000-0000-4000-8000-000000000003', 'alice', 2, 'cara', false) $$,
  'the queue lists every unreviewed report with the usernames and how often the user was reported'
);

update public.reports set reviewed_at = now() where id = '7e000000-0000-4000-8000-000000000002';

select is_empty(
  $$ select 1 from private.reports_to_review where id = '7e000000-0000-4000-8000-000000000002' $$,
  'a reviewed report leaves the queue'
);

-- ---- reports outlive both accounts ------------------------------------------
delete from auth.users where id = tests.uid('a');

select results_eq(
  $$ select reporter_id, reported_user_id is null, reported_username, content_body, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.uid('b'), true, 'alice'::text, 'A to B'::text, true) $$,
  'after the reported user deletes their account the report keeps the snapshot and username'
);

select results_eq(
  $$ select reported_username, reported_account_deleted, reports_against_user::int
     from private.reports_to_review where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values ('alice'::text, true, 2) $$,
  'the queue still names the deleted user and counts their reports by username'
);

delete from auth.users where id = tests.uid('b');

select results_eq(
  $$ select reporter_id is null, reported_user_id is null, reason from public.reports
     where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (true, true, 'harassment'::text) $$,
  'after the reporter deletes their account too, the report is still there, anonymous'
);

select results_eq(
  $$ select reporter_id is null, reported_username, reviewed_at is not null from public.reports
     where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values (true, 'cara'::text, true) $$,
  'a reviewed report filed by a deleted account is kept too'
);

select is(
  (select count(*)::int from public.reports where id in ('7e000000-0000-4000-8000-000000000001',
     '7e000000-0000-4000-8000-000000000002', '7e000000-0000-4000-8000-000000000003')),
  3,
  'no report was lost to account deletion'
);

-- ---- the triggers on every table with created_at --------------------------
select is_empty(
  $$ select c.relname
     from pg_class c
     join pg_attribute a on a.attrelid = c.oid and a.attname = 'created_at' and not a.attisdropped
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
       and not exists (
         select 1 from pg_trigger t
         where t.tgrelid = c.oid and not t.tgisinternal and t.tgname = c.relname || '_stamp_created_at'
       ) $$,
  'every public table with created_at has a <table>_stamp_created_at trigger'
);

select results_eq(
  $$ select tgrelid::regclass::text, tgname::text collate "default" from pg_trigger
     where not tgisinternal and tgname like '%keep_created_at' order by 1 $$,
  $$ values ('profiles', 'profiles_keep_created_at'), ('quotes', 'quotes_keep_created_at') $$,
  'profiles and quotes keep created_at on update (behind their column grants)'
);

select is_empty(
  $$ select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'events' and column_name = 'user_id' $$,
  'events has no user_id column'
);

select * from finish();
rollback;
