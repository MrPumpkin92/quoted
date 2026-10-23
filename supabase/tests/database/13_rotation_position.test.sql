-- quotes_place_in_rotation (supabase/migrations/20261021100000_rotation_position_on_insert.sql):
-- a new quote whose requested Rotation position is taken joins the end of the
-- owner's Rotation; a free position, a null position and an existing id are
-- left alone; rows earlier in the same bulk insert count; other users'
-- positions don't.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(13);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.create_user(who text) returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', tests.uid(who), 'authenticated', 'authenticated',
          who || '@test.quoted.invalid', '', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now())
  returning id
$$;

create function tests.authenticate_as(who text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(who), 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$$;

create function tests.clear_authentication() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

create function tests.position(n int) returns integer language sql stable as $$
  select rotation_position from public.quotes where id = tests.qid(n)
$$;
-- ---------------------------------------------------------------------------

-- A's Rotation is quotes 1, 2, 3 at positions 0, 1, 2. B has no quotes.
select tests.create_user('a');
select tests.create_user('b');
insert into public.quotes (id, owner_id, body, rotation_position) values
  (tests.qid(1), tests.uid('a'), 'One', 0),
  (tests.qid(2), tests.uid('a'), 'Two', 1),
  (tests.qid(3), tests.uid('a'), 'Three', 2);

select ok(
  not has_function_privilege('authenticated', 'private.quotes_place_in_rotation()', 'execute'),
  'clients cannot call the trigger function'
);

select tests.authenticate_as('a');
-- A stale copy asks for position 1, which quote 2 holds.
insert into public.quotes (id, body, rotation_position) values (tests.qid(4), 'Four', 1);
-- A free position (a gap after the end) is kept.
insert into public.quotes (id, body, rotation_position) values (tests.qid(5), 'Five', 10);
-- Not in the Rotation.
insert into public.quotes (id, body, rotation_position) values (tests.qid(6), 'Six', null);
-- A bulk insert where every row asks for the same position (11, then taken).
insert into public.quotes (id, body, rotation_position) values
  (tests.qid(7), 'Seven', 11),
  (tests.qid(8), 'Eight', 11),
  (tests.qid(9), 'Nine', 11);
select tests.clear_authentication();

select is(tests.position(4), 3, 'a taken position moves to the end of the Rotation');
select is(tests.position(2), 1, 'the quote holding the position keeps it');
select is(tests.position(5), 10, 'a free position is kept');
select is(tests.position(6), null::integer, 'a quote outside the Rotation stays outside');
select is(tests.position(7), 11, 'the first row of a bulk insert keeps its free position');
select is(tests.position(8), 12, 'later rows of the same insert see the earlier ones');
select is(tests.position(9), 13, 'each taken position moves past the last one');

-- An upsert of an existing id writes the given position (restoring a quote that still exists).
select tests.authenticate_as('a');
insert into public.quotes (id, body, rotation_position) values (tests.qid(1), 'One', 2)
  on conflict (id) do update set rotation_position = excluded.rotation_position;
select tests.clear_authentication();
select is(tests.position(1), 2, 'an existing id keeps the position it was given');

-- Undo of a delete: the restored quote returns to its free position.
delete from public.quotes where id = tests.qid(2);
select tests.authenticate_as('a');
insert into public.quotes (id, body, rotation_position) values (tests.qid(2), 'Two', 1);
select tests.clear_authentication();
select is(tests.position(2), 1, 'a restored quote returns to its free position');

-- Another user's positions don't count; an empty Rotation starts at 0.
select tests.authenticate_as('b');
insert into public.quotes (id, body, rotation_position) values (tests.qid(20), 'Twenty', 0);
insert into public.quotes (id, body, rotation_position) values (tests.qid(21), 'Twenty-one', 0);
select tests.clear_authentication();
select is(tests.position(20), 0, 'another user''s position 0 does not count');
select is(tests.position(21), 1, 'a position asked for before the library loaded moves to the end');

-- A retried insert of an existing id still fails on the primary key, unchanged.
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.quotes (id, body, rotation_position) values (tests.qid(4), 'Four', 0) $$,
  '23505', null,
  'a retried insert fails on the primary key'
);
select tests.clear_authentication();

select * from finish();
rollback;
