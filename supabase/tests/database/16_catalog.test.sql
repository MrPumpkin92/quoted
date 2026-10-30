-- The verified catalog (supabase/migrations/20261028120000_catalog_corpus.sql and the generated
-- *_catalog_batch_NNN.sql files): format and provenance rules for every row, the public-domain rule
-- for every non-starter, the starter_quotes view, the seal, and the lifecycle (reseal, withdraw,
-- replacement, unstar, freeze, never delete). Plan: docs/catalog-population-plan.md sections 3 and 6.
--
-- The rules run first over whatever the migrations loaded (the 60 starters plus any batches), then
-- the lifecycle runs on fixture rows with ids from 900001, rolled back with the transaction.
--
-- Ported to 20261030030300_conversations_and_messages: shares became quote messages, so the reseal
-- and the withdrawal recheck a message where they rechecked a share (and posts, which hold quote
-- snapshots too). Removed: none. The seal on messages and posts in depth: 24_catalog_social.
--
-- The public-domain cutoffs are computed from an as-of date: set quoted.as_of (for example
-- `set quoted.as_of = '2027-01-01'` before a Public Domain Day batch) or it defaults to today.
-- The starters' own authors, works and provenance arrive with M2; until then they are exempt from
-- the provenance and public-domain checks.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(68);

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

create function tests.verified(n int) returns integer language sql stable as $$
  select verified_starter_id from public.quotes where id = tests.qid(n)
$$;

-- The as-of date and the two public-domain cutoffs (plan section 3.1).
create function tests.as_of() returns date language sql stable as $$
  select coalesce(nullif(current_setting('quoted.as_of', true), '')::date, current_date)
$$;
-- US: the text used was first published at least 95 full years before the as-of year.
create function tests.us_cutoff(d date) returns integer language sql immutable as $$
  select extract(year from d)::int - 96
$$;
-- Strict (every App Store storefront): life+80 (Colombia, Spain), capped by Mexico's life+100
-- for deaths after 1951.
create function tests.strict_cutoff(d date) returns integer language sql immutable as $$
  select least(extract(year from d)::int - 81, greatest(1951, extract(year from d)::int - 101))
$$;
-- ---------------------------------------------------------------------------

select tests.create_user('a');
select tests.create_user('b');
insert into public.profiles (id, username) values (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob');

-- ==== 1. Rules over the loaded rows =========================================

-- ---- format -----------------------------------------------------------------
select is(
  (select pg_get_constraintdef(oid) from pg_constraint where conname = 'catalog_quotes_body_length'),
  'CHECK ((char_length(body) <= 280))',
  'every catalog body is at most 280 characters'
);

select is_empty(
  $$ select id from public.catalog_quotes
     where status <> 'withdrawn'
       and not (themes <@ array['courage', 'calm', 'time', 'love', 'nature', 'purpose', 'self']
                and cardinality(themes) between 1 and 3) $$,
  'every row has 1-3 of the seven themes'
);

select is_empty(
  $$ select id from public.catalog_quotes where body_format <> '[]'::jsonb $$,
  'every catalog quote is plain text (body_format is an empty run array)'
);

select is_empty(
  $$ select id from public.catalog_quotes
     where body <> btrim(body, E' \n\t') or body like E'% \n%' or body like E'%\n %' or body like '%  %'
        or author <> btrim(author) or source <> btrim(source) $$,
  'no stray whitespace in body, author or source'
);

select is_empty(
  $$ select id from public.catalog_quotes where body ~ '[''"]' or author ~ '[''"]' or source ~ '[''"]' $$,
  'apostrophes and quotation marks are typographic, never straight'
);

select is_empty(
  $$ select id from public.catalog_quotes
     where body like '%...%' or body ~ '…[^ \n]' or body ~ '[^ \n]…' $$,
  'elisions are " … " with a space or line break on both sides, never three dots'
);

select is_empty(
  $$ select id from public.catalog_quotes
     where source_url !~ '^https://' or private.is_blank(source_location) $$,
  'every row links its https source and says where in the work it is'
);

select is_empty(
  $$ select md5(body) from public.catalog_quotes where status <> 'withdrawn'
     group by md5(body) having count(*) > 1 $$,
  'no two current rows share a body'
);

select is_empty(
  $$ select lower(regexp_replace(body, '[^[:alnum:]]+', '', 'g')) from public.catalog_quotes
     where status <> 'withdrawn'
     group by 1 having count(*) > 1 $$,
  'no two current rows differ only in punctuation, spacing or case'
);

-- ---- provenance (non-starters; the starters' arrives with M2) ---------------
select is_empty(
  $$ select id from public.catalog_quotes
     where not is_starter
       and not (num_nonnulls(checked_ebook_id, checked_wikisource_oldid) = 1
                and num_nulls(checked_body_sha256, checked_start, checked_end, match_kind, checked_at,
                              verifier_version, author_id, work_id) = 0
                and checked_at <= now()) $$,
  'every non-starter names its author, work and the exact text and span it was checked against'
);

select is_empty(
  $$ select q.id from public.catalog_quotes q join public.catalog_works w on w.id = q.work_id
     where q.checked_ebook_id is not null and q.checked_ebook_id is distinct from w.gutenberg_id $$,
  'a Gutenberg check is against the work''s pinned ebook'
);

select is_empty(
  $$ select q.id from public.catalog_quotes q
     join public.catalog_authors a on a.id = q.author_id
     join public.catalog_works w on w.id = q.work_id
     where q.author <> a.name or q.source <> w.citation $$,
  'author and source are exactly the credited author''s name and the work''s citation (the seal key)'
);

select is_empty(
  $$ select translator from public.catalog_works where translator is not null and reporter is null
     group by translator having count(distinct contributors_last_died_year) > 1 $$,
  'a translator has one death year across works'
);

select is_empty(
  $$ select id from public.catalog_quotes where speaker is not null and private.is_blank(speaker) $$,
  'speakers are never blank'
);

-- ---- public-domain rule (non-starters), from the as-of date -----------------
select is_empty(
  format($$ select q.id from public.catalog_quotes q join public.catalog_works w on w.id = q.work_id
            where not q.is_starter and q.status <> 'withdrawn' and w.edition_year > %s $$,
         tests.us_cutoff(tests.as_of())),
  'US: every non-starter''s text was published at least 95 full years before the as-of year'
);

select is_empty(
  format($$ select q.id from public.catalog_quotes q
            join public.catalog_authors ca on ca.id = q.author_id
            join public.catalog_works w on w.id = q.work_id
            join public.catalog_authors wa on wa.id = w.author_id
            where not q.is_starter and q.status <> 'withdrawn'
              and (ca.died_year is null or wa.died_year is null
                   or greatest(ca.died_year, wa.died_year, w.contributors_last_died_year) > %s) $$,
         tests.strict_cutoff(tests.as_of())),
  'strict: every non-starter''s author, work author, translator and reporter died by the strict cutoff'
);

select is_empty(
  $$ select id from public.catalog_quotes where not is_starter and rights_note is not null $$,
  'no non-starter ships as a rights exception'
);

select results_eq(
  $$ select tests.us_cutoff(d), tests.strict_cutoff(d)
     from unnest(array['2026-10-28', '2026-12-31', '2027-01-01', '2052-06-01', '2053-01-01']::date[])
       with ordinality as t (d, n) order by n $$,
  $$ values (1930, 1945), (1930, 1945), (1931, 1946), (1956, 1951), (1957, 1952) $$,
  'the cutoffs move on 1 January: 1930/1945 in 2026, 1931/1946 in 2027, Mexico caps strict at 1951 until 2052'
);

-- ---- starters ---------------------------------------------------------------
select is(
  (select md5(string_agg(id::text || chr(31) || body || chr(31) || author || chr(31) || source, chr(30) order by id))
   from public.catalog_quotes where is_starter),
  '8eb60da0d520a0a978fc8d1bee7c6f0e',
  'the 60 starters'' ids, bodies, authors and sources are exactly as 20261019040100 shipped them'
);

select results_eq(
  $$ select count(*)::int, count(*) filter (where status = 'live')::int, min(sort_order), max(sort_order)
     from public.catalog_quotes where is_starter $$,
  $$ values (60, 60, 1, 60) $$,
  '60 starters, all live, in onboarding positions 1-60'
);

select is_empty(
  $$ select id from public.catalog_quotes where is_starter <> (sort_order is not null) $$,
  'only starters have an onboarding position'
);

-- ---- the table contract ----------------------------------------------------------
select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default", is_nullable::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'catalog_quotes'
     order by ordinal_position $$,
  $$ values
       ('id', 'integer', 'NO'), ('body', 'text', 'NO'), ('body_format', 'jsonb', 'NO'),
       ('author', 'text', 'NO'), ('source', 'text', 'NO'), ('sort_order', 'integer', 'YES'),
       ('source_location', 'text', 'NO'), ('source_url', 'text', 'NO'), ('is_starter', 'boolean', 'NO'),
       ('author_id', 'integer', 'YES'), ('work_id', 'integer', 'YES'), ('speaker', 'text', 'YES'),
       ('themes', 'ARRAY', 'NO'), ('status', 'text', 'NO'), ('withdrawn_at', 'timestamp with time zone', 'YES'),
       ('withdrawn_reason', 'text', 'YES'), ('replaced_by', 'integer', 'YES'), ('rights_note', 'text', 'YES'),
       ('checked_ebook_id', 'integer', 'YES'), ('checked_wikisource_oldid', 'bigint', 'YES'),
       ('checked_body_sha256', 'text', 'YES'), ('checked_start', 'integer', 'YES'), ('checked_end', 'integer', 'YES'),
       ('match_kind', 'text', 'YES'), ('checked_at', 'timestamp with time zone', 'YES'),
       ('verifier_version', 'text', 'YES'), ('added_at', 'timestamp with time zone', 'NO') $$,
  'catalog_quotes has the agreed columns'
);

select is(
  (select pg_get_indexdef('public.catalog_quotes_body_md5_key'::regclass)),
  'CREATE UNIQUE INDEX catalog_quotes_body_md5_key ON public.catalog_quotes USING btree (md5(body)) WHERE (status <> ''withdrawn''::text)',
  'the seal looks rows up by md5(body), unique among rows that are not withdrawn'
);

select is(
  (select pg_get_indexdef('public.catalog_quotes_starter_sort_order_key'::regclass)),
  'CREATE UNIQUE INDEX catalog_quotes_starter_sort_order_key ON public.catalog_quotes USING btree (sort_order) WHERE (sort_order IS NOT NULL)',
  'onboarding positions are unique'
);

select results_eq(
  $$ select p.proname::text collate "default",
            bool_or(has_function_privilege(r.rolname, p.oid, 'execute'))
     from pg_proc p cross join (values ('anon'), ('authenticated'), ('service_role')) as r (rolname)
     where p.pronamespace = 'private'::regnamespace and p.proname like 'catalog\_%'
     group by p.proname order by p.proname $$,
  $$ values ('catalog_quotes_guard', false), ('catalog_quotes_no_delete', false), ('catalog_reseal', false),
            ('catalog_set_replacement', false), ('catalog_unstar', false), ('catalog_withdraw', false) $$,
  'no API role can run the catalog lifecycle functions (only migrations do)'
);

-- ==== 2. Fixtures ==============================================================
insert into public.catalog_authors (id, slug, name, died_year) values
  (900001, 'test-author', 'Test Author', 1850),
  (900002, 'test-corrected-author', 'Corrected Author', 1860);
insert into public.catalog_works (id, author_id, citation, edition_year, gutenberg_id) values
  (900001, 900001, 'Test Work', 1890, 999999),
  (900002, 900002, 'Test Work', 1890, 999998);

create function tests.add_quote(p_id integer, p_body text, p_author_id integer default 900001,
                                p_status text default 'live') returns void language sql as $$
  insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes, status,
                                     author_id, work_id, checked_ebook_id, checked_body_sha256,
                                     checked_start, checked_end, match_kind, checked_at, verifier_version)
  select p_id, p_body, a.name, 'Test Work', 'Chapter 1', 'https://www.gutenberg.org/ebooks/' || w.gutenberg_id,
         array['calm'], p_status, a.id, w.id, w.gutenberg_id, repeat('a', 64), 0, char_length(p_body), 'exact',
         now(), 'abcdef1'
  from public.catalog_authors a join public.catalog_works w on w.author_id = a.id
  where a.id = p_author_id
$$;

-- ---- what a non-starter row must carry ---------------------------------------
select throws_ok(
  $$ insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes)
     values (900090, 'No provenance.', 'Test Author', 'Test Work', 'Chapter 1', 'https://example.org/t', array['calm']) $$,
  '23514', 'new row for relation "catalog_quotes" violates check constraint "catalog_quotes_attribution"',
  'a non-starter must name its author and work'
);

select throws_ok(
  $$ insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes, author_id, work_id)
     values (900091, 'No provenance.', 'Test Author', 'Test Work', 'Chapter 1', 'https://example.org/t', array['calm'],
             900001, 900001) $$,
  '23514', 'new row for relation "catalog_quotes" violates check constraint "catalog_quotes_provenance"',
  'a non-starter must pin the text it was checked against'
);

select throws_ok(
  $$ select tests.add_quote(900092, repeat('long ', 56) || 'x') $$,
  '23514', 'new row for relation "catalog_quotes" violates check constraint "catalog_quotes_body_length"',
  'a body over 280 characters is refused'
);

select throws_ok(
  $$ insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes, author_id, work_id)
     values (900093, 'Too many themes.', 'Test Author', 'Test Work', 'Chapter 1', 'https://example.org/t',
             array['calm', 'love', 'time', 'self'], 900001, 900001) $$,
  '23514', null,
  'a row has at most three themes'
);

select tests.add_quote(900001, 'A test line that is live in the catalog.');
select tests.add_quote(900002, 'A test line that was retired.', p_status => 'retired');
select tests.add_quote(900003, 'A test line with a wrong credit.');

select throws_ok(
  $$ select tests.add_quote(900094, 'A test line that is live in the catalog.') $$,
  '23505', null,
  'a second current row with the same body is refused'
);

-- ---- the starter_quotes view hides everything but the live starters ----------
-- A retired starter (in its own onboarding position), never shown to old builds.
insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes, is_starter, sort_order,
                                   status)
values (900010, 'A retired test starter.', 'Test Author', 'Test Work', 'Chapter 1', 'https://example.org/t',
        array['calm'], true, 32000, 'retired');

select tests.authenticate_as('a');

select lives_ok(
  $$ select id, body, body_format, author, source, sort_order, source_location, source_url from public.starter_quotes $$,
  'build 5 and 6''s starter select works on the view'
);

select lives_ok(
  $$ select id, body, body_format, author, source, sort_order from public.starter_quotes $$,
  'build 4''s six-column starter select works on the view'
);

select results_eq(
  $$ select id from public.starter_quotes order by sort_order $$,
  $$ select g from generate_series(1, 60) g $$,
  'the view lists exactly the 60 live starters, in onboarding order (no catalog row, no retired starter)'
);

select results_eq(
  $$ select count(*)::int from public.catalog_quotes where id between 900001 and 900010 $$,
  $$ values (4) $$,
  'signed-in users can read every catalog row, retired ones included'
);

select throws_ok(
  $$ update public.catalog_authors set died_year = 1999 where id = 900001 $$,
  '42501', null,
  'clients cannot edit catalog authors'
);

select throws_ok(
  $$ delete from public.catalog_works where id = 900001 $$,
  '42501', null,
  'clients cannot delete catalog works'
);

-- ---- the seal covers the whole catalog -----------------------------------------
insert into public.quotes (id, body, author, source)
  values (tests.qid(1), 'A test line that is live in the catalog.', 'Test Author', 'Test Work'),
         (tests.qid(2), 'A test line that was retired.', 'Test Author', 'Test Work'),
         (tests.qid(3), 'A test line that is live in the catalog.', 'Someone Else', 'Test Work'),
         (tests.qid(4), 'A test line with a wrong credit.', 'Test Author', 'Test Work'),
         (tests.qid(5), 'A line that reaches the catalog later.', 'Test Author', 'Test Work');
select tests.clear_authentication();

select is(tests.verified(1), 900001, 'a copy of a non-starter catalog row is verified (the seal reads the table, not the view)');
select is(tests.verified(2), 900002, 'retired rows still seal');
select is(tests.verified(3), null::integer, 'a different author is not verified');
select is(tests.verified(5), null::integer, 'a line not yet in the catalog is not verified');

-- ---- a batch arrives: reseal -------------------------------------------------------
-- A quote message the server writes (as the move of shares did), so its snapshot is exactly this.
insert into public.conversations (id, user_a, user_b) values (tests.qid(30), tests.uid('a'), tests.uid('b'));
insert into public.messages (id, conversation_id, sender_id, kind, body, author, source)
  values (tests.qid(31), tests.qid(30), tests.uid('a'), 'quote', 'A line that reaches the catalog later.', 'Test Author',
          'Test Work');
create table tests.before_reseal as select updated_at from public.quotes where id = tests.qid(5);

select tests.add_quote(900004, 'A line that reaches the catalog later.');
select is(tests.verified(5), null::integer, 'inserting a catalog row does not touch existing copies by itself');

select results_eq(
  $$ select * from private.catalog_reseal(array[900004]) $$,
  $$ values (1, 1, 0) $$,
  'catalog_reseal rechecks the one matching quote and the one matching message (no post matches)'
);
select is(tests.verified(5), 900004, 'after the reseal, the earlier copy is verified');
select is((select verified_starter_id from public.messages where id = tests.qid(31)), 900004,
  'after the reseal, the earlier message is verified');
select is((select updated_at from public.quotes where id = tests.qid(5)), (select updated_at from tests.before_reseal),
  'a reseal does not look like an edit (updated_at unchanged)');

-- ---- frozen text, never deleted ------------------------------------------------------
select throws_ok($$ update public.catalog_quotes set body = 'Edited.' where id = 900001 $$, '42501', null,
  'a catalog body never changes, even for the table owner');
select throws_ok($$ update public.catalog_quotes set author = 'Corrected Author' where id = 900001 $$, '42501', null,
  'a catalog author never changes');
select throws_ok($$ update public.catalog_quotes set source = 'Another Work' where id = 900001 $$, '42501', null,
  'a catalog source never changes');
select throws_ok($$ update public.catalog_quotes set id = 900099 where id = 900001 $$, '42501', null,
  'a catalog id never changes');
select throws_ok($$ delete from public.catalog_quotes where id = 900001 $$, '42501', null,
  'catalog rows are never deleted');
-- The message above queued its deferred foreign key checks (20261030030300), and TRUNCATE refuses a
-- table with pending trigger events before any trigger runs; run the checks first, as a fresh
-- transaction would have none.
set constraints all immediate;
select throws_ok($$ truncate public.catalog_quotes cascade $$, '42501', null,
  'catalog rows are never truncated');
select lives_ok($$ update public.catalog_quotes set themes = array['calm', 'time'] where id = 900001 $$,
  'themes can change (they are not part of the seal)');

-- ---- a correction: same body, corrected author --------------------------------------
select results_eq(
  $$ select * from private.catalog_withdraw(900003, 'Credited to the wrong person: the line is Corrected Author''s.') $$,
  $$ values (1, 0, 0) $$,
  'withdrawing a row rechecks its copies'
);
select is(tests.verified(4), null::integer, 'withdrawing a catalog row takes the seal off its copies');

select results_eq(
  $$ select status, withdrawn_at is not null, withdrawn_reason is not null from public.catalog_quotes where id = 900003 $$,
  $$ values ('withdrawn'::text, true, true) $$,
  'a withdrawn row keeps its text and records when and why'
);

select tests.add_quote(900005, 'A test line with a wrong credit.', p_author_id => 900002);
select pass('the corrected row (same body, new author) goes in once the old one is withdrawn');

select throws_ok($$ update public.catalog_quotes set replaced_by = 900005 where id = 900003 $$, '42501', null,
  'replaced_by is set only through catalog_set_replacement');
select lives_ok($$ select private.catalog_set_replacement(900003, 900005) $$,
  'catalog_set_replacement points the withdrawn row at its correction');
select is((select replaced_by from public.catalog_quotes where id = 900003), 900005,
  'the withdrawn row names its replacement');
select throws_ok($$ select private.catalog_set_replacement(900001, 900005) $$, '22023', null,
  'only a withdrawn row can be replaced');
select throws_ok($$ update public.catalog_quotes set status = 'live' where id = 900003 $$, '42501', null,
  'withdrawal is final');

select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  values (tests.qid(6), 'A test line with a wrong credit.', 'Test Author', 'Test Work'),
         (tests.qid(7), 'A test line with a wrong credit.', 'Corrected Author', 'Test Work');
select tests.clear_authentication();
select is(tests.verified(6), null::integer, 'a fresh copy of the withdrawn wording stays unsealed');
select is(tests.verified(7), 900005, 'a copy of the corrected row is sealed to the correction');

-- ---- unstar: freeing a retired starter's onboarding slot ----------------------------
select throws_ok($$ select private.catalog_unstar(900001) $$, '22023', null,
  'only a retired starter can be unstarred');
select throws_ok($$ select private.catalog_unstar(900010) $$, '23514', null,
  'a starter needs its author, work and provenance before it stops being a starter');

update public.catalog_quotes
set author_id = 900001, work_id = 900001, checked_ebook_id = 999999, checked_body_sha256 = repeat('b', 64),
    checked_start = 10, checked_end = 30, match_kind = 'exact', checked_at = now(), verifier_version = 'abcdef1'
where id = 900010;
select lives_ok($$ select private.catalog_unstar(900010) $$, 'a retired starter with provenance can be unstarred');
select results_eq(
  $$ select is_starter, sort_order, status from public.catalog_quotes where id = 900010 $$,
  $$ values (false, null::integer, 'retired'::text) $$,
  'unstarring clears the onboarding position and keeps the row retired'
);

-- ---- anon ----------------------------------------------------------------------------
select tests.become_anon();
select throws_ok($$ select 1 from public.starter_quotes $$, '42501', null, 'anon cannot read the starter view');
select tests.clear_authentication();

select * from finish();
rollback;
