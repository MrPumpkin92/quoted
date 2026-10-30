-- Schema contract: RLS everywhere, explicit grants, nothing for anon, named
-- foreign keys (PostgREST embedding hints), indexed foreign keys and safe
-- private functions. See docs/system-design.md section 3.
-- 20261028120000_catalog_corpus: catalog_authors, catalog_works and
-- catalog_quotes, and the starter_quotes view for builds up to 6; every
-- catalog id elsewhere points at catalog_quotes.
-- 20261030030000_provenance_and_accounts: column grants on profiles and quotes,
-- the provenance foreign keys, and the private tables no API role can read.
-- 20261030030100_playlists: the playlists and playlist_items tables, their
-- column grants and foreign keys, and the playlist RPCs and helpers.
-- 20261030030200_posts: the posts table (no client reads source_quote_id),
-- its column grants, foreign keys and indexes, and save_from_post.
-- 20261030030300_conversations_and_messages: shares is gone; conversations,
-- conversation_members and messages (column grants: no client reads
-- source_quote_id or writes a snapshot), the report targets, the deferred
-- foreign key checks, the message tombstones, and the RPCs and helpers.
-- 20261030030400_profiles_and_moderation: profile_view, the founder's
-- suspend_user and unsuspend_user, the reports triggers (target_kind and the
-- auto-hold) and the moderation queue's columns.
-- 20261030030500_forward_quotes: messages.source_post_id and source_message_id
-- (sent, never read back; deferred foreign keys with sparse indexes) and
-- private.forwardable_snapshot, for signed-in senders only.
-- 20261030030600_read_marks_reports_playlist_order: received_quotes is a
-- SECURITY INVOKER read for signed-in users only, returning only the message
-- columns clients may read; the queue gains reporters_against_user.
-- Review fixes: reporters read reports column by column (never the server's
-- copy); private.limit_deletions goes with the account; the one-time share
-- move is dropped; the word filter's folding helper, the per-account publish
-- check and the quote tombstone purge are for no API role.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(53);

select tables_are(
  'public',
  array['profiles', 'quotes', 'friendships', 'blocks', 'reports',
        'catalog_authors', 'catalog_works', 'catalog_quotes', 'events',
        'playlists', 'playlist_items', 'posts', 'conversations', 'conversation_members', 'messages'],
  'public has exactly the MVP tables (shares moved into messages), the catalog, playlists, posts and conversations'
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
       ('conversation_members', 'SELECT'),
       ('conversations', 'SELECT'),
       ('events', 'INSERT'),
       ('friendships', 'DELETE,INSERT,SELECT'),
       ('messages', 'DELETE'),
       ('playlist_items', 'DELETE,SELECT'),
       ('playlists', 'DELETE,SELECT'),
       ('posts', 'DELETE'),
       ('quotes', 'DELETE,SELECT'),
       ('reports', 'INSERT'),
       ('starter_quotes', 'SELECT') $$,
  'authenticated has exactly the intended table privileges (profiles, quotes, playlist, post and message writes and post, message and report reads are column grants)'
);

select results_eq(
  $$ select table_name::text collate "default", privilege_type::text collate "default",
            string_agg(column_name, ',' order by column_name) collate "default"
     from information_schema.column_privileges
     where grantee = 'authenticated' and table_schema = 'public'
       and table_name in ('profiles', 'quotes', 'playlists', 'playlist_items', 'posts', 'conversation_members', 'messages',
                          'reports')
       and not has_table_privilege('authenticated', format('public.%I', table_name), privilege_type)
     group by table_name, privilege_type order by 1, 2 $$,
  $$ values
       ('conversation_members', 'UPDATE', 'cleared_at,last_read_at'),
       ('messages', 'INSERT', 'conversation_id,id,kind,note,playlist_id,source_message_id,source_post_id,source_quote_id,starter_quote_id,text'),
       ('messages', 'SELECT', 'author,body,body_format,conversation_id,created_at,creator_id,creator_username,edited_from_id,edited_from_username,id,kind,note,playlist_id,playlist_title,sender_id,source,starter_quote_id,text,verified_starter_id'),
       ('playlist_items', 'INSERT', 'playlist_id,position,quote_id'),
       ('playlist_items', 'UPDATE', 'position'),
       ('playlists', 'INSERT', 'id,title,visibility'),
       ('playlists', 'UPDATE', 'title,visibility'),
       ('posts', 'INSERT', 'audience,caption,id,source_quote_id,starter_quote_id'),
       ('posts', 'SELECT', 'audience,author,author_id,body,body_format,caption,created_at,creator_id,creator_username,edited_from_id,edited_from_username,held_at,id,source,starter_quote_id,verified_starter_id'),
       ('posts', 'UPDATE', 'audience'),
       ('profiles', 'INSERT', 'display_name,id,username'),
       ('profiles', 'SELECT', 'accepts_text_messages,display_name,id,username'),
       ('profiles', 'UPDATE', 'accepts_text_messages,display_name,favorites_visibility'),
       ('quotes', 'INSERT', 'author,body,body_format,id,is_favorite,origin,rotation_position,source'),
       ('quotes', 'UPDATE', 'author,body,body_format,is_favorite,rotation_position,source'),
       ('reports', 'SELECT', 'created_at,details,id,message_id,playlist_id,post_id,reason,reported_user_id,reporter_id,starter_quote_id,target_kind') $$,
  'column grants: profiles show only their public face; quotes, playlists, posts and messages take no server-owned column; posts and messages hide source_quote_id, and messages their forward sources too; members write only their two times; reporters never read the server''s copy'
);

select results_eq(
  $$ select table_name::text collate "default", string_agg(column_name, ',' order by column_name) collate "default"
     from information_schema.column_privileges
     where grantee = 'authenticated' and table_schema = 'public' and privilege_type = 'UPDATE'
       and table_name in ('conversation_members', 'friendships')
     group by table_name order by table_name $$,
  $$ values ('conversation_members', 'cleared_at,last_read_at'), ('friendships', 'responded_at,status') $$,
  'column-level UPDATE: conversation_members (last_read_at, cleared_at), friendships (status, responded_at)'
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
       ('conversation_members', 'conversation_members_conversation_id_fkey', 'conversations', 'c'),
       ('conversation_members', 'conversation_members_user_id_fkey', 'profiles', 'c'),
       ('conversations', 'conversations_user_a_fkey', 'profiles', 'c'),
       ('conversations', 'conversations_user_b_fkey', 'profiles', 'c'),
       ('friendships', 'friendships_addressee_id_fkey', 'profiles', 'c'),
       ('friendships', 'friendships_requester_id_fkey', 'profiles', 'c'),
       ('messages', 'messages_conversation_id_fkey', 'conversations', 'c'),
       ('messages', 'messages_creator_id_fkey', 'profiles', 'n'),
       ('messages', 'messages_edited_from_id_fkey', 'profiles', 'n'),
       ('messages', 'messages_playlist_id_fkey', 'playlists', 'n'),
       ('messages', 'messages_sender_id_fkey', 'profiles', 'c'),
       ('messages', 'messages_source_message_id_fkey', 'messages', 'n'),
       ('messages', 'messages_source_post_id_fkey', 'posts', 'n'),
       ('messages', 'messages_source_quote_id_fkey', 'quotes', 'n'),
       ('messages', 'messages_starter_quote_id_fkey', 'catalog_quotes', 'n'),
       ('messages', 'messages_verified_starter_id_fkey', 'catalog_quotes', 'n'),
       ('playlist_items', 'playlist_items_playlist_id_fkey', 'playlists', 'c'),
       ('playlist_items', 'playlist_items_quote_id_fkey', 'quotes', 'c'),
       ('playlists', 'playlists_owner_id_fkey', 'profiles', 'c'),
       ('posts', 'posts_author_id_fkey', 'profiles', 'c'),
       ('posts', 'posts_creator_id_fkey', 'profiles', 'n'),
       ('posts', 'posts_edited_from_id_fkey', 'profiles', 'n'),
       ('posts', 'posts_source_quote_id_fkey', 'quotes', 'n'),
       ('posts', 'posts_starter_quote_id_fkey', 'catalog_quotes', 'n'),
       ('posts', 'posts_verified_starter_id_fkey', 'catalog_quotes', 'n'),
       ('profiles', 'profiles_id_fkey', 'auth.users', 'c'),
       ('quotes', 'quotes_creator_id_fkey', 'profiles', 'n'),
       ('quotes', 'quotes_edited_from_id_fkey', 'profiles', 'n'),
       ('quotes', 'quotes_owner_id_fkey', 'auth.users', 'c'),
       ('quotes', 'quotes_verified_starter_id_fkey', 'catalog_quotes', 'n'),
       ('reports', 'reports_message_id_fkey', 'messages', 'n'),
       ('reports', 'reports_playlist_id_fkey', 'playlists', 'n'),
       ('reports', 'reports_post_id_fkey', 'posts', 'n'),
       ('reports', 'reports_reported_user_id_fkey', 'profiles', 'n'),
       ('reports', 'reports_reporter_id_fkey', 'profiles', 'n'),
       ('reports', 'reports_starter_quote_id_fkey', 'catalog_quotes', 'n') $$,
  'foreign keys have stable names, targets and delete actions (events has none; reports outlive both accounts; catalog rows are never deleted, and catalog ids point at catalog_quotes, never the starter_quotes view)'
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

-- ---- 20261030030000_provenance_and_accounts --------------------------------
select results_eq(
  $$ select conname::text collate "default", pg_get_constraintdef(oid) collate "default"
     from pg_constraint where conname in ('quotes_creator_id_fkey', 'quotes_edited_from_id_fkey') order by 1 $$,
  $$ values
       ('quotes_creator_id_fkey', 'FOREIGN KEY (creator_id, creator_username) REFERENCES profiles(id, username) ON DELETE SET NULL'),
       ('quotes_edited_from_id_fkey', 'FOREIGN KEY (edited_from_id, edited_from_username) REFERENCES profiles(id, username) ON DELETE SET NULL') $$,
  'each provenance pair is one composite foreign key to profiles (id, username), cleared together'
);

select results_eq(
  $$ select conrelid::regclass::text, conname::text collate "default", confrelid::regclass::text, confdeltype::text
     from pg_constraint
     where contype = 'f' and connamespace = 'private'::regnamespace
     order by 1, 2 $$,
  $$ values
       ('private.event_rate_limits', 'event_rate_limits_user_id_fkey', 'auth.users', 'c'),
       ('private.limit_deletions', 'limit_deletions_owner_id_fkey', 'auth.users', 'c'),
       ('private.message_tombstones', 'message_tombstones_sender_id_fkey', 'profiles', 'c'),
       ('private.quote_tombstones', 'quote_tombstones_owner_id_fkey', 'auth.users', 'c'),
       ('private.suspensions', 'suspensions_user_id_fkey', 'auth.users', 'c') $$,
  'private per-user rows go with the account'
);

select is_empty(
  $$ select c.relname from pg_class c
     where c.relnamespace = 'private'::regnamespace and c.relkind in ('r', 'v')
       and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select')
            or has_table_privilege('service_role', c.oid, 'select')
            or has_table_privilege('authenticated', c.oid, 'insert')
            or has_table_privilege('authenticated', c.oid, 'update')
            or has_table_privilege('authenticated', c.oid, 'delete')) $$,
  'no API role can read or write any private table (blocked terms, retired usernames, suspensions, tombstones)'
);

select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute')
     from pg_proc p
     where p.oid in ('public.accept_terms(smallint)'::regprocedure, 'public.my_account()'::regprocedure,
                     'public.add_catalog_quotes(integer[], uuid[], boolean)'::regprocedure,
                     'public.save_from_favorite(uuid, uuid, uuid, boolean)'::regprocedure,
                     'public.friend_favorites(uuid)'::regprocedure)
     order by 1 $$,
  $$ values
       ('accept_terms(smallint)', false, true, false),
       ('add_catalog_quotes(integer[],uuid[],boolean)', false, true, false),
       ('friend_favorites(uuid)', false, true, false),
       ('my_account()', false, true, false),
       ('save_from_favorite(uuid,uuid,uuid,boolean)', false, true, false) $$,
  'the new RPCs are for signed-in users only'
);

select results_eq(
  $$ select p.proname::text collate "default", p.prosecdef
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('accept_terms', 'my_account', 'add_catalog_quotes', 'save_from_favorite', 'friend_favorites')
     order by 1 $$,
  $$ values ('accept_terms', false), ('add_catalog_quotes', false), ('friend_favorites', false),
            ('my_account', false), ('save_from_favorite', false) $$,
  'public RPCs are SECURITY INVOKER wrappers'
);

select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute')
     from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname in ('caller_quote_for_retry', 'insert_caller_quote', 'has_blocked_term', 'current_terms_version',
                         'filter_fold', 'user_can_publish', 'purge_quote_tombstones')
     order by 1 $$,
  $$ values
       ('private.caller_quote_for_retry(uuid)', false, false, false),
       ('private.current_terms_version()', false, true, true),
       ('private.filter_fold(text)', false, false, false),
       ('private.has_blocked_term(text)', false, true, true),
       ('private.insert_caller_quote(uuid,text,jsonb,text,text,text,uuid,text,uuid,text,boolean)', false, false, false),
       ('private.purge_quote_tombstones(timestamp with time zone)', false, false, false),
       ('private.user_can_publish(uuid)', false, false, false) $$,
  'the save helpers, the filter''s folding, the per-account publish check and the purge are for no API role; the filter and terms version for the writing roles'
);

select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name in ('accepts_text_messages', 'favorites_visibility', 'terms_version', 'terms_accepted_at', 'shows_favorites')
     order by ordinal_position $$,
  $$ values
       ('accepts_text_messages', 'boolean', 'NO', 'true'),
       ('favorites_visibility', 'text', 'NO', '''private''::text'),
       ('terms_version', 'smallint', 'YES', null::text),
       ('terms_accepted_at', 'timestamp with time zone', 'YES', null) $$,
  'profiles has the new account columns, and shows_favorites is gone'
);

-- ---- 20261030030100_playlists -----------------------------------------------
select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('playlist_view', 'save_from_playlist', 'save_playlist_copy')
     order by 1 $$,
  $$ values
       ('playlist_view(uuid)', false, true, false, false),
       ('save_from_playlist(uuid,uuid,uuid,boolean)', false, true, false, false),
       ('save_playlist_copy(uuid,text)', false, true, false, false) $$,
  'the playlist RPCs are SECURITY INVOKER wrappers for signed-in users only'
);

select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname in ('playlist_access', 'playlist_visible_items', 'playlist_is_public_eligible',
                         'quote_is_public_eligible', 'playlist_view', 'save_from_playlist', 'save_playlist_copy')
     order by 1 $$,
  $$ values
       ('private.playlist_access(uuid)', false, false, false, true),
       ('private.playlist_is_public_eligible(uuid)', false, true, false, false),
       ('private.playlist_view(uuid)', false, true, false, true),
       ('private.playlist_visible_items(uuid)', false, false, false, true),
       ('private.quote_is_public_eligible(uuid,integer,uuid,uuid)', false, true, true, false),
       ('private.save_from_playlist(uuid,uuid,uuid,boolean)', false, true, false, true),
       ('private.save_playlist_copy(uuid,text)', false, true, false, true) $$,
  'the playlist access and item helpers (they return quote ids) are reachable only from the definer functions'
);

select results_eq(
  $$ select table_name::text collate "default", column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name in ('playlists', 'playlist_items')
     order by table_name::text collate "default", ordinal_position $$,
  $$ values
       ('playlist_items', 'playlist_id', 'uuid', 'NO', null::text),
       ('playlist_items', 'quote_id', 'uuid', 'NO', null),
       ('playlist_items', 'position', 'integer', 'NO', null),
       ('playlist_items', 'added_at', 'timestamp with time zone', 'NO', 'now()'),
       ('playlists', 'id', 'uuid', 'NO', 'gen_random_uuid()'),
       ('playlists', 'owner_id', 'uuid', 'NO', 'auth.uid()'),
       ('playlists', 'title', 'text', 'NO', null),
       ('playlists', 'visibility', 'text', 'NO', '''friends''::text'),
       ('playlists', 'held_at', 'timestamp with time zone', 'YES', null),
       ('playlists', 'created_at', 'timestamp with time zone', 'NO', 'now()'),
       ('playlists', 'updated_at', 'timestamp with time zone', 'NO', 'now()') $$,
  'playlists and playlist_items have the agreed columns'
);

select results_eq(
  $$ select indexrelid::regclass::text collate "default", pg_get_indexdef(indexrelid) collate "default"
     from pg_index where indrelid in ('public.playlists'::regclass, 'public.playlist_items'::regclass)
     order by 1 $$,
  $$ values
       ('playlist_items_pkey', 'CREATE UNIQUE INDEX playlist_items_pkey ON public.playlist_items USING btree (playlist_id, quote_id)'),
       ('playlist_items_playlist_id_position_idx', 'CREATE INDEX playlist_items_playlist_id_position_idx ON public.playlist_items USING btree (playlist_id, "position")'),
       ('playlist_items_quote_id_idx', 'CREATE INDEX playlist_items_quote_id_idx ON public.playlist_items USING btree (quote_id)'),
       ('playlists_owner_id_created_at_idx', 'CREATE INDEX playlists_owner_id_created_at_idx ON public.playlists USING btree (owner_id, created_at)'),
       ('playlists_pkey', 'CREATE UNIQUE INDEX playlists_pkey ON public.playlists USING btree (id)') $$,
  'the playlist tables have their keys, the owner and daily-limit index, and the item order and quote indexes'
);

-- ---- 20261030030200_posts ---------------------------------------------------
select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.oid in ('public.save_from_post(uuid, uuid, boolean)'::regprocedure,
                     'private.save_from_post(uuid, uuid, boolean)'::regprocedure,
                     'private.post_access(uuid)'::regprocedure,
                     'private.caller_reported_post(uuid)'::regprocedure)
     order by 1 $$,
  $$ values
       ('private.caller_reported_post(uuid)', false, true, false, false),
       ('private.post_access(uuid)', false, false, false, true),
       ('private.save_from_post(uuid,uuid,boolean)', false, true, false, true),
       ('save_from_post(uuid,uuid,boolean)', false, true, false, false) $$,
  'save_from_post is a SECURITY INVOKER wrapper for signed-in users; post_access is reachable only from the definer functions'
);

select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'posts'
     order by ordinal_position $$,
  $$ values
       ('id', 'uuid', 'NO', 'gen_random_uuid()'),
       ('author_id', 'uuid', 'NO', 'auth.uid()'),
       ('source_quote_id', 'uuid', 'YES', null::text),
       ('starter_quote_id', 'integer', 'YES', null),
       ('caption', 'text', 'YES', null),
       ('body', 'text', 'NO', null),
       ('body_format', 'jsonb', 'NO', '''[]''::jsonb'),
       ('author', 'text', 'YES', null),
       ('source', 'text', 'YES', null),
       ('creator_id', 'uuid', 'YES', null),
       ('creator_username', 'text', 'YES', null),
       ('edited_from_id', 'uuid', 'YES', null),
       ('edited_from_username', 'text', 'YES', null),
       ('verified_starter_id', 'integer', 'YES', null),
       ('audience', 'text', 'NO', '''friends''::text'),
       ('held_at', 'timestamp with time zone', 'YES', null),
       ('created_at', 'timestamp with time zone', 'NO', 'now()') $$,
  'posts has the agreed columns'
);

select results_eq(
  $$ select conname::text collate "default", pg_get_constraintdef(oid) collate "default"
     from pg_constraint where conname in ('posts_creator_id_fkey', 'posts_edited_from_id_fkey') order by 1 $$,
  $$ values
       ('posts_creator_id_fkey', 'FOREIGN KEY (creator_id, creator_username) REFERENCES profiles(id, username) ON DELETE SET NULL'),
       ('posts_edited_from_id_fkey', 'FOREIGN KEY (edited_from_id, edited_from_username) REFERENCES profiles(id, username) ON DELETE SET NULL') $$,
  'a post''s provenance pairs are composite foreign keys to profiles (id, username), cleared together'
);

select results_eq(
  $$ select indexrelid::regclass::text collate "default", pg_get_indexdef(indexrelid) collate "default"
     from pg_index where indrelid = 'public.posts'::regclass
     order by 1 $$,
  $$ values
       ('posts_author_id_created_at_id_idx', 'CREATE INDEX posts_author_id_created_at_id_idx ON public.posts USING btree (author_id, created_at DESC, id)'),
       ('posts_creator_id_creator_username_idx', 'CREATE INDEX posts_creator_id_creator_username_idx ON public.posts USING btree (creator_id, creator_username)'),
       ('posts_edited_from_id_edited_from_username_idx', 'CREATE INDEX posts_edited_from_id_edited_from_username_idx ON public.posts USING btree (edited_from_id, edited_from_username)'),
       ('posts_pkey', 'CREATE UNIQUE INDEX posts_pkey ON public.posts USING btree (id)'),
       ('posts_source_quote_id_idx', 'CREATE INDEX posts_source_quote_id_idx ON public.posts USING btree (source_quote_id)'),
       ('posts_starter_quote_id_idx', 'CREATE INDEX posts_starter_quote_id_idx ON public.posts USING btree (starter_quote_id) WHERE (starter_quote_id IS NOT NULL)'),
       ('posts_verified_starter_id_idx', 'CREATE INDEX posts_verified_starter_id_idx ON public.posts USING btree (verified_starter_id) WHERE (verified_starter_id IS NOT NULL)') $$,
  'posts has its key, the Feed and daily-limit index (author, newest first) and its foreign key indexes'
);

select results_eq(
  $$ select policyname::text collate "default", cmd::text collate "default", roles::text collate "default"
     from pg_policies where schemaname = 'public' and tablename = 'posts' order by 1 $$,
  $$ values
       ('posts: author and accepted friends read', 'SELECT', '{authenticated}'),
       ('posts: author changes who can see it', 'UPDATE', '{authenticated}'),
       ('posts: author deletes own', 'DELETE', '{authenticated}'),
       ('posts: post as yourself, with terms', 'INSERT', '{authenticated}') $$,
  'posts has one policy per command, all for signed-in users'
);

-- ---- 20261030030300_conversations_and_messages --------------------------------
select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.oid in ('public.open_conversation(uuid)'::regprocedure, 'public.inbox_conversations()'::regprocedure,
                     'public.save_from_message(uuid, uuid, boolean)'::regprocedure,
                     'private.open_conversation(uuid)'::regprocedure,
                     'private.save_from_message(uuid, uuid, boolean)'::regprocedure)
     order by 1 $$,
  $$ values
       ('inbox_conversations()', false, true, false, false),
       ('open_conversation(uuid)', false, true, false, false),
       ('private.open_conversation(uuid)', false, true, false, true),
       ('private.save_from_message(uuid,uuid,boolean)', false, true, false, true),
       ('save_from_message(uuid,uuid,boolean)', false, true, false, false) $$,
  'the conversation RPCs are SECURITY INVOKER (inbox_conversations relies on RLS alone) and for signed-in users only'
);

select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname in ('caller_blocked_by', 'caller_reported_message', 'caller_reported_post', 'caller_reported_playlist',
                         'caller_can_read_message', 'caller_can_report_message', 'caller_can_report_post',
                         'caller_can_report_playlist', 'purge_message_tombstones')
     order by 1 $$,
  $$ values
       ('private.caller_blocked_by(uuid,uuid)', false, true, false, true),
       ('private.caller_can_read_message(uuid)', false, false, false, true),
       ('private.caller_can_report_message(uuid,uuid)', false, true, false, true),
       ('private.caller_can_report_playlist(uuid,uuid)', false, true, false, true),
       ('private.caller_can_report_post(uuid,uuid)', false, true, false, true),
       ('private.caller_reported_message(uuid)', false, true, false, false),
       ('private.caller_reported_playlist(uuid)', false, true, false, false),
       ('private.caller_reported_post(uuid)', false, true, false, false),
       ('private.purge_message_tombstones(timestamp with time zone)', false, false, false, true) $$,
  'the policy helpers answer only for the caller; the read rule for definer code and the purge are for no API role'
);

select results_eq(
  $$ select column_name::text collate "default", data_type::text collate "default",
            is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns
     where table_schema = 'public' and table_name = 'messages'
     order by ordinal_position $$,
  $$ values
       ('id', 'uuid', 'NO', 'gen_random_uuid()'),
       ('conversation_id', 'uuid', 'NO', null::text),
       ('sender_id', 'uuid', 'NO', 'auth.uid()'),
       ('kind', 'text', 'NO', null),
       ('text', 'text', 'YES', null),
       ('note', 'text', 'YES', null),
       ('body', 'text', 'YES', null),
       ('body_format', 'jsonb', 'YES', null),
       ('author', 'text', 'YES', null),
       ('source', 'text', 'YES', null),
       ('creator_id', 'uuid', 'YES', null),
       ('creator_username', 'text', 'YES', null),
       ('edited_from_id', 'uuid', 'YES', null),
       ('edited_from_username', 'text', 'YES', null),
       ('verified_starter_id', 'integer', 'YES', null),
       ('source_quote_id', 'uuid', 'YES', null),
       ('starter_quote_id', 'integer', 'YES', null),
       ('playlist_id', 'uuid', 'YES', null),
       ('playlist_title', 'text', 'YES', null),
       ('created_at', 'timestamp with time zone', 'NO', 'now()'),
       ('source_post_id', 'uuid', 'YES', null),
       ('source_message_id', 'uuid', 'YES', null) $$,
  'messages has the agreed columns: no seen or saved column, and the forward sources'
);

select results_eq(
  $$ select indexrelid::regclass::text collate "default", pg_get_indexdef(indexrelid) collate "default"
     from pg_index where indrelid in ('public.conversations'::regclass, 'public.conversation_members'::regclass)
     order by 1 $$,
  $$ values
       ('conversation_members_pkey', 'CREATE UNIQUE INDEX conversation_members_pkey ON public.conversation_members USING btree (conversation_id, user_id)'),
       ('conversation_members_user_id_idx', 'CREATE INDEX conversation_members_user_id_idx ON public.conversation_members USING btree (user_id)'),
       ('conversations_pair_key', 'CREATE UNIQUE INDEX conversations_pair_key ON public.conversations USING btree (user_a, user_b)'),
       ('conversations_pkey', 'CREATE UNIQUE INDEX conversations_pkey ON public.conversations USING btree (id)'),
       ('conversations_user_b_idx', 'CREATE INDEX conversations_user_b_idx ON public.conversations USING btree (user_b)') $$,
  'one conversation per ordered pair (user_a < user_b), and one member row per person'
);

select results_eq(
  $$ select indexrelid::regclass::text collate "default", pg_get_indexdef(indexrelid) collate "default"
     from pg_index where indrelid = 'public.messages'::regclass
     order by 1 $$,
  $$ values
       ('messages_conversation_id_created_at_id_idx', 'CREATE INDEX messages_conversation_id_created_at_id_idx ON public.messages USING btree (conversation_id, created_at DESC, id)'),
       ('messages_creator_id_creator_username_idx', 'CREATE INDEX messages_creator_id_creator_username_idx ON public.messages USING btree (creator_id, creator_username) WHERE (creator_id IS NOT NULL)'),
       ('messages_edited_from_id_edited_from_username_idx', 'CREATE INDEX messages_edited_from_id_edited_from_username_idx ON public.messages USING btree (edited_from_id, edited_from_username) WHERE (edited_from_id IS NOT NULL)'),
       ('messages_pkey', 'CREATE UNIQUE INDEX messages_pkey ON public.messages USING btree (id)'),
       ('messages_playlist_id_idx', 'CREATE INDEX messages_playlist_id_idx ON public.messages USING btree (playlist_id) WHERE (playlist_id IS NOT NULL)'),
       ('messages_sender_id_created_at_idx', 'CREATE INDEX messages_sender_id_created_at_idx ON public.messages USING btree (sender_id, created_at)'),
       ('messages_source_message_id_idx', 'CREATE INDEX messages_source_message_id_idx ON public.messages USING btree (source_message_id) WHERE (source_message_id IS NOT NULL)'),
       ('messages_source_post_id_idx', 'CREATE INDEX messages_source_post_id_idx ON public.messages USING btree (source_post_id) WHERE (source_post_id IS NOT NULL)'),
       ('messages_source_quote_id_idx', 'CREATE INDEX messages_source_quote_id_idx ON public.messages USING btree (source_quote_id) WHERE (source_quote_id IS NOT NULL)'),
       ('messages_starter_quote_id_idx', 'CREATE INDEX messages_starter_quote_id_idx ON public.messages USING btree (starter_quote_id) WHERE (starter_quote_id IS NOT NULL)'),
       ('messages_verified_starter_id_idx', 'CREATE INDEX messages_verified_starter_id_idx ON public.messages USING btree (verified_starter_id) WHERE (verified_starter_id IS NOT NULL)') $$,
  'messages has its key, the conversation page and daily-limit indexes, and its (sparse) foreign key indexes'
);

select results_eq(
  $$ select conrelid::regclass::text, conname::text collate "default"
     from pg_constraint
     where contype = 'f' and connamespace = 'public'::regnamespace and condeferrable and condeferred
     order by 1, 2 $$,
  $$ values
       ('messages', 'messages_conversation_id_fkey'), ('messages', 'messages_creator_id_fkey'),
       ('messages', 'messages_edited_from_id_fkey'), ('messages', 'messages_playlist_id_fkey'),
       ('messages', 'messages_sender_id_fkey'), ('messages', 'messages_source_message_id_fkey'),
       ('messages', 'messages_source_post_id_fkey'), ('messages', 'messages_source_quote_id_fkey'),
       ('messages', 'messages_starter_quote_id_fkey'), ('messages', 'messages_verified_starter_id_fkey'),
       ('reports', 'reports_message_id_fkey'), ('reports', 'reports_playlist_id_fkey'),
       ('reports', 'reports_post_id_fkey'), ('reports', 'reports_starter_quote_id_fkey') $$,
  'messages'' foreign keys and the report targets are checked at commit, so one statement can delete many accounts'
);

select results_eq(
  $$ select tablename::text collate "default", policyname::text collate "default", cmd::text collate "default",
            roles::text collate "default"
     from pg_policies where schemaname = 'public'
       and tablename in ('conversations', 'conversation_members', 'messages', 'reports')
     order by 1, 2 $$,
  $$ values
       ('conversation_members', 'conversation_members: read your own row', 'SELECT', '{authenticated}'),
       ('conversation_members', 'conversation_members: update your own row', 'UPDATE', '{authenticated}'),
       ('conversations', 'conversations: members read, unless blocked by the other', 'SELECT', '{authenticated}'),
       ('messages', 'messages: members read, unless blocked or reported', 'SELECT', '{authenticated}'),
       ('messages', 'messages: members send to an open conversation', 'INSERT', '{authenticated}'),
       ('messages', 'messages: sender unsends', 'DELETE', '{authenticated}'),
       ('reports', 'reports: file as yourself, about what you can see', 'INSERT', '{authenticated}'),
       ('reports', 'reports: read own', 'SELECT', '{authenticated}') $$,
  'conversations are read-only; members read and update their own row; messages are read, sent and unsent, never updated'
);

select is_empty(
  $$ select p.proname from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname in ('shares_stamp_seen_saved', 'shares_enforce_limit', 'reports_snapshot_share') $$,
  'the share trigger functions are gone (private.set_verified_starter stays for quotes)'
);

-- ---- 20261030030400_profiles_and_moderation ---------------------------------
select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.oid in ('public.profile_view(text, timestamptz)'::regprocedure,
                     'private.profile_view(text, timestamptz)'::regprocedure,
                     'private.suspend_user(uuid, text)'::regprocedure,
                     'private.unsuspend_user(uuid)'::regprocedure)
     order by 1 $$,
  $$ values
       ('private.profile_view(text,timestamp with time zone)', false, true, false, true),
       ('private.suspend_user(uuid,text)', false, false, false, true),
       ('private.unsuspend_user(uuid)', false, false, false, true),
       ('profile_view(text,timestamp with time zone)', false, true, false, false) $$,
  'profile_view is a SECURITY INVOKER wrapper for signed-in users; suspending is for the founder only'
);

select results_eq(
  $$ select t.tgname::text collate "default",
            case when t.tgtype & 2 = 2 then 'BEFORE' else 'AFTER' end,
            p.oid::regprocedure::text, p.prosecdef
     from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.reports'::regclass and not t.tgisinternal
     order by 1 $$,
  $$ values
       ('reports_enforce_limit', 'BEFORE', 'private.reports_enforce_limit()', false),
       ('reports_hold_target', 'AFTER', 'private.reports_hold_target()', true),
       ('reports_set_target_kind', 'BEFORE', 'private.reports_set_target_kind()', false),
       ('reports_snapshot_target', 'BEFORE', 'private.reports_snapshot_target()', true),
       ('reports_snapshot_username', 'BEFORE', 'private.reports_snapshot_username()', true),
       ('reports_stamp_created_at', 'BEFORE', 'private.stamp_created_at()', false) $$,
  'reports: the limit, the server''s copy, target_kind and the auto-hold (definer: it writes held_at)'
);

select results_eq(
  $$ select string_agg(column_name::text, ',' order by ordinal_position) collate "default"
     from information_schema.columns where table_schema = 'private' and table_name = 'reports_to_review' $$,
  $$ values ('id,created_at,waiting,target_kind,target_deleted,reason,details,content_verified,content_body,content_author,content_source,content_note,message_id,post_id,playlist_id,starter_quote_id,target_held_at,target_reporters,reported_user_id,reported_username,reported_account_deleted,reported_user_suspended,reports_against_user,reporters_against_user,reporter_id,reporter_username'::text) $$,
  'the moderation queue covers every target: its kind, ids, whether it is gone or held, its reporters, and the reported person''s reports and distinct reporters'
);

-- ---- 20261030030500_forward_quotes ------------------------------------------
select results_eq(
  $$ select conname::text collate "default", pg_get_constraintdef(oid) collate "default"
     from pg_constraint
     where conname in ('messages_source_post_id_fkey', 'messages_source_message_id_fkey')
     order by 1 $$,
  $$ values
       ('messages_source_message_id_fkey', 'FOREIGN KEY (source_message_id) REFERENCES messages(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED'),
       ('messages_source_post_id_fkey', 'FOREIGN KEY (source_post_id) REFERENCES posts(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED') $$,
  'a forward keeps its copy when its source post or message goes (set null, checked at commit)'
);

select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p
     where p.oid = 'private.forwardable_snapshot(uuid, uuid)'::regprocedure $$,
  $$ values ('private.forwardable_snapshot(uuid,uuid)', false, true, false, true) $$,
  'private.forwardable_snapshot is a definer helper that only signed-in senders (the snapshot trigger) can run'
);

-- ---- 20261030030600_read_marks_reports_playlist_order ------------------------
select results_eq(
  $$ select p.oid::regprocedure::text,
            has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef, p.provolatile::text collate "default"
     from pg_proc p
     where p.oid = 'public.received_quotes(timestamptz, uuid, integer)'::regprocedure $$,
  $$ values ('received_quotes(timestamp with time zone,uuid,integer)', false, true, false, false, 's') $$,
  'received_quotes is a STABLE SECURITY INVOKER read (RLS decides) for signed-in users only'
);

select is(
  (select string_agg(a, ',' order by n)
   from pg_proc p, unnest(p.proargnames, p.proargmodes) with ordinality as t(a, mode, n)
   where p.oid = 'public.received_quotes(timestamptz, uuid, integer)'::regprocedure and t.mode = 't'),
  'id,conversation_id,sender_id,kind,text,note,body,body_format,author,source,creator_id,creator_username,edited_from_id,edited_from_username,verified_starter_id,starter_quote_id,playlist_id,playlist_title,created_at',
  'received_quotes returns the message columns clients may read, and no source column'
);

select is_empty(
  $$ select policyname from pg_policies where schemaname = 'public' and length(policyname) >= 63 $$,
  'no policy name reaches the 63-byte identifier limit (it would be silently truncated)'
);

select * from finish();
rollback;
