-- Posts: one quote snapshot plus an optional caption, for the author and their
-- accepted friends (the Feed). Step 4 of the social redesign, built now with
-- Public ("Anyone with your username") kept off by private.can_publish().
-- Contract: docs/system-design.md section 3, and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 (Feed) and
-- 3.
-- Tests: supabase/tests/database/18_posts.test.sql (plus the adjusted 00 and
-- 05).
--
--  1. public.posts: author_id, the source (one of the author's own quotes, or
--     a Quoted Catalog quote), caption (1-280, not blank), the snapshot (body,
--     body_format, author, source, creator and edited-from pairs,
--     verified_starter_id), audience (friends (default) or public), held_at
--     (server-owned: the auto-hold and private.suspend_user set it in a later
--     migration) and created_at on the server clock.
--  2. Clients insert only id, source_quote_id, starter_quote_id, caption and
--     audience; trigger posts_build_snapshot copies everything else from the
--     author's own quote or the catalog row, at post time (a verified
--     snapshot with no creator or edited-from), and refuses any other source
--     (42501). They update only audience, and delete their own.
--     They read every column but source_quote_id, so a friend never learns
--     the author's quote ids.
--  3. Read: the author, and accepted friends with no block either way, while
--     the post is not held and the reader has not reported it. No path for
--     strangers: public posts reach them only through profile_view (a later
--     migration). Posting is a social write (terms, no suspension); the
--     caption and an unverified snapshot pass the word filter (QR003); public
--     needs private.can_publish() and an eligible snapshot (verified, or added
--     by the author with no edited-from), and a public post reaches strangers
--     only while its author may still publish. 20 posts per rolling 24 hours,
--     counting those deleted since (QR001).
--  4. public.save_from_post: saves a post's quote to the caller's Library with
--     its creator and edited-from, when the caller may see the post (the
--     select rule, or a public post they can reach as a stranger).
--
-- Existing rows: none (new table).

-- ---------------------------------------------------------------------------
-- 1. posts
-- ---------------------------------------------------------------------------
create table public.posts (
  id uuid not null default gen_random_uuid(),
  author_id uuid not null default auth.uid(),
  source_quote_id uuid,
  starter_quote_id smallint,
  caption text,
  body text not null,
  body_format jsonb not null default '[]'::jsonb,
  author text,
  source text,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text,
  verified_starter_id smallint,
  audience text not null default 'friends',
  held_at timestamptz,
  created_at timestamptz not null default now(),
  constraint posts_pkey primary key (id),
  constraint posts_author_id_fkey foreign key (author_id) references public.profiles (id) on delete cascade,
  constraint posts_source_quote_id_fkey foreign key (source_quote_id) references public.quotes (id) on delete set null,
  constraint posts_starter_quote_id_fkey foreign key (starter_quote_id) references public.starter_quotes (id) on delete set null,
  constraint posts_creator_id_fkey foreign key (creator_id, creator_username)
    references public.profiles (id, username) on delete set null,
  constraint posts_edited_from_id_fkey foreign key (edited_from_id, edited_from_username)
    references public.profiles (id, username) on delete set null,
  constraint posts_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.starter_quotes (id) on delete set null,
  constraint posts_caption_length check (char_length(caption) between 1 and 280),
  constraint posts_caption_not_blank check (not private.is_blank(caption)),
  constraint posts_body_length check (char_length(body) between 1 and 2000),
  constraint posts_body_not_blank check (not private.is_blank(body)),
  constraint posts_body_format_valid check (private.is_valid_body_format(body_format)),
  constraint posts_author_length check (char_length(author) <= 200),
  constraint posts_author_not_blank check (not private.is_blank(author)),
  constraint posts_source_length check (char_length(source) <= 200),
  constraint posts_source_not_blank check (not private.is_blank(source)),
  constraint posts_creator_pair_valid check ((creator_id is null) = (creator_username is null)),
  constraint posts_edited_from_pair_valid check ((edited_from_id is null) = (edited_from_username is null)),
  constraint posts_audience_valid check (audience in ('friends', 'public'))
);

-- The Feed and a profile's posts, newest first, and the daily limit (also
-- covers the author_id foreign key).
create index posts_author_id_created_at_id_idx on public.posts (author_id, created_at desc, id);
create index posts_source_quote_id_idx on public.posts (source_quote_id);
create index posts_starter_quote_id_idx on public.posts (starter_quote_id)
  where starter_quote_id is not null;
create index posts_creator_id_creator_username_idx on public.posts (creator_id, creator_username);
create index posts_edited_from_id_edited_from_username_idx on public.posts (edited_from_id, edited_from_username);
create index posts_verified_starter_id_idx on public.posts (verified_starter_id)
  where verified_starter_id is not null;

comment on table public.posts is
  'A quote snapshot plus an optional caption, for the author and their accepted friends (the Feed). Neither text nor caption can be edited; only the audience changes. Strangers read public posts only through profile_view. Limit: 20 per 24 hours (QR001).';
comment on column public.posts.source_quote_id is
  'The author''s own quote this post was made from; null once that quote is deleted (the post keeps its snapshot). Not readable by clients (no column grant), so friends never learn the author''s quote ids.';
comment on column public.posts.starter_quote_id is
  'The Quoted Catalog quote this post was made from. Exactly one of source_quote_id and starter_quote_id is set at insert (trigger posts_build_snapshot); either may become null later.';
comment on column public.posts.caption is
  'Optional, 1 to 280 characters, not blank. Checked against the word filter (QR003, trigger posts_build_snapshot).';
comment on column public.posts.body is
  'Server-owned snapshot (trigger posts_build_snapshot) of the source''s wording at post time, as are body_format, author, source, the creator and edited-from pairs and verified_starter_id. Checked against the word filter unless verified.';
comment on column public.posts.creator_id is
  'Server-owned (trigger posts_build_snapshot): the source''s creator at post time ("Added by"); null for verified snapshots ("Quoted Catalog", edited-from too) and when unknown or deleted. The pair with creator_username is a foreign key to profiles (id, username), so deleting that account clears both.';
comment on column public.posts.edited_from_id is
  'Server-owned (trigger posts_build_snapshot): the source''s edited-from at post time; cleared with edited_from_username when that account is deleted.';
comment on column public.posts.verified_starter_id is
  'Server-owned (trigger posts_build_snapshot): the catalog id for a catalog post, else the source quote''s verified_starter_id at post time.';
comment on column public.posts.audience is
  '"Who can see this": friends (default) or public (Anyone with your username). Public needs private.can_publish() and an eligible snapshot: verified, or added by the author with no edited-from (policies and trigger posts_check_audience).';
comment on column public.posts.held_at is
  'Server-owned (no client grant): set by the auto-hold and private.suspend_user; a held post is hidden from everyone but its author until the founder clears it.';
comment on column public.posts.created_at is
  'Server-owned (trigger posts_stamp_created_at).';

-- Clients read every column but source_quote_id, write only these columns,
-- and change only the audience; author_id comes from auth.uid().
revoke all on table public.posts from public, anon, authenticated, service_role;
grant select (id, author_id, starter_quote_id, caption, body, body_format, author, source,
              creator_id, creator_username, edited_from_id, edited_from_username, verified_starter_id,
              audience, held_at, created_at)
  on table public.posts to authenticated;
grant insert (id, source_quote_id, starter_quote_id, caption, audience) on table public.posts to authenticated;
grant update (audience) on table public.posts to authenticated;
grant delete on table public.posts to authenticated;
grant select, insert, update, delete on table public.posts to service_role;

alter table public.posts enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Access helpers
-- ---------------------------------------------------------------------------

-- True when the caller has reported this post; a reported post disappears for
-- its reporter at once. No report can name a post yet, so it is false: the
-- reports rework (20261029090300, which adds reports.post_id) replaces the
-- body with
--   select exists (select 1 from public.reports r
--                  where r.post_id = p_post and r.reporter_id = (select auth.uid()))
-- and the posts policy and private.post_access pick it up from there. SECURITY
-- INVOKER (a reporter reads their own reports), so the policy can inline it;
-- it filters by the caller explicitly, so it is also right inside SECURITY
-- DEFINER functions.
create function private.caller_reported_post(p_post uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select false
$$;
comment on function private.caller_reported_post(uuid) is
  'True when the caller has reported this post (always false until reports gain post_id in 20261029090300).';
revoke all on function private.caller_reported_post(uuid) from public, anon, service_role;
grant execute on function private.caller_reported_post(uuid) to authenticated;

-- How the caller may see a post: 'author'; 'friend' (an accepted friend of the
-- author, no block either way, the post not held and not reported by the
-- caller: exactly the select policy below); 'public' (anyone signed in, the
-- post public, not held, not reported by the caller, no block either way, its
-- snapshot still public-eligible, so a username never reaches a stranger
-- through a post that stopped being eligible, and its author still allowed to
-- publish: private.user_can_publish); null otherwise. The one access
-- rule for save_from_post (and later reports and profile_view). Called only by
-- SECURITY DEFINER functions: no API role may execute it.
create function private.post_access(p_post uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when p.author_id = v.uid then 'author'
           when p.held_at is not null then null
           when private.caller_reported_post(p.id) then null
           when exists (
             select 1 from public.blocks b
             where (b.blocker_id = p.author_id and b.blocked_id = v.uid)
                or (b.blocker_id = v.uid and b.blocked_id = p.author_id)
           ) then null
           when exists (
             select 1 from public.friendships f
             where f.status = 'accepted'
               and ((f.requester_id = v.uid and f.addressee_id = p.author_id)
                 or (f.addressee_id = v.uid and f.requester_id = p.author_id))
           ) then 'friend'
           when p.audience = 'public'
                and private.quote_is_public_eligible(p.author_id, p.verified_starter_id, p.creator_id, p.edited_from_id)
                and private.user_can_publish(p.author_id)
             then 'public'
         end
  from (select (select auth.uid()) as uid) v
  join public.posts p on p.id = p_post
  where v.uid is not null
$$;
revoke all on function private.post_access(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Row Level Security
-- ---------------------------------------------------------------------------

-- The author, and accepted friends with no block either way, while the post
-- is not held and the reader has not reported it. Nothing for strangers. The
-- friendship subquery runs under the reader's own RLS, which shows exactly
-- their own friendships; private.is_blocked_pair sees both directions. Keep
-- in step with private.post_access ('author' and 'friend').
create policy "posts: author and accepted friends read"
  on public.posts for select to authenticated
  using (
    author_id = (select auth.uid())
    or (
      held_at is null
      and exists (
        select 1 from public.friendships f
        where f.status = 'accepted'
          and ((f.requester_id = (select auth.uid()) and f.addressee_id = posts.author_id)
            or (f.addressee_id = (select auth.uid()) and f.requester_id = posts.author_id))
      )
      and not private.is_blocked_pair(posts.author_id, (select auth.uid()))
      and not private.caller_reported_post(posts.id)
    )
  );

-- Posting is a social write. The snapshot columns are already built by
-- posts_build_snapshot when this check runs.
create policy "posts: post as yourself, with terms"
  on public.posts for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and (select private.has_accepted_terms())
    and not (select private.caller_is_suspended())
    and (
      audience = 'friends'
      or ((select private.can_publish())
          and private.quote_is_public_eligible(author_id, verified_starter_id, creator_id, edited_from_id))
    )
  );

-- Column grants limit the writable column to audience. Narrowing to friends
-- is always allowed (a suspended author included); public needs
-- can_publish() (terms, no suspension, Apple) and an eligible snapshot.
create policy "posts: author changes who can see it"
  on public.posts for update to authenticated
  using (author_id = (select auth.uid()))
  with check (
    author_id = (select auth.uid())
    and (
      audience = 'friends'
      or ((select private.can_publish())
          and private.quote_is_public_eligible(author_id, verified_starter_id, creator_id, edited_from_id))
    )
  );

create policy "posts: author deletes own"
  on public.posts for delete to authenticated
  using (author_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------------

create trigger posts_stamp_created_at
  before insert on public.posts
  for each row execute function private.stamp_created_at();

-- BEFORE INSERT, every role: builds the snapshot from the post's one source,
-- whatever the writer sent.
--   clients first: accepted terms and no suspension (one answer whatever the
--     source, like friendships_check_terms);
--   exactly one of source_quote_id and starter_quote_id (23514,
--     posts_one_source);
--   source_quote_id must be the author's own quote: as a client the read runs
--     under RLS, so someone else's quote and one that does not exist fail the
--     same way (42501); starter_quote_id must exist (23503);
--   copies body, body_format, author, source, the creator and edited-from
--     pairs and verified_starter_id (the catalog id, or the quote's own
--     value); a verified snapshot keeps neither pair: it shows "Quoted
--     Catalog", and the hidden name of whoever typed or corrected that
--     wording must not reach the author's friends;
--   clients: the caption, and the snapshot unless verified, pass the word
--     filter (QR003).
-- SECURITY INVOKER so current_user tells clients apart and the author's quote
-- is read with their own rights. Client-only calls to private.* sit in their
-- own IF blocks: the secret key (service_role) has no USAGE on the private
-- schema, and a statement is resolved only when it runs.
create function private.posts_build_snapshot()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_client boolean := current_user not in ('postgres', 'service_role', 'supabase_admin');
  v_quote public.quotes;
  v_starter public.starter_quotes;
begin
  if v_client then
    perform private.assert_can_socialize();
  end if;

  if (new.source_quote_id is null) = (new.starter_quote_id is null) then
    raise exception 'A post quotes exactly one quote: one of yours or one from the Quoted Catalog.'
      using errcode = 'check_violation',
            constraint = 'posts_one_source',
            schema = 'public',
            table = 'posts',
            hint = 'Send source_quote_id or starter_quote_id, not both.';
  end if;

  if new.source_quote_id is not null then
    select q.* into v_quote
      from public.quotes q
     where q.id = new.source_quote_id
       and q.owner_id = new.author_id;
    if not found then
      raise exception 'You can post only quotes from your Library or the Quoted Catalog.'
        using errcode = 'insufficient_privilege';
    end if;
    new.body := v_quote.body;
    new.body_format := v_quote.body_format;
    new.author := v_quote.author;
    new.source := v_quote.source;
    new.creator_id := v_quote.creator_id;
    new.creator_username := v_quote.creator_username;
    new.edited_from_id := v_quote.edited_from_id;
    new.edited_from_username := v_quote.edited_from_username;
    new.verified_starter_id := v_quote.verified_starter_id;
  else
    select s.* into v_starter
      from public.starter_quotes s
     where s.id = new.starter_quote_id;
    if not found then
      raise exception 'catalog quote % does not exist', new.starter_quote_id
        using errcode = 'foreign_key_violation';
    end if;
    new.body := v_starter.body;
    new.body_format := v_starter.body_format;
    new.author := v_starter.author;
    new.source := v_starter.source;
    new.creator_id := null;
    new.creator_username := null;
    new.edited_from_id := null;
    new.edited_from_username := null;
    new.verified_starter_id := v_starter.id;
  end if;

  if new.verified_starter_id is not null then
    new.creator_id := null;
    new.creator_username := null;
    new.edited_from_id := null;
    new.edited_from_username := null;
  end if;

  if v_client then
    if new.verified_starter_id is null then
      perform private.assert_allowed_text(
        new.caption,
        new.body || ' ' || coalesce(new.author, '') || ' ' || coalesce(new.source, '')
      );
    else
      perform private.assert_allowed_text(new.caption);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.posts_build_snapshot() from public, anon, authenticated;

create trigger posts_build_snapshot
  before insert on public.posts
  for each row execute function private.posts_build_snapshot();

-- BEFORE INSERT OR UPDATE (it sorts after posts_build_snapshot, so the
-- snapshot is built). The policies are the rule for clients; this gives them a
-- clear answer first, and binds every role to eligibility:
--   clients: public needs accepted terms and no suspension, then the rest of
--     private.can_publish(), a linked Apple identity (42501 each, with its
--     own message);
--   every role: a public post's snapshot must be verified or added by the
--     author with no edited-from (42501). Clients are checked on every update
--     of a public post, as the policy does; the server only when a post
--     becomes public, so a foreign key's set null never fails.
-- SECURITY INVOKER so current_user tells clients apart; the every-role check
-- reads only the row.
create function private.posts_check_audience()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_client boolean := current_user not in ('postgres', 'service_role', 'supabase_admin');
begin
  if new.audience <> 'public' then
    return new;
  end if;
  if not v_client and tg_op = 'UPDATE' and old.audience = 'public' then
    return new;
  end if;

  if v_client then
    perform private.assert_can_socialize();
    if not private.can_publish() then
      raise exception 'Only accounts backed up with Sign in with Apple can make a post public.'
        using errcode = 'insufficient_privilege', hint = 'Choose Friends.';
    end if;
  end if;

  if not coalesce(
       new.verified_starter_id is not null
         or (new.creator_id = new.author_id and new.edited_from_id is null),
       false) then
    raise exception 'A public post can hold only a Quoted Catalog quote or a quote you added.'
      using errcode = 'insufficient_privilege',
            hint = 'Choose Friends, or post a quote you added.';
  end if;
  return new;
end;
$$;
revoke all on function private.posts_check_audience() from public, anon, authenticated;

create trigger posts_check_audience
  before insert or update on public.posts
  for each row execute function private.posts_check_audience();

-- 20 posts per author per rolling 24 hours (QR001), counting those deleted
-- since (private.limit_deletions). Every role: the counts filter by author_id
-- explicitly. A client posting as someone else is left to the insert policy
-- (42501), so nothing about that person's count shows. A per-author advisory
-- lock serializes one author's inserts. An id that already exists is left to
-- the primary key (23505), so an idempotent retry is not counted as new.
-- SECURITY DEFINER (the deletion log has no API grants); VOLATILE so the count
-- sees the rows earlier in the statement.
create function private.posts_enforce_limit()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.posts p where p.id = new.id) then
    return new;
  end if;
  if (select auth.uid()) is not null and new.author_id is distinct from (select auth.uid()) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.posts:' || new.author_id::text, 0));

  delete from private.limit_deletions d
   where d.owner_id = new.author_id
     and d.kind = 'post'
     and d.created_at <= now() - interval '24 hours';

  if (select count(*) from (
        select 1 from public.posts p
        where p.author_id = new.author_id
          and p.created_at > now() - interval '24 hours'
        limit 20) recent)
     + (select count(*) from (
        select 1 from private.limit_deletions d
        where d.owner_id = new.author_id
          and d.kind = 'post'
          and d.created_at > now() - interval '24 hours'
        limit 20) deleted) >= 20 then
    raise exception 'You can post at most 20 quotes a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;
  return new;
end;
$$;
revoke all on function private.posts_enforce_limit() from public, anon, authenticated;

create trigger posts_enforce_limit
  before insert on public.posts
  for each row execute function private.posts_enforce_limit();

-- A post deleted directly (by its author, or the founder) within a day of
-- being made still counts toward its author's daily limit. Cascades (account
-- deletion) run inside another trigger and log nothing; BEFORE DELETE, since
-- only then does pg_trigger_depth() tell them apart (the AFTER triggers of a
-- cascade fire with the outer statement). SECURITY DEFINER: the log has no
-- API grants.
create function private.posts_log_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() = 1 and old.created_at > now() - interval '24 hours' then
    insert into private.limit_deletions (owner_id, kind, created_at)
    values (old.author_id, 'post', old.created_at);
  end if;
  return old;
end;
$$;
revoke all on function private.posts_log_deletion() from public, anon, authenticated;

create trigger posts_log_deletion
  before delete on public.posts
  for each row execute function private.posts_log_deletion();

-- ---------------------------------------------------------------------------
-- 5. save_from_post
-- ---------------------------------------------------------------------------

-- Saves a post's quote to the caller's Library: origin shared, the post's
-- snapshot with its creator and edited-from (never the poster, unless they are
-- the creator). Refused with 42501, the same answer for every reason, unless
-- the caller may see the post (private.post_access: the author, a friend under
-- the select rule, or a stranger reaching a public post as profile_view
-- would). A p_id the caller already owns returns that quote unchanged (an
-- idempotent retry).
create function private.save_from_post(
  p_post uuid,
  p_id uuid default null,
  p_in_reminders boolean default false
)
returns public.quotes
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_existing public.quotes;
  v_post public.posts;
begin
  if v_uid is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;

  v_existing := private.caller_quote_for_retry(p_id);
  if v_existing.id is not null then
    return v_existing;
  end if;

  select p.* into v_post
    from public.posts p
   where p.id = p_post
     and private.post_access(p.id) is not null;
  if not found then
    raise exception 'This post is not available.' using errcode = 'insufficient_privilege';
  end if;

  return private.insert_caller_quote(
    p_id, v_post.body, v_post.body_format, v_post.author, v_post.source, 'shared',
    v_post.creator_id, v_post.creator_username, v_post.edited_from_id, v_post.edited_from_username,
    p_in_reminders
  );
end;
$$;
revoke all on function private.save_from_post(uuid, uuid, boolean) from public, anon, service_role;
grant execute on function private.save_from_post(uuid, uuid, boolean) to authenticated;

create function public.save_from_post(
  p_post uuid,
  p_id uuid default null,
  p_in_reminders boolean default false
)
returns public.quotes
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.save_from_post(p_post, p_id, p_in_reminders)
$$;
comment on function public.save_from_post(uuid, uuid, boolean) is
  'Saves a post''s quote to the caller''s Library with origin shared and the original creator and edited-from. 42501 unless the caller may see the post (author; accepted friend, not held, no block; or a public post a stranger can reach). SECURITY INVOKER wrapper over private.save_from_post.';
revoke all on function public.save_from_post(uuid, uuid, boolean) from public, anon, service_role;
grant execute on function public.save_from_post(uuid, uuid, boolean) to authenticated;
