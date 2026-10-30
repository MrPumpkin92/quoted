-- profile_view (supabase/migrations/20261030030400_profiles_and_moderation.sql):
-- one profile page by exact username (after normalizing, like find_profile);
-- each relationship (self, friend, incoming, outgoing, none, you_blocked);
-- null when that person blocked the caller, for an unknown or partial
-- username, and when signed out; strangers see only public, unheld posts and
-- playlists (none at all while can_publish is false for everyone) and no
-- favorites; friends see friends items, never held or reported ones, and
-- favorites only when shared (blocked terms skip unverified ones); posts come
-- 30 per page, newest first; the output has no private column and no quote id.
-- Review fixes: public items stop reaching strangers once their owner may no
-- longer publish; a suspended account's favorites are held from friends.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(45);

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
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.pid(n int) returns uuid language sql immutable as $$
  select ('80000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.plid(n int) returns uuid language sql immutable as $$
  select ('91000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- The per-viewer handle profile_view and friend_favorites return for a quote.
create function tests.handle(n int, viewer text) returns uuid language sql immutable as $$
  select md5(tests.qid(n)::text || ':' || tests.uid(viewer)::text)::uuid
$$;

-- The ids of a profile_view list, in order, as text.
create function tests.ids(view jsonb, list text) returns text language sql immutable as $$
  select coalesce(string_agg(e ->> 'id', ',' order by n), '')
  from jsonb_array_elements(view -> list) with ordinality as x (e, n)
$$;

-- A post id as profile_view shows it.
create function tests.p(n int) returns text language sql immutable as $$
  select tests.pid(n)::text
$$;
-- ---------------------------------------------------------------------------

-- A (alice) owns the profile. B is A's friend; C is a stranger; D asked A to
-- be friends (pending); A blocked E; F blocked A.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice A'), (tests.uid('b'), 'bob', 'Bob B'), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('f'), 'fay', null);
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'f']) w;
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('e')), (tests.uid('f'), tests.uid('a'));
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('d'), tests.uid('a'), 'pending');
-- 'fearless' is in catalog quote 3 ("Beware; for I am fearless, ...").
insert into private.blocked_terms (term) values ('darn'), ('fearless');

-- A's quotes: 1 typed by A, 2 a copy of B's words, 3 A's words with a blocked
-- term, 4 A's copy of catalog quote 3 (verified), 5 A's rewrite of B's words.
-- 1 to 4 are favorites.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(3), 'Darn it all', null);
select id from public.add_catalog_quotes(array[3]::integer[], array[tests.qid(4)]);
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username) values
  (tests.qid(2), tests.uid('a'), 'Bob''s line', 'Bo', 'shared', tests.uid('b'), 'bob');
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username, edited_from_id, edited_from_username)
  values (tests.qid(5), tests.uid('a'), 'Bob''s line, my way', 'shared', tests.uid('a'), 'alice', tests.uid('b'), 'bob');
select tests.authenticate_as('a');
update public.quotes set is_favorite = true where id in (tests.qid(1), tests.qid(2), tests.qid(3), tests.qid(4));
select tests.clear_authentication();

-- A's posts. Thirty older ones (two days back and more) for paging, then the
-- seven of the last day: 1 (quote 1), 2 (B's words), 3 (catalog 1), 4 held,
-- 5 (B will report it), 6 public but held, 7 (A's rewrite, never eligible
-- for Public). Inserted in batches and aged, because of the 20-a-day limit.
insert into public.posts (id, author_id, source_quote_id) select tests.pid(100 + n), tests.uid('a'), tests.qid(1) from generate_series(1, 15) n;
update public.posts p set created_at = now() - interval '3 days' - make_interval(mins => n)
  from generate_series(1, 15) n where p.id = tests.pid(100 + n);
insert into public.posts (id, author_id, source_quote_id) select tests.pid(115 + n), tests.uid('a'), tests.qid(1) from generate_series(1, 15) n;
update public.posts p set created_at = now() - interval '2 days' - make_interval(mins => n)
  from generate_series(1, 15) n where p.id = tests.pid(115 + n);
insert into public.posts (id, author_id, source_quote_id, starter_quote_id, caption, audience) values
  (tests.pid(1), tests.uid('a'), tests.qid(1), null, 'One', 'friends'),
  (tests.pid(2), tests.uid('a'), tests.qid(2), null, null, 'friends'),
  (tests.pid(3), tests.uid('a'), null, 1, null, 'friends'),
  (tests.pid(4), tests.uid('a'), tests.qid(1), null, null, 'friends'),
  (tests.pid(5), tests.uid('a'), tests.qid(1), null, null, 'friends'),
  (tests.pid(6), tests.uid('a'), null, 2, null, 'public'),
  (tests.pid(7), tests.uid('a'), tests.qid(5), null, null, 'friends');
update public.posts p set created_at = now() - make_interval(hours => n)
  from generate_series(1, 7) n where p.id = tests.pid(n);
update public.posts set held_at = now() where id in (tests.pid(4), tests.pid(6));
-- E has a public post too (a catalog quote).
insert into public.posts (id, author_id, starter_quote_id, audience) values (tests.pid(50), tests.uid('e'), 2, 'public');

-- A's playlists: 1 friends (quotes 1, 2 and 3), 2 Only me, 3 friends (quotes
-- 1 and 4, both eligible for Public), 4 held, 5 (B will report it).
insert into public.playlists (id, owner_id, title, visibility, held_at) values
  (tests.plid(1), tests.uid('a'), 'Friends list', 'friends', null),
  (tests.plid(2), tests.uid('a'), 'Only me', 'private', null),
  (tests.plid(3), tests.uid('a'), 'Public list', 'friends', null),
  (tests.plid(4), tests.uid('a'), 'Held list', 'friends', now()),
  (tests.plid(5), tests.uid('a'), 'Reported list', 'friends', null);
insert into public.playlist_items (playlist_id, quote_id, position) values
  (tests.plid(1), tests.qid(1), 0), (tests.plid(1), tests.qid(2), 1), (tests.plid(1), tests.qid(3), 2),
  (tests.plid(2), tests.qid(1), 0),
  (tests.plid(3), tests.qid(1), 0), (tests.plid(3), tests.qid(4), 1);

-- B reports post 5 and playlist 5: both disappear for B (one reporter holds
-- nothing).
select tests.authenticate_as('b');
insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(5), tests.uid('a'), 'spam');
insert into public.reports (playlist_id, reported_user_id, reason) values (tests.plid(5), tests.uid('a'), 'spam');
select tests.clear_authentication();

-- ---- the RPC ---------------------------------------------------------------
select results_eq(
  $$ select p.oid::regprocedure::text, has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p where p.proname = 'profile_view' order by 1 $$,
  $$ values ('private.profile_view(text,timestamp with time zone)', false, true, false, true),
            ('profile_view(text,timestamp with time zone)', false, true, false, false) $$,
  'profile_view is a SECURITY INVOKER wrapper for signed-in users only'
);

-- ---- exact username only ------------------------------------------------------
select tests.authenticate_as('c');
select is(public.profile_view('alic'), null, 'a partial username finds nothing');
select is(public.profile_view('nobody'), null, 'an unknown username finds nothing');
select is(public.profile_view(' @Alice '), public.profile_view('alice'),
  'the username is trimmed, one leading @ dropped and lowercased, like find_profile');
select is(public.profile_view('alice') -> 'profile',
  jsonb_build_object('id', tests.uid('a'), 'username', 'alice', 'display_name', 'Alice A'),
  'the profile is its id, username and display name');
select tests.clear_authentication();
set local role authenticated;
select is(public.profile_view('alice'), null, 'signed out (no user in the token), there is nothing');
select tests.clear_authentication();

-- ---- each relationship ---------------------------------------------------------
select tests.authenticate_as('a');
select is(public.profile_view('alice') ->> 'relationship', 'self', 'your own profile is self');
select is(public.profile_view('dan') ->> 'relationship', 'incoming', 'someone who asked you is incoming');
select is(
  public.profile_view('eve'),
  jsonb_build_object('profile', jsonb_build_object('id', tests.uid('e'), 'username', 'eve', 'display_name', null),
                     'relationship', 'you_blocked', 'posts', '[]'::jsonb, 'playlists', '[]'::jsonb, 'favorites', null::jsonb),
  'someone you blocked: the profile and relationship only, nothing they posted, no favorites'
);
select is(public.profile_view('fay'), null, 'someone who blocked you: nothing at all, as if there were no such profile');
select tests.authenticate_as('b');
select is(public.profile_view('alice') ->> 'relationship', 'friend', 'an accepted friend is friend');
select tests.authenticate_as('d');
select is(public.profile_view('alice') ->> 'relationship', 'outgoing', 'someone you asked is outgoing');
select tests.authenticate_as('c');
select is(public.profile_view('alice') ->> 'relationship', 'none', 'a stranger is none');
select tests.authenticate_as('e');
select is(public.profile_view('alice'), null, 'the person A blocked gets nothing');
select tests.authenticate_as('f');
select is(public.profile_view('alice') ->> 'relationship', 'you_blocked', 'the person who blocked A sees that they did');

-- ---- strangers: only public, unheld items; none while Public is off ------------
select tests.authenticate_as('c');
select results_eq(
  $$ select public.profile_view('alice') -> 'posts', public.profile_view('alice') -> 'playlists',
            public.profile_view('alice') -> 'favorites' $$,
  $$ values ('[]'::jsonb, '[]'::jsonb, 'null'::jsonb) $$,
  'while can_publish is false for everyone, a stranger sees no posts, no playlists and no favorites'
);
select tests.authenticate_as('a');
select throws_ok($$ update public.posts set audience = 'public' where id = tests.pid(3) $$, '42501', null,
  'A cannot make a post public without Sign in with Apple');

select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple');
select tests.authenticate_as('a');
select lives_ok(
  $$ update public.posts set audience = 'public' where id in (tests.pid(1), tests.pid(3)) $$,
  'with an Apple identity, A makes posts 1 (A''s own words) and 3 (a catalog quote) public'
);
select throws_ok($$ update public.posts set audience = 'public' where id = tests.pid(7) $$, '42501', null,
  'but not post 7, which is edited from B''s words');
select lives_ok($$ update public.playlists set visibility = 'public' where id = tests.plid(3) $$,
  'and makes playlist 3 public');

select tests.authenticate_as('c');
select is(tests.ids(public.profile_view('alice'), 'posts'), tests.p(1) || ',' || tests.p(3),
  'a stranger sees the public posts, newest first, and not the held public one');
select is((public.profile_view('alice') -> 'playlists') #- '{0,updated_at}',
  jsonb_build_array(jsonb_build_object('id', tests.plid(3), 'title', 'Public list', 'visibility', 'public', 'item_count', 2)),
  'and the public playlist, with its item count');
select is(public.profile_view('alice') -> 'favorites', 'null'::jsonb, 'but never favorites');
select tests.authenticate_as('d');
select results_eq(
  $$ select tests.ids(public.profile_view('alice'), 'posts'), tests.ids(public.profile_view('alice'), 'playlists'),
            public.profile_view('alice') -> 'favorites' $$,
  $$ values (tests.p(1) || ',' || tests.p(3), tests.plid(3)::text, 'null'::jsonb) $$,
  'a pending request does not make D a friend: D sees what a stranger sees'
);
select tests.authenticate_as('c');
insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(1), tests.uid('a'), 'spam');
select is(tests.ids(public.profile_view('alice'), 'posts'), tests.p(3), 'a public post the stranger reported disappears for them');

-- A's acceptance of the terms lapses (as when the Terms of use change): A may
-- no longer publish.
select tests.clear_authentication();
update public.profiles set terms_version = null, terms_accepted_at = null where id = tests.uid('a');
select tests.authenticate_as('d');
select results_eq(
  $$ select public.profile_view('alice') -> 'posts', public.profile_view('alice') -> 'playlists' $$,
  $$ values ('[]'::jsonb, '[]'::jsonb) $$,
  'public items stop reaching strangers once their owner may no longer publish'
);
select tests.authenticate_as('b');
select is(tests.ids(public.profile_view('alice'), 'playlists'), tests.plid(1)::text || ',' || tests.plid(3)::text,
  'friends still see them');
select tests.clear_authentication();
select tests.accept_terms('a');

-- ---- friends: friends and public items, not held, not reported ---------------
select tests.authenticate_as('b');
select is(
  (select string_agg(e ->> 'id', ',' order by n) from jsonb_array_elements(public.profile_view('alice') -> 'posts') with ordinality x (e, n) where n <= 4),
  tests.p(1) || ',' || tests.p(2) || ',' || tests.p(3) || ',' || tests.p(7),
  'a friend sees friends and public posts, newest first, but not the held ones or the one they reported'
);
select results_eq(
  $$ select e ->> 'audience', e ->> 'caption', e ->> 'body', e ->> 'creator_username', e ->> 'edited_from_username',
            (e ->> 'verified_starter_id')::int
     from jsonb_array_elements(public.profile_view('alice') -> 'posts') with ordinality x (e, n) where n <= 4 order by n $$,
  $$ values ('public'::text, 'One'::text, 'Alpha'::text, 'alice'::text, null::text, null::int),
            ('friends', null, 'Bob''s line', 'bob', null, null),
            ('public', null, (select body from public.starter_quotes where id = 1), null, null, 1),
            ('friends', null, 'Bob''s line, my way', 'alice', 'bob', null) $$,
  'each post carries its snapshot and audience; creator usernames only for unverified ones'
);
select is(tests.ids(public.profile_view('alice'), 'playlists'), tests.plid(1)::text || ',' || tests.plid(3)::text,
  'a friend sees friends and public playlists, not the Only me, held or reported ones');
select is(
  (select (e ->> 'item_count')::int from jsonb_array_elements(public.profile_view('alice') -> 'playlists') e
   where e ->> 'id' = tests.plid(1)::text),
  2,
  'item_count is what playlist_view shows: the unverified item with a blocked term is skipped'
);
select is(public.profile_view('alice') -> 'favorites', 'null'::jsonb, 'favorites stay hidden while A keeps them to themselves');

select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
select tests.authenticate_as('b');
select is(
  public.profile_view('alice') -> 'favorites',
  (select jsonb_agg(jsonb_build_object('id', f.id, 'body', f.body, 'body_format', f.body_format, 'author', f.author,
                                       'source', f.source, 'verified_starter_id', f.verified_starter_id,
                                       'creator_username', f.creator_username,
                                       'edited_from_username', f.edited_from_username, 'favorited_at', f.favorited_at)
                    order by n)
   from public.friend_favorites(tests.uid('a')) with ordinality f (id, body, body_format, author, source,
        verified_starter_id, creator_username, edited_from_username, favorited_at, n)),
  'once A shares favorites, a friend sees exactly what friend_favorites returns'
);
select results_eq(
  $$ select (e ->> 'id')::uuid, e ->> 'body', e ->> 'creator_username'
     from jsonb_array_elements(public.profile_view('alice') -> 'favorites') with ordinality x (e, n) order by n $$,
  $$ values (tests.handle(1, 'b'), 'Alpha'::text, 'alice'::text),
            (tests.handle(2, 'b'), 'Bob''s line', 'bob'),
            (tests.handle(4, 'b'), (select body from public.starter_quotes where id = 3), null) $$,
  'per-viewer handles, creators for unverified quotes, and the unverified one with a blocked term skipped (the verified one stays)'
);
select tests.clear_authentication();
insert into private.suspensions (user_id, reason) values (tests.uid('a'), 'test');
select tests.authenticate_as('b');
select is(public.profile_view('alice') -> 'favorites', '[]'::jsonb,
  'a suspended account''s favorites are held from friends, like its posts and playlists');
select tests.clear_authentication();
delete from private.suspensions where user_id = tests.uid('a');
select tests.authenticate_as('c');
select is(public.profile_view('alice') -> 'favorites', 'null'::jsonb, 'a stranger still sees no favorites');

-- ---- paging ------------------------------------------------------------------------
select tests.authenticate_as('b');
select is(jsonb_array_length(public.profile_view('alice') -> 'posts'), 30, 'posts come 30 at a time');
select is(
  (select bool_and((x.e ->> 'created_at')::timestamptz >= (y.e ->> 'created_at')::timestamptz)
   from jsonb_array_elements(public.profile_view('alice') -> 'posts') with ordinality x (e, n)
   join jsonb_array_elements(public.profile_view('alice') -> 'posts') with ordinality y (e, n) on y.n = x.n + 1),
  true,
  'newest first'
);
select is(
  jsonb_array_length(public.profile_view('alice', (public.profile_view('alice') -> 'posts' -> 29 ->> 'created_at')::timestamptz) -> 'posts'),
  4,
  'the next page (older than the last one shown) has the other 4 of the 34 a friend may see'
);
select is(
  (select count(distinct e ->> 'id')::int from (
     select jsonb_array_elements(public.profile_view('alice') -> 'posts') e
     union all
     select jsonb_array_elements(public.profile_view('alice', (public.profile_view('alice') -> 'posts' -> 29 ->> 'created_at')::timestamptz) -> 'posts')
   ) both_pages),
  34,
  'and the two pages do not overlap'
);

-- ---- your own profile ---------------------------------------------------------------
select tests.authenticate_as('a');
select is(
  tests.ids(public.profile_view('alice'), 'playlists'),
  tests.plid(1)::text || ',' || tests.plid(2)::text || ',' || tests.plid(3)::text || ',' || tests.plid(4)::text || ',' || tests.plid(5)::text,
  'you see all your playlists: Only me, held and reported ones too'
);
select is(
  (select string_agg(e ->> 'id', ',' order by n) from jsonb_array_elements(public.profile_view('alice') -> 'posts') with ordinality x (e, n) where n <= 7),
  tests.p(1) || ',' || tests.p(2) || ',' || tests.p(3) || ',' || tests.p(4) || ',' || tests.p(5) || ',' || tests.p(6) || ',' || tests.p(7),
  'and all your posts, held and reported ones too'
);
select results_eq(
  $$ select (e ->> 'id')::uuid, e ->> 'body' from jsonb_array_elements(public.profile_view('alice') -> 'favorites') with ordinality x (e, n) order by n $$,
  $$ values (tests.handle(1, 'a'), 'Alpha'::text), (tests.handle(2, 'a'), 'Bob''s line'),
            (tests.handle(3, 'a'), 'Darn it all'), (tests.handle(4, 'a'), (select body from public.starter_quotes where id = 3)) $$,
  'and all your favorites, unfiltered (your Library is private), with handles, not quote ids'
);

-- ---- no private columns -------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select (select array_agg(k order by k) from jsonb_object_keys(v) k),
            (select array_agg(k order by k) from jsonb_object_keys(v -> 'profile') k),
            (select array_agg(distinct k order by k) from jsonb_array_elements(v -> 'posts') e, jsonb_object_keys(e) k),
            (select array_agg(distinct k order by k) from jsonb_array_elements(v -> 'playlists') e, jsonb_object_keys(e) k),
            (select array_agg(distinct k order by k) from jsonb_array_elements(v -> 'favorites') e, jsonb_object_keys(e) k)
     from (select public.profile_view('alice') as v) x $$,
  $$ values (array['favorites', 'playlists', 'posts', 'profile', 'relationship'],
             array['display_name', 'id', 'username'],
             array['audience', 'author', 'body', 'body_format', 'caption', 'created_at', 'creator_username',
                   'edited_from_username', 'id', 'source', 'verified_starter_id'],
             array['id', 'item_count', 'title', 'updated_at', 'visibility'],
             array['author', 'body', 'body_format', 'creator_username', 'edited_from_username', 'favorited_at', 'id',
                   'source', 'verified_starter_id']) $$,
  'every item has exactly these fields: no last_active_at, purge_exempt, terms, suspension, held_at or favorites setting'
);
select ok(
  position(tests.qid(1)::text in public.profile_view('alice')::text) = 0
    and position(tests.qid(2)::text in public.profile_view('alice')::text) = 0
    and position(tests.uid('b')::text in public.profile_view('alice')::text) = 0,
  'no quote id and no creator''s account id anywhere: only per-viewer handles and usernames'
);

select tests.clear_authentication();

select * from finish();
rollback;
