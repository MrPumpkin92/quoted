-- Deleting an auth user (what delete-account does through the admin API)
-- cascades through every table and leaves other users' data intact. Reports
-- are the exception: they stay for moderation with the deleted user's id set
-- to null (by them, and about them). Events carry no user id at all.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;

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
-- ---------------------------------------------------------------------------

select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('b'), tests.uid('c'), 'accepted');
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('c'));
insert into public.quotes (id, owner_id, body) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'A quote'),
  ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B quote');
insert into public.shares (id, sender_id, recipient_id, quote_id, body) values
  ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), tests.uid('b'), 'a0000000-0000-4000-8000-000000000001', 'A to B'),
  ('5b000000-0000-4000-8000-000000000001', tests.uid('b'), tests.uid('a'), 'b0000000-0000-4000-8000-000000000001', 'B to A'),
  ('5b000000-0000-4000-8000-000000000002', tests.uid('b'), tests.uid('c'), 'b0000000-0000-4000-8000-000000000001', 'B to C');
insert into public.reports (id, reporter_id, share_id, reported_user_id, reason) values
  ('7e000000-0000-4000-8000-000000000001', tests.uid('b'), '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam'),
  ('7e000000-0000-4000-8000-000000000002', tests.uid('c'), '5b000000-0000-4000-8000-000000000002', tests.uid('b'), 'other'),
  ('7e000000-0000-4000-8000-000000000003', tests.uid('a'), '5b000000-0000-4000-8000-000000000001', tests.uid('b'), 'harassment');
-- events are anonymous, so this test's rows are the ones above the current max id.
create table tests.baseline as select coalesce(max(id), 0) as max_event_id from public.events;
insert into public.events (name) values ('web_search_tap'), ('web_search_tap');

select lives_ok(
  $$ delete from auth.users where id = tests.uid('a') $$,
  'deleting A''s auth user succeeds'
);

select is_empty($$ select 1 from public.profiles where id = tests.uid('a') $$, 'A''s profile is gone');
select is_empty($$ select 1 from public.quotes where owner_id = tests.uid('a') $$, 'A''s quotes are gone');
select is_empty(
  $$ select 1 from public.friendships where tests.uid('a') in (requester_id, addressee_id) $$,
  'A''s friendships are gone'
);
select is_empty($$ select 1 from public.blocks where tests.uid('a') in (blocker_id, blocked_id) $$, 'A''s blocks are gone');
select is_empty($$ select 1 from public.shares where tests.uid('a') in (sender_id, recipient_id) $$, 'shares to and from A are gone');
select is_empty(
  $$ select 1 from public.reports where tests.uid('a') in (reporter_id, reported_user_id) $$,
  'no report points at A any more'
);
select results_eq(
  $$ select reporter_id, reported_user_id, reported_username, content_body, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.uid('b'), null::uuid, 'alice'::text, 'A to B'::text, true) $$,
  'a report about A survives with its snapshot and A''s username, without A''s id'
);
select results_eq(
  $$ select reporter_id, reported_user_id, reason, content_body, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values (null::uuid, tests.uid('b'), 'harassment'::text, 'B to A'::text, true) $$,
  'a report A filed survives anonymously, still about B and still verified'
);
select is(
  (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)),
  2,
  'events are anonymous, so deleting A leaves the counts alone'
);

select results_eq(
  $$ select (select count(*)::int from public.profiles where id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.quotes where owner_id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.friendships where requester_id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.shares where sender_id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.reports where id in ('7e000000-0000-4000-8000-000000000001',
               '7e000000-0000-4000-8000-000000000002', '7e000000-0000-4000-8000-000000000003')),
            (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)) $$,
  $$ values (2, 1, 1, 1, 3, 2) $$,
  'B and C keep their profiles, quote, friendship and share; all reports and events remain'
);

select * from finish();
rollback;
