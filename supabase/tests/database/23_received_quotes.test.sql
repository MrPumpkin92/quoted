-- received_quotes (supabase/migrations/20261029090600_read_marks_reports_playlist_order.sql,
-- section 4): the quote messages other people sent the caller, across their
-- conversations, newest first (created_at desc, id), in keyset pages. It
-- returns what a direct read of messages returns under RLS, no more: never
-- the caller's own messages, text, or a conversation the caller is not in;
-- nothing before their "Delete Conversation", nothing they reported, nothing
-- from someone who blocked them. Its query starts from the caller's
-- conversation_members rows, so the messages index serves it (the plan has
-- no sequential scan of messages, even for a later page). For signed-in
-- users only.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(22);

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

create function tests.mid(n int) returns uuid language sql immutable as $$
  select ('3e000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- The conversation between two people, read with definer rights.
create function tests.cid(x text, y text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid(x), tests.uid(y)) and c.user_b = greatest(tests.uid(x), tests.uid(y))
$$;

-- The plan of received_quotes' own query (its body, with the arguments
-- written in), as the caller: a SQL function with SET search_path is not
-- inlined, so EXPLAIN of the call itself shows only a Function Scan.
create function tests.received_plan(p_after_created_at text, p_after_id text) returns setof text
language plpgsql as $$
declare
  v_sql text;
  v_row record;
begin
  select p.prosrc into v_sql from pg_proc p
   where p.oid = 'public.received_quotes(timestamptz, uuid, integer)'::regprocedure;
  v_sql := replace(v_sql, 'p_after_created_at', coalesce(quote_literal(p_after_created_at), 'null') || '::timestamptz');
  v_sql := replace(v_sql, 'p_after_id', coalesce(quote_literal(p_after_id), 'null') || '::uuid');
  v_sql := replace(v_sql, 'p_limit', '500');
  for v_row in execute 'explain (costs off) ' || v_sql loop
    return next v_row."QUERY PLAN";
  end loop;
end
$$;
-- ---------------------------------------------------------------------------

-- A is friends with B and C; B and C are friends too (A is not in their
-- conversation). D is nobody's friend.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid') from unnest(array['a', 'b', 'c', 'd']) w;
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara'), (tests.uid('d'), 'dan');
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd']) w;
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('c'), 'accepted'),
  (tests.uid('b'), tests.uid('c'), 'accepted');
select tests.authenticate_as('a');
select o.id from unnest(array['b', 'c']) w cross join lateral public.open_conversation(tests.uid(w)) o;
select tests.authenticate_as('b');
select id from public.open_conversation(tests.uid('c'));

-- B sends A two quotes and a text; C sends A a quote with a note; A sends B
-- a quote; B sends C a quote.
select tests.authenticate_as('b');
insert into public.messages (id, conversation_id, kind, starter_quote_id) values
  (tests.mid(1), tests.cid('a', 'b'), 'quote', 1);
insert into public.messages (id, conversation_id, kind, text) values
  (tests.mid(2), tests.cid('a', 'b'), 'text', 'Hi Alice');
insert into public.messages (id, conversation_id, kind, starter_quote_id) values
  (tests.mid(3), tests.cid('a', 'b'), 'quote', 2),
  (tests.mid(6), tests.cid('b', 'c'), 'quote', 1);
select tests.authenticate_as('c');
insert into public.messages (id, conversation_id, kind, starter_quote_id, note) values
  (tests.mid(4), tests.cid('a', 'c'), 'quote', 1, 'For you');
select tests.authenticate_as('a');
insert into public.messages (id, conversation_id, kind, starter_quote_id) values
  (tests.mid(5), tests.cid('a', 'b'), 'quote', 3);

-- Times in the past (the server stamped them now): m4 shares m1's time, so
-- the id breaks the tie.
select tests.clear_authentication();
update public.messages set created_at = case id
    when tests.mid(1) then now() - interval '5 hours'
    when tests.mid(2) then now() - interval '4 hours'
    when tests.mid(3) then now() - interval '3 hours'
    when tests.mid(4) then now() - interval '5 hours'
    when tests.mid(5) then now() - interval '2 hours'
    when tests.mid(6) then now() - interval '1 hour'
  end
 where id in (tests.mid(1), tests.mid(2), tests.mid(3), tests.mid(4), tests.mid(5), tests.mid(6));

-- ---- what it returns ---------------------------------------------------------
select tests.authenticate_as('a');

select results_eq(
  $$ select id, sender_id, kind, note from public.received_quotes() $$,
  $$ values (tests.mid(3), tests.uid('b'), 'quote'::text, null::text),
            (tests.mid(1), tests.uid('b'), 'quote', null),
            (tests.mid(4), tests.uid('c'), 'quote', 'For you') $$,
  'A gets the quotes B and C sent, newest first and by id on a tie: not the text, not A''s own quote, not B''s quote to C'
);

select results_eq(
  $$ select id, conversation_id, body, created_at from public.received_quotes() $$,
  $$ select id, conversation_id, body, created_at from public.messages
     where kind = 'quote' and sender_id <> tests.uid('a')
     order by created_at desc, id $$,
  'it returns what a direct read of messages returns (the same RLS)'
);

select results_eq(
  $$ select id from public.received_quotes(p_limit => 2) $$,
  $$ values (tests.mid(3)), (tests.mid(1)) $$,
  'p_limit makes a page'
);

select results_eq(
  $$ select r.id from public.messages m
     cross join lateral public.received_quotes(m.created_at, m.id, 2) r
     where m.id = tests.mid(1) $$,
  $$ values (tests.mid(4)) $$,
  'the next page starts after the given row: the same time with a later id comes next'
);

select results_eq(
  $$ select r.id from public.messages m
     cross join lateral public.received_quotes(m.created_at, m.id) r
     where m.id = tests.mid(3) $$,
  $$ values (tests.mid(1)), (tests.mid(4)) $$,
  'a page after the newest row holds the older rows'
);

select is(
  (select count(*)::int from public.received_quotes(p_limit => 0)),
  1,
  'a p_limit under 1 still returns one row'
);

select is(
  (select count(*)::int from public.received_quotes(p_limit => null)),
  3,
  'a null p_limit means the default page'
);

select tests.authenticate_as('c');

select results_eq(
  $$ select id from public.received_quotes() $$,
  $$ values (tests.mid(6)) $$,
  'C gets only the quote B sent C: nothing from the conversation of A and B'
);

select tests.authenticate_as('d');

select is_empty(
  $$ select id from public.received_quotes() $$,
  'someone in no conversation gets nothing'
);

-- ---- the plan: the messages index, never a scan of the table -----------------
select tests.authenticate_as('a');
set local enable_seqscan = off;

select is_empty(
  $$ select line from tests.received_plan(null, null) line where line like '%Seq Scan on messages%' $$,
  'the first page does not scan the messages table'
);

select isnt_empty(
  $$ select line from tests.received_plan(null, null) line where line like '%messages_conversation_id_created_at_id_idx%' $$,
  'the first page reads each conversation through messages_conversation_id_created_at_id_idx'
);

select is_empty(
  $$ select line from tests.received_plan(now()::text, tests.mid(1)::text) line where line like '%Seq Scan on messages%' $$,
  'a later page does not scan the messages table either'
);

select isnt_empty(
  $$ select line from tests.received_plan(now()::text, tests.mid(1)::text) line
     where line like '%messages_conversation_id_created_at_id_idx%' $$,
  'a later page uses the same index'
);

set local enable_seqscan = on;

-- ---- what RLS takes away ----------------------------------------------------------
select lives_ok(
  $$ insert into public.reports (message_id, reported_user_id, reason) values (tests.mid(3), tests.uid('b'), 'spam') $$,
  'A reports B''s newest quote'
);

select results_eq(
  $$ select id from public.received_quotes() $$,
  $$ values (tests.mid(1)), (tests.mid(4)) $$,
  'a quote A reported is gone for A'
);

select lives_ok(
  $$ update public.conversation_members set cleared_at = now()
     where conversation_id = tests.cid('a', 'c') and user_id = tests.uid('a') $$,
  'A deletes the conversation with C (for A only)'
);

select results_eq(
  $$ select id from public.received_quotes() $$,
  $$ values (tests.mid(1)) $$,
  'quotes from before A''s "Delete Conversation" are gone for A'
);

select tests.authenticate_as('c');

select results_eq(
  $$ select id from public.received_quotes() $$,
  $$ values (tests.mid(6)) $$,
  'C''s own list is unchanged by what A did'
);

select tests.authenticate_as('b');
insert into public.blocks (blocked_id) values (tests.uid('a'));
select tests.authenticate_as('a');

select is_empty(
  $$ select id from public.received_quotes() $$,
  'after B blocks A, B''s quotes are gone for A'
);

-- ---- who may call it ------------------------------------------------------------
select tests.clear_authentication();
set local role anon;

select throws_ok(
  $$ select * from public.received_quotes() $$,
  '42501', null,
  'anon cannot call received_quotes'
);

select tests.clear_authentication();
set local role service_role;

select throws_ok(
  $$ select * from public.received_quotes() $$,
  '42501', null,
  'the secret key cannot call it either (it reads for a signed-in caller)'
);

select tests.clear_authentication();

select is(
  (select count(*)::int from public.messages where id::text like '3e000000-%'),
  6,
  'reading changed nothing'
);

select * from finish();
rollback;
