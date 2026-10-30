-- Favorites (supabase/migrations/20261025090000_favorites.sql): the owner hearts
-- quotes; favorited_at is server-owned; a friend sees the owner's favorites only
-- through public.friend_favorites, only when accepted friends, not blocked, and
-- the owner opted in; quotes stay owner-only otherwise.
-- Ported to 20261030030000_provenance_and_accounts: shows_favorites became
-- favorites_visibility ('private' or 'friends'), friend_favorites also returns
-- the creator and edited-from usernames, and a client cannot send favorited_at
-- at all (column grants, 42501), so the "re-dating" and "client-sent date"
-- checks became 42501 checks.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(36);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'd' then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
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

create function tests.favorite_count(viewer text, owner text) returns int language plpgsql as $$
declare n int;
begin
  perform tests.authenticate_as(viewer);
  select count(*)::int into n from public.friend_favorites(tests.uid(owner));
  perform tests.clear_authentication();
  return n;
end
$$;
-- The handles B was given, to compare with another friend's.
create table tests.b_handles (id uuid, body text);
grant select, insert on tests.b_handles to authenticated;
-- ---------------------------------------------------------------------------

-- A owns quotes 1-3 and favorites 1 and 2. B is A's friend, C is a stranger,
-- D has a pending request to A.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('d'), tests.uid('a'), 'pending');

select tests.authenticate_as('a');
insert into public.quotes (id, body, author, rotation_position) values
  (tests.qid(1), 'One', 'Ann', 0), (tests.qid(2), 'Two', 'Ben', null), (tests.qid(3), 'Three', 'Cy', 1);
select tests.clear_authentication();

-- ---- defaults and the server-owned timestamp ----------------------------------
select is((select is_favorite from public.quotes where id = tests.qid(1)), false, 'quotes are not favorites by default');
select is((select favorites_visibility from public.profiles where id = tests.uid('a')), 'private', 'profiles keep favorites private by default');

select tests.authenticate_as('a');
-- A client cannot send favorited_at; the server stamps now().
select throws_ok(
  $$ update public.quotes set is_favorite = true, favorited_at = '2001-01-01' where id = tests.qid(1) $$,
  '42501', null,
  'a client cannot send favorited_at'
);
update public.quotes set is_favorite = true where id = tests.qid(1);
select tests.clear_authentication();
select ok((select favorited_at > now() - interval '1 minute' from public.quotes where id = tests.qid(1)),
  'favorited_at is stamped by the server');

select tests.authenticate_as('a');
select throws_ok(
  $$ update public.quotes set favorited_at = '2001-01-01' where id = tests.qid(3) $$,
  '42501', null,
  'favorited_at cannot be set without a favorite either'
);
select tests.clear_authentication();
select is((select favorited_at from public.quotes where id = tests.qid(3)), null::timestamptz,
  'a quote that is not a favorite has no favorited_at');

-- now() is fixed inside this transaction, so a re-stamp would look like a kept
-- stamp. Give quote 1 an older time first, so keeping it is distinguishable.
alter table public.quotes disable trigger quotes_stamp_favorited_at;
update public.quotes set favorited_at = now() - interval '1 hour' where id = tests.qid(1);
alter table public.quotes enable trigger quotes_stamp_favorited_at;

create table tests.stamp as select favorited_at from public.quotes where id = tests.qid(1);
select tests.authenticate_as('a');
update public.quotes set body = 'One again' where id = tests.qid(1);
update public.quotes set is_favorite = true where id = tests.qid(1);
select tests.clear_authentication();
select is((select favorited_at from public.quotes where id = tests.qid(1)), (select favorited_at from tests.stamp),
  'editing or re-hearting a favorite keeps favorited_at');

-- The upsert behind Undo and retries takes the same path.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, is_favorite)
  values (tests.qid(1), 'One again', 'Ann', true)
  on conflict (id) do update
  set body = excluded.body, is_favorite = excluded.is_favorite;
select tests.clear_authentication();
select is((select favorited_at from public.quotes where id = tests.qid(1)), (select favorited_at from tests.stamp),
  'an upsert of a favorite keeps favorited_at');

-- An insert can't date itself either.
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.quotes (id, body, author, is_favorite, favorited_at)
     values (tests.qid(4), 'Four', 'Dee', true, '2001-01-01') $$,
  '42501', null,
  'a client cannot send favorited_at on insert'
);
insert into public.quotes (id, body, author, is_favorite) values
  (tests.qid(4), 'Four', 'Dee', true),
  (tests.qid(5), 'Five', 'Eve', false);
select tests.clear_authentication();
select is((select favorited_at from public.quotes where id = tests.qid(4)), now(),
  'a new favorite gets the server time');
select is((select favorited_at from public.quotes where id = tests.qid(5)), null::timestamptz,
  'a new quote that is not a favorite has no favorited_at');
delete from public.quotes where id in (tests.qid(4), tests.qid(5));

select tests.authenticate_as('a');
update public.quotes set is_favorite = true where id = tests.qid(2);
update public.quotes set is_favorite = true where id = tests.qid(3);
update public.quotes set is_favorite = false where id = tests.qid(3);
select tests.clear_authentication();
select is((select favorited_at from public.quotes where id = tests.qid(3)), null::timestamptz,
  'removing a favorite clears favorited_at');

-- ---- privacy: off by default ---------------------------------------------------
select is(tests.favorite_count('b', 'a'), 0, 'a friend sees nothing while favorites are private');

-- B cannot turn it on for A.
select tests.authenticate_as('b');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
select tests.clear_authentication();
select is((select favorites_visibility from public.profiles where id = tests.uid('a')), 'private',
  'another user cannot change your setting');

select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
select tests.clear_authentication();
select is((select favorites_visibility from public.profiles where id = tests.uid('a')), 'friends', 'you can show your favorites to friends');

-- ---- what a friend sees -------------------------------------------------------
-- Three favorites whose time order (2, 1, 3) matches neither id order nor the
-- order of the last writes (3, 1, 2), so only the ORDER BY can produce it.
select tests.authenticate_as('a');
update public.quotes set is_favorite = true where id = tests.qid(3);
select tests.clear_authentication();
alter table public.quotes disable trigger quotes_stamp_favorited_at;
update public.quotes set favorited_at = now() - interval '2 hours' where id = tests.qid(3);
update public.quotes set favorited_at = now() - interval '1 hour' where id = tests.qid(1);
update public.quotes set favorited_at = now() where id = tests.qid(2);
alter table public.quotes enable trigger quotes_stamp_favorited_at;

select is(tests.favorite_count('b', 'a'), 3, 'an accepted friend sees exactly the favorites');
-- The partial index already reads favorites newest first, which would hide a
-- missing ORDER BY. Without index scans only the function's ORDER BY orders them
-- (for the rest of this transaction, including the limit tests).
set local enable_indexscan = off;
set local enable_indexonlyscan = off;
set local enable_bitmapscan = off;
select tests.authenticate_as('b');
select is(
  (select array_agg(f.body order by f.n)
   from public.friend_favorites(tests.uid('a'))
     with ordinality as f(id, body, body_format, author, source, verified_starter_id, creator_username,
                          edited_from_username, favorited_at, n)),
  array['Two', 'One again', 'Three'],
  'favorites come newest first, in the order the function returns them'
);
select ok(
  not exists (select 1 from public.friend_favorites(tests.uid('a')) where id in (tests.qid(1), tests.qid(2), tests.qid(3))),
  'a friend gets a handle for each favorite, never the quote''s id'
);
insert into tests.b_handles select id, body from public.friend_favorites(tests.uid('a'));
select is(
  (select array_agg(id order by id) from public.friend_favorites(tests.uid('a'))),
  (select array_agg(id order by id) from tests.b_handles),
  'a friend gets the same handle for a favorite on every call'
);
select is(
  (select count(*)::int from public.quotes where owner_id = tests.uid('a')),
  0,
  'a friend still cannot read the owner''s quotes table'
);
select tests.clear_authentication();

-- Only these columns: no rotation, owner, ids or timestamps beyond favorited_at.
select is(
  (select string_agg(x, ',') from unnest((select proargnames from pg_proc where oid = 'public.friend_favorites(uuid)'::regprocedure)) x),
  'p_user,id,body,body_format,author,source,verified_starter_id,creator_username,edited_from_username,favorited_at',
  'friend_favorites returns only the quote''s text, attribution, verification, creator usernames and favorited_at'
);

-- ---- who sees nothing --------------------------------------------------------
select is(tests.favorite_count('c', 'a'), 0, 'a stranger sees nothing');

-- The direction of the friendship doesn't matter: C asked A, and A accepted.
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('c'), tests.uid('a'), 'accepted');
select is(tests.favorite_count('c', 'a'), 3, 'a friend who sent the request sees the favorites too');
select tests.authenticate_as('c');
select ok(
  not exists (select 1 from public.friend_favorites(tests.uid('a')) f join tests.b_handles b on b.id = f.id),
  'each friend gets different handles'
);
select tests.clear_authentication();
delete from public.friendships where requester_id = tests.uid('c');
select is(tests.favorite_count('d', 'a'), 0, 'a pending request sees nothing');
select is(tests.favorite_count('a', 'a'), 0, 'the RPC never answers for yourself');

select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'private' where id = tests.uid('a');
select tests.clear_authentication();
select is(tests.favorite_count('b', 'a'), 0, 'turning it off hides favorites again');

select tests.authenticate_as('a');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
insert into public.blocks (blocked_id) values (tests.uid('b'));
select tests.clear_authentication();
select is(tests.favorite_count('b', 'a'), 0, 'a blocked friend sees nothing');

-- Even with a friendship row left in place, a block hides favorites. (The
-- friendship triggers would refuse this row for a blocked pair; they are off
-- only inside this rolled-back transaction.)
alter table public.friendships disable trigger user;
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('a'), tests.uid('b'), 'accepted');
alter table public.friendships enable trigger user;
select is(tests.favorite_count('b', 'a'), 0, 'a block wins over a friendship');

-- The other direction: the viewer blocked the owner (the friendship row again kept).
delete from public.blocks where blocker_id = tests.uid('a');
select tests.authenticate_as('b');
insert into public.blocks (blocked_id) values (tests.uid('a'));
select tests.clear_authentication();
alter table public.friendships disable trigger user;
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('a'), tests.uid('b'), 'accepted');
alter table public.friendships enable trigger user;
select is(tests.favorite_count('b', 'a'), 0, 'a friend who blocked the owner sees nothing');

-- ---- execute rights -------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.friend_favorites(uuid)', 'execute'), 'anon cannot call friend_favorites');
select ok(has_function_privilege('authenticated', 'public.friend_favorites(uuid)', 'execute'), 'signed-in users can call friend_favorites');
select ok(not has_function_privilege('authenticated', 'private.quotes_stamp_favorited_at()', 'execute'), 'clients cannot call the trigger function');

-- ---- limit ------------------------------------------------------------------------
delete from public.blocks where blocker_id in (tests.uid('a'), tests.uid('b'));
select tests.authenticate_as('a');
insert into public.quotes (body, author, is_favorite)
  select 'Bulk ' || g, 'Someone', true from generate_series(1, 110) g;
select tests.clear_authentication();
-- Bulk g was hearted g minutes and 30 seconds ago, so newest first runs: Two (now), Bulk 1-59,
-- One again (1 h), Bulk 60-110, Three (2 h). The first 100 end at Bulk 98.
alter table public.quotes disable trigger quotes_stamp_favorited_at;
update public.quotes set favorited_at = now() - (substr(body, 6)::int * interval '1 minute') - interval '30 seconds'
  where owner_id = tests.uid('a') and body like 'Bulk %';
alter table public.quotes enable trigger quotes_stamp_favorited_at;
select is(tests.favorite_count('b', 'a'), 100, 'at most 100 favorites come back');
select tests.authenticate_as('b');
select is(
  (select f.body from public.friend_favorites(tests.uid('a'))
     with ordinality as f(id, body, body_format, author, source, verified_starter_id, creator_username,
                          edited_from_username, favorited_at, n)
   order by f.n desc limit 1),
  'Bulk 98',
  'beyond 100, the newest 100 come back, in order'
);
select ok(not exists (select 1 from public.friend_favorites(tests.uid('a')) where body = 'Three'),
  'beyond 100, the oldest favorite is left out');
select tests.clear_authentication();

select * from finish();
rollback;
