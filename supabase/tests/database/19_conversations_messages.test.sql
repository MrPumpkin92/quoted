-- Conversations and messages (supabase/migrations/20261029090300_conversations_and_messages.sql).
-- The founder's requirement: for every message and conversation endpoint (the
-- three tables, open_conversation, inbox_conversations, save_from_message and
-- reports), a non-participant can neither read nor send. C is A's friend, not
-- B's: friendship with one member is not enough. Also: each member reads only
-- their own member row, whose times only move forward (cleared_at takes the
-- server clock; last_read_at, since 20261029090600, the client's time of the
-- newest message it showed, never later than the server clock); the server builds every snapshot (forged columns are refused); a
-- quote from your own quote or the catalog, text refused (QR004) when texts
-- are off while quotes and playlists pass; the word filter (QR003) on text,
-- notes, playlist titles and unverified snapshots; terms and suspension;
-- unfriend closes the conversation and a new friendship reopens it; a block
-- hides it from the blocked person, keeps it read-only for the blocker,
-- deletes nothing, and unblocking does not reopen it; unsend by the sender
-- only, gone for both, a tombstone kept; cleared_at for one member only; a
-- reported message disappears for its reporter; save_from_message keeps the
-- creator; 300 messages a day; the secret key; the insert policy's rules each
-- on their own (with the snapshot trigger disabled); account deletion removes
-- the conversation for both.
-- Review fixes: a verified quote is sent with no creator or edited-from; an
-- unsend moves last_message_at back; a blocked sender cannot erase messages
-- even with an unfiltered DELETE; unsending makes no room under the 300-a-day
-- limit; a reporter never reads the server's copy back (column grants); a
-- blocked person who blocks back still cannot read the blocker's profile.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(193);

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
    when 'i' then '33333333-3333-4333-8333-333333333333'
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.mid(n int) returns uuid language sql immutable as $$
  select ('3e000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- The conversation between A and someone, read with definer rights.
create function tests.cid(who text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid('a'), tests.uid(who)) and c.user_b = greatest(tests.uid('a'), tests.uid(who))
$$;

-- A quote's provenance as origin|creator|edited from ('-' for none).
create function tests.prov(n int) returns text language sql stable security definer as $$
  select origin || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
  from public.quotes where id = tests.qid(n)
$$;

-- The caller's own reports with every column, read with definer rights:
-- reporters may not select the server's copy, so the tests read it as the
-- founder does.
create function tests.own_reports() returns setof public.reports language sql stable security definer as $$
  select * from public.reports where reporter_id = auth.uid()
$$;

-- How many messages a conversation holds, read with definer rights.
create function tests.messages_in(c uuid) returns integer language sql volatile security definer as $$
  select count(*)::int from public.messages where conversation_id = c
$$;

-- How many messages of a conversation a statement deletes when the caller runs
-- it; the statement is then undone (its subtransaction is rolled back).
create function tests.deleted_by(statement text, c uuid) returns integer language plpgsql as $$
declare
  v_before integer := tests.messages_in(c);
  v_after integer;
begin
  begin
    execute statement;
    v_after := tests.messages_in(c);
    raise exception 'undo' using errcode = 'P0001';
  exception when sqlstate 'P0001' then
    null;
  end;
  return v_before - v_after;
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

-- A (alice) is friends with B, C, E, F, G, H and I; A asked D (pending). C is
-- not B's friend. E turned texts off. F has not accepted the terms. G is
-- suspended. H and I are for the block and unfriend stories.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice A'), (tests.uid('b'), 'bob', 'Bob B'), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('f'), 'fay', null),
  (tests.uid('g'), 'gus', null), (tests.uid('h'), 'hal', null), (tests.uid('i'), 'ivy', null);
update public.profiles set accepts_text_messages = false where id = tests.uid('e');
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'g', 'h', 'i']) w;
insert into private.suspensions (user_id, reason) values (tests.uid('g'), 'test');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('c'), 'accepted'),
  (tests.uid('a'), tests.uid('e'), 'accepted'), (tests.uid('a'), tests.uid('f'), 'accepted'),
  (tests.uid('a'), tests.uid('g'), 'accepted'), (tests.uid('h'), tests.uid('a'), 'accepted'),
  (tests.uid('a'), tests.uid('i'), 'accepted'), (tests.uid('a'), tests.uid('d'), 'pending');
-- 'fearless' is in catalog quote 3 ("Beware; for I am fearless, ...").
insert into private.blocked_terms (term) values ('darn'), ('heck no'), ('fearless');

-- A's quotes: 1 typed by A, 2 A's copy of B's words, 3 A's words with a
-- blocked term (the private Library is never filtered), 4 A's copy of catalog
-- quote 3 (verified). B, C and H have quotes of their own.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(3), 'Darn it all', null);
select id from public.add_catalog_quotes(array[3]::smallint[], array[tests.qid(4)]);
select tests.authenticate_as('b');
insert into public.quotes (id, body, author) values (tests.qid(10), 'Bob''s line', 'Bo');
select tests.authenticate_as('c');
insert into public.quotes (id, body) values (tests.qid(20), 'Cara''s words');
select tests.authenticate_as('h');
insert into public.quotes (id, body) values (tests.qid(30), 'Hal''s words');
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username) values
  (tests.qid(2), tests.uid('a'), 'Bob''s line', 'Bo', 'shared', tests.uid('b'), 'bob');
-- Playlists: A's Morning (friends), Secret (private), a title with a blocked
-- term (set by the server), a held one; B's and C's own.
insert into public.playlists (id, owner_id, title, visibility, held_at) values
  (tests.plid(1), tests.uid('a'), 'Morning', 'friends', null),
  (tests.plid(2), tests.uid('a'), 'Secret', 'private', null),
  (tests.plid(3), tests.uid('a'), 'Heck no list', 'friends', null),
  (tests.plid(4), tests.uid('a'), 'Held list', 'friends', now()),
  (tests.plid(10), tests.uid('b'), 'Bob list', 'friends', null),
  (tests.plid(20), tests.uid('c'), 'Cara list', 'friends', null);

-- ---- open_conversation ------------------------------------------------------
select tests.authenticate_as('a');

select results_eq(
  $$ select user_a, user_b, closed_at, last_message_at from public.open_conversation(tests.uid('b')) $$,
  $$ values (least(tests.uid('a'), tests.uid('b')), greatest(tests.uid('a'), tests.uid('b')), null::timestamptz, null::timestamptz) $$,
  'A opens a conversation with friend B: one row for the ordered pair, open, no messages yet'
);
select is(
  (select id from public.open_conversation(tests.uid('b'))), tests.cid('b'),
  'opening it again returns the same conversation'
);
select tests.clear_authentication();
select results_eq(
  $$ select user_id, last_read_at, cleared_at from public.conversation_members
     where conversation_id = tests.cid('b') order by user_id $$,
  $$ values (tests.uid('a'), null::timestamptz, null::timestamptz), (tests.uid('b'), null, null) $$,
  'both members have a row'
);
select tests.authenticate_as('b');
select is(
  (select id from public.open_conversation(tests.uid('a'))), tests.cid('b'),
  'B opening it from the other side gets the same conversation'
);
select tests.authenticate_as('a');
select o.id from unnest(array['c', 'e', 'f', 'g', 'h', 'i']) w cross join lateral public.open_conversation(tests.uid(w)) o;

select is(
  tests.error_of($$ select public.open_conversation(tests.uid('d')) $$),
  '42501 | This person is not available. | You can send messages only to friends.',
  'open_conversation refuses a pending request'
);
select is(
  tests.error_of($$ select public.open_conversation(tests.uid('a')) $$),
  '42501 | This person is not available. | You can send messages only to friends.',
  'open_conversation refuses yourself'
);
select is(
  tests.error_of($$ select public.open_conversation('99999999-9999-4999-8999-999999999999') $$),
  '42501 | This person is not available. | You can send messages only to friends.',
  'open_conversation refuses an unknown id the same way'
);
select is(
  tests.error_of($$ select public.open_conversation(null) $$),
  '42501 | This person is not available. | You can send messages only to friends.',
  'open_conversation refuses null'
);
select tests.authenticate_as('c');
select is(
  tests.error_of($$ select public.open_conversation(tests.uid('b')) $$),
  '42501 | This person is not available. | You can send messages only to friends.',
  'C (A''s friend, not B''s) cannot open a conversation with B'
);
select tests.authenticate_as('f');
select throws_ok(
  $$ select public.open_conversation(tests.uid('a')) $$,
  '42501', 'Accept the Terms of use first.',
  'opening a conversation needs accepted terms (the friend would see it)'
);
select tests.authenticate_as('g');
select throws_ok(
  $$ select public.open_conversation(tests.uid('a')) $$,
  '42501', 'This account is suspended.',
  'a suspended account cannot open a conversation'
);

-- ---- sending: column grants and the server-built snapshot ---------------------
select tests.authenticate_as('a');

select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, text) values (tests.mid(1), tests.cid('b'), 'text', 'Hello Bob')
     returning sender_id, kind, text, note, body, created_at = now() $$,
  $$ values (tests.uid('a'), 'text'::text, 'Hello Bob'::text, null::text, null::text, true) $$,
  'A texts B: the sender is A and the time is the server''s'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id, note)
     values (tests.mid(2), tests.cid('b'), 'quote', tests.qid(1), 'for you')
     returning body, author, source, body_format, note, creator_username, edited_from_username, verified_starter_id $$,
  $$ values ('Alpha'::text, 'Ann'::text, null::text, '[]'::jsonb, 'for you'::text, 'alice'::text, null::text, null::smallint) $$,
  'A sends one of A''s quotes: the server copies its wording and creator'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id)
     values (tests.mid(3), tests.cid('b'), 'quote', tests.qid(2))
     returning body, creator_username $$,
  $$ values ('Bob''s line'::text, 'bob'::text) $$,
  'A sends A''s copy of B''s words: the creator stays B, not the sender'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, starter_quote_id)
     values (tests.mid(4), tests.cid('b'), 'quote', 1)
     returning starter_quote_id, body, author, source, creator_id, verified_starter_id $$,
  $$ select 1::smallint, s.body, s.author, s.source, null::uuid, 1::smallint from public.starter_quotes s where s.id = 1 $$,
  'a catalog quote is copied from the catalog: verified, with no creator'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, playlist_id)
     values (tests.mid(5), tests.cid('b'), 'playlist', tests.plid(1))
     returning playlist_id, playlist_title, body $$,
  $$ values (tests.plid(1), 'Morning'::text, null::text) $$,
  'A sends A''s Friends playlist: the server copies its title'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id, body) values (tests.cid('b'), 'quote', tests.qid(1), 'Forged words') $$,
  '42501', 'permission denied for table messages',
  'a client cannot send the body'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id, creator_id, creator_username)
     values (tests.cid('b'), 'quote', tests.qid(1), tests.uid('b'), 'bob') $$,
  '42501', 'permission denied for table messages',
  'nor the creator'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id, verified_starter_id) values (tests.cid('b'), 'quote', tests.qid(1), 1) $$,
  '42501', 'permission denied for table messages',
  'nor the verified catalog id'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id, playlist_title) values (tests.cid('b'), 'playlist', tests.plid(1), 'Renamed') $$,
  '42501', 'permission denied for table messages',
  'nor the playlist title'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, text) values (tests.cid('b'), tests.uid('b'), 'text', 'As Bob') $$,
  '42501', 'permission denied for table messages',
  'nor the sender'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text, created_at) values (tests.cid('b'), 'text', 'Pinned?', '2099-01-01') $$,
  '42501', 'permission denied for table messages',
  'nor created_at'
);
select throws_ok(
  $$ select source_quote_id from public.messages $$,
  '42501', 'permission denied for table messages',
  'not even the sender can read source_quote_id'
);
select throws_ok(
  $$ select * from public.messages $$,
  '42501', 'permission denied for table messages',
  'so select * is refused: clients list the columns they read'
);
select throws_ok(
  $$ update public.messages set text = 'Edited' where id = tests.mid(1) $$,
  '42501', 'permission denied for table messages',
  'messages cannot be edited'
);

select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, source_quote_id) values (tests.cid('b'), 'quote', tests.qid(10)) $$),
  '42501 | You can send only quotes from your Library or the Quoted Catalog.',
  'B''s quote id is refused'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, source_quote_id) values (tests.cid('b'), 'quote', '00000000-0000-4000-8000-000000009999') $$),
  '42501 | You can send only quotes from your Library or the Quoted Catalog.',
  'an unknown quote id fails exactly the same way'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind) values (tests.cid('b'), 'quote') $$,
  '23514', 'A quote message holds exactly one quote: one of yours or one from the Quoted Catalog.',
  'a quote message needs a source'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id, starter_quote_id) values (tests.cid('b'), 'quote', tests.qid(1), 1) $$,
  '23514', null,
  'and only one'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id) values (tests.cid('b'), 'quote', 32000) $$,
  '23503', null,
  'an unknown catalog quote is refused'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(2)) $$,
  '42501', 'You can send only your own playlists that friends can see.',
  'an Only me playlist cannot be sent'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(10)) $$,
  '42501', 'You can send only your own playlists that friends can see.',
  'nor someone else''s'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(4)) $$,
  '42501', 'This playlist is hidden while it is reviewed.',
  'nor a held one'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'photo', 'x') $$,
  '23514', null,
  'the kind is text, quote or playlist'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text, note) values (tests.cid('b'), 'text', 'Hi', 'note') $$,
  '23514', null,
  'a text message carries no note'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', repeat('x', 1001)) $$,
  '23514', null,
  'text is at most 1000 characters'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', E' \n ') $$,
  '23514', null,
  'text cannot be blank'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id, note) values (tests.cid('b'), 'quote', 1, repeat('n', 281)) $$,
  '23514', null,
  'a note is at most 280 characters'
);

-- ---- the word filter (QR003) --------------------------------------------------
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', 'Well, darn.') $$,
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'a blocked term in text is refused'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id, note) values (tests.cid('b'), 'quote', 1, 'Heck no!') $$,
  'QR003', null,
  'in a note'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id) values (tests.cid('b'), 'quote', tests.qid(3)) $$,
  'QR003', null,
  'in an unverified snapshot (the Library copy itself was never filtered)'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(3)) $$,
  'QR003', null,
  'in a playlist title'
);
select lives_ok(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(6), tests.cid('b'), 'quote', tests.qid(4)) $$,
  'a verified catalog quote passes even when its wording holds a blocked term'
);

-- Give A's messages to B distinct times, oldest first: message n at n minutes
-- past now() - 100 minutes.
select tests.clear_authentication();
update public.messages set created_at = now() - make_interval(mins => 100 - right(id::text, 2)::int)
 where conversation_id = tests.cid('b');

-- ---- B, the other member ------------------------------------------------------
select tests.authenticate_as('b');

select results_eq(
  $$ select id, kind, coalesce(text, body, playlist_title), creator_username
     from public.messages where conversation_id = tests.cid('b') order by created_at $$,
  $$ values (tests.mid(1), 'text'::text, 'Hello Bob'::text, null::text),
            (tests.mid(2), 'quote', 'Alpha', 'alice'),
            (tests.mid(3), 'quote', 'Bob''s line', 'bob'),
            (tests.mid(4), 'quote', (select body from public.starter_quotes where id = 1), null),
            (tests.mid(5), 'playlist', 'Morning', null),
            (tests.mid(6), 'quote', (select body from public.starter_quotes where id = 3), null) $$,
  'B reads every message A sent, oldest first'
);
select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('a') $$,
  'receiving A''s quotes does not expose A''s Library'
);
select results_eq(
  $$ select user_id from public.conversation_members where conversation_id = tests.cid('b') $$,
  $$ values (tests.uid('b')) $$,
  'B reads only B''s own member row'
);
select results_eq(
  $$ select other_id, other_username, other_display_name, other_accepts_text_messages, is_closed,
            last_message_kind, last_message_sender_id, unread_count
     from public.inbox_conversations() where conversation_id = tests.cid('b') $$,
  $$ values (tests.uid('a'), 'alice'::text, 'Alice A'::text, true, false, 'quote'::text, tests.uid('a'), 6) $$,
  'B''s Inbox shows A''s public profile, the latest message and six unread'
);
select is(
  (select last_message_preview from public.inbox_conversations() where conversation_id = tests.cid('b')),
  (select left(body, 140) from public.starter_quotes where id = 3),
  'the preview is the first 140 characters of the latest message'
);
select results_eq(
  $$ update public.conversation_members set last_read_at = (select created_at from public.messages where id = tests.mid(3))
     where conversation_id = tests.cid('b')
     returning last_read_at = now() - interval '97 minutes' $$,
  $$ values (true) $$,
  'B marks it read up to message 3, the newest B has shown: the server keeps that time'
);
select is(
  (select unread_count from public.inbox_conversations() where conversation_id = tests.cid('b')),
  3,
  'so the three messages sent after it, which B has not shown, stay unread'
);
select is(
  (select last_read_at from public.inbox_conversations() where conversation_id = tests.cid('b')),
  (select created_at from public.messages where id = tests.mid(3)),
  'and the Inbox row carries B''s own read mark'
);
select results_eq(
  $$ update public.conversation_members set last_read_at = '2999-01-01' where conversation_id = tests.cid('b')
     returning last_read_at = now() $$,
  $$ values (true) $$,
  'a time after the server clock becomes the server clock'
);
select is(
  (select unread_count from public.inbox_conversations() where conversation_id = tests.cid('b')),
  0,
  'nothing is unread after that'
);

-- ---- C, a non-participant: every endpoint ------------------------------------
-- C is A's friend with a conversation of their own with A; C and B are
-- strangers. E (in A's conversation with E) does not accept texts, so a
-- refusal that mentioned it would leak a setting of someone C cannot reach.
select tests.authenticate_as('c');

select is_empty(
  $$ select 1 from public.conversations where id = tests.cid('b') $$,
  'C cannot read A and B''s conversation'
);
select results_eq(
  $$ select id from public.conversations $$,
  $$ values (tests.cid('c')) $$,
  'C reads only C''s own conversation'
);
select is_empty(
  $$ select 1 from public.conversation_members where conversation_id = tests.cid('b') $$,
  'C cannot read either member row'
);
select is_empty(
  $$ select 1 from public.messages where conversation_id = tests.cid('b') or id = tests.mid(1) $$,
  'C cannot read any message in it'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', 'Hi from C') $$),
  '42501 | This conversation is not available.',
  'C cannot send it a text'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, source_quote_id) values (tests.cid('b'), 'quote', tests.qid(20)) $$),
  '42501 | This conversation is not available.',
  'nor one of C''s quotes'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, starter_quote_id) values (tests.cid('b'), 'quote', 1) $$),
  '42501 | This conversation is not available.',
  'nor a catalog quote'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('b'), 'playlist', tests.plid(20)) $$),
  '42501 | This conversation is not available.',
  'nor one of C''s playlists'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, text) values ('99999999-9999-4999-8999-999999999999', 'text', 'Hi') $$),
  '42501 | This conversation is not available.',
  'the answer is the same as for a conversation that does not exist'
);
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, text) values (tests.cid('e'), 'text', 'Hi Eve') $$),
  '42501 | This conversation is not available.',
  'a text into A and E''s conversation fails the same way, never with E''s "quotes only" (QR004)'
);
select is_empty(
  $$ update public.conversation_members set last_read_at = now(), cleared_at = now()
     where conversation_id = tests.cid('b') returning 1 $$,
  'C cannot update either member row'
);
select is_empty(
  $$ delete from public.messages where conversation_id = tests.cid('b') or id = tests.mid(1) returning 1 $$,
  'C cannot delete (unsend) any of its messages'
);
select throws_ok(
  $$ update public.messages set text = 'Edited by C' where id = tests.mid(1) $$,
  '42501', 'permission denied for table messages',
  'nor update one'
);
select throws_ok(
  $$ insert into public.conversation_members (conversation_id, user_id) values (tests.cid('b'), tests.uid('c')) $$,
  '42501', 'permission denied for table conversation_members',
  'C cannot add themselves as a member'
);
select throws_ok(
  $$ delete from public.conversation_members where conversation_id = tests.cid('b') $$,
  '42501', 'permission denied for table conversation_members',
  'nor delete member rows'
);
select throws_ok(
  $$ insert into public.conversations (user_a, user_b) values (tests.uid('b'), tests.uid('c')) $$,
  '42501', 'permission denied for table conversations',
  'C cannot create a conversation directly'
);
select throws_ok(
  $$ update public.conversations set closed_at = null where id = tests.cid('b') $$,
  '42501', 'permission denied for table conversations',
  'nor update one'
);
select throws_ok(
  $$ delete from public.conversations where id = tests.cid('b') $$,
  '42501', 'permission denied for table conversations',
  'nor delete one'
);
select is(
  tests.error_of($$ select public.save_from_message(tests.mid(2)) $$),
  '42501 | This message is not available.',
  'save_from_message refuses C a quote message from A and B''s conversation'
);
select is(
  tests.error_of($$ select public.save_from_message('99999999-9999-4999-8999-999999999999') $$),
  '42501 | This message is not available.',
  'exactly as for a message that does not exist'
);
select results_eq(
  $$ select conversation_id, other_username from public.inbox_conversations() $$,
  $$ values (tests.cid('c'), 'alice'::text) $$,
  'C''s Inbox shows only C''s own conversation'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(2), tests.uid('a'), 'spam') $$,
  '42501', null,
  'C cannot report a message from A and B''s conversation'
);
select is_empty(
  $$ select 1 from public.profiles where id = tests.uid('b') $$,
  'C does not gain B''s profile'
);
select tests.authenticate_as('d');
select is_empty(
  $$ select 1 from public.conversations union all select 1 from public.conversation_members
     union all select 1 from public.messages $$,
  'D (with only a pending request from A) reads no conversation, member row or message at all'
);

-- ---- member rows: the server clock, forward only -------------------------------
select tests.authenticate_as('a');

select results_eq(
  $$ select user_id from public.conversation_members where conversation_id = tests.cid('c') $$,
  $$ values (tests.uid('a')) $$,
  'A reads only A''s own row in A and C''s conversation'
);
select results_eq(
  $$ update public.conversation_members set last_read_at = '1999-01-01', cleared_at = '1999-01-01'
     where conversation_id = tests.cid('c') returning last_read_at = '1999-01-01', cleared_at = now() $$,
  $$ values (true, true) $$,
  'last_read_at keeps the client''s time (the newest message it showed); cleared_at takes the server clock'
);
select results_eq(
  $$ update public.conversation_members set last_read_at = null, cleared_at = null
     where conversation_id = tests.cid('c') returning last_read_at = '1999-01-01', cleared_at = now() $$,
  $$ values (true, true) $$,
  'a client cannot clear them'
);
select results_eq(
  $$ update public.conversation_members set last_read_at = '1998-01-01'
     where conversation_id = tests.cid('c') returning last_read_at = '1999-01-01' $$,
  $$ values (true) $$,
  'nor move last_read_at back'
);
select tests.clear_authentication();
update public.conversation_members set last_read_at = '2099-01-01', cleared_at = '2099-01-01'
 where conversation_id = tests.cid('c') and user_id = tests.uid('a');
select tests.authenticate_as('a');
select results_eq(
  $$ update public.conversation_members set last_read_at = now(), cleared_at = now()
     where conversation_id = tests.cid('c') returning last_read_at, cleared_at $$,
  $$ values ('2099-01-01'::timestamptz, '2099-01-01'::timestamptz) $$,
  'they never move back'
);
select throws_ok(
  $$ update public.conversation_members set user_id = tests.uid('c') where conversation_id = tests.cid('c') $$,
  '42501', 'permission denied for table conversation_members',
  'a member can change only those two columns'
);
select is_empty(
  $$ update public.conversation_members set last_read_at = now() where conversation_id = tests.cid('b') and user_id = tests.uid('b') returning 1 $$,
  'A cannot touch B''s row'
);

-- ---- texts off (QR004) ----------------------------------------------------------
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, text) values (tests.cid('e'), 'text', 'Hi Eve') $$),
  'QR004 | This friend receives quotes only. | Send a quote or a playlist instead.',
  'a text to E, who turned texts off, is refused with QR004'
);
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id) values (tests.cid('e'), 'quote', tests.qid(1)) $$,
  'a quote still reaches E'
);
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, playlist_id) values (tests.cid('e'), 'playlist', tests.plid(1)) $$,
  'so does a playlist'
);
select tests.authenticate_as('e');
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('e'), 'text', 'Thanks!') $$,
  'E can still text A, who accepts texts'
);

-- A's own typed copy of catalog quote 1's exact wording is verified and credits A
-- in A's private Library; sent, it is "Quoted Catalog" and names nobody.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  select tests.qid(6), s.body, s.author, s.source from public.starter_quotes s where s.id = 1;
select is(tests.prov(6), 'manual|alice|-', 'A''s typed catalog wording credits A in A''s own Library');
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id)
     values (tests.mid(8), tests.cid('e'), 'quote', tests.qid(6))
     returning verified_starter_id, creator_id, creator_username, edited_from_id, edited_from_username $$,
  $$ values (1::smallint, null::uuid, null::text, null::uuid, null::text) $$,
  'a verified quote is sent with no creator or edited-from: whoever typed the catalog''s wording stays hidden'
);
select tests.authenticate_as('e');
select results_eq(
  $$ select creator_id, creator_username from public.save_from_message(tests.mid(8), tests.qid(7)) $$,
  $$ values (null::uuid, null::text) $$,
  'and E''s saved copy names nobody either'
);

-- ---- terms and suspension ----------------------------------------------------------
select tests.authenticate_as('f');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('f'), 'text', 'Hi') $$,
  '42501', 'Accept the Terms of use first.',
  'sending needs accepted terms'
);
select tests.authenticate_as('a');
insert into public.messages (id, conversation_id, kind, text) values (tests.mid(40), tests.cid('g'), 'text', 'Hi Gus');
select tests.authenticate_as('g');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('g'), 'text', 'Hi') $$,
  '42501', 'This account is suspended.',
  'a suspended account cannot send'
);
select results_eq(
  $$ select text from public.messages $$,
  $$ values ('Hi Gus'::text) $$,
  'but still reads what friends sent'
);

-- ---- unsend ------------------------------------------------------------------------
select tests.authenticate_as('b');
insert into public.messages (id, conversation_id, kind, text) values (tests.mid(30), tests.cid('b'), 'text', 'Oops, wrong chat');
-- As if B had sent it an hour after everything else.
select tests.clear_authentication();
update public.messages set created_at = now() + interval '1 hour' where id = tests.mid(30);
update public.conversations set last_message_at = now() + interval '1 hour' where id = tests.cid('b');
select tests.authenticate_as('a');
select is_empty(
  $$ delete from public.messages where id = tests.mid(30) returning 1 $$,
  'A cannot delete a message B sent'
);
select tests.authenticate_as('b');
select results_eq(
  $$ delete from public.messages where id = tests.mid(30) returning text $$,
  $$ values ('Oops, wrong chat'::text) $$,
  'B unsends it'
);
select is_empty($$ select 1 from public.messages where id = tests.mid(30) $$, 'it is gone for B');
select tests.authenticate_as('a');
select is_empty($$ select 1 from public.messages where id = tests.mid(30) $$, 'and for A');
select results_eq(
  $$ select last_message_at from public.conversations where id = tests.cid('b') $$,
  $$ select max(created_at) from public.messages where conversation_id = tests.cid('b') $$,
  'last_message_at moves back to the latest message left: an unsent message leaves no time behind'
);
select ok(
  (select last_message_at < now() + interval '1 hour' from public.conversations where id = tests.cid('b')),
  'so A cannot tell that B sent and unsent something, or when'
);
select tests.clear_authentication();
select results_eq(
  $$ select conversation_id, sender_id, payload->>'text', payload->>'kind', deleted_at = now()
     from private.message_tombstones where id = tests.mid(30) $$,
  $$ values (tests.cid('b'), tests.uid('b'), 'Oops, wrong chat'::text, 'text'::text, true) $$,
  'the server keeps a copy for moderation'
);
select tests.authenticate_as('b');
select throws_ok(
  $$ insert into public.messages (id, conversation_id, kind, text) values (tests.mid(30), tests.cid('b'), 'text', 'Different words') $$,
  '23505', 'duplicate key value violates unique constraint "messages_pkey"',
  'an unsent message''s id cannot be reused, so its copy is never overwritten'
);

-- ---- reports: a reported message disappears for its reporter ---------------------
select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason) values
       ('7e000000-0000-4000-8000-000000000001', tests.mid(2), tests.uid('a'), 'spam') $$,
  'B reports A''s quote message'
);
select results_eq(
  $$ select content_body, content_author, content_note, content_verified, reported_username
     from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values ('Alpha'::text, 'Ann'::text, 'for you'::text, true, 'alice'::text) $$,
  'the server copies the snapshot and the note'
);
select throws_ok(
  $$ select content_body, content_note from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'the copy is for the founder: B cannot read it back'
);
select results_eq(
  $$ select message_id, reason from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (tests.mid(2), 'spam'::text) $$,
  'B reads what B filed'
);
select is_empty($$ select 1 from public.messages where id = tests.mid(2) $$, 'the reported message disappears for B');
select throws_ok(
  $$ select public.save_from_message(tests.mid(2)) $$,
  '42501', 'This message is not available.',
  'and B can no longer save it'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(2), tests.uid('a'), 'other') $$,
  '23505', null,
  'a second report on the same message is a duplicate'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(3), tests.uid('c'), 'spam') $$,
  '42501', null,
  'the reported user must be the sender'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select count(*)::int from public.messages where id = tests.mid(2) $$,
  $$ values (1) $$,
  'A still reads it'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(2), tests.uid('a'), 'spam') $$,
  '42501', null,
  'A cannot report their own message'
);

-- ---- save_from_message ------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select owner_id, body, origin from public.save_from_message(tests.mid(3), tests.qid(50)) $$,
  $$ values (tests.uid('b'), 'Bob''s line'::text, 'shared'::text) $$,
  'B saves A''s message to B''s Library'
);
select is(tests.prov(50), 'shared|bob|-', 'it keeps its creator (B), not the sender (A)');
select results_eq(
  $$ select id, body from public.save_from_message(tests.mid(3), tests.qid(50)) $$,
  $$ values (tests.qid(50), 'Bob''s line'::text) $$,
  'a retry with the same id returns the saved quote'
);
select results_eq(
  $$ select verified_starter_id, creator_id from public.save_from_message(tests.mid(4), tests.qid(51)) $$,
  $$ values (1::smallint, null::uuid) $$,
  'a saved catalog quote is verified, with no creator'
);
select throws_ok(
  $$ select public.save_from_message(tests.mid(1)) $$,
  '42501', 'This message is not available.',
  'a text message is not a quote to save'
);
select throws_ok(
  $$ select public.save_from_message(tests.mid(5)) $$,
  '42501', 'This message is not available.',
  'nor is a playlist message'
);

-- ---- Delete Conversation (cleared_at) is for one member only ---------------------
select results_eq(
  $$ update public.conversation_members set cleared_at = '2000-01-01' where conversation_id = tests.cid('b')
     returning cleared_at = now() $$,
  $$ values (true) $$,
  'B deletes the conversation for B'
);
select is_empty(
  $$ select 1 from public.messages where conversation_id = tests.cid('b') $$,
  'B no longer reads the messages sent before that'
);
select is_empty(
  $$ select 1 from public.inbox_conversations() where conversation_id = tests.cid('b') $$,
  'and the conversation leaves B''s Inbox'
);
select throws_ok(
  $$ select public.save_from_message(tests.mid(6)) $$,
  '42501', 'This message is not available.',
  'a cleared message cannot be saved'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select count(*)::int from public.messages where conversation_id = tests.cid('b') $$,
  $$ values (6) $$,
  'A still reads all six'
);
-- Time passes: B cleared a second ago, and A sends something new.
select tests.clear_authentication();
update public.conversation_members set cleared_at = now() - interval '1 second', last_read_at = now() - interval '1 second'
 where conversation_id = tests.cid('b') and user_id = tests.uid('b');
select tests.authenticate_as('a');
insert into public.messages (id, conversation_id, kind, text) values (tests.mid(7), tests.cid('b'), 'text', 'Still there?');
select tests.authenticate_as('b');
select results_eq(
  $$ select id from public.messages where conversation_id = tests.cid('b') $$,
  $$ values (tests.mid(7)) $$,
  'B reads only the new message'
);
select results_eq(
  $$ select last_message_preview, unread_count from public.inbox_conversations() where conversation_id = tests.cid('b') $$,
  $$ values ('Still there?'::text, 1) $$,
  'and the conversation is back in B''s Inbox with one unread'
);

-- ---- unfriend closes the conversation; a new friendship reopens it -------------
select tests.authenticate_as('a');
insert into public.messages (id, conversation_id, kind, text) values (tests.mid(60), tests.cid('i'), 'text', 'Hi Ivy');
select tests.authenticate_as('i');
select lives_ok(
  $$ delete from public.friendships where tests.uid('a') in (requester_id, addressee_id) $$,
  'I unfriends A'
);
select results_eq(
  $$ select closed_at is not null, (select count(*)::int from public.messages m where m.conversation_id = c.id)
     from public.conversations c where c.id = tests.cid('i') $$,
  $$ values (true, 1) $$,
  'the conversation is closed and I still reads it'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('i'), 'text', 'Bye') $$,
  '42501', 'This conversation is closed.',
  'I cannot send into it'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select is_closed, last_message_preview from public.inbox_conversations() where conversation_id = tests.cid('i') $$,
  $$ values (true, 'Hi Ivy'::text) $$,
  'A still reads it too, marked closed in the Inbox'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('i'), 'text', 'Wait') $$,
  '42501', 'This conversation is closed.',
  'nor can A'
);
select throws_ok(
  $$ select public.open_conversation(tests.uid('i')) $$,
  '42501', 'This person is not available.',
  'and open_conversation does not reopen it for non-friends'
);
select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.uid('i')) $$,
  'A asks I again'
);
select tests.clear_authentication();
select is(
  (select closed_at is not null from public.conversations where id = tests.cid('i')),
  true,
  'a pending request does not reopen it'
);
select tests.authenticate_as('i');
select lives_ok(
  $$ update public.friendships set status = 'accepted' where requester_id = tests.uid('a') $$,
  'I accepts'
);
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('i'), 'text', 'Hello again') $$,
  'the new friendship reopened the conversation'
);

-- ---- block: hidden from the blocked person, read-only for the blocker ----------
select tests.authenticate_as('a');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(70), tests.cid('h'), 'quote', tests.qid(1));
select tests.authenticate_as('h');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(71), tests.cid('h'), 'quote', tests.qid(30));
select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'H blocks A'
);
select results_eq(
  $$ select closed_at is not null from public.conversations where id = tests.cid('h') $$,
  $$ values (true) $$,
  'the block closed the conversation; H (the blocker) still reads it'
);
select results_eq(
  $$ select id from public.messages where conversation_id = tests.cid('h') order by id $$,
  $$ values (tests.mid(70)), (tests.mid(71)) $$,
  'H keeps every message, to report from'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('h'), 'text', 'Go away') $$,
  '42501', 'This conversation is closed.',
  'H cannot send'
);
select tests.authenticate_as('a');
select is_empty(
  $$ select 1 from public.conversations where id = tests.cid('h') $$,
  'A (blocked) loses the conversation'
);
select is_empty(
  $$ select 1 from public.conversation_members where conversation_id = tests.cid('h') $$,
  'and A''s own member row in it'
);
select is_empty(
  $$ select 1 from public.messages where conversation_id = tests.cid('h') or id in (tests.mid(70), tests.mid(71)) $$,
  'and every message in it, A''s own included'
);
select is_empty(
  $$ select 1 from public.inbox_conversations() where conversation_id = tests.cid('h') $$,
  'and it leaves A''s Inbox'
);
select is_empty(
  $$ select 1 from public.profiles where id = tests.uid('h') $$,
  'A can no longer read H''s profile'
);
select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('h')) $$,
  'A may block H back'
);
select is_empty(
  $$ select 1 from public.profiles where id = tests.uid('h') $$,
  'but blocking back does not show A H''s profile (or tell A that H blocked them)'
);
delete from public.blocks where blocked_id = tests.uid('h');
select is(
  tests.error_of($$ insert into public.messages (conversation_id, kind, text) values (tests.cid('h'), 'text', 'Why?') $$),
  '42501 | This conversation is not available.',
  'A cannot send into it'
);
select is_empty(
  $$ delete from public.messages where id = tests.mid(70) returning 1 $$,
  'nor unsend from it'
);
select is(
  tests.deleted_by($$ delete from public.messages $$, tests.cid('h')),
  0,
  'nor erase H''s evidence with a DELETE that reads no column (the policy holds the read rule itself)'
);
select throws_ok(
  $$ select public.save_from_message(tests.mid(71)) $$,
  '42501', 'This message is not available.',
  'nor save from it'
);
select throws_ok(
  $$ select public.open_conversation(tests.uid('h')) $$,
  '42501', 'This person is not available.',
  'nor open it again'
);
select lives_ok(
  $$ insert into public.reports (id, message_id, reported_user_id, reason) values
       ('7e000000-0000-4000-8000-000000000002', tests.mid(71), tests.uid('h'), 'harassment') $$,
  'A can still report a message H sent (a member, even after being blocked)'
);
select results_eq(
  $$ select content_body, content_verified from tests.own_reports() where id = '7e000000-0000-4000-8000-000000000002' $$,
  $$ values ('Hal''s words'::text, true) $$,
  'with the server''s copy of it'
);
select throws_ok(
  $$ select content_body from public.reports where id = '7e000000-0000-4000-8000-000000000002' $$,
  '42501', null,
  'which A cannot read back: a report never reopens a message A lost'
);
select tests.clear_authentication();
select results_eq(
  $$ select count(*)::int from public.messages where conversation_id = tests.cid('h') $$,
  $$ values (2) $$,
  'the block deleted nothing'
);
select tests.authenticate_as('h');
select lives_ok(
  $$ delete from public.blocks where blocked_id = tests.uid('a') $$,
  'H unblocks A'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select closed_at is not null from public.conversations where id = tests.cid('h') $$,
  $$ values (true) $$,
  'A reads the conversation again, still closed: unblocking does not reopen it'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('h'), 'text', 'Hi?') $$,
  '42501', 'This conversation is closed.',
  'so A still cannot send'
);
-- Only the server can make a friendship and a block coexist (a block deletes
-- the friendship and refuses new requests). Even then, a block wins.
select tests.clear_authentication();
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('h'), tests.uid('a'));
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('h'), tests.uid('a'), 'accepted');
select is(
  (select closed_at is not null from public.conversations where id = tests.cid('h')),
  true,
  'an accepted friendship does not reopen a conversation while a block exists'
);
select tests.authenticate_as('h');
select throws_ok(
  $$ select public.open_conversation(tests.uid('a')) $$,
  '42501', 'This person is not available.',
  'and open_conversation refuses a blocked pair even when they are friends'
);
select tests.clear_authentication();
delete from public.friendships where requester_id = tests.uid('h') and addressee_id = tests.uid('a');
delete from public.blocks where blocker_id = tests.uid('h') and blocked_id = tests.uid('a');

-- ---- 300 messages a day (QR001) ---------------------------------------------------
select tests.clear_authentication();
insert into public.messages (conversation_id, sender_id, kind, text)
select tests.cid('c'), tests.uid('c'), 'text', 'Message ' || n from generate_series(1, 299) n;
select tests.authenticate_as('c');
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('c'), 'text', 'Message 300') $$,
  'C can send their 300th message of the day'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('c'), 'text', 'Message 301') $$,
  'QR001', 'You can send at most 300 messages a day.',
  'the 301st in 24 hours is refused with QR001'
);
select results_eq(
  $$ delete from public.messages where conversation_id = tests.cid('c') and text = 'Message 300' returning text $$,
  $$ values ('Message 300'::text) $$,
  'C unsends one'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('c'), 'text', 'Message 301') $$,
  'QR001', 'You can send at most 300 messages a day.',
  'which makes no room: unsent messages still count for the day'
);

-- ---- the secret key -----------------------------------------------------------------
select tests.clear_authentication();
set local role service_role;
select results_eq(
  $$ insert into public.messages (id, conversation_id, sender_id, kind, source_quote_id)
     values (tests.mid(80), tests.cid('e'), tests.uid('a'), 'quote', tests.qid(1))
     returning body, creator_username $$,
  $$ values ('Alpha'::text, 'alice'::text) $$,
  'service_role can send for A; the server still builds the snapshot'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, source_quote_id) values (tests.cid('e'), tests.uid('a'), 'quote', tests.qid(10)) $$,
  '42501', 'You can send only quotes from your Library or the Quoted Catalog.',
  'and still refuses someone else''s quote'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, text) values (tests.cid('e'), tests.uid('a'), 'text', 'Hi') $$,
  'QR004', 'This friend receives quotes only.',
  'and texts to someone who turned them off'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, text) values (tests.cid('e'), tests.uid('b'), 'text', 'Hi') $$,
  '42501', 'This conversation is not available.',
  'and a sender outside the pair'
);
select lives_ok(
  $$ delete from public.messages where id = tests.mid(80) $$,
  'service_role can delete a message'
);
select tests.clear_authentication();
select ok(exists (select 1 from private.message_tombstones where id = tests.mid(80)), 'which leaves a tombstone too');

-- ---- tombstones are purged after 30 days ---------------------------------------
select results_eq(
  $$ select jobname::text, schedule::text, command::text, active from cron.job where jobname = 'purge-message-tombstones' $$,
  $$ values ('purge-message-tombstones', '41 3 * * *', 'select private.purge_message_tombstones()', true) $$,
  'pg_cron purges message tombstones daily at 03:41'
);
select is(private.purge_message_tombstones(), 0, 'a fresh tombstone is kept');
select is(
  private.purge_message_tombstones(now() + interval '31 days'),
  3,
  'after 30 days every tombstone is deleted'
);
select is_empty($$ select 1 from private.message_tombstones $$, 'none is left');

-- ---- anon -------------------------------------------------------------------------------
set local role anon;
select throws_ok($$ select 1 from public.conversations $$, '42501', null, 'anon cannot read conversations');
select throws_ok($$ select public.open_conversation(tests.uid('a')) $$, '42501', null, 'anon cannot call open_conversation');
select throws_ok($$ select * from public.inbox_conversations() $$, '42501', null, 'anon cannot call inbox_conversations');
select throws_ok($$ select public.save_from_message(tests.mid(1)) $$, '42501', null, 'anon cannot call save_from_message');

-- ---- the insert policy alone ---------------------------------------------------------
-- messages_build_snapshot refuses all of these first, with clearer messages.
-- With it disabled, the policy must still refuse each one on its own.
-- (Deferred foreign key checks run first: ALTER TABLE refuses pending ones.)
select tests.clear_authentication();
set constraints all immediate;
alter table public.messages disable trigger messages_build_snapshot;
update public.conversations set closed_at = now() where id = tests.cid('i');
update public.conversations set closed_at = null where id = tests.cid('h');
select tests.authenticate_as('d');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('b'), 'text', 'D here') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'policy alone: a non-member cannot send'
);
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('i'), 'text', 'Closed?') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'policy alone: nor a member into a closed conversation, even with a friend'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('h'), 'text', 'Not friends') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'policy alone: nor into an open conversation with someone who is no longer a friend'
);
select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('e'), 'text', 'Policy says yes') $$,
  'policy alone: a member sends to an open conversation with a friend'
);
select tests.authenticate_as('f');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('f'), 'text', 'No terms') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'policy alone: sending needs accepted terms'
);
select tests.authenticate_as('g');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.cid('g'), 'text', 'Suspended') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'policy alone: and no suspension'
);
select tests.clear_authentication();
alter table public.messages enable trigger messages_build_snapshot;
set constraints all deferred;

-- A block closes an open conversation by itself too (here one the server left
-- open after the friendship ended).
select tests.authenticate_as('h');
select lives_ok($$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$, 'H blocks A again');
select is(
  (select closed_at is not null from public.conversations where id = tests.cid('h')),
  true,
  'the block closed the conversation, with no friendship left to end'
);
select tests.clear_authentication();

-- ---- account deletion removes the conversation for both ----------------------------
select tests.clear_authentication();
insert into private.message_tombstones (id, conversation_id, sender_id, payload)
values (tests.mid(90), tests.cid('b'), tests.uid('b'), '{}');

select lives_ok(
  $$ delete from auth.users where id = tests.uid('b') $$,
  'deleting B''s auth user succeeds'
);
select is_empty(
  $$ select 1 from public.conversations where tests.uid('b') in (user_a, user_b) $$,
  'A and B''s conversation is gone'
);
select is_empty(
  $$ select 1 from public.conversation_members where user_id = tests.uid('b') or conversation_id not in (select id from public.conversations) $$,
  'with both member rows'
);
select is_empty(
  $$ select 1 from public.messages where id in (tests.mid(1), tests.mid(2), tests.mid(7)) $$,
  'and every message in it, A''s included: both sides lose that history'
);
select is_empty(
  $$ select 1 from private.message_tombstones where sender_id = tests.uid('b') $$,
  'B''s tombstones go too'
);
select results_eq(
  $$ select message_id is null, reporter_id is null, content_body, content_verified
     from public.reports where id = '7e000000-0000-4000-8000-000000000001' $$,
  $$ values (true, true, 'Alpha'::text, true) $$,
  'B''s report on A''s message stays, with its copy, without the message or B'
);
select results_eq(
  $$ select count(*)::int from public.conversations where tests.uid('a') in (user_a, user_b) $$,
  $$ values (6) $$,
  'A''s other conversations stay'
);

select * from finish();
rollback;
