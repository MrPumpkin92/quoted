-- Reports and moderation (supabase/migrations/20261029090400_profiles_and_moderation.sql,
-- on the reports rework of 20261029090300_conversations_and_messages): a
-- report on a post, a message, a playlist, a Quoted Catalog quote
-- (wrong_wording) and a profile, each with its server-owned target_kind; the
-- target must be one the reporter can see and reported_user_id its author,
-- sender or owner; the server's copy and content_verified; the auto-hold after
-- two different reporters (one reporter twice, or the owner, does not hold);
-- private.suspend_user holds everything, stops every social write and is for
-- no API role, and unsuspend_user leaves items held; reports_to_review lists
-- every kind, including a target that is gone. A reporter reads back what
-- they filed but never the server's copy, the recorded username or
-- reviewed_at (column grants); the tests read those with definer rights.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(66);

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

create function tests.mid(n int) returns uuid language sql immutable as $$
  select ('5a000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.rid(n int) returns uuid language sql immutable as $$
  select ('7e000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- The conversation between A and someone, read with definer rights.
create function tests.cid(who text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid('a'), tests.uid(who)) and c.user_b = greatest(tests.uid('a'), tests.uid(who))
$$;

-- When a post or playlist was held, read with definer rights.
create function tests.post_held(n int) returns timestamptz language sql stable security definer as $$
  select held_at from public.posts where id = tests.pid(n)
$$;
create function tests.playlist_held(n int) returns timestamptz language sql stable security definer as $$
  select held_at from public.playlists where id = tests.plid(n)
$$;

-- The caller's own reports with every column, read with definer rights:
-- reporters may not select the server's copy, so the tests read it as the
-- founder does.
create function tests.own_reports() returns setof public.reports language sql stable security definer as $$
  select * from public.reports where reporter_id = auth.uid()
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

-- A (alice) posts, keeps playlists and sends B messages. B, C and E are A's
-- friends; D is a stranger; F asked A to be friends (pending). Everyone has
-- accepted the terms.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice A'), (tests.uid('b'), 'bob', null), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('f'), 'fay', null);
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'f']) w;
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('c'), 'accepted'),
  (tests.uid('e'), tests.uid('a'), 'accepted'), (tests.uid('f'), tests.uid('a'), 'pending');

select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(2), 'Beta', null);
select tests.clear_authentication();
-- Posts 1, 2 and 4 from A's quotes, 3 from catalog quote 1; all for friends.
insert into public.posts (id, author_id, source_quote_id, starter_quote_id, caption) values
  (tests.pid(1), tests.uid('a'), tests.qid(1), null, 'First'),
  (tests.pid(2), tests.uid('a'), tests.qid(2), null, 'Second'),
  (tests.pid(3), tests.uid('a'), null, 1, null),
  (tests.pid(4), tests.uid('a'), tests.qid(1), null, null);
insert into public.playlists (id, owner_id, title, visibility) values
  (tests.plid(1), tests.uid('a'), 'Morning', 'friends'),
  (tests.plid(2), tests.uid('a'), 'Evening', 'friends'),
  (tests.plid(3), tests.uid('a'), 'Secret', 'private');
insert into public.playlist_items (playlist_id, quote_id, position) values (tests.plid(1), tests.qid(1), 0);
-- A's conversation with B: a quote with a note, and a text.
insert into public.conversations (user_a, user_b) values (least(tests.uid('a'), tests.uid('b')), greatest(tests.uid('a'), tests.uid('b')));
insert into public.conversation_members (conversation_id, user_id) values
  (tests.cid('b'), tests.uid('a')), (tests.cid('b'), tests.uid('b'));
insert into public.messages (id, conversation_id, sender_id, kind, source_quote_id, note) values
  (tests.mid(1), tests.cid('b'), tests.uid('a'), 'quote', tests.qid(1), 'for you');
insert into public.messages (id, conversation_id, sender_id, kind, text) values
  (tests.mid(2), tests.cid('b'), tests.uid('a'), 'text', 'Hello B');

-- ---- schema ---------------------------------------------------------------
select has_trigger('public', 'reports', 'reports_set_target_kind', 'reports has the target_kind trigger');
select has_trigger('public', 'reports', 'reports_hold_target', 'reports has the auto-hold trigger');
select is_definer('private', 'reports_hold_target', array[]::text[],
  'the auto-hold runs with definer rights (reporters cannot write held_at)');
select results_eq(
  $$ select data_type::text collate "default", is_nullable::text collate "default", column_default::text collate "default"
     from information_schema.columns where table_schema = 'public' and table_name = 'reports' and column_name = 'target_kind' $$,
  $$ values ('text', 'NO', '''profile''::text') $$,
  'reports.target_kind is text, never null, profile by default'
);

-- ---- one report of each kind ----------------------------------------------
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason, target_kind, content_body)
     values (tests.rid(1), tests.mid(1), tests.uid('a'), 'spam', 'post', 'forged') $$,
  'B reports A''s quote message, sending a forged kind and body'
);
select results_eq(
  $$ select target_kind, content_body, content_author, content_note, content_verified from tests.own_reports() where id = tests.rid(1) $$,
  $$ values ('message'::text, 'Alpha'::text, 'Ann'::text, 'for you'::text, true) $$,
  'a message report: the server sets the kind and copies the quote and note'
);
select lives_ok(
  $$ insert into public.reports (id, post_id, reported_user_id, reason)
     values (tests.rid(2), tests.pid(1), tests.uid('a'), 'harassment') $$,
  'B reports A''s post'
);
select results_eq(
  $$ select target_kind, content_body, content_note, content_verified from tests.own_reports() where id = tests.rid(2) $$,
  $$ values ('post'::text, 'Alpha'::text, 'First'::text, true) $$,
  'a post report copies the snapshot and the caption'
);
select lives_ok(
  $$ insert into public.reports (id, playlist_id, reported_user_id, reason)
     values (tests.rid(3), tests.plid(1), tests.uid('a'), 'inappropriate') $$,
  'B reports A''s playlist'
);
select results_eq(
  $$ select target_kind, content_body, content_note, content_verified from tests.own_reports() where id = tests.rid(3) $$,
  $$ values ('playlist'::text, null::text, 'Morning'::text, true) $$,
  'a playlist report copies the title'
);
select lives_ok(
  $$ insert into public.reports (id, starter_quote_id, reason, details)
     values (tests.rid(4), 1, 'wrong_wording', 'One word is wrong') $$,
  'B reports a Quoted Catalog quote''s wording'
);
select results_eq(
  $$ select r.target_kind, r.reported_user_id, r.content_body = s.body, r.content_verified
     from tests.own_reports() r join public.starter_quotes s on s.id = r.starter_quote_id where r.id = tests.rid(4) $$,
  $$ values ('catalog_quote'::text, null::uuid, true, true) $$,
  'a catalog report names nobody and copies the catalog row'
);
select lives_ok(
  $$ insert into public.reports (id, reported_user_id, reason, content_body, target_kind, content_verified)
     values (tests.rid(5), tests.uid('a'), 'other', 'What B saw', 'post', true) $$,
  'B reports A''s profile with what B saw'
);
select results_eq(
  $$ select target_kind, content_body, content_verified from tests.own_reports() where id = tests.rid(5) $$,
  $$ values ('profile'::text, 'What B saw'::text, false) $$,
  'a profile report keeps the reporter''s account, unverified, whatever kind the client sent'
);
select throws_ok(
  $$ select content_body, content_note, content_verified from public.reports where id = tests.rid(1) $$,
  '42501', null,
  'B cannot read the server''s copy back (it may come from a message B can no longer read)'
);
select throws_ok(
  $$ select reported_username from public.reports where id = tests.rid(5) $$,
  '42501', null,
  'nor the username the server recorded with a profile report'
);
select throws_ok(
  $$ select reviewed_at from public.reports where id = tests.rid(5) $$,
  '42501', null,
  'nor whether the founder has reviewed it'
);
select results_eq(
  $$ select target_kind, reason, details, starter_quote_id from public.reports where id = tests.rid(4) $$,
  $$ values ('catalog_quote'::text, 'wrong_wording'::text, 'One word is wrong'::text, 1::smallint) $$,
  'B reads what B filed, and its kind'
);

-- ---- the target must be one the reporter can see, naming its author --------
select throws_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(2), tests.uid('c'), 'spam') $$,
  '42501', null,
  'a post report must name the post''s author'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(2), tests.uid('b'), 'spam') $$,
  '42501', null,
  'a message report must name its sender'
);
select throws_ok(
  $$ insert into public.reports (playlist_id, reported_user_id, reason) values (tests.plid(3), tests.uid('a'), 'spam') $$,
  '42501', null,
  'B cannot report A''s Only me playlist, which B cannot see'
);

select tests.authenticate_as('d');
select results_eq(
  $$ select tests.error_of(s) from unnest(array[
       $s$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(2), tests.uid('a'), 'spam') $s$,
       $s$ insert into public.reports (playlist_id, reported_user_id, reason) values (tests.plid(2), tests.uid('a'), 'spam') $s$,
       $s$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(2), tests.uid('a'), 'spam') $s$
     ]) s $$,
  $$ values ('42501 | new row violates row-level security policy for table "reports"'::text),
            ('42501 | new row violates row-level security policy for table "reports"'),
            ('42501 | new row violates row-level security policy for table "reports"') $$,
  'stranger D cannot report A''s friends-only post or playlist, or a message D is not part of'
);

-- ---- the auto-hold --------------------------------------------------------
select tests.authenticate_as('b');
select is(tests.post_held(1), null, 'one reporter does not hold a post');
select throws_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(1), tests.uid('a'), 'other') $$,
  '42501', null,
  'B cannot report the same post twice (it disappeared for B)'
);
select is(tests.post_held(1), null, 'so one reporter (who also reported the profile) still does not hold it');

select tests.authenticate_as('c');
select lives_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(1), tests.uid('a'), 'spam') $$,
  'C reports the same post'
);
select is(tests.post_held(1), now(), 'two different reporters hold the post');

select tests.authenticate_as('e');
select is_empty($$ select 1 from public.posts where id = tests.pid(1) $$,
  'a held post is hidden from friends who did not report it');
select throws_ok($$ select public.save_from_post(tests.pid(1)) $$, '42501', 'This post is not available.',
  'and cannot be saved');
select throws_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(1), tests.uid('a'), 'spam') $$,
  '42501', null,
  'nor reported again: it is already held for review'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select held_at is not null from public.posts where id = tests.pid(1) $$,
  $$ values (true) $$,
  'its author still sees it, and that it is held'
);

select tests.authenticate_as('c');
select lives_ok(
  $$ insert into public.reports (playlist_id, reported_user_id, reason) values (tests.plid(1), tests.uid('a'), 'spam') $$,
  'C reports the playlist B reported'
);
select is(tests.playlist_held(1), now(), 'two different reporters hold the playlist');
select tests.authenticate_as('e');
select is(public.playlist_view(tests.plid(1)), null, 'a held playlist is hidden from friends');
select tests.authenticate_as('a');
select isnt(public.playlist_view(tests.plid(1)), null, 'but not from its owner');
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(1)) $$),
  '42501 | This playlist is hidden while it is reviewed. | Contact support.',
  'and its owner cannot send it while it is held'
);

-- Only different people count, never the owner: through the secret key, A
-- reports A's own post 2 (naming B, so it is a different row), and E reports
-- it twice (naming A, then B). That is one reporter besides the owner.
select tests.clear_authentication();
set local role service_role;
select lives_ok(
  $$ insert into public.reports (reporter_id, post_id, reported_user_id, reason) values
       (tests.uid('a'), tests.pid(2), tests.uid('b'), 'other'),
       (tests.uid('e'), tests.pid(2), tests.uid('a'), 'spam'),
       (tests.uid('e'), tests.pid(2), tests.uid('b'), 'other') $$,
  'the secret key files a report by A on A''s own post and two by E'
);
select is(tests.post_held(2), null, 'the owner''s own report and one person''s two reports do not hold it');

-- ---- suspend_user -----------------------------------------------------------
select tests.clear_authentication();
select results_eq(
  $$ select p.oid::regprocedure::text, has_function_privilege('anon', p.oid, 'execute'),
            has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('service_role', p.oid, 'execute'),
            p.prosecdef
     from pg_proc p where p.pronamespace = 'private'::regnamespace and p.proname in ('suspend_user', 'unsuspend_user')
     order by 1 $$,
  $$ values ('private.suspend_user(uuid,text)', false, false, false, true),
            ('private.unsuspend_user(uuid)', false, false, false, true) $$,
  'suspend_user and unsuspend_user are for the founder only: no API role may run them'
);
select tests.authenticate_as('b');
select throws_ok($$ select * from private.suspend_user(tests.uid('a'), 'B says so') $$, '42501', null,
  'a signed-in user cannot suspend anyone');
select tests.clear_authentication();
set local role service_role;
select throws_ok($$ select * from private.suspend_user(tests.uid('a'), 'Secret key') $$, '42501', null,
  'nor can the secret key');
select tests.clear_authentication();

select results_eq(
  $$ select * from private.suspend_user(tests.uid('a'), 'Spam') $$,
  $$ values (3, 2) $$,
  'the founder suspends A: posts 2 to 4 and the two playlists not held yet are held'
);
select results_eq(
  $$ select (select count(*)::int from public.posts where author_id = tests.uid('a') and held_at is null),
            (select count(*)::int from public.playlists where owner_id = tests.uid('a') and held_at is null),
            (select reason from private.suspensions where user_id = tests.uid('a')) $$,
  $$ values (0, 0, 'Spam'::text) $$,
  'every post and playlist of A''s is held, Only me included, and the suspension is recorded'
);
select results_eq(
  $$ select distinct reported_user_suspended from private.reports_to_review where reported_user_id = tests.uid('a') $$,
  $$ values (true) $$,
  'the queue shows that A is suspended'
);

select tests.authenticate_as('a');
select results_eq(
  $$ select is_suspended, can_publish from public.my_account() $$,
  $$ values (true, false) $$,
  'A''s own account says suspended'
);
select results_eq(
  $$ select tests.error_of(s) from unnest(array[
       $s$ insert into public.posts (source_quote_id) values (tests.qid(1)) $s$,
       $s$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', 'Hi') $s$,
       $s$ select public.open_conversation(tests.uid('c')) $s$,
       $s$ insert into public.friendships (addressee_id) values (tests.uid('d')) $s$,
       $s$ update public.friendships set status = 'accepted' where requester_id = tests.uid('f') $s$,
       $s$ insert into public.playlists (title) values ('New list') $s$,
       $s$ update public.playlists set visibility = 'friends' where id = tests.plid(3) $s$,
       $s$ insert into public.playlist_items (playlist_id, quote_id, position) values (tests.plid(2), tests.qid(2), 0) $s$
     ]) s $$,
  $$ select '42501 | This account is suspended. | Contact support.'::text from generate_series(1, 8) $$,
  'every social write of a suspended account is refused: post, message, conversation, request, accept, playlists and items'
);
select results_eq(
  $$ select count(*)::int from public.posts where author_id = tests.uid('a') $$,
  $$ values (4) $$,
  'A still reads all of their own posts, held as they are'
);
select tests.authenticate_as('b');
select results_eq(
  $$ select (select count(*)::int from public.posts where author_id = tests.uid('a')),
            public.playlist_view(tests.plid(2)) is null,
            jsonb_array_length(public.profile_view('alice') -> 'posts'),
            jsonb_array_length(public.profile_view('alice') -> 'playlists') $$,
  $$ values (0, true, 0, 0) $$,
  'friends see none of A''s posts or playlists, in the tables, playlist_view or profile_view'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select tests.error_of(s) from unnest(array[
       $s$ insert into public.quotes (id, body) values (tests.qid(3), 'Still my library') $s$,
       $s$ delete from public.posts where id = tests.pid(4) $s$,
       $s$ update public.playlists set visibility = 'private' where id = tests.plid(2) $s$
     ]) s $$,
  $$ values ('no error'::text), ('no error'), ('no error') $$,
  'a suspended account still keeps its Library, deletes its posts and narrows its playlists'
);

select tests.clear_authentication();
select results_eq(
  $$ select * from private.suspend_user(tests.uid('a'), 'Spam, again') $$,
  $$ values (0, 0) $$,
  'suspending again holds nothing new'
);
select results_eq(
  $$ select count(*)::int, min(reason) from private.suspensions where user_id = tests.uid('a') $$,
  $$ values (1, 'Spam, again'::text) $$,
  'and replaces the reason in the one suspension row'
);
select throws_ok($$ select * from private.suspend_user('99999999-9999-4999-8999-999999999999', 'Nobody') $$,
  '23503', null, 'suspending an unknown account fails');
select throws_ok($$ select * from private.suspend_user(tests.uid('b'), ' ') $$,
  '23514', null, 'a suspension needs a reason');

select is(private.unsuspend_user(tests.uid('a')), true, 'the founder ends A''s suspension');
select is(private.unsuspend_user(tests.uid('a')), false, 'ending it again finds nothing');
select results_eq(
  $$ select (select count(*)::int from public.posts where author_id = tests.uid('a') and held_at is null),
            (select count(*)::int from public.playlists where owner_id = tests.uid('a') and held_at is null) $$,
  $$ values (0, 0) $$,
  'held posts and playlists stay held until the founder clears them'
);
select tests.authenticate_as('a');
select lives_ok($$ insert into public.posts (id, source_quote_id) values (tests.pid(5), tests.qid(2)) $$,
  'A can post again');
select is(tests.post_held(5), null, 'and the new post is not held');

-- ---- target_kind outlives the target ---------------------------------------
select lives_ok($$ delete from public.messages where id = tests.mid(1) $$, 'A unsends the message B reported');
select tests.clear_authentication();
select results_eq(
  $$ select target_kind, message_id from public.reports where id = tests.rid(1) $$,
  $$ values ('message'::text, null::uuid) $$,
  'the report loses message_id and keeps its kind'
);
update public.reports set target_kind = 'post' where id = tests.rid(5);
select is((select target_kind from public.reports where id = tests.rid(5)), 'profile',
  'target_kind cannot be rewritten, even by the server');
select throws_ok(
  $$ update public.reports set post_id = tests.pid(3), playlist_id = tests.plid(3) where id = tests.rid(5) $$,
  '23514', null,
  'a report still names at most one target'
);

-- ---- the moderation queue -----------------------------------------------------
select results_eq(
  $$ select target_kind, target_deleted, content_note, target_held_at is not null, target_reporters::int
     from private.reports_to_review where reporter_id = tests.uid('b')
     order by target_kind, post_id $$,
  $$ values
       ('catalog_quote'::text, false, null::text, false, 1),
       ('message', true, 'for you', false, null::int),
       ('playlist', false, 'Morning', true, 2),
       ('post', false, 'First', true, 2),
       ('profile', false, null, false, null) $$,
  'the queue lists every kind: what was reported, whether it is gone or held, how many people reported it, and the copy'
);
select results_eq(
  $$ select distinct target_reporters::int from private.reports_to_review where post_id = tests.pid(2) $$,
  $$ values (2) $$,
  'target_reporters counts people, not rows: A and E reported post 2 in three reports'
);
select results_eq(
  $$ select reported_username, reporter_username, reported_user_suspended, reports_against_user::int
     from private.reports_to_review where id = tests.rid(2) $$,
  $$ values ('alice'::text, 'bob'::text, false, 7) $$,
  'with the people involved: after unsuspending, A is no longer marked suspended'
);
update public.reports set reviewed_at = now() where id = tests.rid(2);
select is_empty($$ select 1 from private.reports_to_review where id = tests.rid(2) $$, 'a reviewed report leaves the queue');

select * from finish();
rollback;
