-- Messages (formerly shares), reports and the block trigger.
-- Ported to 20261029090300_conversations_and_messages: shares moved into
-- messages in conversations, so the file keeps its name and its assertions
-- now cover quote and text messages; the full endpoint-by-endpoint proof that
-- a non-participant can neither read nor send is in 19_conversations_messages.
-- Changed with the model:
--   * sending to a pending request or a stranger is now refused by
--     open_conversation (there is no conversation to send into);
--   * a snapshot without a quote row became a text message (clients can no
--     longer send a snapshot at all);
--   * "cannot pre-set seen_at" became "cannot date a message" (seen_at is
--     gone; each member's read mark is private, in conversation_members);
--   * "recipient marks seen and saved" became "B marks the conversation read"
--     (saved_at is gone: nobody sees "Saved");
--   * the sender "cannot mark seen" became "cannot touch B's member row";
--   * "redirect a share" became "move a message to another conversation";
--   * the recipient can no longer delete a received share: only the sender
--     unsends, and the recipient clears the conversation for themselves;
--   * a block no longer deletes anything: the messages stay in both
--     directions, so the report keeps its message_id.
-- Removed: none.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(38);

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

-- The user has accepted the current terms (social writes need them).
create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- The conversation between two users, read with definer rights.
create function tests.pair(x text, y text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid(x), tests.uid(y)) and c.user_b = greatest(tests.uid(x), tests.uid(y))
$$;
-- ---------------------------------------------------------------------------

-- A and B are friends with a conversation. A and C have only a pending
-- request (C once sent A a message, kept from before). D is a stranger.
select tests.create_user('a');
select tests.create_user('b');
select tests.create_user('c');
select tests.create_user('d');
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd']) w;
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('a'), tests.uid('c'), 'pending');
insert into public.quotes (id, owner_id, body, author) values
  ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'A quote', 'Ann'),
  ('b0000000-0000-4000-8000-000000000001', tests.uid('b'), 'B quote', 'Ben');
insert into public.conversations (user_a, user_b, closed_at) values (tests.uid('a'), tests.uid('c'), now());
insert into public.conversation_members (conversation_id, user_id)
select tests.pair('a', 'c'), u from unnest(array[tests.uid('a'), tests.uid('c')]) u;
insert into public.messages (conversation_id, sender_id, kind, text) values (tests.pair('a', 'c'), tests.uid('c'), 'text', 'C to A');
select tests.authenticate_as('a');
select public.open_conversation(tests.uid('b'));

-- ---- sending --------------------------------------------------------------
select lives_ok(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id, note)
     values ('5a000000-0000-4000-8000-000000000001', tests.pair('a', 'b'), 'quote',
             'a0000000-0000-4000-8000-000000000001', 'for you') $$,
  'A can send their own quote to friend B'
);

select lives_ok(
  $$ insert into public.messages (id, conversation_id, kind, text)
     values ('5a000000-0000-4000-8000-000000000002', tests.pair('a', 'b'), 'text', 'Typed, no quote row') $$,
  'A can send a text without a quote row'
);

select throws_ok(
  $$ select public.open_conversation(tests.uid('c')) $$,
  '42501', null,
  'A cannot open a conversation with C (request still pending)'
);

select throws_ok(
  $$ select public.open_conversation(tests.uid('d')) $$,
  '42501', null,
  'A cannot open a conversation with a non-friend'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, source_quote_id)
     values (tests.pair('a', 'b'), 'quote', 'b0000000-0000-4000-8000-000000000001') $$,
  '42501', null,
  'A cannot send someone else''s quote'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, kind, text) values (tests.pair('a', 'b'), tests.uid('b'), 'text', 'forged') $$,
  '42501', null,
  'A cannot send a message as B'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text, created_at) values (tests.pair('a', 'b'), 'text', 'pre-dated', now()) $$,
  '42501', null,
  'A cannot date a message'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id, note) values (tests.pair('a', 'b'), 'quote', 1, repeat('n', 281)) $$,
  '23514', null,
  'note is at most 280 characters'
);

-- ---- receiving ------------------------------------------------------------
select tests.authenticate_as('b');

select results_eq(
  $$ select count(*)::int from public.messages where sender_id = tests.uid('a') $$,
  $$ values (2) $$,
  'B sees both messages from A'
);

select results_eq(
  $$ update public.conversation_members set last_read_at = now()
     where conversation_id = tests.pair('a', 'b')
     returning last_read_at is not null $$,
  $$ values (true) $$,
  'recipient B can mark the conversation read'
);

select throws_ok(
  $$ update public.messages set body = 'edited' where id = '5a000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'recipient B cannot change the body'
);

select throws_ok(
  $$ update public.messages set conversation_id = tests.pair('a', 'c') where id = '5a000000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'recipient B cannot move a message to another conversation'
);

select is_empty(
  $$ select 1 from public.quotes where owner_id = tests.uid('a') $$,
  'receiving a quote does not expose the sender''s quotes'
);

select tests.authenticate_as('a');

select is_empty(
  $$ update public.conversation_members set last_read_at = now()
     where conversation_id = tests.pair('a', 'b') and user_id = tests.uid('b') returning 1 $$,
  'sender A cannot touch B''s read mark'
);

select throws_ok(
  $$ update public.messages set text = 'edited' where id = '5a000000-0000-4000-8000-000000000002' $$,
  '42501', null,
  'sender A cannot edit a sent message'
);

select tests.authenticate_as('c');

select is_empty(
  $$ select 1 from public.messages where conversation_id = tests.pair('a', 'b') $$,
  'C cannot see messages between A and B'
);

select is_empty(
  $$ delete from public.messages where conversation_id = tests.pair('a', 'b') returning 1 $$,
  'C cannot delete messages between A and B'
);

-- Deleting the source quote keeps the snapshot.
select tests.authenticate_as('a');
delete from public.quotes where id = 'a0000000-0000-4000-8000-000000000001';
select tests.clear_authentication();

select results_eq(
  $$ select source_quote_id is null, body from public.messages where id = '5a000000-0000-4000-8000-000000000001' $$,
  $$ values (true, 'A quote'::text) $$,
  'deleting the source quote nulls source_quote_id and keeps the snapshot'
);

select tests.authenticate_as('b');

-- ---- reports --------------------------------------------------------------
select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason, details)
     values ('5a000000-0000-4000-8000-000000000002', tests.uid('a'), 'spam', 'unwanted') $$,
  'B can report a message received from A'
);

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('d'), 'other') $$,
  'B can report a user without a message'
);

select results_eq(
  $$ select count(*)::int from public.reports $$,
  $$ values (2) $$,
  'B can read their own reports'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, reported_user_id, reason) values (tests.uid('a'), tests.uid('d'), 'spam') $$,
  '42501', null,
  'B cannot file a report as A'
);

select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('d'), 'spam') $$,
  '42501', null,
  'a reported message must come from the reported user'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'boring') $$,
  '23514', null,
  'reason must be spam, harassment, inappropriate, copyright, wrong_wording or other'
);

select throws_ok(
  $$ update public.reports set reason = 'other' $$,
  '42501', null,
  'reports cannot be edited'
);

select throws_ok(
  $$ delete from public.reports $$,
  '42501', null,
  'reports cannot be deleted by clients'
);

select tests.authenticate_as('a');

select is_empty(
  $$ select 1 from public.reports $$,
  'A cannot read reports filed by B (or about A)'
);

select tests.authenticate_as('c');

select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5a000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  '42501', null,
  'C cannot report a message from a conversation C is not in'
);

-- ---- sender delete (unsend) ----------------------------------------------
select tests.clear_authentication();
insert into public.messages (id, conversation_id, sender_id, kind, text)
values ('5a000000-0000-4000-8000-000000000003', tests.pair('a', 'b'), tests.uid('a'), 'text', 'Sent by mistake');
select tests.authenticate_as('a');

select results_eq(
  $$ delete from public.messages where id = '5a000000-0000-4000-8000-000000000003' returning text $$,
  $$ values ('Sent by mistake') $$,
  'sender A can unsend a message'
);

select tests.authenticate_as('b');

select is_empty(
  $$ select 1 from public.messages where id = '5a000000-0000-4000-8000-000000000003' $$,
  'the unsent message is gone for recipient B too'
);

-- ---- the recipient cannot delete ------------------------------------------

select is_empty(
  $$ delete from public.messages where id = '5a000000-0000-4000-8000-000000000001' returning 1 $$,
  'recipient B cannot delete a message A sent (B clears the conversation instead)'
);

-- ---- block trigger ----------------------------------------------------------
select tests.clear_authentication();
insert into public.messages (id, conversation_id, sender_id, kind, text) values
  ('5b000000-0000-4000-8000-000000000001', tests.pair('a', 'b'), tests.uid('b'), 'text', 'B to A');

select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.blocks (blocked_id) values (tests.uid('a')) $$,
  'B can block friend A'
);

select tests.clear_authentication();

select is_empty(
  $$ select 1 from public.friendships
     where least(requester_id, addressee_id) = least(tests.uid('a'), tests.uid('b'))
       and greatest(requester_id, addressee_id) = greatest(tests.uid('a'), tests.uid('b')) $$,
  'the block removed the A-B friendship'
);

select results_eq(
  $$ select coalesce(text, body) from public.messages where conversation_id = tests.pair('a', 'b') order by 1 $$,
  $$ values ('A quote'), ('B to A'), ('Typed, no quote row') $$,
  'the block kept the messages in both directions'
);

select results_eq(
  $$ select text from public.messages where conversation_id = tests.pair('a', 'c') $$,
  $$ values ('C to A') $$,
  'messages with other people are untouched'
);

select results_eq(
  $$ select message_id, reason from public.reports where reported_user_id = tests.uid('a') $$,
  $$ values ('5a000000-0000-4000-8000-000000000002'::uuid, 'spam') $$,
  'the report on A still points at the message'
);

select results_eq(
  $$ select status from public.friendships where requester_id in (tests.uid('a'), tests.uid('b'), tests.uid('c'), tests.uid('d')) $$,
  $$ values ('pending') $$,
  'the unrelated A-C request is untouched'
);

select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.pair('a', 'b'), 'text', 'still there?') $$,
  '42501', null,
  'after the block, A cannot send to B'
);

select * from finish();
rollback;
