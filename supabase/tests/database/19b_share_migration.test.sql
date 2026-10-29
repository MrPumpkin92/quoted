-- The move of shares into messages (supabase/migrations/20261029090300_conversations_and_messages.sql,
-- private.move_shares_to_messages). The migration runs the move once, before
-- it drops public.shares and reports.share_id, and then drops the function,
-- and every test file runs after the migrations. So this file recreates those
-- two exactly as they were (the columns the move reads) and a verbatim copy of
-- the function, fills them with realistic rows as postgres, and runs it: one
-- conversation per pair (closed unless the pair are friends now), both member
-- rows with last_read_at from the latest seen_at, one quote message per share
-- with the same id, time, note, snapshot and verification, the creator only
-- for the sender's own typed quote, last_message_at, reports.message_id, a
-- sender with more than 300 shares over several days, and a second run that
-- changes nothing.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(28);

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

create function tests.sid(n int) returns uuid language sql immutable as $$
  select ('5a000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

create function tests.pair(x text, y text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid(x), tests.uid(y)) and c.user_b = greatest(tests.uid(x), tests.uid(y))
$$;
-- ---------------------------------------------------------------------------

-- What 20261029090300 drops, as it was (the columns the move reads). The old
-- triggers are not needed: these rows are written as the server wrote them.
create table public.shares (
  id uuid primary key,
  sender_id uuid not null references public.profiles (id),
  recipient_id uuid not null references public.profiles (id),
  quote_id uuid references public.quotes (id) on delete set null,
  body text not null,
  body_format jsonb not null default '[]'::jsonb,
  author text,
  source text,
  note text,
  created_at timestamptz not null,
  seen_at timestamptz,
  saved_at timestamptz,
  verified_starter_id smallint
);
alter table public.reports add column share_id uuid;

-- The migration runs private.move_shares_to_messages once and then drops it
-- (it can only fail once public.shares is gone). This is a verbatim copy of
-- it from 20261029090300_conversations_and_messages; keep the two identical.
select is_empty(
  $$ select 1 from pg_proc where pronamespace = 'private'::regnamespace and proname = 'move_shares_to_messages' $$,
  'the migration leaves no move function behind (it could only fail once shares is gone)'
);
create function private.move_shares_to_messages()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_share record;
  v_moved integer := 0;
begin
  insert into public.conversations (user_a, user_b, closed_at)
  select pair.user_a, pair.user_b,
         case when exists (
                select 1 from public.friendships f
                where f.status = 'accepted'
                  and least(f.requester_id, f.addressee_id) = pair.user_a
                  and greatest(f.requester_id, f.addressee_id) = pair.user_b
              ) then null else now() end
  from (
    select distinct least(s.sender_id, s.recipient_id) as user_a, greatest(s.sender_id, s.recipient_id) as user_b
    from public.shares s
  ) pair
  on conflict on constraint conversations_pair_key do nothing;

  insert into public.conversation_members as cm (conversation_id, user_id, last_read_at)
  select c.id, mem.user_id,
         (select max(s.seen_at)
            from public.shares s
           where s.recipient_id = mem.user_id
             and s.sender_id = case when mem.user_id = c.user_a then c.user_b else c.user_a end)
  from public.conversations c
  cross join lateral (values (c.user_a), (c.user_b)) mem (user_id)
  where exists (
    select 1 from public.shares s
    where least(s.sender_id, s.recipient_id) = c.user_a
      and greatest(s.sender_id, s.recipient_id) = c.user_b
  )
  on conflict on constraint conversation_members_pkey do update
    set last_read_at = greatest(cm.last_read_at, excluded.last_read_at);

  for v_share in
    select s.id, s.sender_id, s.created_at, s.note, s.body, s.body_format, s.author, s.source,
           c.id as conversation_id,
           q.id as sender_quote_id,
           q.origin as sender_quote_origin,
           p.username as sender_username
    from public.shares s
    join public.conversations c
      on c.user_a = least(s.sender_id, s.recipient_id) and c.user_b = greatest(s.sender_id, s.recipient_id)
    join public.profiles p on p.id = s.sender_id
    left join public.quotes q on q.id = s.quote_id and q.owner_id = s.sender_id
    where not exists (select 1 from public.messages m where m.id = s.id)
    order by s.created_at, s.id
  loop
    insert into public.messages (
      id, conversation_id, sender_id, kind, note, body, body_format, author, source,
      creator_id, creator_username, source_quote_id
    )
    values (
      v_share.id, v_share.conversation_id, v_share.sender_id, 'quote', v_share.note,
      v_share.body, v_share.body_format, v_share.author, v_share.source,
      case when v_share.sender_quote_origin in ('manual', 'pasted') then v_share.sender_id end,
      case when v_share.sender_quote_origin in ('manual', 'pasted') then v_share.sender_username end,
      v_share.sender_quote_id
    );
    update public.messages m set created_at = v_share.created_at where m.id = v_share.id;
    v_moved := v_moved + 1;
  end loop;

  update public.conversations c
     set last_message_at = x.last_at,
         created_at = least(c.created_at, x.first_at)
    from (
      select m.conversation_id, max(m.created_at) as last_at, min(m.created_at) as first_at
      from public.messages m
      group by m.conversation_id
    ) x
   where x.conversation_id = c.id
     and exists (
       select 1 from public.shares s
       where least(s.sender_id, s.recipient_id) = c.user_a
         and greatest(s.sender_id, s.recipient_id) = c.user_b
     );

  update public.reports r
     set message_id = r.share_id
   where r.share_id is not null
     and r.message_id is null
     and exists (select 1 from public.messages m where m.id = r.share_id);

  return v_moved;
end;
$$;
revoke all on function private.move_shares_to_messages() from public, anon, authenticated, service_role;

-- A and B are friends. A and C were friends (C unfriended A). D is friends
-- with A and sent A more than 300 shares over five days.
select tests.create_user(w) from unnest(array['a', 'b', 'c', 'd']) w;
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('d'), tests.uid('a'), 'accepted');
-- A's quotes: 1 typed (manual), 2 saved from a friend (shared), 3 pasted. B's 10.
insert into public.quotes (id, owner_id, body, origin) values
  (tests.qid(1), tests.uid('a'), 'Typed by Alice', 'manual'),
  (tests.qid(2), tests.uid('a'), 'Saved by Alice', 'shared'),
  (tests.qid(3), tests.uid('a'), 'Pasted by Alice', 'pasted'),
  (tests.qid(10), tests.uid('b'), 'Bob''s own', 'manual');
insert into private.blocked_terms (term) values ('darn');
update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
 where id = tests.uid('c');

insert into public.shares (id, sender_id, recipient_id, quote_id, body, body_format, author, source, note,
                           created_at, seen_at, verified_starter_id) values
  -- A to B: seen in order; B's latest seen_at is 2 days ago.
  (tests.sid(1), tests.uid('a'), tests.uid('b'), tests.qid(1), 'Typed by Alice', '[{"start":0,"length":5,"bold":true}]',
   'Ann', 'Notebook', 'for you', now() - interval '6 days', now() - interval '5 days', null),
  (tests.sid(2), tests.uid('a'), tests.uid('b'), tests.qid(2), 'Saved by Alice', '[]', null, null, null,
   now() - interval '4 days', now() - interval '2 days', null),
  (tests.sid(3), tests.uid('a'), tests.uid('b'), null, 'No quote row any more', '[]', null, null, null,
   now() - interval '3 days', null, null),
  -- A shared B's quote id (the old policy refused this; the server is careful anyway).
  (tests.sid(4), tests.uid('a'), tests.uid('b'), tests.qid(10), 'Bob''s own', '[]', null, null, null,
   now() - interval '1 day', null, null),
  -- B to A: one seen, one not.
  (tests.sid(5), tests.uid('b'), tests.uid('a'), null, 'From Bob', '[]', null, null, null,
   now() - interval '5 days', now() - interval '3 days', null),
  (tests.sid(6), tests.uid('b'), tests.uid('a'), null, 'Darn, from Bob', '[]', null, null, 'unfiltered',
   now() - interval '2 hours', null, null),
  -- A to C: a pasted quote, and a catalog quote's exact wording; C to A: a
  -- share that claimed verification without matching the catalog.
  (tests.sid(7), tests.uid('a'), tests.uid('c'), tests.qid(3), 'Pasted by Alice', '[]', null, null, null,
   now() - interval '10 days', null, null),
  (tests.sid(9), tests.uid('c'), tests.uid('a'), null, 'Not a catalog quote', '[]', 'Someone', null, null,
   now() - interval '8 days', now() - interval '7 days', 1);
insert into public.shares (id, sender_id, recipient_id, body, author, source, created_at, verified_starter_id)
select tests.sid(8), tests.uid('a'), tests.uid('c'), s.body, s.author, s.source, now() - interval '9 days', s.id
from public.starter_quotes s where s.id = 1;
-- D to A: 320 shares, 64 a day over five days (the old limit was 100 a day).
insert into public.shares (id, sender_id, recipient_id, body, created_at)
select tests.sid(1000 + n), tests.uid('d'), tests.uid('a'), 'D share ' || n,
       now() - interval '5 days' + make_interval(mins => n * 22)
from generate_series(1, 320) n;

-- Reports as the old trigger left them: B on share 1 (verified copy), A on a
-- share that had already been deleted (share_id still set by the client).
insert into public.reports (id, reporter_id, reported_user_id, reason, content_body, share_id) values
  ('7e000000-0000-4000-8000-000000000001', tests.uid('b'), tests.uid('a'), 'spam', 'Typed by Alice', tests.sid(1)),
  ('7e000000-0000-4000-8000-000000000002', tests.uid('a'), tests.uid('c'), 'other', 'Gone', tests.sid(99));
update public.reports set content_verified = true where id = '7e000000-0000-4000-8000-000000000001';

-- ---- the move ---------------------------------------------------------------------
select is(private.move_shares_to_messages(), 329, 'every share is moved');

select results_eq(
  $$ select (select count(*)::int from public.conversations),
            (select count(*)::int from public.conversation_members),
            (select count(*)::int from public.messages) $$,
  $$ values (3, 6, 329) $$,
  'one conversation per pair, two member rows each, one message per share'
);
select results_eq(
  $$ select tests.pair('a', 'b') is not null, (select closed_at from public.conversations where id = tests.pair('a', 'b')),
            (select closed_at = now() from public.conversations where id = tests.pair('a', 'c')),
            (select closed_at from public.conversations where id = tests.pair('a', 'd')) $$,
  $$ values (true, null::timestamptz, true, null::timestamptz) $$,
  'friends now get an open conversation; A and C, no longer friends, a closed one'
);
select results_eq(
  $$ select user_id, last_read_at from public.conversation_members
     where conversation_id = tests.pair('a', 'b') order by user_id $$,
  $$ values (tests.uid('a'), now() - interval '3 days'), (tests.uid('b'), now() - interval '2 days') $$,
  'each member''s last_read_at is the latest seen_at among the shares they received'
);
select results_eq(
  $$ select user_id, last_read_at from public.conversation_members
     where conversation_id = tests.pair('a', 'c') order by user_id $$,
  $$ values (tests.uid('a'), now() - interval '7 days'), (tests.uid('c'), null::timestamptz) $$,
  'someone who never saw a share has no read mark'
);
select results_eq(
  $$ select m.id, m.conversation_id, m.sender_id, m.kind, m.note, m.body, m.body_format, m.author, m.source,
            m.created_at, m.text, m.playlist_id
     from public.messages m where m.id = tests.sid(1) $$,
  $$ values (tests.sid(1), tests.pair('a', 'b'), tests.uid('a'), 'quote'::text, 'for you'::text, 'Typed by Alice'::text,
             '[{"start":0,"length":5,"bold":true}]'::jsonb, 'Ann'::text, 'Notebook'::text, now() - interval '6 days',
             null::text, null::uuid) $$,
  'a share becomes a quote message with the same id, time, note and snapshot'
);
select results_eq(
  $$ select m.id, m.creator_id, m.creator_username, m.source_quote_id, m.edited_from_id
     from public.messages m where m.id in (tests.sid(1), tests.sid(2), tests.sid(3), tests.sid(4), tests.sid(7))
     order by m.id $$,
  $$ values (tests.sid(1), tests.uid('a'), 'alice'::text, tests.qid(1), null::uuid),
            (tests.sid(2), null, null, tests.qid(2), null),
            (tests.sid(3), null, null, null, null),
            (tests.sid(4), null, null, null, null),
            (tests.sid(7), tests.uid('a'), 'alice', tests.qid(3), null) $$,
  'the sender is the creator only of their own manual or pasted quote; a quote that is not theirs is not linked'
);
select results_eq(
  $$ select m.id, m.verified_starter_id, m.creator_id from public.messages m
     where m.id in (tests.sid(8), tests.sid(9)) order by m.id $$,
  $$ values (tests.sid(8), 1::smallint, null::uuid), (tests.sid(9), null::smallint, null::uuid) $$,
  'verification is recomputed from the wording: the catalog copy stays verified, a false claim does not'
);
select results_eq(
  $$ select body, note from public.messages where id = tests.sid(6) $$,
  $$ values ('Darn, from Bob'::text, 'unfiltered'::text) $$,
  'old shares are moved as they were: the word filter applies to new writes only'
);
select results_eq(
  $$ select last_message_at, created_at from public.conversations where id = tests.pair('a', 'b') $$,
  $$ values (now() - interval '2 hours', now() - interval '6 days') $$,
  'the conversation''s last_message_at and created_at come from its messages'
);
select results_eq(
  $$ select count(*)::int, min(created_at) = now() - interval '5 days' + interval '22 minutes',
            max(created_at) = now() - interval '5 days' + interval '7040 minutes'
     from public.messages where sender_id = tests.uid('d') $$,
  $$ values (320, true, true) $$,
  'all 320 of D''s shares moved with their own times: the 300-a-day limit counts real times'
);
select results_eq(
  $$ select id::text collate "default", message_id, content_body, content_verified from public.reports
     where id::text like '7e000000-%' order by id $$,
  $$ values ('7e000000-0000-4000-8000-000000000001', tests.sid(1), 'Typed by Alice'::text, true),
            ('7e000000-0000-4000-8000-000000000002', null::uuid, 'Gone', false) $$,
  'reports.share_id becomes message_id where the message exists; snapshots stay as they were'
);
select is_empty(
  $$ select 1 from private.message_tombstones $$,
  'moving leaves no tombstone'
);

-- ---- a second run changes nothing ----------------------------------------------------
create table tests.before as
  select (select jsonb_agg(m order by m.id) from public.messages m) as messages,
         (select jsonb_agg(c order by c.id) from public.conversations c) as conversations,
         (select jsonb_agg(cm order by cm.conversation_id, cm.user_id) from public.conversation_members cm) as members;
select is(private.move_shares_to_messages(), 0, 'a second run moves nothing');
select results_eq(
  $$ select (select jsonb_agg(m order by m.id) from public.messages m) = b.messages,
            (select jsonb_agg(c order by c.id) from public.conversations c) = b.conversations,
            (select jsonb_agg(cm order by cm.conversation_id, cm.user_id) from public.conversation_members cm) = b.members
     from tests.before b $$,
  $$ values (true, true, true) $$,
  'and leaves every row as it was'
);

-- ---- the moved conversations work like any other -------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select id from public.messages order by created_at, id $$,
  $$ values (tests.sid(5)), (tests.sid(2)), (tests.sid(3)), (tests.sid(4)), (tests.sid(6)) $$,
  'B reads the moved messages of A and B''s conversation and no others; share 1, which B reported, stays hidden from B'
);
select results_eq(
  $$ select other_username, is_closed, last_message_preview, unread_count from public.inbox_conversations() $$,
  $$ values ('alice'::text, false, 'Darn, from Bob'::text, 1) $$,
  'B''s Inbox counts what A sent after B''s last seen share as unread'
);
select throws_ok(
  $$ select source_quote_id from public.messages $$,
  '42501', null,
  'B cannot read the link to A''s quote'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select other_username, is_closed, unread_count from public.inbox_conversations() order by other_username $$,
  $$ values ('bob'::text, false, 1), ('cara', true, 0), ('dan', false, 320) $$,
  'A''s Inbox: B''s unseen share is unread, the conversation with C is closed'
);
select results_eq(
  $$ select creator_username, origin from public.save_from_message(tests.sid(1)) $$,
  $$ values ('alice'::text, 'shared'::text) $$,
  'a moved quote can be saved like any message (here by its own sender)'
);
select tests.authenticate_as('c');
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, text) values (tests.pair('a', 'c'), 'text', 'Hi again') $$,
  '42501', 'This conversation is closed.',
  'C reads the closed conversation but cannot send'
);
select results_eq(
  $$ select count(*)::int from public.messages $$,
  $$ values (3) $$,
  'C reads the three shares of A and C''s conversation'
);
select tests.authenticate_as('b');
select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.sid(2), tests.uid('a'), 'spam') $$,
  'B can report a moved message'
);
select throws_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.sid(1), tests.uid('a'), 'harassment') $$,
  '23505', null,
  'B''s moved report on share 1 still counts: a second report on that message is a duplicate'
);

-- ---- the rest of the migration runs after the move ------------------------------------
-- As 20261029090300 does next: run the deferred checks the move queued, then
-- drop reports.share_id and shares. ALTER TABLE refuses a table with pending
-- trigger events, so without the first step this fails on real data.
select tests.clear_authentication();
select lives_ok(
  $$ do $do$ begin set constraints all immediate; end $do$ $$,
  'the deferred foreign key checks the move queued all pass'
);
select lives_ok(
  $$ alter table public.reports drop column share_id $$,
  'so the migration can then drop reports.share_id'
);
select lives_ok(
  $$ drop table public.shares $$,
  'and the shares table'
);

select * from finish();
rollback;
