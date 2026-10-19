-- Starter pack seed (supabase/migrations/20261019040100_starter_pack.sql):
-- exactly 60 rows, readable by any signed-in user and by nobody without a
-- session. Sources: docs/starter-pack-sources.md
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.uid() returns uuid language sql immutable as $$
  select 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid
$$;

-- A freshly signed-up user with no profile yet: onboarding reads the pack
-- before the username step finishes, so the pack must not depend on profiles.
create function tests.create_user() returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', tests.uid(), 'authenticated', 'authenticated',
          'starter@test.quoted.invalid', '', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now())
  returning id
$$;

create function tests.authenticate() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(), 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$$;

create function tests.become_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
end
$$;

create function tests.clear_authentication() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;
-- ---------------------------------------------------------------------------

select tests.create_user();

-- ---- seeded content (as the table owner, RLS bypassed) ---------------------
select is(
  (select count(*)::int from public.starter_quotes),
  60,
  'the migration seeds exactly 60 starter quotes'
);

select set_eq(
  $$ select id::int as id, sort_order::int as sort_order from public.starter_quotes $$,
  $$ select g as id, g as sort_order from generate_series(1, 60) g $$,
  'ids and sort_order both run 1..60 with no gaps'
);

-- ---- authenticated --------------------------------------------------------
select tests.authenticate();

select is(
  (select count(*)::int from public.starter_quotes),
  60,
  'a signed-in user (no profile yet) can read all 60 starter quotes'
);

select results_eq(
  $$ select author, source from public.starter_quotes order by sort_order limit 1 $$,
  $$ values ('Ralph Waldo Emerson'::text, 'Self-Reliance'::text) $$,
  'onboarding order starts with the first mockup quote'
);

select is_empty(
  $$ select id from public.starter_quotes where body_format <> '[]'::jsonb $$,
  'every starter quote is plain text (body_format is an empty run array)'
);

select is(
  (select count(distinct author)::int from public.starter_quotes),
  59,
  '59 distinct authors (Shakespeare appears twice)'
);

select is_empty(
  $$ select id from public.starter_quotes
     where body <> btrim(body, E' \n\t') or author <> btrim(author) or source is null or source = '' $$,
  'no stray whitespace in body or author, and every quote names its source'
);

select is(
  (select count(*)::int from public.starter_quotes where body like E'%\n%'),
  18,
  '18 verse quotes keep their line breaks as real newlines'
);

select is_empty(
  $$ select id from public.starter_quotes where body ~ '[''"]' or author ~ '[''"]' or source ~ '[''"]' $$,
  'apostrophes and quotation marks are typographic, never straight'
);

select tests.clear_authentication();

-- ---- anon (publishable key, no session) -----------------------------------
select ok(
  not has_table_privilege('anon', 'public.starter_quotes', 'select'),
  'anon has no SELECT privilege on starter_quotes'
);

select tests.become_anon();

select throws_ok(
  $$ select count(*) from public.starter_quotes $$,
  '42501', null,
  'anon reads of starter_quotes are refused, so no rows are visible'
);

select tests.clear_authentication();

select is(
  (select count(*)::int from public.starter_quotes),
  60,
  'the pack is unchanged after the client checks'
);

select * from finish();
rollback;
