-- The verified catalog (20261028120000_catalog_corpus and its batch migrations) inside the social
-- redesign (20261030030000-20261030030600): catalog ids are integers in catalog_quotes, so a batch
-- quote (id > 60) is verified everywhere a starter is (add_catalog_quotes, messages, posts, forwards,
-- reports, public eligibility); a retired row still seals but is no longer offered; and
-- private.catalog_reseal and catalog_withdraw, which kept shares right before shares became
-- messages, now reach quote messages and posts. A future batch migration (simulated here: catalog
-- rows inserted, then the reseal every batch ends with) still works after the redesign. A copy that
-- loses its seal gets back only its sender's or author's own credit, so a batch and a withdrawal
-- leave a post of the author's own words public-eligible. The move of shares that already carried a
-- batch seal: 19b_share_migration.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(31);

-- ---- test helpers (rolled back with the transaction) ----------------------
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.uid(who text) returns uuid language sql immutable as $$
  select (case who
    when 'a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'b' then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'c' then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
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

create function tests.accept_terms(who text) returns void language sql security definer as $$
  update public.profiles set terms_version = private.current_terms_version(), terms_accepted_at = now()
  where id = tests.uid(who)
$$;

-- The conversation between A and someone, read with definer rights.
create function tests.cid(who text) returns uuid language sql stable security definer as $$
  select c.id from public.conversations c
  where c.user_a = least(tests.uid('a'), tests.uid(who)) and c.user_b = greatest(tests.uid('a'), tests.uid(who))
$$;

-- The seals of one quote, one message and one post, read with definer rights.
create function tests.seals(q int, m int, p int) returns table (quote integer, message integer, post integer)
language sql stable security definer as $$
  select (select verified_starter_id from public.quotes where id = tests.qid(q)),
         (select verified_starter_id from public.messages where id = tests.mid(m)),
         (select verified_starter_id from public.posts where id = tests.pid(p))
$$;

-- A catalog row as a batch migration writes one: a non-starter with its author, work and provenance.
create function tests.add_catalog_row(p_id integer, p_body text, p_status text default 'live') returns void
language sql as $$
  insert into public.catalog_quotes (id, body, author, source, source_location, source_url, themes, status,
                                     author_id, work_id, checked_ebook_id, checked_body_sha256, checked_start,
                                     checked_end, match_kind, checked_at, verifier_version)
  values (p_id, p_body, 'Later Author', 'Later Work', 'Chapter 1', 'https://www.gutenberg.org/ebooks/900200',
          array['calm'], p_status, 900200, 900200, 900200, repeat('a', 64), 0, char_length(p_body), 'exact',
          now(), 'abcdef1')
$$;
-- ---------------------------------------------------------------------------

-- Catalog quote 61 arrived with batch 001 (20261029020004), before the redesign.
create table tests.q61 as select body, author, source from public.catalog_quotes where id = 61;
grant select on tests.q61 to authenticated;

insert into public.catalog_authors (id, slug, name, died_year) values (900200, 'later-author', 'Later Author', 1850);
insert into public.catalog_works (id, author_id, citation, edition_year, gutenberg_id)
  values (900200, 900200, 'Later Work', 1890, 900200);
select tests.add_catalog_row(900101, 'A retired line that still seals.', 'retired');

-- A is friends with B and C; B and C are strangers. B may make a post public (current terms, an
-- Apple identity).
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid') from unnest(array['a', 'b', 'c']) w;
insert into public.profiles (id, username) values
  (tests.uid('a'), 'alice'), (tests.uid('b'), 'bob'), (tests.uid('c'), 'cara');
select tests.accept_terms(w) from unnest(array['a', 'b', 'c']) w;
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('c'), 'accepted');
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-bob', tests.uid('b'), '{}', 'apple');
select tests.authenticate_as('a');
select (public.open_conversation(tests.uid(w))).id from unnest(array['b', 'c']) w;
select tests.clear_authentication();

-- ---- the contract ---------------------------------------------------------------
select is_empty(
  $$ select p.oid::regprocedure from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
       and (p.prosrc ~ 'public\.shares\M' or p.prosrc ~ 'public\.starter_quotes\M') $$,
  'no function reads the dropped shares table or the starter_quotes view (catalog ids live in catalog_quotes)'
);

select results_eq(
  $$ select p.oid::regprocedure::text, pg_get_function_result(p.oid)
     from pg_proc p
     where p.oid in ('private.catalog_reseal(integer[])'::regprocedure,
                     'private.catalog_withdraw(integer, text)'::regprocedure)
     order by 1 $$,
  $$ values
       ('private.catalog_reseal(integer[])',
        'TABLE(quotes_rechecked integer, messages_rechecked integer, posts_rechecked integer)'),
       ('private.catalog_withdraw(integer,text)',
        'TABLE(quotes_rechecked integer, messages_rechecked integer, posts_rechecked integer)') $$,
  'the reseal and the withdrawal keep the signatures batch migrations call, and count messages and posts instead of shares'
);

-- ---- a batch quote is verified like a starter -----------------------------------
select tests.authenticate_as('a');
select results_eq(
  $$ select origin, creator_id, verified_starter_id
     from public.add_catalog_quotes(array[1, 61], array[tests.qid(1), tests.qid(2)]) $$,
  $$ values ('starter'::text, null::uuid, 1), ('catalog', null, 61) $$,
  'add_catalog_quotes saves a batch quote verified with origin catalog (a starter keeps origin starter)'
);
select throws_ok(
  $$ select * from public.add_catalog_quotes(array[900101]) $$,
  '23503', null,
  'a retired catalog row is no longer offered'
);

insert into public.quotes (id, body, author, source) select tests.qid(3), body, author, source from tests.q61;
select results_eq(
  $$ select origin, creator_username, verified_starter_id from public.quotes where id = tests.qid(3) $$,
  $$ values ('manual'::text, 'alice'::text, 61) $$,
  'a batch quote typed word for word is verified in A''s own Library, credited to A'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id)
     values (tests.mid(2), tests.cid('b'), 'quote', tests.qid(3))
     returning verified_starter_id, creator_id, edited_from_id $$,
  $$ values (61, null::uuid, null::uuid) $$,
  'sent, it goes as "Quoted Catalog": verified, with no creator'
);
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, starter_quote_id)
     values (tests.mid(3), tests.cid('c'), 'quote', 61)
     returning verified_starter_id, creator_id, body = (select body from tests.q61) $$,
  $$ values (61, null::uuid, true) $$,
  'a message made from batch quote 61 copies the catalog row, verified'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id) values (tests.cid('c'), 'quote', 900101) $$,
  '23503', null,
  'a message cannot be made from a retired catalog row'
);

select tests.authenticate_as('b');
select results_eq(
  $$ insert into public.posts (id, starter_quote_id, audience) values (tests.pid(1), 61, 'public')
     returning verified_starter_id, creator_id, audience $$,
  $$ values (61, null::uuid, 'public'::text) $$,
  'B posts batch quote 61 publicly: verified, so public-eligible'
);
insert into public.messages (id, conversation_id, kind, starter_quote_id) values (tests.mid(4), tests.cid('b'), 'quote', 61);

select tests.authenticate_as('c');
select results_eq(
  $$ select owner_id, origin, creator_id, verified_starter_id from public.save_from_post(tests.pid(1), tests.qid(30)) $$,
  $$ values (tests.uid('c'), 'shared'::text, null::uuid, 61) $$,
  'C, a stranger to B, reaches the public post and saves it verified'
);

select tests.authenticate_as('a');
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_message_id)
     values (tests.mid(5), tests.cid('c'), 'quote', tests.mid(4))
     returning verified_starter_id, creator_id $$,
  $$ values (61, null::uuid) $$,
  'a forward of B''s message is checked against the whole catalog and stays verified'
);
select lives_ok(
  $$ insert into public.reports (id, starter_quote_id, reason, details)
     values (tests.rid(1), 61, 'wrong_wording', 'One word is off') $$,
  'A can report batch quote 61''s wording'
);
select tests.clear_authentication();
select results_eq(
  $$ select target_kind, reported_user_id, content_body = (select body from tests.q61), content_verified
     from public.reports where id = tests.rid(1) $$,
  $$ values ('catalog_quote'::text, null::uuid, true, true) $$,
  'the server copies the batch row into the report, naming nobody'
);

-- ---- a later batch migration still works --------------------------------------
-- A's own words, kept, sent to B and posted, before a batch takes them in.
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  values (tests.qid(10), 'Words that a later batch takes in.', 'Later Author', 'Later Work');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(10), tests.cid('b'), 'quote', tests.qid(10));
insert into public.posts (id, source_quote_id) values (tests.pid(10), tests.qid(10));
select tests.clear_authentication();

-- What a generated batch migration does: insert the rows, then reseal their ids.
select tests.add_catalog_row(900201, 'Words that a later batch takes in.');
select results_eq(
  $$ select * from private.catalog_reseal(array[900201]) $$,
  $$ values (1, 1, 1) $$,
  'a batch''s reseal runs after the redesign: it rechecks the matching quote, quote message and post'
);
select results_eq(
  $$ select * from tests.seals(10, 10, 10) $$,
  $$ values (900201, 900201, 900201) $$,
  'the quote, the message and the post all carry the new seal'
);
select results_eq(
  $$ select (select creator_username from public.quotes where id = tests.qid(10)),
            (select creator_username from public.messages where id = tests.mid(10)),
            (select creator_username from public.posts where id = tests.pid(10)) $$,
  $$ values ('alice'::text, null::text, null::text) $$,
  'a snapshot that gains the seal drops its creator, as a verified one does when sent or posted; A''s own row keeps it'
);
select tests.authenticate_as('b');
select results_eq(
  $$ select (select verified_starter_id from public.messages where id = tests.mid(10)),
            (select creator_username from public.messages where id = tests.mid(10)),
            (select verified_starter_id from public.posts where id = tests.pid(10)),
            (select creator_username from public.posts where id = tests.pid(10)) $$,
  $$ values (900201, null::text, 900201, null::text) $$,
  'B reads the message and the post as "Quoted Catalog"'
);
select tests.clear_authentication();

-- ---- a withdrawal takes the seal off every copy ---------------------------------
select results_eq(
  $$ select * from private.catalog_withdraw(900201, 'Test: credited to the wrong person.') $$,
  $$ values (1, 1, 1) $$,
  'withdrawing the row rechecks the quote, the message and the post'
);
select results_eq(
  $$ select * from tests.seals(10, 10, 10) $$,
  $$ values (null::integer, null::integer, null::integer) $$,
  'none of them is verified any more'
);
select results_eq(
  $$ select (select creator_username from public.messages where id = tests.mid(10)),
            (select creator_username from public.posts where id = tests.pid(10)) $$,
  $$ values ('alice'::text, 'alice'::text) $$,
  'the message and the post of A''s own words credit A again, as sending or posting them now would'
);
select tests.authenticate_as('a');
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id)
     values (tests.mid(11), tests.cid('b'), 'quote', tests.qid(10))
     returning verified_starter_id, creator_username $$,
  $$ values (null::integer, 'alice'::text) $$,
  'sent again, the wording is unverified and credits its creator'
);
select throws_ok(
  $$ insert into public.messages (conversation_id, kind, starter_quote_id) values (tests.cid('b'), 'quote', 900201) $$,
  '23503', null,
  'a withdrawn catalog row cannot be sent'
);

-- Batch quote 61 is withdrawn too: every copy made above loses its seal, and B's public post is no
-- longer eligible, so strangers lose it.
select tests.clear_authentication();
select private.catalog_withdraw(61, 'Test: one word is wrong.');
select results_eq(
  $$ select m.n, m.sealed, (select verified_starter_id from public.posts where id = tests.pid(1)), q.n, q.sealed
     from (select count(*)::int as n, count(verified_starter_id)::int as sealed from public.messages
            where id in (tests.mid(2), tests.mid(3), tests.mid(4), tests.mid(5))) m,
          (select count(*)::int as n, count(verified_starter_id)::int as sealed from public.quotes
            where id in (tests.qid(2), tests.qid(3), tests.qid(30))) q $$,
  $$ values (4, 0, null::integer, 3, 0) $$,
  'withdrawing batch quote 61 unseals its messages (sent, by catalog id, received and forwarded), the post and the saved quotes'
);
select results_eq(
  $$ select creator_username from public.messages
     where id in (tests.mid(2), tests.mid(3), tests.mid(4), tests.mid(5)) order by id $$,
  $$ values ('alice'::text), (null), (null), (null) $$,
  'only the message A sent from A''s own typed copy (verified when sent) credits A again; copies by catalog id and the forward name nobody'
);
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_post(tests.pid(1)) $$,
  '42501', 'This post is not available.',
  'B''s public post of the withdrawn quote is out of a stranger''s reach'
);

-- ---- a batch and a withdrawal leave B's own public post public -------------------------
-- B types words, posts them publicly and sends them to A; A saves B's message and sends the copy
-- to C. Then a batch takes the words in and a withdrawal takes them out again.
select tests.authenticate_as('b');
insert into public.quotes (id, body, author, source)
  values (tests.qid(40), 'Words B posts before a batch takes them in.', 'Later Author', 'Later Work');
insert into public.posts (id, source_quote_id, audience) values (tests.pid(40), tests.qid(40), 'public');
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(40), tests.cid('b'), 'quote', tests.qid(40));
select tests.authenticate_as('a');
select public.save_from_message(tests.mid(40), tests.qid(41));
insert into public.messages (id, conversation_id, kind, source_quote_id) values (tests.mid(41), tests.cid('c'), 'quote', tests.qid(41));
select tests.clear_authentication();

select tests.add_catalog_row(900202, 'Words B posts before a batch takes them in.');
select results_eq(
  $$ select * from private.catalog_reseal(array[900202]) $$,
  $$ values (2, 2, 1) $$,
  'the batch seals B''s quote and A''s saved copy, both messages and B''s post'
);
select private.catalog_withdraw(900202, 'Test: credited to the wrong person.');
select results_eq(
  $$ select (select creator_username from public.posts where id = tests.pid(40)),
            (select creator_username from public.messages where id = tests.mid(40)),
            (select creator_username from public.messages where id = tests.mid(41)) $$,
  $$ values ('bob'::text, 'bob'::text, null::text) $$,
  'withdrawn, B''s post and message of B''s own words credit B again; A''s copy of B''s words names nobody'
);
select tests.authenticate_as('c');
select results_eq(
  $$ select creator_username, verified_starter_id from public.save_from_post(tests.pid(40), tests.qid(42)) $$,
  $$ values ('bob'::text, null::integer) $$,
  'so C, a stranger to B, still reaches B''s public post'
);

-- ---- a retired row still seals -------------------------------------------------------
select tests.authenticate_as('a');
insert into public.quotes (id, body, author, source)
  values (tests.qid(20), 'A retired line that still seals.', 'Later Author', 'Later Work');
select results_eq(
  $$ insert into public.messages (id, conversation_id, kind, source_quote_id)
     values (tests.mid(20), tests.cid('b'), 'quote', tests.qid(20))
     returning verified_starter_id $$,
  $$ values (900101) $$,
  'a copy of a retired row is still verified when sent'
);
select tests.clear_authentication();
select results_eq(
  $$ select * from private.catalog_reseal(array[900101]) $$,
  $$ values (1, 1, 0) $$,
  'a reseal of the retired row rechecks its quote and message'
);
select is((select verified_starter_id from public.messages where id = tests.mid(20)), 900101,
  'and the message keeps the seal');

select * from finish();
rollback;
