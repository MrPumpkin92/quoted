-- Forwarding (supabase/migrations/20261029090500_forward_quotes.sql): a quote
-- message made from a post (source_post_id) or from another quote message
-- (source_message_id). A friend forwards a friend's post and a received quote
-- message to another friend, and the copy keeps the creator unless it is
-- verified; never the caption or the note. Every refusal is the same 42501 as
-- an unknown id: a conversation you are not in, a cleared, reported or
-- blocked message, a text or playlist message, a friends-only post you are a
-- stranger to, a reported or blocked post, and a held post (for its author
-- too). A stranger may forward a public post. Text and playlist messages
-- carry neither column; a quote message has exactly one source (23514).
-- Clients cannot read the columns back; the server roles never forward. The
-- word filter still runs on an unverified forwarded snapshot. A forward is
-- checked against the catalog as it is now, not as its source stored it.
-- Deleting the source post or message, or its author's account, leaves the
-- copy.
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
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'd' then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    when 'e' then 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    when 'h' then '44444444-4444-4444-8444-444444444444'
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.pid(n int) returns uuid language sql immutable as $$
  select ('80000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- A forward of a post (kind 'p') or a message ('m') into A's conversation
-- with someone, as the current caller, with an optional note. Every attempt
-- below has its own message id, so a refusal that wrongly succeeds fails only
-- its own test.
create function tests.forward(n int, kind text, source uuid, who text, note text default null)
returns text language sql as $$
  select format(
    'insert into public.messages (id, conversation_id, kind, %s, note) values (%L, %L, ''quote'', %L, %L)',
    case kind when 'p' then 'source_post_id' else 'source_message_id' end,
    tests.mid(n), tests.cid(who), source, note)
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

-- A (alice) is friends with B, C, D, E and H. C and D are strangers to B (and
-- C is in no conversation with B). H will block A.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'h']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', null), (tests.uid('b'), 'bob', null), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('h'), 'hal', null);
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'h']) w;
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('c'), 'accepted'),
  (tests.uid('a'), tests.uid('d'), 'accepted'), (tests.uid('a'), tests.uid('e'), 'accepted'),
  (tests.uid('h'), tests.uid('a'), 'accepted');
-- B may make a post public (current terms, an Apple identity).
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-bob', tests.uid('b'), '{}', 'apple');
insert into public.playlists (id, owner_id, title, visibility) values (tests.plid(10), tests.uid('b'), 'Bob list', 'friends');

select tests.authenticate_as('a');
select (public.open_conversation(tests.uid(w))).id from unnest(array['b', 'c', 'd', 'e', 'h']) w;

-- B's quotes and posts: 1 B's own words with a caption, 2 catalog quote 1
-- (verified), 3 to be reported by A, 4 to be held, 5 public, 6 words that
-- become blocked later, 7 catalog quote 3 (verified, "fearless").
select tests.authenticate_as('b');
insert into public.quotes (id, body, author) values (tests.qid(10), 'Bob''s line', 'Bo'), (tests.qid(12), 'Odd gadzooks', null);
insert into public.posts (id, source_quote_id, caption) values (tests.pid(1), tests.qid(10), 'Morning thought');
insert into public.posts (id, starter_quote_id, caption) values (tests.pid(2), 1, 'Classic');
insert into public.posts (id, source_quote_id) values (tests.pid(3), tests.qid(10)), (tests.pid(4), tests.qid(10));
insert into public.posts (id, source_quote_id, audience) values (tests.pid(5), tests.qid(10), 'public');
insert into public.posts (id, source_quote_id) values (tests.pid(6), tests.qid(12));
insert into public.posts (id, starter_quote_id) values (tests.pid(7), 3);
-- B's messages to A: 1 B's quote with a note, 2 a catalog quote, 3 to be
-- reported, 4 text, 5 a playlist, 6 words that become blocked later.
insert into public.messages (id, conversation_id, kind, source_quote_id, note)
  values (tests.mid(1), tests.cid('b'), 'quote', tests.qid(10), 'For you');
insert into public.messages (id, conversation_id, kind, starter_quote_id) values (tests.mid(2), tests.cid('b'), 'quote', 1);
insert into public.messages (id, conversation_id, kind, source_quote_id) values
  (tests.mid(3), tests.cid('b'), 'quote', tests.qid(10)), (tests.mid(6), tests.cid('b'), 'quote', tests.qid(12));
insert into public.messages (id, conversation_id, kind, text) values (tests.mid(4), tests.cid('b'), 'text', 'Hi there');
insert into public.messages (id, conversation_id, kind, playlist_id) values (tests.mid(5), tests.cid('b'), 'playlist', tests.plid(10));
-- E and H send A a quote; H posts.
select tests.authenticate_as('e');
insert into public.quotes (id, body) values (tests.qid(50), 'Eve''s words');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(20), tests.cid('e'), 'quote', tests.qid(50));
select tests.authenticate_as('h');
insert into public.quotes (id, body) values (tests.qid(30), 'Hal''s words');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(30), tests.cid('h'), 'quote', tests.qid(30));
insert into public.posts (id, source_quote_id) values (tests.pid(30), tests.qid(30));
select tests.clear_authentication();
update public.posts set held_at = now() where id = tests.pid(4);

-- ---- a friend forwards a post and a received message ----------------------
select tests.authenticate_as('a');
select results_eq(
  tests.forward(100, 'p', tests.pid(1), 'c', 'Look at this') || ' returning body, author, creator_username, note, verified_starter_id',
  $$ values ('Bob''s line'::text, 'Bo'::text, 'bob'::text, 'Look at this'::text, null::smallint) $$,
  'A forwards friend B''s post to C: the quote and its creator, with A''s own note and not B''s caption'
);
select results_eq(
  tests.forward(101, 'm', tests.mid(1), 'c') || ' returning body, author, creator_username, note, verified_starter_id',
  $$ values ('Bob''s line'::text, 'Bo'::text, 'bob'::text, null::text, null::smallint) $$,
  'A forwards a quote message B sent to C: the quote and its creator, not B''s note'
);
select results_eq(
  tests.forward(102, 'p', tests.pid(2), 'c') || ' returning body, creator_id, creator_username, verified_starter_id',
  $$ select body, null::uuid, null::text, 1::smallint from public.starter_quotes where id = 1 $$,
  'a verified post goes as "Quoted Catalog": no creator'
);
select results_eq(
  tests.forward(103, 'm', tests.mid(2), 'c') || ' returning body, creator_id, edited_from_id, verified_starter_id',
  $$ select body, null::uuid, null::uuid, 1::smallint from public.starter_quotes where id = 1 $$,
  'so does a verified message'
);
select tests.clear_authentication();
-- The server never builds this, but a verified snapshot still loses a pair
-- that is somehow there.
update public.posts set creator_id = tests.uid('b'), creator_username = 'bob', edited_from_id = tests.uid('b'),
       edited_from_username = 'bob' where id = tests.pid(2);
select tests.authenticate_as('a');
select results_eq(
  tests.forward(104, 'p', tests.pid(2), 'c') || ' returning creator_id, edited_from_id, verified_starter_id',
  $$ values (null::uuid, null::uuid, 1::smallint) $$,
  'a forwarded verified snapshot keeps neither pair, whatever its source holds'
);
select results_eq(
  tests.forward(105, 'm', tests.mid(30), 'c') || ' returning body, creator_username',
  $$ values ('Hal''s words'::text, 'hal'::text) $$,
  'A forwards H''s message (H has not blocked A yet)'
);

select tests.authenticate_as('c');
select results_eq(
  $$ select id, sender_id, body, creator_username from public.messages
     where id in (tests.mid(100), tests.mid(101)) order by id $$,
  $$ values (tests.mid(100), tests.uid('a'), 'Bob''s line'::text, 'bob'::text),
            (tests.mid(101), tests.uid('a'), 'Bob''s line'::text, 'bob'::text) $$,
  'C, who is not B''s friend, reads both forwards from A, "Added by @bob"'
);
select results_eq(
  tests.forward(106, 'm', tests.mid(101), 'c') || ' returning body, creator_username',
  $$ values ('Bob''s line'::text, 'bob'::text) $$,
  'a forward can be forwarded again, still crediting B'
);
select tests.clear_authentication();
select results_eq(
  $$ select id, source_post_id, source_message_id, source_quote_id, starter_quote_id from public.messages
     where id in (tests.mid(100), tests.mid(101), tests.mid(106)) order by id $$,
  $$ values (tests.mid(100), tests.pid(1), null::uuid, null::uuid, null::smallint),
            (tests.mid(101), null::uuid, tests.mid(1), null::uuid, null::smallint),
            (tests.mid(106), null::uuid, tests.mid(101), null::uuid, null::smallint) $$,
  'each forward records its one source'
);

-- ---- a stranger forwards a public post, never a friends-only one -----------
select tests.authenticate_as('d');
select results_eq(
  tests.forward(107, 'p', tests.pid(5), 'd') || ' returning body, creator_username',
  $$ values ('Bob''s line'::text, 'bob'::text) $$,
  'D, a stranger to B, forwards B''s public post (as profile_view shows it) to A'
);
select is(
  tests.error_of(tests.forward(120, 'p', tests.pid(1), 'd')),
  '42501 | This quote is not available.',
  'but not B''s friends-only post'
);
select is(
  tests.error_of(tests.forward(121, 'p', '80000000-0000-4000-8000-000000009999', 'd')),
  '42501 | This quote is not available.',
  'which fails exactly as an unknown post does'
);

-- ---- a non-participant cannot forward a message ----------------------------
select tests.authenticate_as('c');
select is(
  tests.error_of(tests.forward(122, 'm', tests.mid(1), 'c')),
  '42501 | This quote is not available.',
  'C cannot forward a message from A and B''s conversation'
);
select is(
  tests.error_of(tests.forward(123, 'm', tests.mid(1), 'c')),
  tests.error_of(tests.forward(124, 'm', '3e000000-0000-4000-8000-000000009999', 'c')),
  'and gets exactly the answer for a message that does not exist'
);
select is(
  tests.error_of(tests.forward(125, 'm', tests.mid(20), 'c')),
  '42501 | This quote is not available.',
  'nor one from A and E''s conversation'
);

-- ---- only a quote message can be forwarded -----------------------------------
select tests.authenticate_as('a');
select is(
  tests.error_of(tests.forward(126, 'm', tests.mid(4), 'c')),
  '42501 | This quote is not available.',
  'a text message cannot be forwarded as a quote'
);
select is(
  tests.error_of(tests.forward(127, 'm', tests.mid(5), 'c')),
  '42501 | This quote is not available.',
  'nor a playlist message'
);

-- ---- held, reported, cleared and blocked ----------------------------------------
select is(
  tests.error_of(tests.forward(128, 'p', tests.pid(4), 'c')),
  '42501 | This quote is not available.',
  'a held post cannot be forwarded by a friend'
);
select tests.authenticate_as('b');
select is(
  tests.error_of(tests.forward(129, 'p', tests.pid(4), 'b')),
  '42501 | This quote is not available.',
  'nor by its author (the app disables Send while it is held)'
);
select results_eq(
  tests.forward(130, 'p', tests.pid(1), 'b') || ' returning body',
  $$ values ('Bob''s line'::text) $$,
  'while the author may forward their own post that is not held'
);

select tests.authenticate_as('a');
select lives_ok(
  $$ insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(3), tests.uid('b'), 'spam') $$,
  'A reports B''s post 3'
);
select is(
  tests.error_of(tests.forward(131, 'p', tests.pid(3), 'c')),
  '42501 | This quote is not available.',
  'a post A reported cannot be forwarded by A'
);
select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(3), tests.uid('b'), 'spam') $$,
  'A reports B''s message 3'
);
select is(
  tests.error_of(tests.forward(132, 'm', tests.mid(3), 'c')),
  '42501 | This quote is not available.',
  'a message A reported cannot be forwarded by A'
);

select results_eq(
  $$ update public.conversation_members set cleared_at = now() where conversation_id = tests.cid('e')
     returning cleared_at = now() $$,
  $$ values (true) $$,
  'A deletes the conversation with E (for A)'
);
select is(
  tests.error_of(tests.forward(133, 'm', tests.mid(20), 'c')),
  '42501 | This quote is not available.',
  'a message A cleared cannot be forwarded by A'
);
select tests.authenticate_as('e');
select results_eq(
  tests.forward(134, 'm', tests.mid(20), 'e') || ' returning body',
  $$ values ('Eve''s words'::text) $$,
  'while E, who cleared nothing, still forwards it'
);

select tests.authenticate_as('h');
select lives_ok($$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$, 'H blocks A');
select tests.authenticate_as('a');
select is(
  tests.error_of(tests.forward(135, 'm', tests.mid(30), 'c')),
  '42501 | This quote is not available.',
  'A can no longer forward H''s message'
);
select is(
  tests.error_of(tests.forward(136, 'p', tests.pid(30), 'c')),
  '42501 | This quote is not available.',
  'nor H''s post'
);
select results_eq(
  $$ select body, creator_username from public.messages where id = tests.mid(105) $$,
  $$ values ('Hal''s words'::text, 'hal'::text) $$,
  'the copy A forwarded before the block stays'
);

-- ---- the shape: one source, and only quotes forward ---------------------------
select is(
  tests.error_of(format(
    'insert into public.messages (conversation_id, kind, source_post_id, source_message_id) values (%L, ''quote'', %L, %L)',
    tests.cid('c'), tests.pid(1), tests.mid(1))),
  '23514 | A quote message holds exactly one quote: one of yours or one from the Quoted Catalog. | Send exactly one of source_quote_id, starter_quote_id, source_post_id and source_message_id. | messages_one_source',
  'a post and a message together are two sources'
);
select throws_ok(
  format('insert into public.messages (conversation_id, kind, source_post_id, starter_quote_id) values (%L, ''quote'', %L, 1)',
         tests.cid('c'), tests.pid(1)),
  '23514', null,
  'so are a post and a catalog quote'
);
select throws_ok(
  format('insert into public.messages (conversation_id, kind, source_message_id, source_quote_id) values (%L, ''quote'', %L, %L)',
         tests.cid('c'), tests.mid(1), tests.qid(10)),
  '23514', null,
  'and a message and a quote'
);
select matches(
  tests.error_of(format('insert into public.messages (conversation_id, kind, text, source_post_id) values (%L, ''text'', ''Hi'', %L)',
                        tests.cid('c'), tests.pid(1))),
  '^23514 \| .*messages_kind_shape$',
  'a text message cannot carry source_post_id'
);
select matches(
  tests.error_of(format('insert into public.messages (conversation_id, kind, text, source_message_id) values (%L, ''text'', ''Hi'', %L)',
                        tests.cid('c'), tests.mid(1))),
  '^23514 \| .*messages_kind_shape$',
  'nor source_message_id'
);
select tests.clear_authentication();
insert into public.playlists (id, owner_id, title, visibility) values (tests.plid(1), tests.uid('a'), 'Alice list', 'friends');
select tests.authenticate_as('a');
select matches(
  tests.error_of(format('insert into public.messages (conversation_id, kind, playlist_id, source_post_id) values (%L, ''playlist'', %L, %L)',
                        tests.cid('c'), tests.plid(1), tests.pid(1))),
  '^23514 \| .*messages_kind_shape$',
  'a playlist message cannot carry source_post_id'
);
select matches(
  tests.error_of(format('insert into public.messages (conversation_id, kind, playlist_id, source_message_id) values (%L, ''playlist'', %L, %L)',
                        tests.cid('c'), tests.plid(1), tests.mid(1))),
  '^23514 \| .*messages_kind_shape$',
  'nor source_message_id'
);
select lives_ok(
  format('insert into public.messages (conversation_id, kind, playlist_id) values (%L, ''playlist'', %L)',
         tests.cid('c'), tests.plid(1)),
  'while the same playlist goes without them'
);
select is(
  (select count(*)::int from private.forwardable_snapshot(tests.pid(1), tests.mid(1))),
  0,
  'private.forwardable_snapshot answers nothing when given both a post and a message'
);

-- ---- clients send the sources but never read them -----------------------------------
select tests.authenticate_as('c');
select throws_ok(
  $$ select source_post_id from public.messages $$,
  '42501', 'permission denied for table messages',
  'not even the recipient can read source_post_id'
);
select throws_ok(
  $$ select source_message_id from public.messages $$,
  '42501', 'permission denied for table messages',
  'nor source_message_id'
);
select tests.authenticate_as('a');
select throws_ok(
  tests.forward(137, 'p', tests.pid(1), 'c') || ' returning source_post_id',
  '42501', 'permission denied for table messages',
  'and the sender cannot read it back'
);

-- ---- the word filter still runs on an unverified forward ---------------------------
select tests.clear_authentication();
insert into private.blocked_terms (term) values ('gadzooks'), ('fearless');
select tests.authenticate_as('a');
select throws_ok(
  tests.forward(138, 'p', tests.pid(6), 'c'),
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'a post whose words are blocked now cannot be forwarded'
);
select throws_ok(
  tests.forward(139, 'm', tests.mid(6), 'c'),
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'nor such a message'
);
select throws_ok(
  tests.forward(140, 'p', tests.pid(1), 'c', 'Gadzooks!'),
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'and the forwarder''s note is checked too'
);
select results_eq(
  tests.forward(141, 'p', tests.pid(7), 'c') || ' returning verified_starter_id',
  $$ values (3::smallint) $$,
  'a verified quote is not filtered ("fearless" is in catalog quote 3)'
);

-- ---- the server roles never forward -------------------------------------------------
select tests.clear_authentication();
set local role service_role;
select is(
  tests.error_of(format(
    'insert into public.messages (conversation_id, sender_id, kind, source_post_id) values (%L, %L, ''quote'', %L)',
    tests.cid('c'), tests.uid('a'), tests.pid(1))),
  '42501 | Only a signed-in person can forward a post or a message. | Send source_quote_id or starter_quote_id instead.',
  'service_role cannot forward a post'
);
select throws_ok(
  format('insert into public.messages (conversation_id, sender_id, kind, source_message_id) values (%L, %L, ''quote'', %L)',
         tests.cid('c'), tests.uid('a'), tests.mid(1)),
  '42501', 'Only a signed-in person can forward a post or a message.',
  'nor a message'
);
select throws_ok(
  format('insert into public.messages (conversation_id, sender_id, kind, body, source_post_id) values (%L, %L, ''quote'', ''Mine'', %L)',
         tests.cid('c'), tests.uid('a'), tests.pid(1)),
  '42501', 'Only a signed-in person can forward a post or a message.',
  'not even with a snapshot of its own'
);
select results_eq(
  format('insert into public.messages (conversation_id, sender_id, kind, starter_quote_id) values (%L, %L, ''quote'', 1) returning verified_starter_id',
         tests.cid('c'), tests.uid('a')),
  $$ values (1::smallint) $$,
  'while service_role still sends a catalog quote'
);
select tests.clear_authentication();
select throws_ok(
  format('insert into public.messages (conversation_id, sender_id, kind, source_post_id) values (%L, %L, ''quote'', %L)',
         tests.cid('c'), tests.uid('a'), tests.pid(1)),
  '42501', 'Only a signed-in person can forward a post or a message.',
  'and postgres cannot forward either'
);

-- ---- the catalog changes after the post or message ------------------------------
-- B's own words, posted and sent to A, later become catalog quote 900: a
-- forward goes as "Quoted Catalog" and never names whoever typed them, as
-- saving and then sending would. A post of catalog quote 2 whose wording the
-- catalog corrects afterwards loses its seal when forwarded.
select tests.authenticate_as('b');
insert into public.quotes (id, body, author, source) values (tests.qid(14), 'A wording nobody has catalogued yet', 'Ann Author', 'Some Book');
insert into public.posts (id, source_quote_id) values (tests.pid(8), tests.qid(14));
insert into public.posts (id, starter_quote_id) values (tests.pid(9), 2);
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(8), tests.cid('b'), 'quote', tests.qid(14));
select tests.clear_authentication();
insert into public.starter_quotes (id, body, author, source, sort_order, source_location, source_url)
  values (900, 'A wording nobody has catalogued yet', 'Ann Author', 'Some Book', 900, 'p. 1', 'https://example.invalid/');
update public.starter_quotes set body = body || ' (corrected)' where id = 2;
insert into private.blocked_terms (term) values ('catalogued');
select tests.authenticate_as('a');
select results_eq(
  tests.forward(150, 'p', tests.pid(8), 'c') || ' returning verified_starter_id, creator_id, creator_username',
  $$ values (900::smallint, null::uuid, null::text) $$,
  'a post of words the catalog took in later goes as "Quoted Catalog", without B''s name and past the word filter'
);
select results_eq(
  tests.forward(151, 'm', tests.mid(8), 'c') || ' returning verified_starter_id, creator_id, creator_username',
  $$ values (900::smallint, null::uuid, null::text) $$,
  'so does a message of them'
);
select results_eq(
  tests.forward(152, 'p', tests.pid(9), 'c') || ' returning verified_starter_id, creator_id',
  $$ values (null::smallint, null::uuid) $$,
  'a post of a catalog wording the catalog has since corrected loses its seal'
);
select tests.authenticate_as('c');
select results_eq(
  $$ select id, verified_starter_id, creator_username from public.messages
     where id in (tests.mid(150), tests.mid(151)) order by id $$,
  $$ values (tests.mid(150), 900::smallint, null::text), (tests.mid(151), 900::smallint, null::text) $$,
  'C, a stranger to B, never learns who typed the words'
);
select tests.clear_authentication();
delete from private.blocked_terms where term = 'catalogued';

-- ---- deleting the source leaves the copy ------------------------------------------
select tests.authenticate_as('b');
select lives_ok($$ delete from public.posts where id = tests.pid(1) $$, 'B deletes post 1');
select lives_ok($$ delete from public.messages where id = tests.mid(1) $$, 'B unsends message 1');
select tests.authenticate_as('c');
select results_eq(
  $$ select id, body, creator_username from public.messages where id in (tests.mid(100), tests.mid(101)) order by id $$,
  $$ values (tests.mid(100), 'Bob''s line'::text, 'bob'::text), (tests.mid(101), 'Bob''s line'::text, 'bob'::text) $$,
  'C still reads both copies'
);
select tests.clear_authentication();
select results_eq(
  $$ select id, source_post_id, source_message_id from public.messages
     where id in (tests.mid(100), tests.mid(101), tests.mid(106)) order by id $$,
  $$ values (tests.mid(100), null::uuid, null::uuid), (tests.mid(101), null::uuid, null::uuid),
            (tests.mid(106), null::uuid, tests.mid(101)) $$,
  'with their sources set to null (a forward of a forward keeps its own)'
);
select is(
  (select payload ->> 'source_post_id' from private.message_tombstones where id = tests.mid(1)),
  null,
  'the unsent message''s tombstone holds the row, the new columns included'
);
select ok(
  (select payload ? 'source_message_id' from private.message_tombstones where id = tests.mid(1)),
  'with both keys'
);

select lives_ok($$ delete from auth.users where id = tests.uid('b') $$, 'B''s account is deleted');
select tests.authenticate_as('c');
select results_eq(
  $$ select id, body, creator_username from public.messages where id in (tests.mid(100), tests.mid(101)) order by id $$,
  $$ values (tests.mid(100), 'Bob''s line'::text, null::text), (tests.mid(101), 'Bob''s line'::text, null::text) $$,
  'the copies outlive B''s account, now "Added by a person"'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select id, body from public.messages where id = tests.mid(107) $$,
  $$ values (tests.mid(107), 'Bob''s line'::text) $$,
  'and so does D''s forward of B''s public post'
);

-- One statement deletes the forwarders and their sources (the purge): the
-- foreign keys are checked at commit, so the cascade does not trip on itself.
select tests.clear_authentication();
select lives_ok(
  $$ delete from auth.users where id in (tests.uid('a'), tests.uid('c'), tests.uid('d'), tests.uid('e'), tests.uid('h')) $$,
  'deleting every other account in one statement succeeds'
);
select lives_ok($$ set constraints all immediate $$, 'and every deferred foreign key check passes');
select is_empty(
  $$ select 1 from public.messages $$,
  'no message is left'
);

select * from finish();
rollback;
