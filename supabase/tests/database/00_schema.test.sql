-- Schema contract: RLS everywhere, explicit grants, nothing for anon, named
-- foreign keys (PostgREST embedding hints), indexed foreign keys and safe
-- private functions. See docs/system-design.md section 3.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(20);

select tables_are(
  'public',
  array['profiles', 'quotes', 'friendships', 'blocks', 'shares', 'reports',
        'catalog_authors', 'catalog_works', 'catalog_quotes', 'events'],
  'public has exactly the MVP tables'
);

-- builds up to 6 read the starter pack through this view (20261028120000_catalog_corpus).
select views_are('public', array['starter_quotes'], 'public has exactly one view, starter_quotes');

select is(
  (select reloptions from pg_class where oid = 'public.starter_quotes'::regclass),
  array['security_invoker=true'],
  'starter_quotes runs as the caller, so catalog_quotes RLS applies through it'
);

select is_empty(
  $$ select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity $$,
  'RLS is enabled on every public table'
);

select is_empty(
  $$ select table_name, privilege_type from information_schema.role_table_grants
     where grantee in ('anon', 'PUBLIC') and table_schema = 'public' $$,
  'anon and PUBLIC have no table privileges in public'
);

select is_empty(
  $$ select table_name, column_name from information_schema.column_privileges
     where grantee in ('anon', 'PUBLIC') and table_schema = 'public' $$,
  'anon and PUBLIC have no column privileges in public'
);

select is_empty(
  $$ select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
       and (has_sequence_privilege('anon', c.oid, 'usage') or has_sequence_privilege('authenticated', c.oid, 'usage')) $$,
  'anon and authenticated cannot use public sequences'
);

select results_eq(
  $$ select table_name::text collate "default", string_agg(privilege_type, ',' order by privilege_type) collate "default"
     from information_schema.role_table_grants
     where grantee = 'authenticated' and table_schema = 'public'
     group by table_name order by table_name $$,
  $$ values
       ('blocks', 'DELETE,INSERT,SELECT'),
       ('catalog_authors', 'SELECT'),
       ('catalog_quotes', 'SELECT'),
       ('catalog_works', 'SELECT'),
       ('events', 'INSERT'),
       ('friendships', 'DELETE,INSERT,SELECT'),
       ('profiles', 'INSERT,SELECT,UPDATE'),
       ('quotes', 'DELETE,INSERT,SELECT,UPDATE'),
       ('reports', 'INSERT,SELECT'),
       ('shares', 'DELETE,INSERT,SELECT'),
       ('starter_quotes', 'SELECT') $$,
  'authenticated has exactly the intended table privileges'
);

select results_eq(
  $$ select table_name::text collate "default", string_agg(column_name, ',' order by column_name) collate "default"
     from information_schema.column_privileges
     where grantee = 'authenticated' and table_schema = 'public' and privilege_type = 'UPDATE'
       and table_name in ('shares', 'friendships')
     group by table_name order by table_name $$,
  $$ values ('friendships', 'responded_at,status'), ('shares', 'saved_at,seen_at') $$,
  'column-level UPDATE: friendships (status, responded_at), shares (seen_at, saved_at)'
);

select results_eq(
  $$ select conrelid::regclass::text, conname::text collate "default", confrelid::regclass::text, confdeltype::text
     from pg_constraint
     where contype = 'f' and connamespace = 'public'::regnamespace
     order by 1, 2 $$,
  $$ values
       ('blocks', 'blocks_blocked_id_fkey', 'profiles', 'c'),
       ('blocks', 'blocks_blocker_id_fkey', 'profiles', 'c'),
       ('catalog_quotes', 'catalog_quotes_author_id_fkey', 'catalog_authors', 'a'),
       ('catalog_quotes', 'catalog_quotes_replaced_by_fkey', 'catalog_quotes', 'a'),
       ('catalog_quotes', 'catalog_quotes_work_id_fkey', 'catalog_works', 'a'),
       ('catalog_works', 'catalog_works_author_id_fkey', 'catalog_authors', 'a'),
       ('friendships', 'friendships_addressee_id_fkey', 'profiles', 'c'),
       ('friendships', 'friendships_requester_id_fkey', 'profiles', 'c'),
       ('profiles', 'profiles_id_fkey', 'auth.users', 'c'),
       ('quotes', 'quotes_owner_id_fkey', 'auth.users', 'c'),
       ('quotes', 'quotes_verified_starter_id_fkey', 'catalog_quotes', 'n'),
       ('reports', 'reports_reported_user_id_fkey', 'profiles', 'n'),
       ('reports', 'reports_reporter_id_fkey', 'profiles', 'n'),
       ('reports', 'reports_share_id_fkey', 'shares', 'n'),
       ('shares', 'shares_quote_id_fkey', 'quotes', 'n'),
       ('shares', 'shares_recipient_id_fkey', 'profiles', 'c'),
       ('shares', 'shares_sender_id_fkey', 'profiles', 'c'),
       ('shares', 'shares_verified_starter_id_fkey', 'catalog_quotes', 'n') $$,
  'foreign keys have stable names, targets and delete actions (events has none; reports outlive both accounts; catalog rows are never deleted)'
);

select is_empty(
  $$ select c.conrelid::regclass, c.conname
     from pg_constraint c
     where c.contype = 'f' and c.connamespace = 'public'::regnamespace
       and not exists (
         select 1 from pg_index i
         where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]
       ) $$,
  'every foreign key column leads an index'
);

select is(
  (select pg_get_indexdef('public.friendships_pair_key'::regclass)),
  'CREATE UNIQUE INDEX friendships_pair_key ON public.friendships USING btree (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id))',
  'friendships has a unique index on the unordered pair'
);

select is(
  (select pg_get_indexdef('public.quotes_owner_id_rotation_position_idx'::regclass)),
  'CREATE INDEX quotes_owner_id_rotation_position_idx ON public.quotes USING btree (owner_id, rotation_position) WHERE (rotation_position IS NOT NULL)',
  'quotes has a partial rotation index'
);

select is_definer('private', 'is_blocked_pair', array['uuid', 'uuid'], 'private.is_blocked_pair is SECURITY DEFINER');

select is_empty(
  $$ select p.proname from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and not coalesce(p.proconfig @> array['search_path=""'], false) $$,
  'every private function pins search_path to empty'
);

select results_eq(
  $$ select has_schema_privilege('anon', 'private', 'usage'),
            has_function_privilege('anon', 'private.is_blocked_pair(uuid, uuid)', 'execute'),
            has_function_privilege('authenticated', 'private.is_blocked_pair(uuid, uuid)', 'execute') $$,
  $$ values (false, false, true) $$,
  'only authenticated can reach private.is_blocked_pair'
);

-- CHECK constraints call these as the writing role, so authenticated and
-- service_role need EXECUTE; anon never writes.
select results_eq(
  $$ select has_function_privilege('anon', 'private.is_blank(text)', 'execute'),
            has_function_privilege('anon', 'private.is_valid_body_format(jsonb)', 'execute'),
            has_function_privilege('authenticated', 'private.is_blank(text)', 'execute'),
            has_function_privilege('authenticated', 'private.is_valid_body_format(jsonb)', 'execute'),
            has_function_privilege('service_role', 'private.is_blank(text)', 'execute'),
            has_function_privilege('service_role', 'private.is_valid_body_format(jsonb)', 'execute') $$,
  $$ values (false, false, true, true, true, true) $$,
  'the CHECK validators are executable by the writing roles only'
);

select results_eq(
  $$ select has_table_privilege('anon', 'private.reports_to_review', 'select'),
            has_table_privilege('authenticated', 'private.reports_to_review', 'select'),
            has_table_privilege('service_role', 'private.reports_to_review', 'select') $$,
  $$ values (false, false, false) $$,
  'no API role can read the moderation queue view'
);

select is_empty(
  $$ select p.proname from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.prorettype = 'trigger'::regtype
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')) $$,
  'trigger functions are not directly executable by clients'
);

select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'starter_quotes'
     order by ordinal_position $$,
  $$ values
       ('id', 'integer', 'YES', null::text),
       ('body', 'text', 'YES', null),
       ('body_format', 'jsonb', 'YES', null),
       ('author', 'text', 'YES', null),
       ('source', 'text', 'YES', null),
       ('sort_order', 'integer', 'YES', null),
       ('source_location', 'text', 'YES', null),
       ('source_url', 'text', 'YES', null) $$,
  'the starter_quotes view keeps the columns builds 4-6 select (views report every column nullable; catalog_quotes'' own contract is in 16_catalog)'
);

select * from finish();
rollback;
