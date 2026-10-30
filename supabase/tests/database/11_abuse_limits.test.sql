-- Write limits (supabase/migrations/20261021090000_abuse_limits_privacy_cleanup.sql):
-- each limit just under and hit, the QR001 (rate) and QR002 (total) codes,
-- one report per reporter + reported user + share, a blocked pair that fails
-- like an unknown user, and the supporting indexes. The users who send friend
-- requests have accepted the terms (20261030030000_provenance_and_accounts;
-- the 150-friend cap is in 16_provenance_accounts).
-- Ported to 20261030030300_conversations_and_messages: the shares limit (100 a
-- day) became the messages limit (300 a day, SECURITY DEFINER because a
-- sender cannot read all of their own messages); one report per reporter,
-- reported user and target (reports_reporter_reported_target_key); a block no
-- longer deletes messages, so the "reports lose their share" collision case
-- now unsends the two reported messages. Removed: none.
-- 20261030030600: an unverified report (about a person, with what the reporter
-- saw of a gone item) is one per content too; one reporter files at most 3
-- profile reports about one person in 24 hours (QR001), and the queue counts
-- the different people who reported someone (reporters_against_user).
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(75);

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

-- Target n (1-90): an email user with the profile target_00n.
create function tests.target(n int) returns uuid language sql immutable as $$
  select ('10000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- Everything a client can learn from a failed statement, as one string.
create function tests.error_of(statement text) returns text language plpgsql as $$
declare
  v_state text; v_message text; v_detail text; v_hint text;
  v_constraint text; v_table text; v_schema text; v_column text;
begin
  execute statement;
  return 'no error';
exception when others then
  get stacked diagnostics
    v_state = returned_sqlstate, v_message = message_text, v_detail = pg_exception_detail,
    v_hint = pg_exception_hint, v_constraint = constraint_name, v_table = table_name,
    v_schema = schema_name, v_column = column_name;
  return concat_ws(' | ', nullif(v_state, ''), nullif(v_message, ''), nullif(v_detail, ''), nullif(v_hint, ''),
                   nullif(v_constraint, ''), nullif(v_schema, ''), nullif(v_table, ''), nullif(v_column, ''));
end
$$;
-- ---------------------------------------------------------------------------

select tests.create_user(tests.uid(w), w || '@test.quoted.invalid') from unnest(array['a', 'b', 'c', 'd']) w;
select tests.create_user(tests.target(n), 'target' || n || '@test.quoted.invalid') from generate_series(1, 90) n;
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.profiles (id, username)
select tests.target(n), 'target_' || lpad(n::text, 3, '0') from generate_series(1, 90) n;
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd']) w;
-- A is friends with B (messages) and with C (C's reports), with a
-- conversation each.
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'),
  (tests.uid('a'), tests.uid('c'), 'accepted');
insert into public.conversations (id, user_a, user_b) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), tests.uid('b')),
  ('c0a00000-0000-4000-8000-0000000000ac', tests.uid('a'), tests.uid('c'));
insert into public.conversation_members (conversation_id, user_id) values
  ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('a')), ('c0a00000-0000-4000-8000-0000000000ab', tests.uid('b')),
  ('c0a00000-0000-4000-8000-0000000000ac', tests.uid('a')), ('c0a00000-0000-4000-8000-0000000000ac', tests.uid('c'));

-- ---- schema ---------------------------------------------------------------
select results_eq(
  -- One line each, with the report key's unit separators (chr(31)) spelled <US>.
  $$ select c.relname::text collate "default",
            regexp_replace(replace(pg_get_indexdef(c.oid), chr(31), '<US>'), '\s+', ' ', 'g') collate "default"
     from pg_class c
     where c.relname in ('friendships_requester_id_created_at_idx', 'messages_sender_id_created_at_idx',
                         'reports_reporter_id_created_at_idx', 'reports_reporter_reported_target_key',
                         'quotes_owner_id_created_at_idx')
     order by 1 $$,
  $$ values
       ('friendships_requester_id_created_at_idx',
        'CREATE INDEX friendships_requester_id_created_at_idx ON public.friendships USING btree (requester_id, created_at)'),
       ('messages_sender_id_created_at_idx',
        'CREATE INDEX messages_sender_id_created_at_idx ON public.messages USING btree (sender_id, created_at)'),
       ('quotes_owner_id_created_at_idx',
        'CREATE INDEX quotes_owner_id_created_at_idx ON public.quotes USING btree (owner_id, created_at DESC)'),
       ('reports_reporter_id_created_at_idx',
        'CREATE INDEX reports_reporter_id_created_at_idx ON public.reports USING btree (reporter_id, created_at)'),
       ('reports_reporter_reported_target_key',
        'CREATE UNIQUE INDEX reports_reporter_reported_target_key ON public.reports USING btree (reporter_id, reported_user_id, message_id, post_id, playlist_id, starter_quote_id, ( CASE WHEN content_verified THEN NULL::text ELSE md5(((((((COALESCE(content_body, ''''::text) || ''<US>''::text) || COALESCE(content_author, ''''::text)) || ''<US>''::text) || COALESCE(content_source, ''''::text)) || ''<US>''::text) || COALESCE(content_note, ''''::text))) END)) NULLS NOT DISTINCT WHERE ((reporter_id IS NOT NULL) AND ((reported_user_id IS NOT NULL) OR (starter_quote_id IS NOT NULL)) AND ((message_id IS NOT NULL) OR (post_id IS NOT NULL) OR (playlist_id IS NOT NULL) OR (starter_quote_id IS NOT NULL) OR (NOT content_verified)))') $$,
  'the limit counts and the duplicate-report rule have their indexes'
);

select is_empty(
  $$ select relname from pg_class
     where relname in ('friendships_requester_id_idx', 'shares_sender_id_idx', 'reports_reporter_id_idx') $$,
  'the single-column indexes the composite ones replace are gone'
);

select results_eq(
  $$ select c.relname::text collate "default", t.tgname::text collate "default", p.prosecdef
     from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_proc p on p.oid = t.tgfoid
     where t.tgname in ('quotes_enforce_limit', 'friendships_enforce_limits', 'messages_enforce_limit',
                        'reports_enforce_limit', 'events_enforce_limit')
     order by 1 $$,
  $$ values
       ('events', 'events_enforce_limit', true),
       ('friendships', 'friendships_enforce_limits', false),
       ('messages', 'messages_enforce_limit', true),
       ('quotes', 'quotes_enforce_limit', false),
       ('reports', 'reports_enforce_limit', false) $$,
  'every limit is a BEFORE INSERT trigger; only the events and messages counters need definer rights'
);

select results_eq(
  $$ select has_table_privilege('anon', 'private.event_rate_limits', 'select'),
            has_table_privilege('authenticated', 'private.event_rate_limits', 'select'),
            has_table_privilege('authenticated', 'private.event_rate_limits', 'insert'),
            has_table_privilege('service_role', 'private.event_rate_limits', 'select') $$,
  $$ values (false, false, false, false) $$,
  'no API role can read or write the event counters'
);

-- ---- quotes: 5000 per owner (QR002) ---------------------------------------
-- 4998 quotes for A, written by the table owner (the trigger counts them too).
insert into public.quotes (owner_id, body)
select tests.uid('a'), 'Quote ' || n from generate_series(1, 4998) n;
insert into public.quotes (id, owner_id, body)
values ('a0000000-0000-4000-8000-000000000001', tests.uid('a'), 'Kept for the retry test');

select tests.authenticate_as('a');

select throws_ok(
  $$ insert into public.quotes (body) values ('one'), ('two') $$,
  'QR002', 'You can keep at most 5000 quotes.',
  'a bulk insert that would pass 5000 quotes fails on the row past the limit'
);

select is(
  (select count(*)::int from public.quotes),
  4999,
  'the failed bulk insert added nothing'
);

select lives_ok(
  $$ insert into public.quotes (body) values ('the 5000th') $$,
  'A can save their 5000th quote'
);

select throws_ok(
  $$ insert into public.quotes (body) values ('the 5001st') $$,
  'QR002', 'You can keep at most 5000 quotes.',
  'the 5001st quote is refused with QR002'
);

select throws_ok(
  $$ insert into public.quotes (id, body) values ('a0000000-0000-4000-8000-000000000001', 'retry') $$,
  '23505', null,
  'at the limit, a retried insert of an existing quote still fails on the primary key, not the limit'
);

select results_eq(
  $$ insert into public.quotes (id, body) values ('a0000000-0000-4000-8000-000000000001', 'Edited by upsert')
     on conflict (id) do update set body = excluded.body
     returning body $$,
  $$ values ('Edited by upsert') $$,
  'at the limit, an upsert of an existing quote adds nothing and is allowed'
);

select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.quotes (body) values ('B is not affected') $$,
  'another user can still save quotes'
);

-- ---- friend requests: 20 a day (QR001) ------------------------------------
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.friendships (addressee_id) select tests.target(n) from generate_series(1, 19) n $$,
  'D sends 19 requests in one statement'
);

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(20)) $$,
  'D can send their 20th request of the day'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(21)) $$,
  'QR001', 'You can send at most 20 friend requests a day.',
  'the 21st request in 24 hours is refused with QR001'
);

select tests.clear_authentication();
update public.friendships set created_at = now() - interval '25 hours' where requester_id = tests.uid('d');
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(21)) $$,
  'the window rolls: requests older than 24 hours no longer count'
);

-- ---- friend requests: 50 pending (QR001) ----------------------------------
-- 28 more pending requests from two days ago: 49 pending in all, 1 today.
-- The limit applies to the table owner too, so they go in below the daily
-- limit and are backdated in between.
select tests.clear_authentication();
insert into public.friendships (requester_id, addressee_id)
select tests.uid('d'), tests.target(n) from generate_series(22, 40) n;
update public.friendships set created_at = now() - interval '2 days'
 where requester_id = tests.uid('d') and addressee_id <> tests.target(21);
insert into public.friendships (requester_id, addressee_id)
select tests.uid('d'), tests.target(n) from generate_series(41, 49) n;
update public.friendships set created_at = now() - interval '2 days'
 where requester_id = tests.uid('d') and addressee_id <> tests.target(21);
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(50)) $$,
  'D can have 50 requests waiting'
);

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(51)) $$,
  'QR001', 'You can have at most 50 friend requests waiting for an answer.',
  'a 51st pending request is refused with QR001'
);

select tests.clear_authentication();
update public.friendships set status = 'accepted' where requester_id = tests.uid('d') and addressee_id = tests.target(1);
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(51)) $$,
  'an accepted request frees a pending slot'
);

-- ---- a blocked pair fails like an unknown user (23503) ----------------------
-- C has sent no requests, so no limit is involved. Target 52 blocks C; C
-- blocks target 53; target 54 has nothing to do with C.
select tests.clear_authentication();
insert into public.blocks (blocker_id, blocked_id) values
  (tests.target(52), tests.uid('c')), (tests.uid('c'), tests.target(53));
select tests.authenticate_as('c');

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values ('99999999-9999-4999-8999-999999999999') $$),
  '23503 | insert or update on table "friendships" violates foreign key constraint "friendships_addressee_id_fkey" | Key is not present in table "profiles". | friendships_addressee_id_fkey | public | friendships',
  'a request to an unknown user id fails on friendships_addressee_id_fkey'
);

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.target(52)) $$),
  tests.error_of($$ insert into public.friendships (addressee_id) values ('99999999-9999-4999-8999-999999999999') $$),
  'a request to someone who blocked you fails exactly like one to an unknown user'
);

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.target(53)) $$),
  tests.error_of($$ insert into public.friendships (addressee_id) values ('99999999-9999-4999-8999-999999999999') $$),
  'a request to someone you blocked fails the same way'
);

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(54)) $$,
  'C can still send a request to anyone else'
);

-- ---- messages: 300 a day (QR001) ------------------------------------------
select tests.clear_authentication();
insert into public.messages (conversation_id, sender_id, kind, text)
select 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'text', 'Message ' || n from generate_series(1, 298) n;
insert into public.messages (id, conversation_id, sender_id, kind, text)
values ('5a000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ab', tests.uid('a'), 'text', 'Message 299');
-- A cleared the conversation, so A no longer reads those messages; they count all the same.
update public.conversation_members set cleared_at = now()
 where conversation_id = 'c0a00000-0000-4000-8000-0000000000ab' and user_id = tests.uid('a');
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values ('c0a00000-0000-4000-8000-0000000000ab', 'text', 'Message 300') $$,
  'A can send their 300th message of the day'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values ('c0a00000-0000-4000-8000-0000000000ab', 'text', 'Message 301') $$,
  'QR001', 'You can send at most 300 messages a day.',
  'the 301st message in 24 hours is refused with QR001, though A cleared the ones before'
);

select throws_ok(
  $$ insert into public.messages (id, conversation_id, kind, text)
     values ('5a000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ab', 'text', 'retry') $$,
  '23505', null,
  'at the limit, a retried insert of an existing message still fails on the primary key, not the limit'
);

select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values ('c0a00000-0000-4000-8000-0000000000ab', 'text', 'B to A') $$,
  'the recipient is not limited by the sender''s messages'
);

select tests.clear_authentication();
update public.messages set created_at = now() - interval '25 hours' where sender_id = tests.uid('a');
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.messages (conversation_id, kind, text) values ('c0a00000-0000-4000-8000-0000000000ab', 'text', 'Next day') $$,
  'the window rolls: messages older than 24 hours no longer count'
);

-- ---- reports: 20 a day (QR001) --------------------------------------------
select tests.clear_authentication();
insert into public.reports (reporter_id, reported_user_id, reason)
select tests.uid('b'), tests.target(n), 'spam' from generate_series(61, 79) n;
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.target(80), 'spam') $$,
  'B can file their 20th report of the day'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.target(81), 'spam') $$,
  'QR001', 'You can send at most 20 reports a day.',
  'the 21st report in 24 hours is refused with QR001'
);

select tests.clear_authentication();
update public.reports set created_at = now() - interval '25 hours' where reporter_id = tests.uid('b');
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.target(81), 'spam') $$,
  'the window rolls: reports older than 24 hours no longer count'
);

-- ---- reports: no duplicates (23505) ---------------------------------------
select tests.clear_authentication();
insert into public.messages (id, conversation_id, sender_id, kind, text) values
  ('5c000000-0000-4000-8000-000000000001', 'c0a00000-0000-4000-8000-0000000000ac', tests.uid('a'), 'text', 'A to C, one'),
  ('5c000000-0000-4000-8000-000000000002', 'c0a00000-0000-4000-8000-0000000000ac', tests.uid('a'), 'text', 'A to C, two');
select tests.authenticate_as('c');

select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5c000000-0000-4000-8000-000000000001', tests.uid('a'), 'spam') $$,
  'C reports a message from A'
);

select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5c000000-0000-4000-8000-000000000001', tests.uid('a'), 'harassment') $$,
  '23505', 'duplicate key value violates unique constraint "reports_reporter_reported_target_key"',
  'a second report on the same message is a duplicate (whatever the reason)'
);

select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason)
     values ('5c000000-0000-4000-8000-000000000002', tests.uid('a'), 'spam') $$,
  'C can report another message from A'
);

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'other') $$,
  'C can also report A without a target'
);

select throws_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'spam') $$,
  '23505', 'duplicate key value violates unique constraint "reports_reporter_reported_target_key"',
  'a second report about A without a target is a duplicate (NULLS NOT DISTINCT)'
);

-- When the item itself is gone (unsent, deleted), the app reports the person
-- with what it showed: each gone item is its own report.
select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_body, content_note)
     values (tests.uid('a'), 'harassment', 'Abusive quote X', 'Note X') $$,
  'C reports A with what C saw of a message A unsent'
);
select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_body, content_note)
     values (tests.uid('a'), 'spam', 'Abusive quote X', 'Note X') $$,
  '23505', 'duplicate key value violates unique constraint "reports_reporter_reported_target_key"',
  'the same content again is a duplicate (whatever the reason)'
);
select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_body, content_note)
     values (tests.uid('a'), 'harassment', 'Abusive quote Y', 'Note X') $$,
  'and again with what C saw of another one: a different report (C''s third profile report about A)'
);
-- That content is the reporter's own, so varying it would let one account
-- file every report of its day about one person: at most 3 profile reports
-- per reporter and person in 24 hours. C's two message reports about A do
-- not count.
select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_body, content_note)
     values (tests.uid('a'), 'harassment', 'Abusive quote Z', 'Note Z') $$,
  'QR001', 'You can report the same person at most 3 times a day.',
  'a fourth profile report about the same person in 24 hours is refused with QR001, whatever its content'
);

select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.uid('a'), 'other') $$,
  'another reporter can still report A'
);

select tests.clear_authentication();

select results_eq(
  $$ select distinct reports_against_user::int, reporters_against_user::int
     from private.reports_to_review where reported_user_id = tests.uid('a') $$,
  $$ values (6, 2) $$,
  'the queue shows A''s six reports and that they come from two people'
);

-- A unsends both messages, so both message reports get message_id = null
-- next to the user report: they must not collide.
select tests.authenticate_as('a');

select lives_ok(
  $$ delete from public.messages where id in ('5c000000-0000-4000-8000-000000000001', '5c000000-0000-4000-8000-000000000002') $$,
  'A can unsend two messages after C reported both of them and A'
);

select tests.clear_authentication();

select results_eq(
  $$ select count(*)::int, count(*) filter (where message_id is null)::int, count(*) filter (where content_verified)::int
     from public.reports where reporter_id = tests.uid('c') and reported_user_id = tests.uid('a') $$,
  $$ values (5, 5, 2) $$,
  'after the unsend all five reports remain, the two verified ones without their message'
);

select lives_ok(
  $$ delete from auth.users where id in (tests.target(61), tests.target(62)) $$,
  'deleting two users B reported (their ids become null in B''s reports) does not collide'
);

select lives_ok(
  $$ delete from auth.users where id = tests.uid('c') $$,
  'deleting a reporter with several reports about one user does not collide'
);

select is(
  (select count(*)::int from public.reports where reporter_id is null and reported_user_id = tests.uid('a')),
  5,
  'C''s reports are kept without C''s id'
);

-- ---- reports: 3 a day about one person (QR001) ---------------------------
-- D and target 88 are strangers: no friendship, no conversation, nothing
-- posted. A direct API insert can invent the content of a profile report.
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.target(88), 'spam', 'n1') $$,
  'D reports a stranger with invented content'
);
select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.target(88), 'spam', 'n2') $$,
  'D reports the stranger again with other invented content'
);
select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.target(88), 'spam', 'n3') $$,
  'and a third time'
);
select throws_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.target(88), 'spam', 'n4') $$,
  'QR001', 'You can report the same person at most 3 times a day.',
  'the fourth report about the same stranger in 24 hours is refused with QR001'
);
select lives_ok(
  $$ insert into public.reports (reported_user_id, reason) values (tests.target(87), 'spam') $$,
  'the limit is per person: D can still report someone else'
);

select tests.clear_authentication();

select results_eq(
  $$ select count(*)::int, max(reports_against_user)::int, max(reporters_against_user)::int
     from private.reports_to_review where reported_user_id = tests.target(88) $$,
  $$ values (3, 3, 1) $$,
  'the queue holds D''s three reports about the stranger, from one reporter'
);

update public.reports set created_at = now() - interval '25 hours'
 where reporter_id = tests.uid('d') and reported_user_id = tests.target(88);
select tests.authenticate_as('d');

select lives_ok(
  $$ insert into public.reports (reported_user_id, reason, content_note) values (tests.target(88), 'spam', 'n4') $$,
  'the window rolls: profile reports older than 24 hours no longer count'
);

select tests.clear_authentication();

-- ---- events: 30 an hour (QR001) -------------------------------------------
select tests.authenticate_as('a');

select lives_ok(
  $$ insert into public.events (name) select 'web_search_tap' from generate_series(1, 29) $$,
  'A logs 29 events in one statement'
);

select lives_ok(
  $$ insert into public.events (name) values ('web_search_tap') $$,
  'A can log their 30th event this hour'
);

select throws_ok(
  $$ insert into public.events (name) values ('web_search_tap') $$,
  'QR001', 'Too many events this hour.',
  'the 31st event this hour is refused with QR001'
);

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.events (name) select 'web_search_tap' from generate_series(1, 31) $$,
  'QR001', 'Too many events this hour.',
  'a bulk insert of 31 events fails'
);

-- D's counter from two hours ago is stale: B's next event clears it.
select tests.clear_authentication();
insert into private.event_rate_limits (user_id, window_start, event_count)
values (tests.uid('d'), date_trunc('hour', now()) - interval '2 hours', 7);
select tests.authenticate_as('b');

select lives_ok(
  $$ insert into public.events (name) values ('web_search_tap') $$,
  'after the failed bulk insert, B can still log an event'
);

select tests.clear_authentication();

select results_eq(
  $$ select user_id, event_count from private.event_rate_limits order by event_count desc $$,
  $$ values (tests.uid('a'), 30), (tests.uid('b'), 1) $$,
  'only this hour''s counters are kept: A at 30, B at 1, D''s stale counter is gone'
);

select is(
  (select max(window_start) = date_trunc('hour', now()) and min(window_start) = date_trunc('hour', now())
   from private.event_rate_limits),
  true,
  'every counter is for the current hour'
);

select tests.authenticate_as('a');

select throws_ok(
  $$ select * from private.event_rate_limits $$,
  '42501', null,
  'a client cannot read the event counters'
);

-- The table owner (no user id) is not limited.
select tests.clear_authentication();

select lives_ok(
  $$ insert into public.events (name) select 'web_search_tap' from generate_series(1, 40) $$,
  'server-side inserts without a user are not counted'
);

-- ---- limits apply per actor, also through the secret key ------------------
set local role service_role;

select throws_ok(
  $$ insert into public.quotes (owner_id, body) values (tests.uid('a'), 'via secret key') $$,
  'QR002', 'You can keep at most 5000 quotes.',
  'the quote limit applies to the secret key too'
);

select lives_ok(
  $$ insert into public.quotes (owner_id, body) values (tests.uid('b'), 'via secret key') $$,
  'the secret key can write for an account under the limit'
);

select tests.clear_authentication();

-- ---- deleted rows free their slot ------------------------------------------
select tests.authenticate_as('d');

select throws_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(55)) $$,
  'QR001', 'You can have at most 50 friend requests waiting for an answer.',
  'D is at 50 pending again'
);

select lives_ok(
  $$ delete from public.friendships where requester_id = tests.uid('d') and addressee_id = tests.target(50) $$,
  'D cancels one request'
);

select lives_ok(
  $$ insert into public.friendships (addressee_id) values (tests.target(55)) $$,
  'a cancelled request frees its pending slot'
);

-- ---- the limits do not leak other people's rows ---------------------------
select tests.clear_authentication();

select results_eq(
  $$ select (select count(*)::int from public.quotes where owner_id = tests.uid('a')),
            (select count(*)::int from public.quotes where owner_id = tests.uid('b')) $$,
  $$ values (5000, 2) $$,
  'A ends at exactly 5000 quotes; B has 2'
);

select results_eq(
  $$ select count(*)::int from public.friendships where requester_id = tests.uid('d') and status = 'pending' $$,
  $$ values (50) $$,
  'D ends at exactly 50 pending requests'
);

select results_eq(
  $$ select count(*)::int from public.messages where sender_id = tests.uid('a') and created_at > now() - interval '24 hours' $$,
  $$ values (1) $$,
  'A has one message in the current window'
);

select results_eq(
  $$ select count(*)::int from public.reports
     where reporter_id = tests.uid('b') and created_at > now() - interval '24 hours' $$,
  $$ values (2) $$,
  'B has two reports in the current window'
);

-- ---- messages a client sees ------------------------------------------------
select tests.authenticate_as('a');

select is(
  tests.error_of($$ insert into public.quotes (body) values ('over') $$),
  'QR002 | You can keep at most 5000 quotes. | Delete some quotes to add new ones.',
  'QR002 carries a short message and hint'
);

select tests.authenticate_as('d');

select is(
  tests.error_of($$ insert into public.friendships (addressee_id) values (tests.target(56)) $$),
  'QR001 | You can have at most 50 friend requests waiting for an answer. | Cancel some requests or wait for answers.',
  'QR001 carries a short message and hint'
);

select tests.clear_authentication();

select results_eq(
  $$ select p.proname::text collate "default", p.provolatile::text collate "default"
     from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname in ('quotes_enforce_limit', 'friendships_enforce_limits', 'messages_enforce_limit',
                         'reports_enforce_limit', 'events_enforce_limit')
     order by 1 $$,
  $$ values ('events_enforce_limit', 'v'), ('friendships_enforce_limits', 'v'), ('messages_enforce_limit', 'v'),
            ('quotes_enforce_limit', 'v'), ('reports_enforce_limit', 'v') $$,
  'the limit triggers are VOLATILE, so they see earlier rows of the same bulk insert'
);

select is_empty(
  $$ select p.proname from pg_proc p
     where p.pronamespace = 'private'::regnamespace
       and p.proname like '%enforce_limit%'
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')) $$,
  'clients cannot execute the limit trigger functions'
);

select * from finish();
rollback;
