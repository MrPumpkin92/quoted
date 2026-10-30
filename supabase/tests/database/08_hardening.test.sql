-- Hardening (supabase/migrations/20261019060000_hardening.sql): body_format
-- validation and byte cap, non-blank text, server-owned timestamps, reports
-- that record verification and stay reviewable, and the moderation queue view.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(52);

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

-- 200 runs; `flags` is merged into each {start, length} object.
create function tests.runs(first_start int, step int, run_length int, flags jsonb) returns jsonb
language sql immutable as $$
  select jsonb_agg(jsonb_build_object('start', first_start + step * i, 'length', run_length) || flags order by i)
  from generate_series(0, 199) i
$$;
-- ---------------------------------------------------------------------------

-- A and B are friends; C is a stranger. A sent B one share.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice'), (tests.uid('b'), 'bob', null);
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted');
insert into public.quotes (id, owner_id, body) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'Seen long ago');
-- Share 2 was seen in 2001 (set directly here; clients cannot pre-set seen_at).
insert into public.shares (id, sender_id, recipient_id, quote_id, body, seen_at) values
  ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), tests.uid('b'), null, 'A to B', null),
  ('5a000000-0000-4000-8000-000000000002', tests.uid('a'), tests.uid('b'), 'a0000000-0000-4000-8000-000000000001',
   'Seen long ago', '2001-01-01');

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

select throws_ok(
  $$ insert into public.shares (recipient_id, body, body_format) values (tests.uid('b'), 'x', '[{"start":0,"length":1,"junk":1}]') $$,
  '23514', null,
  'shares validate body_format the same way'
);

select tests.clear_authentication();

-- A row that is valid in every other way, so only the body_format check can refuse it.
select throws_ok(
  $$ insert into public.catalog_quotes (id, body, body_format, author, source, sort_order, source_location, source_url,
                                       is_starter, themes)
     values (32767, 'x', '[{"start":0,"length":1,"junk":1}]', 'y', 'z', 32767, 'Chapter 1', 'https://example.org/text',
             true, array['calm']) $$,
  '23514', 'new row for relation "catalog_quotes" violates check constraint "catalog_quotes_body_format_valid"',
  'catalog_quotes validate body_format the same way'
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
  $$ insert into public.shares (recipient_id, body) values (tests.uid('b'), E'\t ') $$,
  '23514', null,
  'a blank share body is rejected'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, body, note) values (tests.uid('b'), 'x', '  ') $$,
  '23514', null,
  'a blank share note is rejected (the app sends null)'
);

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, details) values (tests.uid('a'), 'spam', ' ') $$,
  '23514', null,
  'blank report details are rejected (the app sends null)'
);

-- ---- server-owned timestamps ----------------------------------------------
select tests.authenticate_as('c');

select results_eq(
  $$ insert into public.profiles (id, username, created_at) values (tests.uid('c'), 'cara', '1999-01-01')
     returning created_at = now() $$,
  $$ values (true) $$,
  'profiles.created_at is the server clock, whatever the client sends'
);

select results_eq(
  $$ update public.profiles set created_at = '1999-01-01' where id = tests.uid('c') returning created_at = now() $$,
  $$ values (true) $$,
  'profiles.created_at cannot be changed later'
);

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

select results_eq(
  $$ insert into public.quotes (body, created_at, updated_at) values ('Dated', '2099-01-01', '2099-01-01')
     returning created_at = now(), updated_at = now() $$,
  $$ values (true, true) $$,
  'quotes.created_at and updated_at are the server clock on insert'
);

select results_eq(
  $$ insert into public.shares (id, recipient_id, body, created_at)
     values ('5a000000-0000-4000-8000-000000000003', tests.uid('b'), 'Pinned?', '2099-01-01')
     returning created_at = now() $$,
  $$ values (true) $$,
  'a share dated 2099 is stamped with the server clock, so it cannot pin itself to the top of the inbox'
);

select tests.authenticate_as('b');

select results_eq(
  $$ update public.shares set seen_at = '2099-01-01', saved_at = '1999-01-01'
     where id = '5a000000-0000-4000-8000-000000000001'
     returning seen_at = now(), saved_at = now() $$,
  $$ values (true, true) $$,
  'seen_at and saved_at take the server clock, not the client''s'
);

select results_eq(
  $$ update public.shares set seen_at = '2099-01-01' where id = '5a000000-0000-4000-8000-000000000002'
     returning seen_at $$,
  $$ values ('2001-01-01'::timestamptz) $$,
  'the first seen_at is kept'
);

select results_eq(
  $$ update public.shares set saved_at = null where id = '5a000000-0000-4000-8000-000000000001'
     returning saved_at is null, seen_at = now() $$,
  $$ values (true, true) $$,
  'saved_at can be cleared, and clearing it leaves seen_at alone'
);

select tests.clear_authentication();
-- Deleting the source quote nulls shares.quote_id through the foreign key, an
-- UPDATE that runs the shares trigger; it must leave the stamps alone.
delete from public.quotes where id = 'a0000000-0000-4000-8000-000000000001';

select results_eq(
  $$ select quote_id is null, seen_at from public.shares where id = '5a000000-0000-4000-8000-000000000002' $$,
  $$ values (true, '2001-01-01'::timestamptz) $$,
  'a foreign-key update (quote deleted) leaves seen_at alone'
);

-- ---- reports --------------------------------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (id, share_id, reported_user_id, reason, created_at, reviewed_at, reported_username, content_verified)
     values ('7e000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'harassment',
             '2000-01-01', '2000-01-01', 'mallory', false) $$,
  'B reports A''s share, trying to set every server-owned column'
);

select results_eq(
  $$ select created_at = now(), reviewed_at is null, reported_username, content_verified, content_body
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (true, true, 'alice'::text, true, 'A to B'::text) $$,
  'created_at, reviewed_at, reported_username and content_verified are set by the server'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body, content_verified)
     values ('7e000000-0000-4000-8000-000000000002', tests.uid('c'), 'other', 'Made up', true) $$,
  'B can report a user without a share'
);

select results_eq(
  $$ select share_id is null, content_body, content_verified, reported_username
     from public.reports where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values (true, 'Made up'::text, false, 'cara'::text) $$,
  'a report without a share keeps the client''s text but is marked unverified'
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
  $$ insert into public.reports (id, reporter_id, share_id, reported_user_id, reason, content_body)
     values ('7e000000-0000-4000-8000-000000000003', tests.uid('c'), '5a000000-0000-4000-8000-000000000001',
             tests.uid('a'), 'spam', 'Not what C saw') $$,
  'service_role can file a report naming a share the reporter never received'
);

select results_eq(
  $$ select content_body is null, content_verified from public.reports where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values (true, false) $$,
  'that report gets no snapshot and is not verified: only the share''s recipient verifies it'
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
  'the tables with a table-level UPDATE grant keep created_at on update'
);

select is_empty(
  $$ select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'events' and column_name = 'user_id' $$,
  'events has no user_id column'
);

select * from finish();
rollback;
