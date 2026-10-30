-- Playlists (supabase/migrations/20261030030100_playlists.sql): owner-only
-- tables with column grants; playlist_view for the owner, accepted friends
-- and (public) anyone, never across a block, never when held or private;
-- terms, suspension and the word filter (QR003) on titles; Public needs
-- can_publish and eligible items; the limits (20 a day, 100 in all, 200
-- items); save_from_playlist and save_playlist_copy keep creators and reuse
-- quotes the saver already holds; item changes move updated_at.
-- Review fixes: a public playlist reaches strangers only while its owner may
-- still publish, and takes new items only from an owner who may; a verified
-- item is saved (and copied) as "Quoted Catalog", without the owner row's
-- hidden creator or edited-from; deleting a playlist makes no room under the
-- 20-a-day limit.
-- 20261030030600: set_playlist_positions reorders a playlist in one statement,
-- for its owner only.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(126);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'd' then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    when 'e' then 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    when 'f' then 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    when 'g' then '55555555-5555-4555-8555-555555555555'
    when 'h' then '44444444-4444-4444-8444-444444444444'
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.pid(n int) returns uuid language sql immutable as $$
  select ('90000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.create_user(id uuid, email text) returns uuid language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
          email, '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now())
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

-- Back to the test runner's role (bypasses RLS) to inspect state.
create function tests.clear_authentication() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- The user has accepted the current terms (social writes need them).
create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- A quote's provenance as origin|creator|edited from ('-' for none), read with
-- definer rights so it works from any role.
create function tests.prov(n int) returns text language sql stable security definer as $$
  select origin || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
  from public.quotes where id = tests.qid(n)
$$;

-- The playlist_view handle `viewer` gets for quote n.
create function tests.handle(n int, viewer text) returns uuid language sql immutable as $$
  select md5(tests.qid(n)::text || ':' || tests.uid(viewer)::text)::uuid
$$;

-- The items of playlist_view(p) as body|creator|edited from ('-' for none), in order.
create function tests.view_items(p uuid) returns text language sql stable as $$
  select string_agg(i->>'body' || '|' || coalesce(i->>'creator_username', '-') || '|'
                    || coalesce(i->>'edited_from_username', '-'), ' / ' order by n)
  from jsonb_array_elements(public.playlist_view(p)->'items') with ordinality as x(i, n)
$$;

-- A playlist's updated_at moved back a day, past the trigger that stamps it.
create function tests.age_playlist(p uuid) returns void language plpgsql security definer as $$
begin
  alter table public.playlists disable trigger playlists_set_updated_at;
  update public.playlists set updated_at = now() - interval '1 day' where id = p;
  alter table public.playlists enable trigger playlists_set_updated_at;
end
$$;

-- Everything a client can learn from a failed statement, as one string.
create function tests.error_of(statement text) returns text language plpgsql as $$
declare
  v_state text; v_message text; v_detail text; v_hint text; v_constraint text;
begin
  execute statement;
  return 'no error';
exception when others then
  get stacked diagnostics
    v_state = returned_sqlstate, v_message = message_text, v_detail = pg_exception_detail,
    v_hint = pg_exception_hint, v_constraint = constraint_name;
  return concat_ws(' | ', nullif(v_state, ''), nullif(v_message, ''), nullif(v_detail, ''),
                   nullif(v_hint, ''), nullif(v_constraint, ''));
end
$$;
-- ---------------------------------------------------------------------------

-- A (alice) owns the playlists. B is A's friend; C is a stranger; D is A's
-- friend whom A blocked; E has a pending request from A; F is A's friend who
-- blocked A; G has not accepted the terms; H gets suspended. Blocks go in
-- first, because a new block deletes the pair's friendship.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice A'), (tests.uid('b'), 'bob', null), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('f'), 'fay', null),
  (tests.uid('g'), 'gus', null), (tests.uid('h'), 'hal', null);
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'h']) w;
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('d')), (tests.uid('f'), tests.uid('a'));
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('d'), 'accepted'),
  (tests.uid('f'), tests.uid('a'), 'accepted'), (tests.uid('a'), tests.uid('e'), 'pending');
insert into private.blocked_terms (term) values ('darn'), ('heck no');

-- A's quotes: 1 and 6 typed by A, 2 from the catalog (verified), 3 a copy of
-- B's words, 4 A's rewrite of B's words, 5 A's words with a blocked term.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values
  (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(5), 'Darn it all', null), (tests.qid(6), 'Zeta', 'Zed');
select id from public.add_catalog_quotes(array[2]::integer[], array[tests.qid(2)]);
select tests.authenticate_as('b');
insert into public.quotes (id, body, author) values (tests.qid(30), 'Bob''s line', 'Bo');
select tests.authenticate_as('c');
insert into public.quotes (id, body) values (tests.qid(40), 'Cara''s words');
select tests.authenticate_as('g');
insert into public.quotes (id, body) values (tests.qid(45), 'Gus''s words');
select tests.authenticate_as('h');
insert into public.quotes (id, body) values (tests.qid(50), 'Hal''s words');
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username) values
  (tests.qid(3), tests.uid('a'), 'Bob''s line', 'Bo', 'shared', tests.uid('b'), 'bob');
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username, edited_from_id, edited_from_username)
  values (tests.qid(4), tests.uid('a'), 'Bob''s line, Alice''s way', 'Bo', 'shared', tests.uid('a'), 'alice', tests.uid('b'), 'bob');

-- ---- owner-only tables and column grants ------------------------------------
select tests.authenticate_as('a');

select results_eq(
  $$ insert into public.playlists (id, title) values (tests.pid(1), 'Morning')
     returning owner_id, title, visibility, held_at, created_at = now(), updated_at = now() $$,
  $$ values (tests.uid('a'), 'Morning'::text, 'friends'::text, null::timestamptz, true, true) $$,
  'A makes a playlist: owned by A, friends by default, not held, on the server clock'
);
select throws_ok(
  $$ insert into public.playlists (title, owner_id) values ('Forged', tests.uid('b')) $$,
  '42501', 'permission denied for table playlists',
  'a client cannot choose the owner'
);
select throws_ok($$ insert into public.playlists (title, held_at) values ('Held?', null) $$, '42501', null,
  'a client cannot write held_at on insert');
select throws_ok($$ insert into public.playlists (title, created_at) values ('Old', now()) $$, '42501', null,
  'a client cannot write created_at');
select throws_ok($$ update public.playlists set held_at = null where id = tests.pid(1) $$, '42501', null,
  'a client cannot write held_at on update');
select throws_ok($$ update public.playlists set updated_at = now() where id = tests.pid(1) $$, '42501', null,
  'a client cannot write updated_at');

insert into public.playlists (id, title, visibility) values (tests.pid(2), 'Just me', 'private');
select lives_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values
       (tests.pid(1), tests.qid(1), 0), (tests.pid(1), tests.qid(2), 1), (tests.pid(1), tests.qid(3), 2),
       (tests.pid(1), tests.qid(4), 3), (tests.pid(1), tests.qid(5), 4), (tests.pid(2), tests.qid(1), 0) $$,
  'A adds A''s own quotes to A''s playlists'
);
select results_eq(
  $$ select count(*)::int, bool_and(added_at = now()) from public.playlist_items $$,
  $$ values (6, true) $$,
  'the owner reads the items, stamped with the server clock'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(30), 5) $$,
  '42501', 'new row violates row-level security policy for table "playlist_items"',
  'someone else''s quote cannot go into your playlist'
);
select is(
  tests.error_of($$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(30), 5) $$),
  tests.error_of($$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(999), 5) $$),
  'someone else''s quote fails exactly like a quote that does not exist'
);
select throws_ok(
  $$ update public.playlist_items set quote_id = tests.qid(6) where playlist_id = tests.pid(1) and quote_id = tests.qid(1) $$,
  '42501', null,
  'an item''s quote cannot be swapped (only position is writable)'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position, added_at) values (tests.pid(2), tests.qid(6), 1, now()) $$,
  '42501', null,
  'a client cannot write added_at'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(2), tests.qid(6), -1) $$,
  '23514', null,
  'a position cannot be negative'
);

select tests.authenticate_as('c');
select is_empty($$ select 1 from public.playlists $$, 'a stranger cannot select A''s playlists');
select is_empty($$ select 1 from public.playlist_items $$, 'nor their items');
select is_empty($$ update public.playlists set title = 'Mine now' returning 1 $$, 'nor rename them');
select is_empty($$ update public.playlist_items set position = 9 returning 1 $$, 'nor reorder their items');
select is_empty($$ delete from public.playlist_items returning 1 $$, 'nor remove their items');
select is_empty($$ delete from public.playlists returning 1 $$, 'nor delete them');
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(40), 9) $$,
  '42501', 'new row violates row-level security policy for table "playlist_items"',
  'a stranger cannot add their own quote to A''s playlist'
);
select is(
  tests.error_of($$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(40), 9) $$),
  tests.error_of($$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(999), tests.qid(40), 9) $$),
  'and gets the same answer as for a playlist that does not exist'
);

select tests.authenticate_as('b');
select is_empty($$ select 1 from public.playlists $$, 'even a friend cannot select the playlists table directly');

-- ---- playlist_view ----------------------------------------------------------------
select results_eq(
  $$ select v->'playlist'->>'id', v->'playlist'->>'title', v->'playlist'->>'visibility',
            v->'playlist'->'owner'->>'id', v->'playlist'->'owner'->>'username',
            v->'playlist'->'owner'->>'display_name', (v->'playlist'->>'updated_at')::timestamptz = now()
     from (select public.playlist_view(tests.pid(1)) v) x $$,
  $$ values (tests.pid(1)::text, 'Morning'::text, 'friends'::text, tests.uid('a')::text, 'alice'::text, 'Alice A'::text, true) $$,
  'a friend sees a friends playlist with its owner'
);
select results_eq(
  $$ select (i->>'position')::int, i->>'body', i->>'creator_username', i->>'edited_from_username',
            (i->>'verified_starter_id')::integer
     from jsonb_array_elements(public.playlist_view(tests.pid(1))->'items') with ordinality as x(i, n) order by n $$,
  $$ values (0, 'Alpha'::text, 'alice'::text, null::text, null::integer),
            (1, (select body from public.starter_quotes where id = 2), null, null, 2::integer),
            (2, 'Bob''s line', 'bob', null, null),
            (3, 'Bob''s line, Alice''s way', 'alice', 'bob', null) $$,
  'items in order with creator usernames; none on the verified one; the blocked-term item is skipped'
);
select results_eq(
  $$ select (i->>'handle')::uuid
     from jsonb_array_elements(public.playlist_view(tests.pid(1))->'items') with ordinality as x(i, n) order by n $$,
  $$ values (tests.handle(1, 'b')), (tests.handle(2, 'b')), (tests.handle(3, 'b')), (tests.handle(4, 'b')) $$,
  'each item carries the viewer''s handle (md5 of quote and viewer), never the quote id'
);
select results_eq(
  $$ select (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(v->'playlist') k),
            (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(v->'playlist'->'owner') k),
            (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(v->'items'->0) k),
            (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(v) k)
     from (select public.playlist_view(tests.pid(1)) v) x $$,
  $$ values ('id,owner,title,updated_at,visibility'::text, 'display_name,id,username'::text,
             'author,body,body_format,creator_username,edited_from_username,handle,position,source,verified_starter_id'::text,
             'items,playlist'::text) $$,
  'playlist_view returns exactly these fields (no quote id, held_at or private profile column)'
);
select is(public.playlist_view(tests.pid(2)), null, 'a friend gets null for a private playlist');
select is(public.playlist_view(tests.pid(999)), null, 'and for a playlist that does not exist');

select tests.authenticate_as('c');
select is(public.playlist_view(tests.pid(1)), null, 'a stranger gets null for a friends playlist');
select tests.authenticate_as('e');
select is(public.playlist_view(tests.pid(1)), null, 'so does someone with only a pending request');
select tests.authenticate_as('d');
select is(public.playlist_view(tests.pid(1)), null, 'so does a friend the owner blocked');
select tests.authenticate_as('f');
select is(public.playlist_view(tests.pid(1)), null, 'so does a friend who blocked the owner');

select tests.authenticate_as('a');
select results_eq(
  $$ select tests.view_items(tests.pid(2)), jsonb_array_length(public.playlist_view(tests.pid(1))->'items') $$,
  $$ values ('Alpha|alice|-'::text, 4) $$,
  'the owner sees their own private playlist, and the same items friends see'
);

select tests.clear_authentication();
update public.playlists set held_at = now() where id = tests.pid(1);
select tests.authenticate_as('b');
select is(public.playlist_view(tests.pid(1)), null, 'a held playlist is hidden from friends');
select tests.authenticate_as('a');
select isnt(public.playlist_view(tests.pid(1)), null, 'but not from its owner');
select tests.clear_authentication();
update public.playlists set held_at = null where id = tests.pid(1);

select is(public.playlist_view(tests.pid(1)), null, 'nobody signed in: null');
set local role anon;
select throws_ok($$ select public.playlist_view(tests.pid(1)) $$, '42501', null, 'anon cannot call playlist_view');
select tests.clear_authentication();

-- ---- terms, suspension and the word filter ----------------------------------------
select tests.authenticate_as('g');
select lives_ok(
  $$ insert into public.playlists (id, title, visibility) values (tests.pid(20), 'Gus only', 'private') $$,
  'without accepted terms you can still make a private playlist'
);
select lives_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(20), tests.qid(45), 0) $$,
  'and fill it'
);
select throws_ok(
  $$ insert into public.playlists (title) values ('Gus for friends') $$,
  '42501', 'Accept the Terms of use first.',
  'a playlist friends can see (the default) needs accepted terms'
);
select throws_ok(
  $$ update public.playlists set visibility = 'friends' where id = tests.pid(20) $$,
  '42501', 'Accept the Terms of use first.',
  'and so does widening a private one'
);

select tests.clear_authentication();
insert into public.playlists (id, owner_id, title) values (tests.pid(21), tests.uid('h'), 'Hal''s list');
insert into private.suspensions (user_id, reason) values (tests.uid('h'), 'test');
select tests.authenticate_as('h');
select throws_ok(
  $$ insert into public.playlists (title) values ('Hal again') $$,
  '42501', 'This account is suspended.',
  'a suspended account cannot make a playlist friends can see'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(21), tests.qid(50), 0) $$,
  '42501', 'This account is suspended.',
  'nor add to one'
);
select throws_ok(
  $$ update public.playlists set title = 'Hal''s new list' where id = tests.pid(21) $$,
  '42501', 'This account is suspended.',
  'nor rename one'
);
select lives_ok(
  $$ update public.playlists set visibility = 'private' where id = tests.pid(21) $$,
  'but it can make it private'
);
select lives_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(21), tests.qid(50), 0) $$,
  'and keep adding to it once it is private'
);

select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.playlists (title) values ('Darn good lines') $$,
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'a title with a blocked term is refused with QR003'
);
select throws_ok(
  $$ update public.playlists set title = 'Darn' where id = tests.pid(2) $$,
  'QR003', null,
  'so is a new title with one, even on a private playlist'
);
select tests.clear_authentication();
insert into public.playlists (id, owner_id, title) values (tests.pid(5), tests.uid('a'), 'Heck no list');
select tests.authenticate_as('a');
select lives_ok(
  $$ update public.playlists set visibility = 'private' where id = tests.pid(5) $$,
  'a title a later term catches never stops its owner making it private'
);
select throws_ok(
  $$ update public.playlists set visibility = 'friends' where id = tests.pid(5) $$,
  'QR003', null,
  'but widening it again is checked'
);
select throws_ok($$ insert into public.playlists (title, visibility) values (' ', 'private') $$, '23514', null,
  'a blank title is refused');
select throws_ok($$ insert into public.playlists (title, visibility) values (repeat('x', 61), 'private') $$, '23514', null,
  'a title longer than 60 characters is refused');
select throws_ok($$ insert into public.playlists (title, visibility) values ('Everyone', 'everyone') $$, '23514', null,
  'visibility is private, friends or public');

-- ---- Public -------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.playlists (title, visibility) values ('For everyone', 'public') $$,
  '42501', 'Only accounts backed up with Sign in with Apple can make a playlist public.',
  'without a linked Apple identity a playlist cannot be public'
);
select throws_ok(
  $$ update public.playlists set visibility = 'public' where id = tests.pid(2) $$,
  '42501', 'Only accounts backed up with Sign in with Apple can make a playlist public.',
  'nor become public'
);

select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple');
select tests.authenticate_as('a');
select lives_ok(
  $$ insert into public.playlists (id, title, visibility) values (tests.pid(3), 'Best of', 'public') $$,
  'with an Apple identity A can make a public playlist'
);
select lives_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position)
     values (tests.pid(3), tests.qid(1), 0), (tests.pid(3), tests.qid(2), 1) $$,
  'A''s own words and a catalog quote can go into it'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(3), tests.qid(3), 2) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'a quote someone else added cannot go into a public playlist'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(3), tests.qid(4), 2) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'nor one A rewrote from someone else (it has an edited-from)'
);
select throws_ok(
  $$ update public.playlists set visibility = 'public' where id = tests.pid(1) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'a playlist holding such quotes cannot become public'
);
select lives_ok(
  $$ update public.playlists set visibility = 'public' where id = tests.pid(2) $$,
  'a playlist of only eligible quotes can'
);
update public.playlists set visibility = 'private' where id = tests.pid(2);
select tests.clear_authentication();
select throws_ok(
  $$ update public.playlists set visibility = 'public' where id = tests.pid(1) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'the eligibility rule binds the table owner too'
);

-- Zeta goes in eligible, then (a server-side change) is credited to B.
select tests.authenticate_as('a');
insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(3), tests.qid(6), 2);
select tests.clear_authentication();
update public.quotes set creator_id = tests.uid('b'), creator_username = 'bob' where id = tests.qid(6);

select tests.authenticate_as('c');
select results_eq(
  $$ select v->'playlist'->>'title', v->'playlist'->>'visibility', tests.view_items(tests.pid(3))
     from (select public.playlist_view(tests.pid(3)) v) x $$,
  $$ values ('Best of'::text, 'public'::text,
             'Alpha|alice|-' || ' / ' || (select body from public.starter_quotes where id = 2) || '|-|-') $$,
  'a stranger sees a public playlist, and only its eligible items'
);
select is_empty($$ select 1 from public.playlists $$, 'a public playlist still cannot be selected from the table');
select tests.authenticate_as('b');
select is(
  tests.view_items(tests.pid(3)),
  'Alpha|alice|-' || ' / ' || (select body from public.starter_quotes where id = 2) || '|-|-' || ' / Zeta|bob|-',
  'a friend sees every item of a public playlist'
);
select tests.authenticate_as('a');
select lives_ok(
  $$ delete from public.playlist_items where playlist_id = tests.pid(3) and quote_id = tests.qid(6) $$,
  'the owner can still remove items'
);

select tests.clear_authentication();
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('c'), tests.uid('a'));
select tests.authenticate_as('c');
select is(public.playlist_view(tests.pid(3)), null, 'a stranger who blocked the owner gets null for a public playlist');
select tests.clear_authentication();
delete from public.blocks where blocker_id = tests.uid('c');
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('c'));
select tests.authenticate_as('c');
select is(public.playlist_view(tests.pid(3)), null, 'so does a stranger the owner blocked');
select tests.clear_authentication();
delete from public.blocks where blocker_id = tests.uid('a') and blocked_id = tests.uid('c');
update public.playlists set held_at = now() where id = tests.pid(3);
select tests.authenticate_as('c');
select is(public.playlist_view(tests.pid(3)), null, 'a held public playlist is hidden from strangers');
select tests.clear_authentication();
update public.playlists set held_at = null where id = tests.pid(3);

-- A's Apple identity is unlinked: A may no longer publish.
delete from auth.identities where user_id = tests.uid('a') and provider = 'apple';
select tests.authenticate_as('c');
select is(public.playlist_view(tests.pid(3)), null,
  'a public playlist stops reaching strangers once its owner may no longer publish');
select tests.authenticate_as('b');
select isnt(public.playlist_view(tests.pid(3)), null, 'friends still see it');
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(3), tests.qid(5), 3) $$,
  '42501', 'Only accounts backed up with Sign in with Apple can add to a public playlist.',
  'and its owner cannot add to it, as they could not rename it'
);
select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple');

-- ---- save_from_playlist --------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select id, owner_id from public.save_from_playlist(tests.pid(1), tests.handle(4, 'b'), tests.qid(60)) $$,
  $$ values (tests.qid(60), tests.uid('b')) $$,
  'B saves an item of A''s playlist into B''s own Library'
);
select is(tests.prov(60), 'shared|alice|bob', 'the saved quote keeps its creator and edited-from');
select results_eq(
  $$ select id, (select count(*)::int from public.quotes)
     from public.save_from_playlist(tests.pid(1), tests.handle(4, 'b'), tests.qid(60)) $$,
  $$ values (tests.qid(60), 2) $$,
  'a retry with the same id returns the saved quote and adds nothing'
);
select results_eq(
  $$ select id from public.save_from_playlist(tests.pid(1), tests.handle(3, 'b'), tests.qid(61)) $$,
  $$ values (tests.qid(30)) $$,
  'saving words B already holds (same text and author) returns B''s quote instead of a copy'
);
select results_eq(
  $$ select (select count(*)::int from public.quotes where id = tests.qid(61)), tests.prov(30) $$,
  $$ values (0, 'manual|bob|-'::text) $$,
  'no duplicate is made and B''s quote is unchanged'
);
select results_eq(
  $$ select origin, creator_id, verified_starter_id, rotation_position
     from public.save_from_playlist(tests.pid(1), tests.handle(2, 'b'), tests.qid(62), true) $$,
  $$ values ('shared'::text, null::uuid, 2::integer, 0) $$,
  'a catalog item is saved verified with no creator; p_in_reminders adds it to the Reminders'
);
select throws_ok(
  $$ select public.save_from_playlist(tests.pid(1), tests.handle(5, 'b')) $$,
  '42501', 'This quote is not available.',
  'an item the view skips (blocked term) cannot be saved'
);
select throws_ok(
  $$ select public.save_from_playlist(tests.pid(1), tests.handle(1, 'c')) $$,
  '42501', 'This quote is not available.',
  'another viewer''s handle does not work'
);
select throws_ok(
  $$ select public.save_from_playlist(tests.pid(1), tests.qid(1)) $$,
  '42501', 'This quote is not available.',
  'the quote''s own id is not a handle'
);
select throws_ok(
  $$ select public.save_from_playlist(tests.pid(2), tests.handle(1, 'b')) $$,
  '42501', 'This quote is not available.',
  'nothing can be saved from a private playlist'
);
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_playlist(tests.pid(1), tests.handle(1, 'c')) $$,
  '42501', 'This quote is not available.',
  'a stranger cannot save from a friends playlist'
);
select results_eq(
  $$ select id, owner_id from public.save_from_playlist(tests.pid(3), tests.handle(1, 'c'), tests.qid(63)) $$,
  $$ values (tests.qid(63), tests.uid('c')) $$,
  'a stranger can save from a public playlist'
);
select is(tests.prov(63), 'shared|alice|-', 'crediting the creator');
select tests.authenticate_as('a');
select results_eq(
  $$ select id from public.save_from_playlist(tests.pid(1), tests.handle(1, 'a')) $$,
  $$ values (tests.qid(1)) $$,
  'the owner saving from their own playlist gets their own quote back'
);

-- ---- save_playlist_copy --------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select owner_id, title, visibility, held_at from public.save_playlist_copy(tests.pid(1)) $$,
  $$ values (tests.uid('b'), 'Morning'::text, 'private'::text, null::timestamptz) $$,
  'B copies A''s playlist: a new private playlist of B''s with the same title'
);
select results_eq(
  $$ select i.position, q.body, q.creator_username, q.edited_from_username, q.verified_starter_id
     from public.playlist_items i
     join public.playlists p on p.id = i.playlist_id
     join public.quotes q on q.id = i.quote_id
     where p.title = 'Morning' order by i.position $$,
  $$ values (0, 'Alpha'::text, 'alice'::text, null::text, null::integer),
            (1, (select body from public.starter_quotes where id = 2), null, null, 2::integer),
            (2, 'Bob''s line', 'bob', null, null),
            (3, 'Bob''s line, Alice''s way', 'alice', 'bob', null) $$,
  'the copy holds the visible items in order, each keeping its creator'
);
select results_eq(
  $$ select array_agg(i.quote_id order by i.position) filter (where i.position > 0),
            (select count(*)::int from public.quotes)
     from public.playlist_items i join public.playlists p on p.id = i.playlist_id
     where p.title = 'Morning' $$,
  $$ values (array[tests.qid(62), tests.qid(30), tests.qid(60)], 4) $$,
  'quotes B already held are reused; only the new one was added'
);
select results_eq(
  $$ select origin, creator_username, rotation_position from public.quotes where body = 'Alpha' $$,
  $$ values ('shared'::text, 'alice'::text, null::integer) $$,
  'the new quote is origin shared, credited to A, and not in the Reminders'
);
select results_eq(
  $$ select title from public.save_playlist_copy(tests.pid(1), 'Bob''s mornings') $$,
  $$ values ('Bob''s mornings'::text) $$,
  'a copy can take a new title'
);
select is((select count(*)::int from public.quotes), 4, 'a second copy reuses every quote');
select throws_ok(
  $$ select public.save_playlist_copy(tests.pid(1), 'Darn mornings') $$,
  'QR003', null,
  'a copy''s title passes the word filter'
);
select throws_ok(
  $$ select public.save_playlist_copy(tests.pid(2)) $$,
  '42501', 'This playlist is not available.',
  'a private playlist cannot be copied'
);
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_playlist_copy(tests.pid(1)) $$,
  '42501', 'This playlist is not available.',
  'a stranger cannot copy a friends playlist'
);
select results_eq(
  $$ select visibility from public.save_playlist_copy(tests.pid(3)) $$,
  $$ values ('private'::text) $$,
  'a stranger can copy a public playlist, as a private one'
);
select results_eq(
  $$ select i.position, i.quote_id = tests.qid(63), q.body, q.creator_username
     from public.playlist_items i join public.quotes q on q.id = i.quote_id order by i.position $$,
  $$ values (0, true, 'Alpha'::text, 'alice'::text),
            (1, false, (select body from public.starter_quotes where id = 2), null) $$,
  'the copy reuses the quote C saved before and adds the catalog quote'
);

-- ---- updated_at follows item changes --------------------------------------------------
select tests.age_playlist(tests.pid(1));
select tests.authenticate_as('a');
update public.playlist_items set position = 9 where playlist_id = tests.pid(1) and quote_id = tests.qid(1);
select is((select updated_at from public.playlists where id = tests.pid(1)), now(), 'reordering moves updated_at');
select tests.age_playlist(tests.pid(1));
insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(1), tests.qid(6), 10);
select is((select updated_at from public.playlists where id = tests.pid(1)), now(), 'adding an item moves updated_at');
select tests.age_playlist(tests.pid(1));
delete from public.quotes where id = tests.qid(5);
select results_eq(
  $$ select (select updated_at from public.playlists where id = tests.pid(1)) = now(),
            (select count(*)::int from public.playlist_items where playlist_id = tests.pid(1)) $$,
  $$ values (true, 5) $$,
  'deleting a quote from the Library removes it from the playlist and moves updated_at'
);

select results_eq(
  $$ delete from public.playlists where id = tests.pid(2) returning title $$,
  $$ values ('Just me'::text) $$,
  'the owner deletes a playlist'
);
select results_eq(
  $$ select (select count(*)::int from public.playlist_items where playlist_id = tests.pid(2)),
            (select count(*)::int from public.quotes where id = tests.qid(1)) $$,
  $$ values (0, 1) $$,
  'its items go with it; the quotes stay'
);

-- ---- the secret key (service_role) -------------------------------------------------------
-- Eve's own words (70) and Bob's words in Eve's Library (71).
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, creator_id, creator_username) values
  (tests.qid(70), tests.uid('e'), 'Eve''s words', tests.uid('e'), 'eve'),
  (tests.qid(71), tests.uid('e'), 'Bob''s words, kept by Eve', tests.uid('b'), 'bob');
set local role service_role;
select lives_ok(
  $$ insert into public.playlists (id, owner_id, title, visibility) values (tests.pid(30), tests.uid('e'), 'Service list', 'private');
     insert into public.playlist_items (playlist_id, quote_id, position)
       values (tests.pid(30), tests.qid(70), 0), (tests.pid(30), tests.qid(71), 1) $$,
  'the secret key can make a playlist and fill it'
);
select throws_ok(
  $$ update public.playlists set visibility = 'public' where id = tests.pid(30) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'the eligibility rule binds the secret key too'
);
select lives_ok(
  $$ delete from public.playlist_items where playlist_id = tests.pid(30) and quote_id = tests.qid(71);
     update public.playlists set visibility = 'public' where id = tests.pid(30) $$,
  'with only eligible items the secret key can make it public'
);
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.pid(30), tests.qid(71), 1) $$,
  '42501', 'A public playlist can hold only Quoted Catalog quotes and quotes you added.',
  'and cannot add an ineligible quote to it'
);

-- ---- verified items travel as "Quoted Catalog" --------------------------------------
-- A corrects a copy of B's words (8) to catalog quote 5's exact wording: A
-- becomes the creator and B "edited from", and the row is verified. A also
-- typed catalog quote 4's exact wording (9). Both go in A's Austen playlist.
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username)
  values (tests.qid(8), tests.uid('a'), 'Courage rises', 'shared', tests.uid('b'), 'bob');
select tests.authenticate_as('a');
update public.quotes q set body = s.body, author = s.author, source = s.source
  from public.starter_quotes s where s.id = 5 and q.id = tests.qid(8);
insert into public.quotes (id, body, author, source)
  select tests.qid(9), s.body, s.author, s.source from public.starter_quotes s where s.id = 4;
insert into public.playlists (id, title, visibility) values (tests.pid(8), 'Austen', 'friends');
insert into public.playlist_items (playlist_id, quote_id, position)
  values (tests.pid(8), tests.qid(8), 0), (tests.pid(8), tests.qid(9), 1);
select is(tests.prov(8) || ' ' || tests.prov(9), 'shared|alice|bob manual|alice|-',
  'A''s own rows keep their creators (and B as edited-from)');
select tests.authenticate_as('b');
select results_eq(
  $$ select verified_starter_id, creator_id, edited_from_id
     from public.save_from_playlist(tests.pid(8), tests.handle(8, 'b'), tests.qid(68)) $$,
  $$ values (5::integer, null::uuid, null::uuid) $$,
  'a verified item is saved as "Quoted Catalog": no creator, and no edited-from naming a third person'
);
select title from public.save_playlist_copy(tests.pid(8), 'Austen copy');
select results_eq(
  $$ select q.verified_starter_id, q.creator_id, q.edited_from_id
     from public.playlists c
     join public.playlist_items i on i.playlist_id = c.id
     join public.quotes q on q.id = i.quote_id
     where c.title = 'Austen copy' and q.id <> tests.qid(68) $$,
  $$ values (4::integer, null::uuid, null::uuid) $$,
  'save_playlist_copy saves a verified item without a creator too'
);

-- ---- limits ---------------------------------------------------------------------------
-- Playlist 4 holds 200 of A's quotes.
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body)
  select ('70000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, tests.uid('a'), 'Filler ' || n
  from generate_series(1, 201) n;
insert into public.playlists (id, owner_id, title, visibility) values (tests.pid(4), tests.uid('a'), 'Two hundred', 'private');
insert into public.playlist_items (playlist_id, quote_id, position)
  select tests.pid(4), ('70000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, n
  from generate_series(1, 200) n;
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position)
     values (tests.pid(4), '70000000-0000-4000-8000-000000000201', 201) $$,
  'QR002', 'A playlist can hold at most 200 quotes.',
  'a playlist holds at most 200 quotes (QR002)'
);
select lives_ok(
  $$ insert into public.playlist_items (playlist_id, quote_id, position)
     values (tests.pid(4), '70000000-0000-4000-8000-000000000001', 0)
     on conflict (playlist_id, quote_id) do update set position = excluded.position $$,
  'a full playlist can still reorder through an upsert'
);

-- A has made 20 playlists today (counting those A deleted since).
select tests.clear_authentication();
insert into public.playlists (owner_id, title, visibility)
  select tests.uid('a'), 'Filler ' || n, 'private'
  from generate_series(1, 20 - (select count(*)::int from public.playlists
                                 where owner_id = tests.uid('a') and created_at > now() - interval '24 hours')
                             - (select count(*)::int from private.limit_deletions
                                 where owner_id = tests.uid('a') and kind = 'playlist'
                                   and created_at > now() - interval '24 hours')) n;
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.playlists (title, visibility) values ('One too many', 'private') $$,
  'QR001', 'You can make at most 20 playlists a day.',
  'at most 20 new playlists a day (QR001)'
);
select throws_ok(
  $$ insert into public.playlists (id, title, visibility) values (tests.pid(1), 'Retry', 'private') $$,
  '23505', null,
  'an id that already exists fails on the primary key, not the limit'
);
select results_eq(
  $$ delete from public.playlists where title = 'Filler 1' returning title $$,
  $$ values ('Filler 1'::text) $$,
  'A deletes one of today''s playlists'
);
select throws_ok(
  $$ insert into public.playlists (title, visibility) values ('Room again?', 'private') $$,
  'QR001', 'You can make at most 20 playlists a day.',
  'which makes no room: a deleted playlist still counts for the day'
);

-- A has 100 playlists, none made today.
select tests.clear_authentication();
update public.playlists set created_at = now() - interval '2 days' where owner_id = tests.uid('a');
alter table public.playlists disable trigger playlists_stamp_created_at;
insert into public.playlists (owner_id, title, visibility, created_at)
  select tests.uid('a'), 'Old filler ' || n, 'private', now() - interval '2 days'
  from generate_series(1, 100 - (select count(*)::int from public.playlists where owner_id = tests.uid('a'))) n;
alter table public.playlists enable trigger playlists_stamp_created_at;
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.playlists (title, visibility) values ('Hundred and one', 'private') $$,
  'QR002', 'You can keep at most 100 playlists.',
  'at most 100 playlists in all (QR002)'
);

-- B has made 20 playlists today (three of them copies).
select tests.clear_authentication();
insert into public.playlists (owner_id, title, visibility)
  select tests.uid('b'), 'Filler ' || n, 'private'
  from generate_series(1, 20 - (select count(*)::int from public.playlists
                                 where owner_id = tests.uid('b') and created_at > now() - interval '24 hours')
                             - (select count(*)::int from private.limit_deletions
                                 where owner_id = tests.uid('b') and kind = 'playlist'
                                   and created_at > now() - interval '24 hours')) n;
select tests.authenticate_as('b');
select throws_ok(
  $$ select public.save_playlist_copy(tests.pid(1)) $$,
  'QR001', 'You can make at most 20 playlists a day.',
  'the limits apply to copies too'
);
select tests.clear_authentication();

-- ---- reordering in one statement (set_playlist_positions, 20261030030600) -------------
-- Playlist 4 (full, 200 items): item n sits at position n, item 1 at 0.
create function tests.fq(n int) returns uuid language sql immutable as $$
  select ('70000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;
select tests.authenticate_as('a');
select results_eq(
  $$ select quote_id, position from public.set_playlist_positions(
       tests.pid(4), array[tests.fq(200), tests.fq(1), tests.fq(200), tests.fq(999)], array[0, 5000, 7, 3])
     order by position $$,
  $$ values (tests.fq(200), 0), (tests.fq(1), 5000) $$,
  'A moves two items of a full playlist in one call (a repeated quote keeps its first position; one not in the playlist is skipped)'
);
select results_eq(
  $$ select quote_id, position from public.playlist_items
     where playlist_id = tests.pid(4) and quote_id in (tests.fq(1), tests.fq(2), tests.fq(200)) order by position $$,
  $$ values (tests.fq(200), 0), (tests.fq(2), 2), (tests.fq(1), 5000) $$,
  'the other items stay where they were'
);
select throws_ok(
  $$ select * from public.set_playlist_positions(tests.pid(4), array[tests.fq(2), tests.fq(3)], array[100, -1]) $$,
  '23514', null,
  'a negative position fails the whole call'
);
select results_eq(
  $$ select quote_id, position from public.playlist_items
     where playlist_id = tests.pid(4) and quote_id in (tests.fq(2), tests.fq(3)) order by position $$,
  $$ values (tests.fq(2), 2), (tests.fq(3), 3) $$,
  'and moves nothing'
);
select throws_ok(
  $$ select * from public.set_playlist_positions(tests.pid(4), array[tests.fq(2)], array[1, 2]) $$,
  '22023', 'Give one position for each quote.',
  'one position for each quote'
);
select tests.authenticate_as('b');
select is_empty(
  $$ select 1 from public.set_playlist_positions(tests.pid(4), array[tests.fq(2)], array[9]) $$,
  'someone else cannot reorder A''s playlist'
);
select tests.clear_authentication();
select results_eq(
  $$ select position from public.playlist_items where playlist_id = tests.pid(4) and quote_id = tests.fq(2) $$,
  $$ values (2) $$,
  'which stays as it was'
);
select results_eq(
  $$ select has_function_privilege('anon', p.oid, 'execute'), has_function_privilege('authenticated', p.oid, 'execute'),
            has_function_privilege('service_role', p.oid, 'execute'), p.prosecdef
     from pg_proc p where p.oid = 'public.set_playlist_positions(uuid, uuid[], integer[])'::regprocedure $$,
  $$ values (false, true, false, false) $$,
  'set_playlist_positions is SECURITY INVOKER, for signed-in users only'
);

-- ---- schema details -------------------------------------------------------------------
select results_eq(
  $$ select t.tgname::text collate "default", p.prosecdef
     from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid in ('public.playlists'::regclass, 'public.playlist_items'::regclass) and not t.tgisinternal
     order by 1 $$,
  $$ values ('playlist_items_bump_playlist', true), ('playlist_items_check_insert', false),
            ('playlist_items_stamp_added_at', false), ('playlists_check_write', false),
            ('playlists_enforce_limits', true), ('playlists_log_deletion', true),
            ('playlists_set_updated_at', false), ('playlists_stamp_created_at', false) $$,
  'the guard triggers run as the writer; the limit, its deletion log and the updated_at bump have definer rights'
);

select * from finish();
rollback;
