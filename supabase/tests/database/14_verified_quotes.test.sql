-- Verified quotes (supabase/migrations/20261024090000_verified_quotes.sql, widened to the catalog by
-- 20261028120000_catalog_corpus.sql): every starter quote has where-to-find-it details; quotes and
-- shares get verified_starter_id only when body, author and source match a catalog quote exactly; a
-- client can never set it; editing the text clears it, formatting does not; a shared verified quote
-- stays verified; withdrawing a catalog quote clears it. Non-starter rows: 16_catalog.
-- Since 20261030030000_provenance_and_accounts the column is not writable by clients
-- (42501), and a friend's copy is saved through save_from_favorite.
-- Ported to 20261030030300_conversations_and_messages: shares became messages;
-- a snapshot the server supplies (as the move of shares did) is verified
-- against the catalog whatever verified_starter_id it carries. Removed: none.
-- How the seal reaches messages and posts on a reseal or withdrawal:
-- 24_catalog_social.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(21);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
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

create function tests.verified(n int) returns integer language sql stable as $$
  select verified_starter_id from public.quotes where id = tests.qid(n)
$$;

-- Starter quote 1, exactly as stored.
create table tests.emerson as
  select body, author, source from public.starter_quotes where id = 1;
grant select on tests.emerson to authenticated;
-- ---------------------------------------------------------------------------

-- ---- starter quote details --------------------------------------------------
select is(
  (select count(*)::int from public.starter_quotes
   where source_location <> '' and source_url like 'https://%'),
  (select count(*)::int from public.starter_quotes),
  'every starter quote has a location and an https source link'
);
select ok(
  not has_function_privilege('authenticated', 'private.set_verified_starter()', 'execute'),
  'clients cannot call the trigger function'
);

select tests.create_user('a');
select tests.create_user('b');
insert into public.profiles (id, username) values (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob');

-- ---- quotes -----------------------------------------------------------------
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  select tests.qid(1), body, author, source from tests.emerson;
-- A client claims verification for text that isn't a starter quote: the
-- column is not writable at all (20261030030000_provenance_and_accounts).
select throws_ok(
  $$ insert into public.quotes (id, body, author, source, verified_starter_id)
     values (tests.qid(2), 'Something I made up.', 'Ralph Waldo Emerson', 'Self-Reliance', 1) $$,
  '42501', null,
  'a client cannot send verified_starter_id'
);
insert into public.quotes (id, body, author, source)
  values (tests.qid(2), 'Something I made up.', 'Ralph Waldo Emerson', 'Self-Reliance');
-- Right words, wrong attribution.
insert into public.quotes (id, body, author, source)
  select tests.qid(3), body, 'Henry David Thoreau', source from tests.emerson;
-- Right words and author, no source.
insert into public.quotes (id, body, author, source)
  select tests.qid(4), body, author, null from tests.emerson;
select tests.clear_authentication();

select is(tests.verified(1), 1::integer, 'an exact copy of a starter quote is verified');
select is(tests.verified(2), null::integer, 'made-up words under a real author are not verified');
select is(tests.verified(3), null::integer, 'a different author is not verified');
select is(tests.verified(4), null::integer, 'a missing source is not verified');

select tests.authenticate_as('a');
update public.quotes set body_format = '[{"start": 0, "length": 5, "bold": true}]' where id = tests.qid(1);
select tests.clear_authentication();
select is(tests.verified(1), 1::integer, 'formatting keeps the quote verified');

select tests.authenticate_as('a');
update public.quotes set body = body || ' Indeed.' where id = tests.qid(1);
select tests.clear_authentication();
select is(tests.verified(1), null::integer, 'editing the wording clears verification');

select tests.authenticate_as('a');
update public.quotes q set body = e.body from tests.emerson e where q.id = tests.qid(1);
select tests.clear_authentication();
select is(tests.verified(1), 1::integer, 'restoring the exact wording verifies it again');

select tests.authenticate_as('a');
update public.quotes set author = 'R. W. Emerson' where id = tests.qid(1);
select tests.clear_authentication();
select is(tests.verified(1), null::integer, 'editing the author clears verification');

select tests.authenticate_as('a');
select throws_ok(
  $$ update public.quotes set verified_starter_id = 5 where id = tests.qid(2) $$,
  '42501', null,
  'a client cannot update verified_starter_id'
);
update public.quotes set rotation_position = 0 where id = tests.qid(3);
select tests.clear_authentication();
select is(tests.verified(2), null::integer, 'a client cannot set verification with an update');
select is(tests.verified(3), null::integer, 'an unrelated update changes nothing');

-- Rotation writes don't touch the text, so they keep verification.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source, rotation_position)
  select tests.qid(5), body, author, source, null from tests.emerson;
select public.set_rotation(array[tests.qid(5)]);
select tests.clear_authentication();
select is(tests.verified(5), 1::integer, 'set_rotation keeps verification');

-- Undo of a delete (a re-insert with the same id) recomputes it.
select tests.authenticate_as('a');
delete from public.quotes where id = tests.qid(5);
insert into public.quotes (id, body, author, source)
  select tests.qid(5), body, author, source from tests.emerson
  on conflict (id) do update set body = excluded.body;
select tests.clear_authentication();
select is(tests.verified(5), 1::integer, 'a restored quote is verified again');

-- ---- messages -----------------------------------------------------------------
insert into public.conversations (id, user_a, user_b) values (tests.qid(30), tests.uid('a'), tests.uid('b'));
insert into public.messages (id, conversation_id, sender_id, kind, body, author, source, verified_starter_id)
  select tests.qid(31), tests.qid(30), tests.uid('a'), 'quote', body, author, source, null from tests.emerson;
insert into public.messages (id, conversation_id, sender_id, kind, body, author, source, verified_starter_id)
  values (tests.qid(32), tests.qid(30), tests.uid('a'), 'quote', 'Not a starter quote.', 'Someone', null, 1);
select is((select verified_starter_id from public.messages where id = tests.qid(31)), 1::integer,
  'a message of a verified quote is verified');
select is((select verified_starter_id from public.messages where id = tests.qid(32)), null::integer,
  'a sender cannot claim verification for a message');

-- A friend saves a verified quote (direct origin 'shared' inserts are gone;
-- this goes through save_from_favorite): the copy is verified too.
insert into public.friendships (requester_id, addressee_id, status) values (tests.uid('a'), tests.uid('b'), 'accepted');
update public.profiles set favorites_visibility = 'friends' where id = tests.uid('a');
update public.quotes set is_favorite = true where id = tests.qid(5);
select tests.authenticate_as('b');
select public.save_from_favorite(tests.uid('a'), (select f.id from public.friend_favorites(tests.uid('a')) f), tests.qid(40));
select tests.clear_authentication();
select is(tests.verified(40), 1::integer, 'a saved copy of a verified quote is verified');

-- Catalog quotes are never deleted. Withdrawing one (its wording or credit was wrong) takes the seal
-- off every copy, and a fresh copy afterwards stays unsealed.
select private.catalog_withdraw(1, 'test withdrawal');
select is(tests.verified(40), null::integer, 'withdrawing a catalog quote clears the copies');
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  select tests.qid(41), body, author, source from tests.emerson;
select tests.clear_authentication();
select is(tests.verified(41), null::integer, 'a new copy of a withdrawn quote is not verified');

select * from finish();
rollback;
