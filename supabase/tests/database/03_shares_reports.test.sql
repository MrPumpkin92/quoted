-- shares, reports and the block cleanup trigger.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(38);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated;

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

-- A and B are friends. A and C have only a pending request. D is a stranger.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('a'), tests.uid('c'), 'pending');
insert into public.quotes (id, owner_id, body, author) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'A quote', 'Ann'),
  ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B quote', 'Ben');

-- ---- sending --------------------------------------------------------------
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.shares (id, recipient_id, quote_id, body, body_format, author, note)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('b'), 'a0000000-0000-4000-8000-000000000001',
             'A quote', '[{"start":0,"length":1,"italic":true}]', 'Ann', 'for you') $$,
  'A can share their own quote with friend B'
);

select lives_ok(
  $$ insert into public.shares (id, recipient_id, body)
     values ('5a000000-0000-4000-8000-000000000002', tests.uid('b'), 'Typed, no quote row') $$,
  'A can share a snapshot without a quote_id'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, body) values (tests.uid('c'), 'hi') $$,
  '42501', null,
  'A cannot share with C (request still pending)'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, body) values (tests.uid('d'), 'hi') $$,
  '42501', null,
  'A cannot share with a non-friend'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, quote_id, body)
     values (tests.uid('b'), 'b0000000-0000-4000-8000-000000000001', 'B quote') $$,
  '42501', null,
  'A cannot share someone else''s quote'
);

select throws_ok(
  $$ insert into public.shares (sender_id, recipient_id, body) values (tests.uid('b'), tests.uid('a'), 'forged') $$,
  '42501', null,
  'A cannot send a share as B'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, body, seen_at) values (tests.uid('b'), 'pre-seen', now()) $$,
  '42501', null,
  'A cannot pre-set seen_at when sending'
);

select throws_ok(
  $$ insert into public.shares (recipient_id, body, note) values (tests.uid('b'), 'x', repeat('n', 281)) $$,
  '23514', null,
  'note is at most 280 characters'
);

-- ---- receiving ------------------------------------------------------------
select tests.authenticate_as('b');

select results_eq(
  $$ select count(*)::int from public.shares where recipient_id = tests.uid('b') $$,
  $$ values (2) $$,
  'B sees both shares from A'
);

select results_eq(
  $$ update public.shares set seen_at = now(), saved_at = now()
     where id = '5a000000-0000-4000-8000-000000000001'
     returning seen_at is not null and saved_at is not null $$,
  $$ values (true) $$,
  'recipient B can mark a share seen and saved'
);

select throws_ok(
  $$ update public.shares set body = 'edited' where id = '5a000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'recipient B cannot change the body'
);

select throws_ok(
  $$ update public.shares set recipient_id = tests.uid('c') where id = '5a000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'recipient B cannot redirect a share'
);

select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('a') $$,
  'receiving a share does not expose the sender''s quotes'
);

select tests.authenticate_as('a');

select is_empty(
  $$ update public.shares set seen_at = now() where id = '5a000000-0000-4000-8000-000000000002' returning 1 $$,
  'sender A cannot mark a share seen'
);

select throws_ok(
  $$ update public.shares set body = 'edited' where id = '5a000000-0000-4000-8000-000000000002' $$,
  '42501', null,
  'sender A cannot edit a sent share'
);

select tests.authenticate_as('c');

select is_empty(
  $$ select 1 from public.shares $$,
  'C cannot see shares between A and B'
);

select is_empty(
  $$ delete from public.shares returning 1 $$,
  'C cannot delete shares between A and B'
);

-- Deleting the source quote keeps the snapshot.
select tests.authenticate_as('a');
delete from public.quotes where id = 'a0000000-0000-4000-8000-000000000001';
select tests.authenticate_as('b');

select results_eq(
  $$ select quote_id is null, body from public.shares where id = '5a000000-0000-4000-8000-000000000001' $$,
  $$ values (true, 'A quote') $$,
  'deleting the source quote nulls quote_id and keeps the snapshot'
);

-- ---- reports --------------------------------------------------------------
select lives_ok(
  $$ insert into public.reports (share_id, reported_user_id, reason, details)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam', 'unwanted') $$,
  'B can report a share received from A'
);

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('d'), 'other') $$,
  'B can report a user without a share'
);

select results_eq(
  $$ select count(*)::int from public.reports $$,
  $$ values (2) $$,
  'B can read their own reports'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, reported_user_id, reason) values (tests.uid('a'), tests.uid('d'), 'spam') $$,
  '42501', null,
  'B cannot file a report as A'
);

select throws_ok(
  $$ insert into public.reports (share_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('d'), 'spam') $$,
  '42501', null,
  'a reported share must come from the reported user'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'boring') $$,
  '23514', null,
  'reason must be spam, harassment, inappropriate or other'
);

select throws_ok(
  $$ update public.reports set reason = 'other' $$,
  '42501', null,
  'reports cannot be edited'
);

select throws_ok(
  $$ delete from public.reports $$,
  '42501', null,
  'reports cannot be deleted by clients'
);

select tests.authenticate_as('a');

select is_empty(
  $$ select 1 from public.reports $$,
  'A cannot read reports filed by B (or about A)'
);

select tests.authenticate_as('c');

select throws_ok(
  $$ insert into public.reports (share_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '42501', null,
  'C cannot report a share they did not receive'
);

-- ---- sender delete (unsend) ----------------------------------------------
select tests.clear_authentication();
insert into public.shares (id, sender_id, recipient_id, body)
values ('5a000000-0000-4000-8000-000000000003', tests.uid('a'), tests.uid('b'), 'Sent by mistake');
select tests.authenticate_as('a');

select results_eq(
  $$ delete from public.shares where id = '5a000000-0000-4000-8000-000000000003' returning body $$,
  $$ values ('Sent by mistake') $$,
  'sender A can delete a share they sent'
);

select tests.authenticate_as('b');

select is_empty(
  $$ select 1 from public.shares where id = '5a000000-0000-4000-8000-000000000003' $$,
  'the deleted share is gone for recipient B too'
);

-- ---- recipient delete -----------------------------------------------------

select results_eq(
  $$ delete from public.shares where id = '5a000000-0000-4000-8000-000000000002' returning 1 $$,
  $$ values (1) $$,
  'recipient B can delete a received share'
);

-- ---- block cleanup trigger ------------------------------------------------
select tests.clear_authentication();
insert into public.shares (id, sender_id, recipient_id, body) values
  ('5b000000-0000-4000-8000-000000000001', tests.uid('b'), tests.uid('a'), 'B to A'),
  ('5c000000-0000-4000-8000-000000000001', tests.uid('c'), tests.uid('a'), 'C to A');

select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'B can block friend A'
);

select tests.clear_authentication();

select is_empty(
  $$ select 1 from public.friendships
     where least(requester_id, addressee_id) = least(tests.uid('a'), tests.uid('b'))
       and greatest(requester_id, addressee_id) = greatest(tests.uid('a'), tests.uid('b')) $$,
  'the block removed the A-B friendship'
);

select is_empty(
  $$ select 1 from public.shares
     where (sender_id, recipient_id) in ((tests.uid('a'), tests.uid('b')), (tests.uid('b'), tests.uid('a'))) $$,
  'the block removed shares in both directions'
);

select results_eq(
  $$ select body from public.shares where sender_id in (tests.uid('a'), tests.uid('b'), tests.uid('c'), tests.uid('d')) order by body $$,
  $$ values ('C to A') $$,
  'shares with other people are untouched'
);

select results_eq(
  $$ select share_id is null, reason from public.reports where reported_user_id = tests.uid('a') $$,
  $$ values (true, 'spam') $$,
  'the report on A survives the share deletion'
);

select results_eq(
  $$ select status from public.friendships where requester_id in (tests.uid('a'), tests.uid('b'), tests.uid('c'), tests.uid('d')) $$,
  $$ values ('pending') $$,
  'the unrelated A-C request is untouched'
);

select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.shares (recipient_id, body) values (tests.uid('b'), 'still there?') $$,
  '42501', null,
  'after the block, A cannot share with B'
);

select * from finish();
rollback;
