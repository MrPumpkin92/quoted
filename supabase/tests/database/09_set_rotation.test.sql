-- public.set_rotation (supabase/migrations/20261019070000_set_rotation.sql): the
-- Rotation write takes ids only, numbers the caller's own quotes without gaps,
-- never inserts (no resurrection), never writes content, and is executable by
-- signed-in users only.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(21);

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

-- A owns quotes 1-4 (1 and 2 in the Rotation, 4 at position 7); B owns quote 9.
select tests.create_user('a');
select tests.create_user('b');
insert into public.quotes (id, owner_id, body, rotation_position) values
  (tests.qid(1), tests.uid('a'), 'One', 0),
  (tests.qid(2), tests.uid('a'), 'Two', 1),
  (tests.qid(3), tests.uid('a'), 'Three', null),
  (tests.qid(4), tests.uid('a'), 'Four', 7),
  (tests.qid(9), tests.uid('b'), 'Nine', 0);

-- ---- privileges and shape --------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.set_rotation(uuid[], uuid[])', 'execute'),
  'anon cannot execute set_rotation'
);
select ok(
  has_function_privilege('authenticated', 'public.set_rotation(uuid[], uuid[])', 'execute'),
  'authenticated can execute set_rotation'
);
select ok(
  not (select prosecdef from pg_proc where oid = 'public.set_rotation(uuid[], uuid[])'::regprocedure),
  'set_rotation is SECURITY INVOKER (RLS applies)'
);
select ok(
  (select 'search_path=""' = any(proconfig) from pg_proc where oid = 'public.set_rotation(uuid[], uuid[])'::regprocedure),
  'set_rotation pins search_path to empty'
);

-- ---- ordering, removal, skipping -----------------------------------------
select tests.authenticate_as('a');

-- 3, 1, 3 again (duplicate), B's quote 9 and an unknown id; 2 leaves.
select is(
  (select array_agg(id order by rotation_position nulls last, id)
     from public.set_rotation(
       array[tests.qid(3), tests.qid(1), tests.qid(3), tests.qid(9), tests.qid(99)],
       array[tests.qid(2)])),
  array[tests.qid(3), tests.qid(1), tests.qid(2)],
  'returns exactly the caller''s updated rows'
);

select tests.clear_authentication();
select is(tests.position(3), 0, 'the first ordered quote gets position 0');
select is(tests.position(1), 1, 'positions follow the order, a duplicate keeps its first place');
select is(tests.position(2), null::integer, 'a removed quote leaves the Rotation');
select is(tests.position(4), 7, 'a quote in neither list is not touched');
select is(tests.position(9), 0, 'another user''s quote is not touched');
select is((select count(*)::int from public.quotes where id = tests.qid(99)), 0, 'an unknown id is not inserted');
select is((select body from public.quotes where id = tests.qid(1)), 'One', 'content is not written');

-- Skipped ids leave no gap: B's quote between two of A's.
select tests.authenticate_as('a');
select is(
  (select count(*)::int from public.set_rotation(array[tests.qid(1), tests.qid(9), tests.qid(2)])),
  2,
  'only the caller''s quotes are updated'
);
select tests.clear_authentication();
select is(tests.position(2), 1, 'positions have no gap where another user''s id was skipped');

-- An id in both lists stays in the Rotation.
select tests.authenticate_as('a');
select is((select count(*)::int from public.set_rotation(array[tests.qid(1)], array[tests.qid(1), tests.qid(3)])), 2,
  'an id in both lists is updated once');
select tests.clear_authentication();
select is(tests.position(1), 0, 'an id in both lists stays in the Rotation');
select is(tests.position(3), null::integer, 'the other removed id leaves');

-- A quote deleted elsewhere is never resurrected.
delete from public.quotes where id = tests.qid(4);
select tests.authenticate_as('a');
select is(
  (select count(*)::int from public.set_rotation(array[tests.qid(4), tests.qid(2)])),
  1,
  'a deleted quote is skipped'
);
select tests.clear_authentication();
select is((select count(*)::int from public.quotes where id = tests.qid(4)), 0, 'a deleted quote is not re-inserted');

-- B cannot reorder A's quotes; null lists do nothing.
select tests.authenticate_as('b');
select is((select count(*)::int from public.set_rotation(array[tests.qid(2), tests.qid(1)], array[tests.qid(1)])), 0,
  'another user''s quotes are invisible to set_rotation');
select is((select count(*)::int from public.set_rotation(null, null)), 0, 'null lists change nothing');

select * from finish();
rollback;
