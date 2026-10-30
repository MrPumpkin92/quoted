-- Deleting an auth user (what delete-account does through the admin API)
-- cascades through every table and leaves other users' data intact. Reports
-- are the exception: they stay for moderation with the deleted user's id set
-- to null (by them, and about them). Events carry no user id at all.
-- 20261030030000_provenance_and_accounts: other people's copies keep their text
-- and lose the creator and edited-from ("Added by a person"), the private
-- per-user rows (tombstones, suspension) go too, and the username is retired.
-- 20261030030100_playlists: A's playlists and their items go; B's playlist
-- keeps its items, including B's copy of A's words.
-- 20261030030200_posts: A's posts go; posts others made of A's words keep
-- their snapshot and lose A as creator and edited-from.
-- 20261030030300_conversations_and_messages: shares became messages. A's
-- conversations go with every message in them (both sides lose that history)
-- and A's message tombstones; B and C keep their own conversation; reports
-- name message_id instead of share_id and keep their snapshots.
-- 20261030030400_profiles_and_moderation: a report keeps its target_kind when
-- its target goes with the account; profile_view finds nothing for a deleted
-- (retired) username; and D's quote and post, whose creator and edited-from
-- accounts are deleted in one statement, lose both pairs and keep their text.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(27);

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
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('b'), tests.uid('c'), 'accepted');
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('c'));
insert into public.quotes (id, owner_id, body) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'A quote'),
  ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B quote');
-- B saved A's words (creator A); C rewrote A's words (edited from A).
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username) values
  ('b0000000-0000-4000-8000-000000000002', tests.uid('b'), 'A quote', 'shared', tests.uid('a'), 'alice');
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username, edited_from_id, edited_from_username) values
  ('c0000000-0000-4000-8000-000000000001', tests.uid('c'), 'A quote, my way', 'shared', tests.uid('c'), 'cara',
   tests.uid('a'), 'alice');
-- D saved C's rewrite of B's words (creator C, edited from B).
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username, edited_from_id, edited_from_username) values
  ('d0000000-0000-4000-8000-000000000001', tests.uid('d'), 'B''s words, C''s way', 'shared', tests.uid('c'), 'cara',
   tests.uid('b'), 'bob');
insert into private.quote_tombstones (id, owner_id, origin, wording_md5, was_verified)
values ('a0000000-0000-4000-8000-000000000009', tests.uid('a'), 'manual', md5('x'), false);
insert into private.suspensions (user_id, reason) values (tests.uid('a'), 'test');
insert into public.playlists (id, owner_id, title) values
  ('91000000-0000-4000-8000-00000000000a', tests.uid('a'), 'A''s list'),
  ('91000000-0000-4000-8000-00000000000b', tests.uid('b'), 'B''s list');
insert into public.playlist_items (playlist_id, quote_id, position) values
  ('91000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 0),
  ('91000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000001', 0),
  ('91000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000002', 1);
-- A posted A's words; B posted B's copy of them; C posted C's rewrite.
insert into public.posts (id, author_id, source_quote_id) values
  ('80000000-0000-4000-8000-00000000000a', tests.uid('a'), 'a0000000-0000-4000-8000-000000000001'),
  ('80000000-0000-4000-8000-00000000000b', tests.uid('b'), 'b0000000-0000-4000-8000-000000000002'),
  ('80000000-0000-4000-8000-00000000000c', tests.uid('c'), 'c0000000-0000-4000-8000-000000000001'),
  ('80000000-0000-4000-8000-00000000000d', tests.uid('d'), 'd0000000-0000-4000-8000-000000000001');
-- Conversations A-B and B-C (as open_conversation makes them), with messages
-- both ways; A and B each unsent one message (tombstones).
insert into public.conversations (id, user_a, user_b) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), tests.uid('b')),
  ('c0a00000-0000-4000-8000-0000000000bc', tests.uid('b'), tests.uid('c'));
insert into public.conversation_members (conversation_id, user_id) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a')), ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('b')),
  ('c0a00000-0000-4000-8000-0000000000bc', tests.uid('b')), ('c0a00000-0000-4000-8000-0000000000bc', tests.uid('c'));
insert into public.messages (id, conversation_id, sender_id, kind, body) values
  ('5a000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'quote', 'A to B'),
  ('5b000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('b'), 'quote', 'B to A'),
  ('5b000000-0000-4000-8000-000000000002', 'c0a00000-0000-4000-8000-0000000000bc', tests.uid('b'), 'quote', 'B to C');
insert into private.message_tombstones (id, conversation_id, sender_id, payload) values
  ('5a000000-0000-4000-8000-000000000009', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), '{}'),
  ('5b000000-0000-4000-8000-000000000009', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('b'), '{}');
insert into public.reports (id, reporter_id, message_id, reported_user_id, reason) values
  ('7e000000-0000-4000-8000-000000000001', tests.uid('b'), '5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam'),
  ('7e000000-0000-4000-8000-000000000002', tests.uid('c'), '5b000000-0000-4000-8000-000000000002', tests.uid('b'), 'other'),
  ('7e000000-0000-4000-8000-000000000003', tests.uid('a'), '5b000000-0000-4000-8000-000000000001', tests.uid('b'), 'harassment');
-- events are anonymous, so this test's rows are the ones above the current max id.
create table tests.baseline as select coalesce(max(id), 0) as max_event_id from public.events;
insert into public.events (name) values ('web_search_tap'), ('web_search_tap');

select lives_ok(
  $$ delete from auth.users where id = tests.uid('a') $$,
  'deleting A''s auth user succeeds'
);

select is_empty($$ select 1 from public.profiles where id = tests.uid('a') $$, 'A''s profile is gone');
select is_empty($$ select 1 from public.quotes where owner_id = tests.uid('a') $$, 'A''s quotes are gone');
select is_empty(
  $$ select 1 from public.friendships where tests.uid('a') in (requester_id, addressee_id) $$,
  'A''s friendships are gone'
);
select is_empty($$ select 1 from public.blocks where tests.uid('a') in (blocker_id, blocked_id) $$, 'A''s blocks are gone');
select is_empty(
  $$ select 1 from public.conversations where tests.uid('a') in (user_a, user_b) $$,
  'A''s conversations are gone'
);
select is_empty(
  $$ select 1 from public.conversation_members where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab' or user_id = tests.uid('a') $$,
  'with both member rows'
);
select is_empty(
  $$ select 1 from public.messages where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab' or sender_id = tests.uid('a') $$,
  'and every message in them, B''s included: both sides lose that history'
);
select results_eq(
  $$ select sender_id from private.message_tombstones where id::text like '5_000000-0000-4000-8000-000000000009' $$,
  $$ values (tests.uid('b')) $$,
  'A''s message tombstones are gone; B''s own stays until it is purged'
);
select is_empty(
  $$ select 1 from public.reports where tests.uid('a') in (reporter_id, reported_user_id) $$,
  'no report points at A any more'
);
select results_eq(
  $$ select reporter_id, reported_user_id, reported_username, content_body, content_verified, message_id, target_kind
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.uid('b'), null::uuid, 'alice'::text, 'A to B'::text, true, null::uuid, 'message'::text) $$,
  'a report about A survives with its snapshot, A''s username and what it was about, without A''s id or the message'
);
select results_eq(
  $$ select reporter_id, reported_user_id, reason, content_body, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000003' $$,
  $$ values (null::uuid, tests.uid('b'), 'harassment'::text, 'B to A'::text, true) $$,
  'a report A filed survives anonymously, still about B and still verified'
);
select is(
  (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)),
  2,
  'events are anonymous, so deleting A leaves the counts alone'
);

select results_eq(
  $$ select (select count(*)::int from public.profiles where id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.quotes where owner_id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.friendships where requester_id in (tests.uid('b'), tests.uid('c'))),
            (select count(*)::int from public.messages where conversation_id = 'c0a00000-0000-4000-8000-0000000000bc'),
            (select count(*)::int from public.reports where id in ('7e000000-0000-4000-8000-000000000001',
               '7e000000-0000-4000-8000-000000000002', '7e000000-0000-4000-8000-000000000003')),
            (select count(*)::int from public.events where id > (select max_event_id from tests.baseline)) $$,
  $$ values (2, 3, 1, 1, 3, 2) $$,
  'B and C keep their profiles, quotes, friendship and conversation; all reports and events remain'
);

select results_eq(
  $$ select id, body, creator_id, creator_username, edited_from_id, edited_from_username from public.quotes
     where id in ('b0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001') order by id $$,
  $$ values ('b0000000-0000-4000-8000-000000000002'::uuid, 'A quote'::text, null::uuid, null::text, null::uuid, null::text),
            ('c0000000-0000-4000-8000-000000000001', 'A quote, my way', tests.uid('c'), 'cara', null, null) $$,
  'copies others hold keep their text and lose A as creator and as edited-from'
);
select is_empty($$ select 1 from private.quote_tombstones where owner_id = tests.uid('a') $$, 'A''s quote tombstones are gone');
select is_empty($$ select 1 from private.suspensions where user_id = tests.uid('a') $$, 'A''s suspension row is gone');
select ok(exists (select 1 from private.retired_usernames where username = 'alice'), 'A''s username is retired');
select tests.authenticate_as('b');
select is(public.profile_view('alice'), null, 'and no profile page answers to it');
select tests.clear_authentication();

select results_eq(
  $$ select (select count(*)::int from public.playlists where owner_id = tests.uid('a')),
            (select count(*)::int from public.playlist_items where playlist_id = '91000000-0000-4000-8000-00000000000a') $$,
  $$ values (0, 0) $$,
  'A''s playlists and their items are gone'
);
select results_eq(
  $$ select i.quote_id, i.position from public.playlist_items i
     join public.playlists p on p.id = i.playlist_id
     where p.owner_id = tests.uid('b') order by i.position $$,
  $$ values ('b0000000-0000-4000-8000-000000000001'::uuid, 0), ('b0000000-0000-4000-8000-000000000002', 1) $$,
  'B''s playlist keeps its items, including B''s copy of A''s words'
);

select is_empty($$ select 1 from public.posts where author_id = tests.uid('a') $$, 'A''s posts are gone');
select results_eq(
  $$ select author_id, body, creator_id, creator_username, edited_from_id, edited_from_username
     from public.posts order by id $$,
  $$ values (tests.uid('b'), 'A quote'::text, null::uuid, null::text, null::uuid, null::text),
            (tests.uid('c'), 'A quote, my way', tests.uid('c'), 'cara', null, null),
            (tests.uid('d'), 'B''s words, C''s way', tests.uid('c'), 'cara', tests.uid('b'), 'bob') $$,
  'posts others made of A''s words keep their snapshot and lose A as creator and edited-from'
);

-- The purge deletes many accounts in one statement. C reported B's message
-- and both go at once: the report's message_id, post_id and playlist_id
-- foreign keys are checked at commit, after the cascade has nulled them.
select lives_ok(
  $$ delete from auth.users where id in (tests.uid('b'), tests.uid('c')) $$,
  'deleting B and C in one statement (as the purge does) succeeds, though C reported B''s message'
);
select lives_ok(
  $$ set constraints all immediate $$,
  'and every deferred foreign key check passes once the cascade is done'
);
select results_eq(
  $$ select reporter_id, reported_user_id, message_id, reported_username, content_body
     from public.reports where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values (null::uuid, null::uuid, null::uuid, 'bob'::text, 'B to C'::text) $$,
  'that report stays, anonymous on both sides, with its copy'
);
select results_eq(
  $$ select (select body || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
             from public.quotes where id = 'd0000000-0000-4000-8000-000000000001'),
            (select body || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
             from public.posts where id = '80000000-0000-4000-8000-00000000000d') $$,
  $$ values ('B''s words, C''s way|-|-'::text, 'B''s words, C''s way|-|-'::text) $$,
  'D''s quote and post lose both their creator and edited-from in that one statement, and keep their text'
);

select * from finish();
rollback;
