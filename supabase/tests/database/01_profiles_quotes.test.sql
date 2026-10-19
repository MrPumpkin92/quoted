-- profiles and quotes: own-row writes, no cross-user access, constraints.
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

-- ---- profiles -------------------------------------------------------------
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.profiles (id, username, display_name) values (tests.uid('a'), 'alice', 'Alice') $$,
  'A can create their own profile'
);

select throws_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('b'), 'not_bob') $$,
  '42501', null,
  'A cannot create a profile for B'
);

select tests.authenticate_as('b');
select lives_ok(
  $$ insert into public.profiles (id, username) values (tests.uid('b'), 'bob') $$,
  'B can create their own profile (display_name is optional)'
);

select tests.authenticate_as('a');

select results_eq(
  $$ select username from public.profiles where id = tests.uid('b') $$,
  $$ values ('bob') $$,
  'A can read B''s public handle'
);

select is_empty(
  $$ update public.profiles set display_name = 'Hacked' where id = tests.uid('b') returning 1 $$,
  'A cannot update B''s profile'
);

select results_eq(
  $$ update public.profiles set display_name = 'Alice A.' where id = tests.uid('a') returning display_name $$,
  $$ values ('Alice A.') $$,
  'A can update their own profile'
);

select throws_ok(
  $$ update public.profiles set id = tests.uid('b') where id = tests.uid('a') $$,
  '42501', null,
  'A cannot move their profile onto another user id'
);

select throws_ok(
  $$ update public.profiles set username = 'Not Valid!' where id = tests.uid('a') $$,
  '23514', null,
  'username must match ^[a-z0-9_.]{3,20}$'
);

select throws_ok(
  $$ update public.profiles set username = 'bob' where id = tests.uid('a') $$,
  '23505', null,
  'usernames are unique'
);

select throws_ok(
  $$ update public.profiles set display_name = repeat('x', 51) where id = tests.uid('a') $$,
  '23514', null,
  'display_name is at most 50 characters'
);

select throws_ok(
  $$ delete from public.profiles where id = tests.uid('a') $$,
  '42501', null,
  'clients cannot delete profiles (deletion cascades from auth.users)'
);

-- ---- quotes ---------------------------------------------------------------
select tests.clear_authentication();
-- B's quote, plus one of A's. Timestamps are server-owned (triggers), so even
-- the table owner's dates are replaced by the server clock.
insert into public.quotes (id, owner_id, body, author)
values ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B1', 'Bea');
insert into public.quotes (id, owner_id, body, created_at, updated_at)
values ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'A old', '2000-01-01', '2000-01-01');

select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.quotes (body, author, source, body_format)
     values ('Stay hungry', 'Someone', 'Somewhere', '[{"start":0,"length":4,"bold":true}]') $$,
  'A can create a quote (owner_id defaults to auth.uid())'
);

select results_eq(
  $$ select count(*)::int, bool_and(owner_id = tests.uid('a')) from public.quotes $$,
  $$ values (2, true) $$,
  'A sees only their own quotes'
);

select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('b') $$,
  'A cannot read B''s quotes'
);

select throws_ok(
  $$ insert into public.quotes (owner_id, body) values (tests.uid('b'), 'planted') $$,
  '42501', null,
  'A cannot create a quote owned by B'
);

select is_empty(
  $$ update public.quotes set body = 'Hacked' where owner_id = tests.uid('b') returning 1 $$,
  'A cannot update B''s quotes'
);

select is_empty(
  $$ delete from public.quotes where owner_id = tests.uid('b') returning 1 $$,
  'A cannot delete B''s quotes'
);

select throws_ok(
  $$ update public.quotes set owner_id = tests.uid('b') where id = 'a0000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'A cannot hand a quote to B'
);

select results_eq(
  $$ update public.quotes set body = 'A new', rotation_position = 0, created_at = '2000-01-01', updated_at = '2000-01-01'
     where id = 'a0000000-0000-4000-8000-000000000001'
     returning created_at = now(), updated_at = now() $$,
  $$ values (true, true) $$,
  'updating a quote stamps updated_at with the server clock and keeps created_at'
);

select throws_ok(
  $$ insert into public.quotes (body) values ('') $$,
  '23514', null,
  'body cannot be empty'
);

select throws_ok(
  $$ insert into public.quotes (body) values (repeat('x', 2001)) $$,
  '23514', null,
  'body is at most 2000 characters'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format) values ('x', '{"start":0}') $$,
  '23514', null,
  'body_format must be a JSON array'
);

select throws_ok(
  $$ insert into public.quotes (body, body_format)
     select 'x', jsonb_agg(jsonb_build_object('start', i, 'length', 1, 'bold', true))
     from generate_series(0, 200) i $$,
  '23514', null,
  'body_format holds at most 200 runs'
);

select throws_ok(
  $$ insert into public.quotes (body, origin) values ('x', 'scraped') $$,
  '23514', null,
  'origin must be manual, starter, shared or pasted'
);

select throws_ok(
  $$ insert into public.quotes (body, author) values ('x', repeat('a', 201)) $$,
  '23514', null,
  'author is at most 200 characters'
);

select throws_ok(
  $$ insert into public.quotes (body, rotation_position) values ('x', -1) $$,
  '23514', null,
  'rotation_position cannot be negative'
);

select results_eq(
  $$ delete from public.quotes where id = 'a0000000-0000-4000-8000-000000000001' returning body $$,
  $$ values ('A new') $$,
  'A can delete their own quote'
);

select tests.clear_authentication();
select results_eq(
  $$ select body from public.quotes where owner_id = tests.uid('b') $$,
  $$ values ('B1') $$,
  'B''s quote is untouched'
);

select * from finish();
rollback;
