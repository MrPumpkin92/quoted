-- friendships lifecycle and blocks.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(34);

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
select tests.create_user('c');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara');

-- ---- request --------------------------------------------------------------
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('b')) $$,
  'A can send B a friend request'
);

select results_eq(
  $$ select requester_id, status, responded_at is null from public.friendships $$,
  $$ values (tests.uid('a'), 'pending', true) $$,
  'the request is pending, from A, with no responded_at'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('a')) $$,
  '23514', null,
  'A cannot send themselves a request'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('b')) $$,
  '23505', null,
  'A cannot send B a second request'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id, status) values (tests.uid('c'), 'accepted') $$,
  '42501', null,
  'A cannot create an already-accepted friendship'
);

select throws_ok(
  $$ insert into public.friendships (requester_id, addressee_id) values (tests.uid('b'), tests.uid('c')) $$,
  '42501', null,
  'A cannot send a request on behalf of B'
);

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('a')) $$,
  '23505', null,
  'B cannot open a second, reverse request while one is pending'
);

-- ---- accept ---------------------------------------------------------------
select tests.authenticate_as('a');

select is_empty(
  $$ update public.friendships set status = 'accepted' where addressee_id = tests.uid('b') returning 1 $$,
  'A cannot accept their own request'
);

select tests.authenticate_as('c');

select is_empty(
  $$ select 1 from public.friendships $$,
  'C cannot see the A-B request'
);

select is_empty(
  $$ update public.friendships set status = 'accepted' returning 1 $$,
  'C cannot accept the A-B request'
);

select is_empty(
  $$ delete from public.friendships returning 1 $$,
  'C cannot delete the A-B request'
);

select tests.authenticate_as('b');

select results_eq(
  $$ select requester_id, addressee_id from public.friendships $$,
  $$ values (tests.uid('a'), tests.uid('b')) $$,
  'B sees the incoming request'
);

select throws_ok(
  $$ update public.friendships set requester_id = tests.uid('c') where requester_id = tests.uid('a') $$,
  '42501', null,
  'B cannot rewrite who sent the request (column grant)'
);

select results_eq(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('a')
     returning status, responded_at is not null $$,
  $$ values ('accepted', true) $$,
  'B accepts; responded_at is stamped'
);

select is_empty(
  $$ update public.friendships set status = 'pending' returning 1 $$,
  'an accepted friendship cannot go back to pending'
);

select tests.authenticate_as('a');

select results_eq(
  $$ select status from public.friendships where addressee_id = tests.uid('b') $$,
  $$ values ('accepted') $$,
  'A sees the accepted friendship'
);

-- ---- unfriend -------------------------------------------------------------
select results_eq(
  $$ delete from public.friendships where addressee_id = tests.uid('b') returning 1 $$,
  $$ values (1) $$,
  'A can unfriend B'
);

select tests.authenticate_as('b');

select is_empty(
  $$ select 1 from public.friendships $$,
  'the friendship is gone for B too'
);

-- Decline: the addressee deletes a pending request.
select tests.authenticate_as('a');
insert into public.friendships (addressee_id) values (tests.uid('b'));
select tests.authenticate_as('b');

select results_eq(
  $$ delete from public.friendships where requester_id = tests.uid('a') returning status $$,
  $$ values ('pending') $$,
  'B can decline a pending request'
);

-- ---- blocks ---------------------------------------------------------------
select tests.authenticate_as('a');
insert into public.friendships (addressee_id) values (tests.uid('c'));

select tests.authenticate_as('c');

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'C can block A'
);

select is_empty(
  $$ select 1 from public.friendships $$,
  'blocking removed the pending A-C request'
);

select results_eq(
  $$ select blocker_id, blocked_id from public.blocks $$,
  $$ values (tests.uid('c'), tests.uid('a')) $$,
  'C sees their block'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('a')) $$,
  '42501', null,
  'C (the blocker) cannot send A a request'
);

select throws_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('c')) $$,
  '23514', null,
  'nobody can block themselves'
);

select throws_ok(
  $$ update public.blocks set created_at = now() $$,
  '42501', null,
  'blocks cannot be updated'
);

select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('c')) $$,
  '42501', null,
  'A (blocked) cannot send C a request'
);

select is_empty(
  $$ select 1 from public.blocks $$,
  'A cannot see that C blocked them'
);

select is_empty(
  $$ delete from public.blocks returning 1 $$,
  'A cannot remove C''s block'
);

select throws_ok(
  $$ insert into public.blocks (blocker_id, blocked_id) values (tests.uid('c'), tests.uid('b')) $$,
  '42501', null,
  'A cannot create a block on behalf of C'
);

-- is_blocked_pair answers only for pairs that include the caller.
select tests.clear_authentication();
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('b'), tests.uid('c'));
select tests.authenticate_as('a');

select is(
  private.is_blocked_pair(tests.uid('b'), tests.uid('c')),
  false,
  'is_blocked_pair does not reveal blocks between other users'
);

select tests.authenticate_as('c');

select is(
  private.is_blocked_pair(tests.uid('c'), tests.uid('b')),
  true,
  'is_blocked_pair sees a block against the caller'
);

-- ---- unblock --------------------------------------------------------------
select results_eq(
  $$ delete from public.blocks where blocked_id = tests.uid('a') returning 1 $$,
  $$ values (1) $$,
  'C can unblock A'
);

select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('c')) $$,
  'after the unblock, A can send C a request again'
);

select tests.clear_authentication();

select results_eq(
  $$ select count(*)::int from public.blocks where blocker_id in (tests.uid('a'), tests.uid('b'), tests.uid('c'), tests.uid('d')) $$,
  $$ values (1) $$,
  'only the unrelated B->C block remains'
);

select * from finish();
rollback;
