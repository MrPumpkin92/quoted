-- reports keep a copy of the reported content: copied from the share by
-- trigger (client values ignored, content_verified = true), kept as sent when
-- share_id is null (content_verified = false), and still there after a block
-- deletes the share.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(30);

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
-- ---------------------------------------------------------------------------

-- A and B are friends; A sent B two shares. C and D are strangers to the pair.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted');
insert into public.shares (id, sender_id, recipient_id, body, author, source) values
  ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), tests.uid('b'), 'A quote', 'Ann', 'Notebook'),
  ('5a000000-0000-4000-8000-000000000002', tests.uid('a'), tests.uid('b'), 'Plain share', null, null),
  -- A third copy of share 1, because a reporter can file only one report per
  -- reported user and share (reports_reporter_reported_share_key).
  ('5a000000-0000-4000-8000-000000000003', tests.uid('a'), tests.uid('b'), 'A quote', 'Ann', 'Notebook');
-- D to C, for the service-role check.
insert into public.shares (id, sender_id, recipient_id, body, author) values
  ('5d000000-0000-4000-8000-000000000001', tests.uid('d'), tests.uid('c'), 'D to C', 'Dee');

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
       ('content_verified', 'boolean', 'NO', 'false') $$,
  'reports has nullable content_body, content_author and content_source, and content_verified'
);

select has_trigger('public', 'reports', 'reports_snapshot_share', 'reports has the snapshot trigger');

select isnt_definer(
  'private', 'reports_snapshot_share', array[]::text[],
  'the snapshot trigger runs as the invoker (it copies only shares the reporter can read)'
);

select results_eq(
  $$ select string_agg(privilege_type, ',' order by privilege_type)::text collate "default"
     from information_schema.role_table_grants
     where grantee = 'authenticated' and table_schema = 'public' and table_name = 'reports' $$,
  $$ values ('INSERT,SELECT') $$,
  'authenticated still has only insert and select on reports'
);

-- ---- snapshot copied from the share ---------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (id, share_id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  'B reports a share from A without sending a snapshot'
);

select results_eq(
  $$ select content_body, content_author, content_source, content_verified from public.reports
     where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values ('A quote'::text, 'Ann'::text, 'Notebook'::text, true) $$,
  'the snapshot is copied from the share and marked verified'
);

select lives_ok(
  $$ insert into public.reports (id, share_id, reported_user_id, reason, content_body, content_author, content_source, content_verified)
     values ('7e000000-0000-4000-8000-000000000002', '5a000000-0000-4000-8000-000000000002', tests.uid('a'), 'harassment',
             'Something A never said', 'Mallory', 'Made up', false) $$,
  'B reports a share from A with a forged snapshot'
);

select results_eq(
  $$ select content_body, content_author, content_source from public.reports
     where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values ('Plain share'::text, null::text, null::text) $$,
  'forged content is overwritten with the share''s, including null author and source'
);

select lives_ok(
  $$ insert into public.reports (id, share_id, reported_user_id, reason, content_body, content_author, content_source)
     values ('7e000000-0000-4000-8000-000000000003', '5a000000-0000-4000-8000-000000000003', tests.uid('a'), 'other',
             repeat('x', 5000), repeat('y', 500), repeat('z', 500)) $$,
  'an oversized client snapshot is replaced before the length checks run'
);

select results_eq(
  $$ select content_body, content_author, content_source from public.reports
     where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values ('A quote'::text, 'Ann'::text, 'Notebook'::text) $$,
  'the oversized snapshot became the share''s content'
);

-- ---- snapshot kept as sent when share_id is null ----------------------------
-- About C, because B's one user report about A is filed after the block below.
select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body, content_author, content_verified)
     values ('7e000000-0000-4000-8000-000000000004', tests.uid('c'), 'inappropriate', 'What B saw', 'Someone', true) $$,
  'B reports C without a share but with a snapshot'
);

select results_eq(
  $$ select share_id is null, content_body, content_author, content_source, content_verified from public.reports
     where id = '7e000000-0000-4000-8000-000000000004' $$,
  $$ values (true, 'What B saw'::text, 'Someone'::text, null::text, false) $$,
  'without a share_id the client snapshot is kept, unverified even when the client claims otherwise'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason)
     values ('7e000000-0000-4000-8000-000000000005', tests.uid('d'), 'other') $$,
  'a user report without a snapshot still works'
);

select results_eq(
  $$ select content_body is null and content_author is null and content_source is null from public.reports
     where id = '7e000000-0000-4000-8000-000000000005' $$,
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
  $$ update public.reports set content_body = 'edited' $$,
  '42501', null,
  'the reporter cannot edit a snapshot'
);

-- ---- other users ------------------------------------------------------------
select tests.authenticate_as('c');

select throws_ok(
  $$ insert into public.reports (share_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '42501', null,
  'C cannot report (and so copy) a share they did not receive'
);

select is_empty(
  $$ select 1 from public.reports $$,
  'C cannot read B''s reports or their snapshots'
);

select tests.authenticate_as('a');

select is_empty(
  $$ select 1 from public.reports $$,
  'A cannot read the reports about them, even as the share''s sender'
);

-- ---- the snapshot survives a block --------------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'B blocks A'
);

select tests.clear_authentication();

select is_empty(
  $$ select 1 from public.shares where sender_id = tests.uid('a') and recipient_id = tests.uid('b') $$,
  'the block deleted A''s shares to B'
);

select results_eq(
  $$ select id::text collate "default", share_id is null, content_body, content_author, content_source, content_verified
     from public.reports where reporter_id = tests.uid('b') and reported_user_id = tests.uid('a')
     order by id $$,
  $$ values
       ('7e000000-0000-4000-8000-000000000001', true, 'A quote'::text, 'Ann'::text, 'Notebook'::text, true),
       ('7e000000-0000-4000-8000-000000000002', true, 'Plain share', null, null, true),
       ('7e000000-0000-4000-8000-000000000003', true, 'A quote', 'Ann', 'Notebook', true) $$,
  'after the block, share_id is null and every snapshot and verified flag is intact'
);

-- Reporting after the block: the share is gone, so the client falls back to a
-- user report and its snapshot is kept.
select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.reports (share_id, reported_user_id, reason, content_body)
     values ('5a000000-0000-4000-8000-000000000002', tests.uid('a'), 'spam', 'Plain share') $$,
  '42501', null,
  'a deleted share can no longer be referenced'
);

select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body)
     values ('7e000000-0000-4000-8000-000000000006', tests.uid('a'), 'spam', 'Plain share') $$,
  'B can still report A with the snapshot the app holds'
);

select results_eq(
  $$ select count(*)::int from public.reports where content_body is not null $$,
  $$ values (5) $$,
  'B reads their own snapshots'
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
  $$ insert into public.reports (id, reporter_id, share_id, reported_user_id, reason, content_body, content_author)
     values ('7e000000-0000-4000-8000-000000000007', tests.uid('c'), '5d000000-0000-4000-8000-000000000001',
             tests.uid('d'), 'other', 'rewritten', 'nobody') $$,
  'service_role can file a report on a share'
);

select results_eq(
  $$ select content_body, content_author, content_source, content_verified from public.reports
     where id = '7e000000-0000-4000-8000-000000000007' $$,
  $$ values ('D to C'::text, 'Dee'::text, null::text, true) $$,
  'service_role cannot override the snapshot of a share either'
);

select tests.clear_authentication();

select * from finish();
rollback;
