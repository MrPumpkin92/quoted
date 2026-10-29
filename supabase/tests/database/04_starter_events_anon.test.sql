-- starter_quotes (read-only), events (insert-only, anonymous) and anon (no access at all).
-- Ported to 20261029090300_conversations_and_messages: shares became
-- messages, so anon's share checks now cover conversations, conversation_members
-- and messages (reading; updating a member row instead of a share). Removed: none.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(28);

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

-- Act as a caller with only the publishable key (no session).
create function tests.become_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
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

select tests.create_user('a');
select tests.create_user('b');
insert into public.profiles (id, username) values (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob');
-- An id/sort_order far from the real starter pack so the test never collides with it.
insert into public.starter_quotes (id, body, author, source, sort_order, source_location, source_url)
values (32767, 'Test starter quote', 'Test Author', null, 32767, 'Chapter 1', 'https://example.org/text');
-- events are anonymous, so this test's rows are the ones above the current max id.
create table tests.baseline as select coalesce(max(id), 0) as max_event_id from public.events;
insert into public.events (name) values ('web_search_tap');

-- ---- starter_quotes -------------------------------------------------------
select tests.authenticate_as('a');

select results_eq(
  $$ select body, author, body_format from public.starter_quotes where id = 32767 $$,
  $$ values ('Test starter quote', 'Test Author', '[]'::jsonb) $$,
  'authenticated users can read starter quotes'
);

select throws_ok(
  $$ insert into public.starter_quotes (id, body, author, sort_order) values (32766, 'x', 'y', 32766) $$,
  '42501', null,
  'clients cannot add starter quotes'
);

select throws_ok(
  $$ update public.starter_quotes set body = 'edited' where id = 32767 $$,
  '42501', null,
  'clients cannot edit starter quotes'
);

select throws_ok(
  $$ delete from public.starter_quotes where id = 32767 $$,
  '42501', null,
  'clients cannot delete starter quotes'
);

-- ---- events ---------------------------------------------------------------
select lives_ok(
  $$ insert into public.events (name, created_at) values ('web_search_tap', '2000-01-01') $$,
  'A can log a web_search_tap event'
);

select throws_ok(
  $$ insert into public.events (user_id, name) values (tests.uid('b'), 'web_search_tap') $$,
  '42703', null,
  'events has no user_id column, so an event cannot name a user'
);

select throws_ok(
  $$ insert into public.events (name) values ('search_term:cats') $$,
  '42501', null,
  'only known event names are accepted (the insert policy refuses the rest)'
);

select throws_ok(
  $$ select * from public.events $$,
  '42501', null,
  'clients cannot read events, not even their own'
);

select throws_ok(
  $$ update public.events set name = 'web_search_tap' $$,
  '42501', null,
  'clients cannot update events'
);

select throws_ok(
  $$ delete from public.events $$,
  '42501', null,
  'clients cannot delete events'
);

select tests.clear_authentication();

select results_eq(
  $$ select name, count(*)::int, bool_and(created_at = date_trunc('hour', now())) from public.events
     where id > (select max_event_id from tests.baseline) group by name $$,
  $$ values ('web_search_tap', 2, true) $$,
  'both events are stored anonymously, stamped with the server hour (the client''s date is ignored)'
);

-- ---- anon -----------------------------------------------------------------
select tests.become_anon();

select throws_ok($$ select 1 from public.profiles $$, '42501', null, 'anon cannot read profiles');
select throws_ok($$ select 1 from public.quotes $$, '42501', null, 'anon cannot read quotes');
select throws_ok($$ select 1 from public.friendships $$, '42501', null, 'anon cannot read friendships');
select throws_ok($$ select 1 from public.blocks $$, '42501', null, 'anon cannot read blocks');
select throws_ok($$ select 1 from public.conversations $$, '42501', null, 'anon cannot read conversations');
select throws_ok($$ select 1 from public.conversation_members $$, '42501', null, 'anon cannot read conversation members');
select throws_ok($$ select 1 from public.messages $$, '42501', null, 'anon cannot read messages');
select throws_ok($$ select 1 from public.reports $$, '42501', null, 'anon cannot read reports');
select throws_ok($$ select 1 from public.starter_quotes $$, '42501', null, 'anon cannot read starter quotes');
select throws_ok($$ select 1 from public.events $$, '42501', null, 'anon cannot read events');

select throws_ok(
  $$ insert into public.quotes (owner_id, body) values (tests.uid('a'), 'anon write') $$,
  '42501', null,
  'anon cannot write quotes'
);

select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('a'), 'anon_write') $$,
  '42501', null,
  'anon cannot write profiles'
);

select throws_ok(
  $$ insert into public.events (name) values ('web_search_tap') $$,
  '42501', null,
  'anon cannot write events'
);

select throws_ok(
  $$ update public.conversation_members set last_read_at = now() $$,
  '42501', null,
  'anon cannot update conversation members'
);

select throws_ok(
  $$ delete from public.friendships $$,
  '42501', null,
  'anon cannot delete friendships'
);

select throws_ok(
  $$ select private.is_blocked_pair(tests.uid('a'), tests.uid('b')) $$,
  '42501', null,
  'anon cannot call private functions'
);

select tests.clear_authentication();

select results_eq(
  $$ select (select count(*)::int from public.quotes where owner_id in (tests.uid('a'), tests.uid('b'))),
            (select count(*)::int from public.profiles where id in (tests.uid('a'), tests.uid('b'))) $$,
  $$ values (0, 2) $$,
  'nothing was written by anon'
);

select * from finish();
rollback;
