-- Posts (supabase/migrations/20261029090200_posts.sql): strangers get zero
-- posts; the author and accepted friends read them, never across a block or
-- while held; clients send only the source, caption and audience and the
-- server builds the snapshot from the author's own quote or the catalog;
-- exactly one source; only the audience changes; terms, suspension and the
-- word filter (QR003) on the caption and an unverified snapshot; Public needs
-- can_publish and an eligible snapshot; 20 posts a day; save_from_post keeps
-- the creator and is refused to anyone who cannot see the post.
-- 20261029090300_conversations_and_messages gave reports post_id and the real
-- private.caller_reported_post: a post its reader reported disappears for
-- them (and cannot be saved), not for its author or other friends.
-- Review fixes: a verified snapshot keeps no creator or edited-from; a public
-- post reaches strangers only while its author may still publish; deleting a
-- post makes no room under the 20-a-day limit.
begin;
set local client_min_messages = warning;
create extension if not exists pgtap with schema extensions;
select plan(104);

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
  end)::uuid
$$;

create function tests.qid(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function tests.pid(n int) returns uuid language sql immutable as $$
  select ('80000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
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

-- A quote's provenance as origin|creator|edited from ('-' for none), read with
-- definer rights so it works from any role.
create function tests.prov(n int) returns text language sql stable security definer as $$
  select origin || '|' || coalesce(creator_username, '-') || '|' || coalesce(edited_from_username, '-')
  from public.quotes where id = tests.qid(n)
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

-- A (alice) posts. B is A's friend; C is a stranger; D is A's friend whom A
-- blocked; E has a pending request from A; F is A's friend who blocked A; G
-- has not accepted the terms; H gets suspended. Blocks go in first, because a
-- new block deletes the pair's friendship.
select tests.create_user(tests.uid(w), w || '@test.quoted.invalid')
  from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) w;
insert into public.profiles (id, username, display_name) values
  (tests.uid('a'), 'alice', 'Alice A'), (tests.uid('b'), 'bob', null), (tests.uid('c'), 'cara', null),
  (tests.uid('d'), 'dan', null), (tests.uid('e'), 'eve', null), (tests.uid('f'), 'fay', null),
  (tests.uid('g'), 'gus', null), (tests.uid('h'), 'hal', null);
select tests.accept_terms(w) from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'h']) w;
insert into public.blocks (blocker_id, blocked_id) values (tests.uid('a'), tests.uid('d')), (tests.uid('f'), tests.uid('a'));
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.uid('a'), tests.uid('b'), 'accepted'), (tests.uid('a'), tests.uid('d'), 'accepted'),
  (tests.uid('f'), tests.uid('a'), 'accepted'), (tests.uid('a'), tests.uid('e'), 'pending');
-- 'fearless' is in catalog quote 3 ("Beware; for I am fearless, ...").
insert into private.blocked_terms (term) values ('darn'), ('heck no'), ('fearless');

-- A's quotes: 1 and 6 typed by A, 2 A's copy of catalog quote 3 (verified),
-- 3 a copy of B's words, 4 A's rewrite of B's words, 5 A's words with a
-- blocked term (the private Library is never filtered).
select tests.authenticate_as('a');
insert into public.quotes (id, body, author) values
  (tests.qid(1), 'Alpha', 'Ann'), (tests.qid(5), 'Darn it all', null), (tests.qid(6), 'Zeta', 'Zed');
select id from public.add_catalog_quotes(array[3]::smallint[], array[tests.qid(2)]);
select tests.authenticate_as('b');
insert into public.quotes (id, body, author) values (tests.qid(30), 'Bob''s line', 'Bo');
select tests.authenticate_as('c');
insert into public.quotes (id, body) values (tests.qid(40), 'Cara''s words');
select tests.authenticate_as('g');
insert into public.quotes (id, body) values (tests.qid(45), 'Gus''s words');
select tests.authenticate_as('h');
insert into public.quotes (id, body) values (tests.qid(50), 'Hal''s words');
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username) values
  (tests.qid(3), tests.uid('a'), 'Bob''s line', 'Bo', 'shared', tests.uid('b'), 'bob');
insert into public.quotes (id, owner_id, body, author, origin, creator_id, creator_username, edited_from_id, edited_from_username)
  values (tests.qid(4), tests.uid('a'), 'Bob''s line, Alice''s way', 'Bo', 'shared', tests.uid('a'), 'alice', tests.uid('b'), 'bob');
insert into public.quotes (id, owner_id, body, creator_id, creator_username) values
  (tests.qid(52), tests.uid('d'), 'Dan''s words', tests.uid('d'), 'dan'),
  (tests.qid(55), tests.uid('f'), 'Fay''s words', tests.uid('f'), 'fay');
-- D and F have posted too (the server path builds the snapshot as well).
insert into public.posts (id, author_id, source_quote_id) values
  (tests.pid(52), tests.uid('d'), tests.qid(52)), (tests.pid(55), tests.uid('f'), tests.qid(55));

-- ---- posting: column grants and the server-built snapshot ---------------------
select tests.authenticate_as('a');

select results_eq(
  $$ insert into public.posts (id, source_quote_id, caption) values (tests.pid(1), tests.qid(1), 'Morning thought')
     returning id, author_id, starter_quote_id, caption, body, author, source, creator_username,
               edited_from_username, verified_starter_id, audience, held_at, created_at = now() $$,
  $$ values (tests.pid(1), tests.uid('a'), null::smallint, 'Morning thought'::text, 'Alpha'::text, 'Ann'::text,
             null::text, 'alice'::text, null::text, null::smallint, 'friends'::text, null::timestamptz, true) $$,
  'A posts one of A''s quotes: the server copies its wording and creator; friends by default, on the server clock'
);
select throws_ok(
  $$ select source_quote_id from public.posts $$,
  '42501', 'permission denied for table posts',
  'not even the author can read source_quote_id'
);
select throws_ok(
  $$ select * from public.posts $$,
  '42501', 'permission denied for table posts',
  'so select * is refused: clients list the columns they read'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, body) values (tests.qid(1), 'Forged words') $$,
  '42501', 'permission denied for table posts',
  'a client cannot send the body'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, creator_id, creator_username) values (tests.qid(1), tests.uid('b'), 'bob') $$,
  '42501', 'permission denied for table posts',
  'nor the creator'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, verified_starter_id) values (tests.qid(1), 1) $$,
  '42501', 'permission denied for table posts',
  'nor the verified catalog id'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, author_id) values (tests.qid(1), tests.uid('b')) $$,
  '42501', 'permission denied for table posts',
  'nor the author'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, held_at) values (tests.qid(1), null) $$,
  '42501', 'permission denied for table posts',
  'nor held_at'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, created_at) values (tests.qid(1), now()) $$,
  '42501', 'permission denied for table posts',
  'nor created_at'
);

select results_eq(
  $$ insert into public.posts (id, starter_quote_id) values (tests.pid(2), 1)
     returning starter_quote_id, body, author, source, body_format, creator_id, edited_from_id, verified_starter_id $$,
  $$ select 1::smallint, s.body, s.author, s.source, s.body_format, null::uuid, null::uuid, 1::smallint
     from public.starter_quotes s where s.id = 1 $$,
  'a catalog post copies the catalog row: verified, with no creator'
);
select results_eq(
  $$ insert into public.posts (id, source_quote_id) values (tests.pid(3), tests.qid(2))
     returning starter_quote_id, body, creator_id, verified_starter_id $$,
  $$ select null::smallint, s.body, null::uuid, 3::smallint from public.starter_quotes s where s.id = 3 $$,
  'a post of A''s own verified copy stays verified, and verified wording skips the word filter (it holds "fearless")'
);
select results_eq(
  $$ insert into public.posts (id, source_quote_id) values (tests.pid(4), tests.qid(3))
     returning body, creator_id, creator_username, edited_from_username $$,
  $$ values ('Bob''s line'::text, tests.uid('b'), 'bob'::text, null::text) $$,
  'a post of B''s words that A holds credits B, not the poster'
);
select results_eq(
  $$ insert into public.posts (id, source_quote_id) values (tests.pid(5), tests.qid(4))
     returning body, creator_username, edited_from_id, edited_from_username $$,
  $$ values ('Bob''s line, Alice''s way'::text, 'alice'::text, tests.uid('b'), 'bob'::text) $$,
  'a post of A''s rewrite credits A and keeps B as edited-from'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id) values (tests.qid(30)) $$,
  '42501', 'You can post only quotes from your Library or the Quoted Catalog.',
  'A cannot post B''s quote'
);
select is(
  tests.error_of($$ insert into public.posts (source_quote_id) values (tests.qid(30)) $$),
  tests.error_of($$ insert into public.posts (source_quote_id) values (tests.qid(999)) $$),
  'someone else''s quote fails exactly like a quote that does not exist'
);
select throws_ok(
  $$ insert into public.posts (caption) values ('Nothing quoted') $$,
  '23514', 'A post quotes exactly one quote: one of yours or one from the Quoted Catalog.',
  'a post needs a source'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, starter_quote_id) values (tests.qid(1), 1) $$,
  '23514', 'A post quotes exactly one quote: one of yours or one from the Quoted Catalog.',
  'and only one'
);
select throws_ok(
  $$ insert into public.posts (starter_quote_id) values (999) $$,
  '23503', null,
  'a catalog id that does not exist is refused'
);
select throws_ok($$ insert into public.posts (source_quote_id, caption) values (tests.qid(1), ' ') $$, '23514', null,
  'a blank caption is refused');
select throws_ok($$ insert into public.posts (source_quote_id, caption) values (tests.qid(1), repeat('x', 281)) $$, '23514', null,
  'a caption longer than 280 characters is refused');
select tests.clear_authentication();
select throws_ok(
  $$ insert into public.posts (author_id, source_quote_id, audience) values (tests.uid('a'), tests.qid(1), 'everyone') $$,
  '23514', null,
  'the audience is friends or public (a client is refused even earlier, by the policy)'
);
select tests.authenticate_as('a');

-- ---- the word filter ------------------------------------------------------------------
select throws_ok(
  $$ insert into public.posts (source_quote_id, caption) values (tests.qid(1), 'Darn good line') $$,
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'a caption with a blocked term is refused with QR003'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id) values (tests.qid(5)) $$,
  'QR003', 'Quoted doesn''t allow some words in posts and messages.',
  'so is an unverified quote with one'
);
select throws_ok(
  $$ insert into public.posts (starter_quote_id, caption) values (1, 'Heck no, read this') $$,
  'QR003', null,
  'the caption is checked even on a verified quote'
);

-- ---- the snapshot stays as posted ------------------------------------------------------
insert into public.posts (id, source_quote_id) values (tests.pid(6), tests.qid(6));
update public.quotes set body = 'Alpha, revised' where id = tests.qid(1);
delete from public.quotes where id = tests.qid(6);
select results_eq(
  $$ select id, body from public.posts where id in (tests.pid(1), tests.pid(6)) order by id $$,
  $$ values (tests.pid(1), 'Alpha'::text), (tests.pid(6), 'Zeta'::text) $$,
  'editing or deleting the source quote leaves the post as it was posted'
);
select tests.clear_authentication();
select results_eq(
  $$ select id, source_quote_id from public.posts where id in (tests.pid(1), tests.pid(6)) order by id $$,
  $$ values (tests.pid(1), tests.qid(1)), (tests.pid(6), null::uuid) $$,
  'the post points at its source quote until that quote is deleted'
);

-- ---- who reads ---------------------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select id from public.posts order by id $$,
  $$ values (tests.pid(1)), (tests.pid(2)), (tests.pid(3)), (tests.pid(4)), (tests.pid(5)), (tests.pid(6)) $$,
  'a friend sees every one of A''s posts'
);
select results_eq(
  $$ select author_id, caption, body, creator_username, edited_from_username, audience, held_at
     from public.posts where id = tests.pid(5) $$,
  $$ values (tests.uid('a'), null::text, 'Bob''s line, Alice''s way'::text, 'alice'::text, 'bob'::text,
             'friends'::text, null::timestamptz) $$,
  'with the snapshot, its creator and edited-from'
);
select throws_ok(
  $$ select source_quote_id from public.posts $$,
  '42501', 'permission denied for table posts',
  'a friend cannot read A''s quote ids'
);
select throws_ok(
  $$ select id from public.posts where source_quote_id = tests.qid(1) $$,
  '42501', 'permission denied for table posts',
  'nor probe them in a filter'
);
select is_empty($$ update public.posts set audience = 'friends' returning 1 $$, 'a friend cannot change A''s posts');
select is_empty($$ delete from public.posts returning 1 $$, 'nor delete them');
insert into public.posts (id, source_quote_id) values (tests.pid(30), tests.qid(30));

select tests.authenticate_as('c');
select is_empty($$ select 1 from public.posts $$, 'a stranger gets zero posts');
select is_empty($$ update public.posts set audience = 'friends' returning 1 $$, 'and changes none');
select is_empty($$ delete from public.posts returning 1 $$, 'and deletes none');
select tests.authenticate_as('e');
select is_empty($$ select 1 from public.posts $$, 'someone with only a pending request gets zero posts');
select tests.authenticate_as('d');
select is_empty($$ select 1 from public.posts where author_id = tests.uid('a') $$, 'a friend A blocked gets none of A''s');
select tests.authenticate_as('f');
select is_empty($$ select 1 from public.posts where author_id = tests.uid('a') $$, 'a friend who blocked A gets none of A''s');
select tests.authenticate_as('a');
select results_eq(
  $$ select author_id from public.posts where author_id <> tests.uid('a') $$,
  $$ values (tests.uid('b')) $$,
  'A sees B''s post (friendship works both ways), but not D''s (A blocked D) or F''s (F blocked A)'
);

select tests.clear_authentication();
update public.posts set held_at = now() where id = tests.pid(1);
select tests.authenticate_as('b');
select is_empty($$ select 1 from public.posts where id = tests.pid(1) $$, 'a held post is hidden from friends');
select tests.authenticate_as('a');
select results_eq(
  $$ select held_at = now() from public.posts where id = tests.pid(1) $$,
  $$ values (true) $$,
  'but not from its author, who can see that it is held'
);
select tests.clear_authentication();
update public.posts set held_at = null where id = tests.pid(1);

-- B reports one of A's posts: it disappears for B at once.
select tests.authenticate_as('b');
insert into public.reports (post_id, reported_user_id, reason) values (tests.pid(3), tests.uid('a'), 'spam');
select is_empty($$ select 1 from public.posts where id = tests.pid(3) $$, 'a post its reader reported disappears for them');
select throws_ok(
  $$ select public.save_from_post(tests.pid(3)) $$,
  '42501', 'This post is not available.',
  'and they can no longer save it'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select count(*)::int from public.posts where id = tests.pid(3) $$,
  $$ values (1) $$,
  'its author still sees it'
);
select tests.clear_authentication();
select results_eq(
  $$ select r.content_body = p.body, r.content_verified, p.held_at from public.reports r join public.posts p on p.id = r.post_id
     where r.post_id = tests.pid(3) $$,
  $$ values (true, true, null::timestamptz) $$,
  'the report holds a copy of the post; the post itself is not deleted or held by one report'
);

set local role anon;
select throws_ok($$ select id from public.posts $$, '42501', null, 'anon cannot read posts at all');
select tests.clear_authentication();

-- ---- only the audience changes; the author deletes -----------------------------------------
select tests.authenticate_as('a');
select throws_ok($$ update public.posts set caption = 'New caption' where id = tests.pid(1) $$, '42501', null,
  'the caption cannot be edited');
select throws_ok($$ update public.posts set body = 'New words' where id = tests.pid(1) $$, '42501', null,
  'nor the wording');
select throws_ok($$ update public.posts set held_at = null where id = tests.pid(1) $$, '42501', null,
  'nor held_at');
select throws_ok(
  $$ update public.posts set audience = 'public' where id = tests.pid(1) $$,
  '42501', 'Only accounts backed up with Sign in with Apple can make a post public.',
  'without a linked Apple identity a post cannot become public'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, audience) values (tests.qid(1), 'public') $$,
  '42501', 'Only accounts backed up with Sign in with Apple can make a post public.',
  'nor be posted publicly'
);
select results_eq(
  $$ delete from public.posts where id = tests.pid(6) returning body $$,
  $$ values ('Zeta'::text) $$,
  'the author deletes their own post'
);

-- ---- terms and suspension ------------------------------------------------------------------
select tests.authenticate_as('g');
select throws_ok(
  $$ insert into public.posts (source_quote_id) values (tests.qid(45)) $$,
  '42501', 'Accept the Terms of use first.',
  'posting needs accepted terms'
);
select is(
  tests.error_of($$ insert into public.posts (source_quote_id) values (tests.qid(30)) $$),
  tests.error_of($$ insert into public.posts (source_quote_id) values (tests.qid(45)) $$),
  'and says so first, whatever the source'
);

select tests.clear_authentication();
insert into public.posts (id, author_id, source_quote_id, audience) values (tests.pid(20), tests.uid('h'), tests.qid(50), 'public');
insert into private.suspensions (user_id, reason) values (tests.uid('h'), 'test');
select tests.authenticate_as('h');
select throws_ok(
  $$ insert into public.posts (source_quote_id) values (tests.qid(50)) $$,
  '42501', 'This account is suspended.',
  'a suspended account cannot post'
);
select lives_ok(
  $$ update public.posts set audience = 'friends' where id = tests.pid(20) $$,
  'but it can narrow a post to Friends'
);
select throws_ok(
  $$ update public.posts set audience = 'public' where id = tests.pid(20) $$,
  '42501', 'This account is suspended.',
  'and cannot widen it again'
);
select lives_ok($$ delete from public.posts where id = tests.pid(20) $$, 'and can delete it');

-- ---- Public ---------------------------------------------------------------------------------
select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple');
select tests.authenticate_as('a');
select lives_ok(
  $$ insert into public.posts (id, source_quote_id, audience) values (tests.pid(7), tests.qid(1), 'public') $$,
  'with an Apple identity A can post A''s own words publicly'
);
select lives_ok(
  $$ insert into public.posts (id, starter_quote_id, audience) values (tests.pid(8), 2, 'public') $$,
  'and a catalog quote'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, audience) values (tests.qid(3), 'public') $$,
  '42501', 'A public post can hold only a Quoted Catalog quote or a quote you added.',
  'but not a quote someone else added'
);
select throws_ok(
  $$ insert into public.posts (source_quote_id, audience) values (tests.qid(4), 'public') $$,
  '42501', 'A public post can hold only a Quoted Catalog quote or a quote you added.',
  'nor A''s rewrite of someone else''s words (it has an edited-from)'
);
select throws_ok(
  $$ update public.posts set audience = 'public' where id = tests.pid(4) $$,
  '42501', 'A public post can hold only a Quoted Catalog quote or a quote you added.',
  'and such a post cannot become public'
);
-- The policies hold on their own, without the trigger's clearer answers.
select tests.clear_authentication();
alter table public.posts disable trigger posts_check_audience;
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.posts (source_quote_id, audience) values (tests.qid(3), 'public') $$,
  '42501', 'new row violates row-level security policy for table "posts"',
  'without the audience trigger, the insert policy still refuses an ineligible public post'
);
select throws_ok(
  $$ update public.posts set audience = 'public' where id = tests.pid(4) $$,
  '42501', 'new row violates row-level security policy for table "posts"',
  'and the update policy refuses making one public'
);
select tests.clear_authentication();
alter table public.posts enable trigger posts_check_audience;
select tests.authenticate_as('a');
select lives_ok(
  $$ update public.posts set audience = 'friends' where id = tests.pid(7);
     update public.posts set audience = 'public' where id = tests.pid(7) $$,
  'an eligible post can be narrowed and widened again'
);
select tests.authenticate_as('b');
select results_eq(
  $$ select id from public.posts where audience = 'public' order by id $$,
  $$ values (tests.pid(7)), (tests.pid(8)) $$,
  'friends see public posts too'
);
select tests.authenticate_as('c');
select is_empty($$ select 1 from public.posts $$, 'a stranger still gets zero posts by select, public ones included');

select tests.clear_authentication();
select throws_ok(
  $$ update public.posts set audience = 'public' where id = tests.pid(4) $$,
  '42501', 'A public post can hold only a Quoted Catalog quote or a quote you added.',
  'the eligibility rule binds the table owner'
);
set local role service_role;
select throws_ok(
  $$ insert into public.posts (author_id, source_quote_id, audience) values (tests.uid('a'), tests.qid(3), 'public') $$,
  '42501', 'A public post can hold only a Quoted Catalog quote or a quote you added.',
  'and the secret key'
);
select tests.clear_authentication();

-- ---- save_from_post ----------------------------------------------------------------------------
select tests.authenticate_as('b');
select results_eq(
  $$ select id, owner_id from public.save_from_post(tests.pid(5), tests.qid(60)) $$,
  $$ values (tests.qid(60), tests.uid('b')) $$,
  'B saves A''s post into B''s own Library'
);
select is(tests.prov(60), 'shared|alice|bob', 'the saved quote keeps its creator and edited-from');
select results_eq(
  $$ select origin, creator_username, edited_from_username from public.save_from_post(tests.pid(4), tests.qid(61)) $$,
  $$ values ('shared'::text, 'bob'::text, null::text) $$,
  'saving A''s post of B''s words credits B, not the poster'
);
select results_eq(
  $$ select id, (select count(*)::int from public.quotes) from public.save_from_post(tests.pid(5), tests.qid(60)) $$,
  $$ values (tests.qid(60), 3) $$,
  'a retry with the same id returns the saved quote and adds nothing'
);
select results_eq(
  $$ select origin, creator_id, verified_starter_id, rotation_position
     from public.save_from_post(tests.pid(2), tests.qid(62), true) $$,
  $$ values ('shared'::text, null::uuid, 1::smallint, 0) $$,
  'a catalog post is saved verified with no creator; p_in_reminders adds it to the Reminders'
);
select throws_ok(
  $$ select public.save_from_post(tests.pid(999)) $$,
  '42501', 'This post is not available.',
  'a post that does not exist cannot be saved'
);
select throws_ok(
  $$ select public.save_from_post(tests.pid(5), tests.qid(1)) $$,
  '23505', null,
  'a p_id that belongs to someone else fails like the primary key'
);
select tests.clear_authentication();
update public.posts set held_at = now() where id = tests.pid(5);
select tests.authenticate_as('b');
select throws_ok(
  $$ select public.save_from_post(tests.pid(5)) $$,
  '42501', 'This post is not available.',
  'a held post cannot be saved by friends'
);
select tests.clear_authentication();
update public.posts set held_at = null where id = tests.pid(5);

select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_post(tests.pid(1)) $$,
  '42501', 'This post is not available.',
  'a stranger cannot save a friends post, even one that could be public'
);
select is(
  tests.error_of($$ select public.save_from_post(tests.pid(1)) $$),
  tests.error_of($$ select public.save_from_post(tests.pid(999)) $$),
  'and gets the same answer as for a post that does not exist'
);
select results_eq(
  $$ select owner_id, origin, creator_username from public.save_from_post(tests.pid(7), tests.qid(63)) $$,
  $$ values (tests.uid('c'), 'shared'::text, 'alice'::text) $$,
  'a stranger can save a public post (one profile_view would show), crediting its creator'
);
select tests.authenticate_as('e');
select throws_ok(
  $$ select public.save_from_post(tests.pid(1)) $$,
  '42501', 'This post is not available.',
  'someone with only a pending request cannot save a friends post'
);
select tests.authenticate_as('d');
select throws_ok(
  $$ select public.save_from_post(tests.pid(7)) $$,
  '42501', 'This post is not available.',
  'a friend A blocked cannot save, not even a public post'
);
select tests.authenticate_as('f');
select throws_ok(
  $$ select public.save_from_post(tests.pid(7)) $$,
  '42501', 'This post is not available.',
  'nor can a friend who blocked A'
);

-- Catalog quote 2 leaves the catalog: public post 8 is no longer verified, so
-- strangers lose it; friends keep it.
select tests.clear_authentication();
delete from public.starter_quotes where id = 2;
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_post(tests.pid(8)) $$,
  '42501', 'This post is not available.',
  'a public post that is no longer eligible is out of a stranger''s reach'
);
select tests.authenticate_as('b');
select results_eq(
  $$ select owner_id, creator_id, verified_starter_id from public.save_from_post(tests.pid(8)) $$,
  $$ values (tests.uid('b'), null::uuid, null::smallint) $$,
  'but a friend can still save it'
);
select tests.clear_authentication();
update public.posts set held_at = now() where id = tests.pid(7);
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_post(tests.pid(7)) $$,
  '42501', 'This post is not available.',
  'a held public post is out of a stranger''s reach'
);
select tests.authenticate_as('a');
select results_eq(
  $$ select owner_id, creator_username from public.save_from_post(tests.pid(4)) $$,
  $$ values (tests.uid('a'), 'bob'::text) $$,
  'the author may save from their own post, held or not'
);
select tests.clear_authentication();
update public.posts set held_at = null where id = tests.pid(7);

-- A's Apple identity is unlinked: A may no longer publish.
delete from auth.identities where user_id = tests.uid('a') and provider = 'apple';
select tests.authenticate_as('c');
select throws_ok(
  $$ select public.save_from_post(tests.pid(7)) $$,
  '42501', 'This post is not available.',
  'a public post stops reaching strangers once its author may no longer publish'
);
select tests.authenticate_as('b');
select isnt_empty($$ select 1 from public.posts where id = tests.pid(7) $$, 'friends still read it');
select tests.clear_authentication();
insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-alice', tests.uid('a'), '{}', 'apple');

-- A corrects a copy of B's words (8) to catalog quote 5's exact wording: A
-- becomes the creator, B "edited from", and the row is verified. Posted, it
-- is "Quoted Catalog" and names nobody.
insert into public.quotes (id, owner_id, body, origin, creator_id, creator_username)
  values (tests.qid(8), tests.uid('a'), 'Courage rises', 'shared', tests.uid('b'), 'bob');
select tests.authenticate_as('a');
update public.quotes q set body = s.body, author = s.author, source = s.source
  from public.starter_quotes s where s.id = 5 and q.id = tests.qid(8);
select is(tests.prov(8), 'shared|alice|bob', 'A''s own row keeps A as creator and B as edited-from');
select results_eq(
  $$ insert into public.posts (id, source_quote_id) values (tests.pid(9), tests.qid(8))
     returning verified_starter_id, creator_id, creator_username, edited_from_id, edited_from_username $$,
  $$ values (5::smallint, null::uuid, null::text, null::uuid, null::text) $$,
  'a verified snapshot keeps no creator or edited-from: the names in A''s row stay in A''s Library'
);
select tests.authenticate_as('b');
select results_eq(
  $$ select creator_id, creator_username, edited_from_id, edited_from_username from public.posts where id = tests.pid(9) $$,
  $$ values (null::uuid, null::text, null::uuid, null::text) $$,
  'so A''s friends read no hidden name in the post'
);
select results_eq(
  $$ select verified_starter_id, creator_id, edited_from_id from public.save_from_post(tests.pid(9), tests.qid(64)) $$,
  $$ values (5::smallint, null::uuid, null::uuid) $$,
  'nor in a copy they save'
);
select tests.clear_authentication();

set local role anon;
select throws_ok($$ select public.save_from_post(tests.pid(7)) $$, '42501', null, 'anon cannot call save_from_post');
select tests.clear_authentication();

-- ---- the secret key (service_role) -----------------------------------------------------------
select tests.clear_authentication();
insert into public.quotes (id, owner_id, body, creator_id, creator_username) values
  (tests.qid(70), tests.uid('e'), 'Eve''s words', tests.uid('e'), 'eve');
set local role service_role;
select results_eq(
  $$ insert into public.posts (author_id, source_quote_id, body, creator_id, creator_username)
     values (tests.uid('e'), tests.qid(70), 'Forged words', tests.uid('b'), 'bob')
     returning body, creator_username, created_at = now() $$,
  $$ values ('Eve''s words'::text, 'eve'::text, true) $$,
  'the secret key can post, and the server still builds the snapshot from the source'
);
select throws_ok(
  $$ insert into public.posts (author_id, source_quote_id) values (tests.uid('e'), tests.qid(30)) $$,
  '42501', 'You can post only quotes from your Library or the Quoted Catalog.',
  'and only from the author''s own quote'
);
select lives_ok(
  $$ update public.posts set held_at = now() where id = tests.pid(7);
     update public.posts set held_at = null where id = tests.pid(7) $$,
  'the secret key can hold and clear a public post'
);
select tests.clear_authentication();

-- ---- 20 posts a day ---------------------------------------------------------------------------
-- A has posted 20 times today (counting the posts A deleted since).
insert into public.posts (author_id, starter_quote_id)
  select tests.uid('a'), 1
  from generate_series(1, 20 - (select count(*)::int from public.posts
                                 where author_id = tests.uid('a') and created_at > now() - interval '24 hours')
                             - (select count(*)::int from private.limit_deletions
                                 where owner_id = tests.uid('a') and kind = 'post'
                                   and created_at > now() - interval '24 hours'));
select tests.authenticate_as('a');
select throws_ok(
  $$ insert into public.posts (starter_quote_id) values (1) $$,
  'QR001', 'You can post at most 20 quotes a day.',
  'at most 20 posts a day (QR001)'
);
select throws_ok(
  $$ insert into public.posts (id, starter_quote_id) values (tests.pid(1), 1) $$,
  '23505', null,
  'an id that already exists fails on the primary key, not the limit'
);
select results_eq(
  $$ delete from public.posts where id = tests.pid(9) returning id $$,
  $$ values (tests.pid(9)) $$,
  'A deletes one of today''s posts'
);
select throws_ok(
  $$ insert into public.posts (starter_quote_id) values (1) $$,
  'QR001', 'You can post at most 20 quotes a day.',
  'which makes no room: a deleted post still counts for the day'
);
select tests.clear_authentication();
update public.posts set created_at = now() - interval '25 hours' where author_id = tests.uid('a');
select tests.authenticate_as('a');
select lives_ok(
  $$ insert into public.posts (starter_quote_id) values (1) $$,
  'posts older than 24 hours do not count'
);
select tests.clear_authentication();

-- ---- schema details ------------------------------------------------------------------------
select results_eq(
  $$ select t.tgname::text collate "default", p.prosecdef
     from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.posts'::regclass and not t.tgisinternal
     order by 1 $$,
  $$ values ('posts_build_snapshot', false), ('posts_check_audience', false),
            ('posts_enforce_limit', true), ('posts_log_deletion', true), ('posts_stamp_created_at', false) $$,
  'the snapshot and audience triggers run as the writer; the limit and its deletion log have definer rights'
);

select * from finish();
rollback;
