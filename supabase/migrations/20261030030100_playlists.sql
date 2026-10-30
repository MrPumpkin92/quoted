-- Playlists: a named, ordered list of quotes from the owner's own Library,
-- which friends (and, once Public ships, anyone with the owner's username) can
-- view live, save from, and copy. Step 5 of the social redesign, built now
-- with Public kept off by private.can_publish().
-- Contract: docs/system-design.md section 3, and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 (Playlists)
-- and 3.
-- Tests: supabase/tests/database/17_playlists.test.sql (plus the adjusted 00
-- and 05).
--
--  1. public.playlists: owner_id, title (1-60, not blank, word filter QR003),
--     visibility (private, friends (default) or public), held_at (server-owned:
--     the auto-hold and private.suspend_user set it in a later migration),
--     created_at and updated_at on the server clock. Owner only. A visibility
--     other than private needs accepted terms and no suspension; public also
--     needs private.can_publish() (false for everyone until Sign in with Apple
--     linking ships) and every item eligible. 20 new per rolling 24 hours,
--     counting those deleted since (private.limit_deletions) (QR001), and 100
--     in all (QR002) per owner.
--  2. public.playlist_items: (playlist_id, quote_id), position, added_at.
--     Owner only, and the quote must be the owner's own. 200 per playlist
--     (QR002). A quote that is not public-eligible (verified, or added by the
--     owner with no edited-from) cannot go into a public playlist (42501).
--     Adding an item to a playlist others can see is a social write (terms,
--     no suspension), and to a public one needs private.can_publish(). Every
--     item change moves the playlist's updated_at.
--  3. public.playlist_view(id): the live, read-only view for the owner, an
--     accepted friend (friends or public, not held, no block either way) and,
--     for a public playlist, anyone signed in with no block either way while
--     its owner may still publish.
--     Items carry a per-viewer handle, never the quote id; creator usernames
--     only for unverified items; unverified items holding a blocked term are
--     skipped; a viewer who reaches a public playlist only because it is
--     public sees only its eligible items.
--  4. public.save_from_playlist and public.save_playlist_copy: save one item,
--     or copy the whole visible list into a new private playlist of the
--     caller's. Each quote keeps its creator and edited-from; a quote whose
--     text and author the caller already holds is reused, not duplicated.
--
-- Existing rows: none (new tables).

-- ---------------------------------------------------------------------------
-- 1. Public eligibility
-- ---------------------------------------------------------------------------

-- The rule that keeps other people's usernames away from strangers: a quote
-- can be shown publicly by its holder when it is verified (a Quoted Catalog
-- quote, shown with no creator) or when the holder added it themselves with
-- no "edited from". Used by the playlist policies and views here and by posts
-- later; executable by the writing roles because policies call it. Trigger
-- code that the secret key also runs spells the rule out instead (service_role
-- has no USAGE on the private schema).
create function private.quote_is_public_eligible(
  p_holder uuid,
  p_verified_starter_id integer,
  p_creator_id uuid,
  p_edited_from_id uuid
)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(
    p_verified_starter_id is not null
      or (p_creator_id = p_holder and p_edited_from_id is null),
    false
  )
$$;
comment on function private.quote_is_public_eligible(uuid, integer, uuid, uuid) is
  'True when a quote held by p_holder may be shown to strangers: verified, or created by p_holder with no edited-from.';
revoke all on function private.quote_is_public_eligible(uuid, integer, uuid, uuid) from public, anon;
grant execute on function private.quote_is_public_eligible(uuid, integer, uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. playlists
-- ---------------------------------------------------------------------------
create table public.playlists (
  id uuid not null default gen_random_uuid(),
  owner_id uuid not null default auth.uid(),
  title text not null,
  visibility text not null default 'friends',
  held_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint playlists_pkey primary key (id),
  constraint playlists_owner_id_fkey foreign key (owner_id) references public.profiles (id) on delete cascade,
  constraint playlists_title_length check (char_length(title) between 1 and 60),
  constraint playlists_title_not_blank check (not private.is_blank(title)),
  constraint playlists_visibility_valid check (visibility in ('private', 'friends', 'public'))
);

-- The owner's list and the daily limit (also covers the owner_id foreign key).
create index playlists_owner_id_created_at_idx on public.playlists (owner_id, created_at);

comment on table public.playlists is
  'A named, ordered list of quotes from the owner''s own Library. Owner only; everyone else reads it through public.playlist_view (and later profile_view). Limits: 20 new per 24 hours (QR001), 100 per owner (QR002).';
comment on column public.playlists.title is
  '1 to 60 characters, not blank. Checked against the word filter (QR003, trigger playlists_check_write).';
comment on column public.playlists.visibility is
  '"Who can see this": private (Only me), friends (default) or public (Anyone with your username). Friends and public need accepted terms and no suspension; public needs private.can_publish() and every item public-eligible (policies and trigger playlists_check_write).';
comment on column public.playlists.held_at is
  'Server-owned (no client grant): set by the auto-hold and private.suspend_user; a held playlist is hidden from everyone but its owner until the founder clears it.';
comment on column public.playlists.created_at is
  'Server-owned (trigger playlists_stamp_created_at).';
comment on column public.playlists.updated_at is
  'Server-owned (trigger playlists_set_updated_at, and playlist_items_bump_playlist when an item is added, moved or removed).';

-- Clients write only these columns; owner_id comes from auth.uid().
revoke all on table public.playlists from public, anon, authenticated, service_role;
grant select, delete on table public.playlists to authenticated;
grant insert (id, title, visibility) on table public.playlists to authenticated;
grant update (title, visibility) on table public.playlists to authenticated;
grant select, insert, update, delete on table public.playlists to service_role;

alter table public.playlists enable row level security;

-- ---------------------------------------------------------------------------
-- 3. playlist_items
-- ---------------------------------------------------------------------------
create table public.playlist_items (
  playlist_id uuid not null,
  quote_id uuid not null,
  position integer not null,
  added_at timestamptz not null default now(),
  constraint playlist_items_pkey primary key (playlist_id, quote_id),
  constraint playlist_items_playlist_id_fkey foreign key (playlist_id) references public.playlists (id) on delete cascade,
  constraint playlist_items_quote_id_fkey foreign key (quote_id) references public.quotes (id) on delete cascade,
  constraint playlist_items_position_nonnegative check (position >= 0)
);

-- The primary key leads with playlist_id (its foreign key index).
create index playlist_items_quote_id_idx on public.playlist_items (quote_id);
create index playlist_items_playlist_id_position_idx on public.playlist_items (playlist_id, position);

comment on table public.playlist_items is
  'The quotes in a playlist, each one of the owner''s own quotes. Owner only. 200 per playlist (QR002). Deleting the quote removes the item; saved copies elsewhere stay.';
comment on column public.playlist_items.position is
  'Order in the playlist, 0 or more. The owner may reorder; positions need not be unique or dense.';
comment on column public.playlist_items.added_at is
  'Server-owned (trigger playlist_items_stamp_added_at).';

revoke all on table public.playlist_items from public, anon, authenticated, service_role;
grant select, delete on table public.playlist_items to authenticated;
grant insert (playlist_id, quote_id, position) on table public.playlist_items to authenticated;
grant update (position) on table public.playlist_items to authenticated;
grant select, insert, update, delete on table public.playlist_items to service_role;

alter table public.playlist_items enable row level security;

-- True when every item of the playlist is public-eligible for its owner (an
-- empty playlist is). SECURITY INVOKER: called by the playlists policies and
-- trigger, where the caller is the owner and reads every item and quote of
-- their own; for anyone else it sees no items, and the ownership checks it is
-- combined with refuse them anyway.
create function private.playlist_is_public_eligible(p_playlist uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select not exists (
    select 1
    from public.playlist_items i
    join public.playlists p on p.id = i.playlist_id
    join public.quotes q on q.id = i.quote_id
    where i.playlist_id = p_playlist
      and not private.quote_is_public_eligible(p.owner_id, q.verified_starter_id, q.creator_id, q.edited_from_id)
  )
$$;
comment on function private.playlist_is_public_eligible(uuid) is
  'True when every item of the playlist is verified or added by its owner with no edited-from, so the playlist may be public.';
revoke all on function private.playlist_is_public_eligible(uuid) from public, anon, service_role;
grant execute on function private.playlist_is_public_eligible(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------

-- playlists: owner only. A visibility others can see is a social write.
create policy "playlists: owner reads own"
  on public.playlists for select to authenticated
  using (owner_id = (select auth.uid()));

create policy "playlists: owner creates, wider visibility needs terms"
  on public.playlists for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and (
      visibility = 'private'
      or ((select private.has_accepted_terms()) and not (select private.caller_is_suspended()))
    )
    and (
      visibility <> 'public'
      or ((select private.can_publish()) and private.playlist_is_public_eligible(id))
    )
  );

create policy "playlists: owner updates, wider visibility needs terms"
  on public.playlists for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and (
      visibility = 'private'
      or ((select private.has_accepted_terms()) and not (select private.caller_is_suspended()))
    )
    and (
      visibility <> 'public'
      or ((select private.can_publish()) and private.playlist_is_public_eligible(id))
    )
  );

create policy "playlists: owner deletes own"
  on public.playlists for delete to authenticated
  using (owner_id = (select auth.uid()));

-- playlist_items: the playlist's owner only, and only their own quotes. Each
-- subquery runs under the caller's own RLS, which shows exactly their own
-- playlists and quotes, so someone else's quote id and an unknown one fail
-- the same way (42501).
create policy "playlist_items: playlist owner reads"
  on public.playlist_items for select to authenticated
  using (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_items.playlist_id and p.owner_id = (select auth.uid())
    )
  );

create policy "playlist_items: playlist owner adds own quotes"
  on public.playlist_items for insert to authenticated
  with check (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_items.playlist_id and p.owner_id = (select auth.uid())
    )
    and exists (
      select 1 from public.quotes q
      where q.id = playlist_items.quote_id and q.owner_id = (select auth.uid())
    )
  );

-- Column grants limit the writable column to position.
create policy "playlist_items: playlist owner reorders"
  on public.playlist_items for update to authenticated
  using (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_items.playlist_id and p.owner_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_items.playlist_id and p.owner_id = (select auth.uid())
    )
    and exists (
      select 1 from public.quotes q
      where q.id = playlist_items.quote_id and q.owner_id = (select auth.uid())
    )
  );

create policy "playlist_items: playlist owner removes"
  on public.playlist_items for delete to authenticated
  using (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_items.playlist_id and p.owner_id = (select auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 5. playlists: triggers
-- ---------------------------------------------------------------------------

create trigger playlists_stamp_created_at
  before insert on public.playlists
  for each row execute function private.stamp_created_at();

create trigger playlists_set_updated_at
  before insert or update on public.playlists
  for each row execute function private.set_updated_at();

-- The policies above are the rule; this BEFORE trigger gives a client a clear
-- answer first, in this order: terms and suspension (a visibility others can
-- see), the word filter on the title (on insert, on a new title, and when the
-- visibility widens, so a term added later never stops the owner narrowing
-- it), then Public: private.can_publish() and every item eligible. For every
-- role, a change to public re-checks the items (the server and the founder
-- included). It runs with the playlist row locked by the update, and
-- playlist_items_check_insert locks the same row, so an item insert and a
-- change to public cannot pass each other. SECURITY INVOKER so current_user
-- tells clients apart; VOLATILE so the item check sees committed items. The
-- every-role check spells out private.quote_is_public_eligible over public
-- tables only: the secret key (service_role) has no USAGE on the private
-- schema, and the client-only branch is never parsed for it.
create function private.playlists_check_write()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_client boolean := current_user not in ('postgres', 'service_role', 'supabase_admin');
  v_widens boolean;
begin
  if v_client then
    if new.visibility <> 'private' then
      perform private.assert_can_socialize();
    end if;

    if tg_op = 'INSERT' then
      v_widens := true;
    else
      v_widens := new.title is distinct from old.title
        or array_position(array['private', 'friends', 'public'], new.visibility)
           > array_position(array['private', 'friends', 'public'], old.visibility);
    end if;
    if coalesce(v_widens, false) then
      perform private.assert_allowed_text(new.title);
    end if;

    if new.visibility = 'public' and not private.can_publish() then
      raise exception 'Only accounts backed up with Sign in with Apple can make a playlist public.'
        using errcode = 'insufficient_privilege', hint = 'Choose Friends or Only me.';
    end if;
  end if;

  if tg_op = 'UPDATE'
     and new.visibility = 'public'
     and (v_client or old.visibility is distinct from 'public')
     and exists (
       select 1
       from public.playlist_items i
       join public.quotes q on q.id = i.quote_id
       where i.playlist_id = new.id
         and not coalesce(
               q.verified_starter_id is not null
                 or (q.creator_id = new.owner_id and q.edited_from_id is null),
               false)
     ) then
    raise exception 'A public playlist can hold only Quoted Catalog quotes and quotes you added.'
      using errcode = 'insufficient_privilege',
            hint = 'Remove the quotes other people added, or choose Friends or Only me.';
  end if;
  return new;
end;
$$;
revoke all on function private.playlists_check_write() from public, anon, authenticated;

create trigger playlists_check_write
  before insert or update on public.playlists
  for each row execute function private.playlists_check_write();

-- Things deleted within a day of being made. A daily limit counts them with
-- the live ones, so deleting does not make room for more the same day:
-- playlists here, posts in 20261030030200 (unsent messages are counted from
-- private.message_tombstones). Written by the AFTER DELETE triggers
-- playlists_log_deletion and posts_log_deletion; each limit trigger clears
-- the owner's rows that no longer count, so an owner holds at most a day's
-- worth (no more than the limit). Gone with the account.
create table private.limit_deletions (
  id bigint generated always as identity,
  owner_id uuid not null,
  kind text not null,
  created_at timestamptz not null,
  constraint limit_deletions_pkey primary key (id),
  constraint limit_deletions_owner_id_fkey foreign key (owner_id) references auth.users (id) on delete cascade,
  constraint limit_deletions_kind_valid check (kind in ('playlist', 'post'))
);
create index limit_deletions_owner_id_kind_created_at_idx on private.limit_deletions (owner_id, kind, created_at);
comment on table private.limit_deletions is
  'Playlists and posts deleted within a day of being made (created_at is when they were made), so the daily limits still count them. Written by triggers playlists_log_deletion and posts_log_deletion, trimmed by the limit triggers. No API role can read it.';
revoke all on table private.limit_deletions from public, anon, authenticated, service_role;

-- 20 new playlists per owner per rolling 24 hours (QR001), counting those
-- deleted since (private.limit_deletions), and 100 in all (QR002). Every
-- role, the secret key and the save functions included; the counts filter by
-- owner_id explicitly. A client writing a playlist for someone else is left
-- to the insert policy (42501), so nothing about that person's counts shows.
-- A per-owner advisory lock serializes one owner's inserts. An id that
-- already exists is left to the primary key (23505), so an idempotent retry
-- is not counted as new. SECURITY DEFINER: the deletion log has no API
-- grants.
create function private.playlists_enforce_limits()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.playlists p where p.id = new.id) then
    return new;
  end if;
  if (select auth.uid()) is not null and new.owner_id is distinct from (select auth.uid()) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.playlists:' || new.owner_id::text, 0));

  delete from private.limit_deletions d
   where d.owner_id = new.owner_id
     and d.kind = 'playlist'
     and d.created_at <= now() - interval '24 hours';

  if (select count(*) from (
        select 1 from public.playlists p
        where p.owner_id = new.owner_id
          and p.created_at > now() - interval '24 hours'
        limit 20) recent)
     + (select count(*) from (
        select 1 from private.limit_deletions d
        where d.owner_id = new.owner_id
          and d.kind = 'playlist'
          and d.created_at > now() - interval '24 hours'
        limit 20) deleted) >= 20 then
    raise exception 'You can make at most 20 playlists a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;

  if (select count(*) from (
        select 1 from public.playlists p
        where p.owner_id = new.owner_id
        limit 100) mine) >= 100 then
    raise exception 'You can keep at most 100 playlists.'
      using errcode = 'QR002', hint = 'Delete a playlist to make a new one.';
  end if;
  return new;
end;
$$;
revoke all on function private.playlists_enforce_limits() from public, anon, authenticated;

create trigger playlists_enforce_limits
  before insert on public.playlists
  for each row execute function private.playlists_enforce_limits();

-- A playlist deleted directly (by its owner, or the founder) within a day of
-- being made still counts toward its owner's daily limit. Cascades (account
-- deletion) run inside another trigger and log nothing; BEFORE DELETE, since
-- only then does pg_trigger_depth() tell them apart (the AFTER triggers of a
-- cascade fire with the outer statement). SECURITY DEFINER: the log has no
-- API grants.
create function private.playlists_log_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() = 1 and old.created_at > now() - interval '24 hours' then
    insert into private.limit_deletions (owner_id, kind, created_at)
    values (old.owner_id, 'playlist', old.created_at);
  end if;
  return old;
end;
$$;
revoke all on function private.playlists_log_deletion() from public, anon, authenticated;

create trigger playlists_log_deletion
  before delete on public.playlists
  for each row execute function private.playlists_log_deletion();

-- ---------------------------------------------------------------------------
-- 6. playlist_items: triggers
-- ---------------------------------------------------------------------------

create function private.playlist_items_stamp_added_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.added_at := now();
  return new;
end;
$$;
revoke all on function private.playlist_items_stamp_added_at() from public, anon, authenticated;

create trigger playlist_items_stamp_added_at
  before insert on public.playlist_items
  for each row execute function private.playlist_items_stamp_added_at();

-- BEFORE INSERT. A pair that already exists is left to the primary key (or
-- the upsert's update). Otherwise it locks the playlist row (so item inserts
-- and a change to public run one at a time) and checks, in order:
--   clients: a playlist others can see needs accepted terms and no suspension,
--     and a public one private.can_publish(), as renaming it would;
--   every role: at most 200 items (QR002), counted by playlist_id explicitly;
--   every role: a public playlist takes only public-eligible quotes (42501).
-- As a client the lock and reads run under RLS: a playlist or quote that is
-- not the caller's is not found, the checks are skipped, and the insert
-- policy refuses it (42501) without revealing anything about it. SECURITY
-- INVOKER; VOLATILE so the count sees the rows earlier in the statement. The
-- eligibility test spells out private.quote_is_public_eligible because the
-- secret key (service_role) has no USAGE on the private schema.
create function private.playlist_items_check_insert()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_playlist public.playlists;
  v_quote public.quotes;
begin
  if exists (
    select 1 from public.playlist_items i
    where i.playlist_id = new.playlist_id and i.quote_id = new.quote_id
  ) then
    return new;
  end if;

  select p.* into v_playlist
    from public.playlists p
   where p.id = new.playlist_id
     for no key update;
  if not found then
    return new;
  end if;

  if current_user not in ('postgres', 'service_role', 'supabase_admin') and v_playlist.visibility <> 'private' then
    perform private.assert_can_socialize();
    if v_playlist.visibility = 'public' and not private.can_publish() then
      raise exception 'Only accounts backed up with Sign in with Apple can add to a public playlist.'
        using errcode = 'insufficient_privilege', hint = 'Choose Friends or Only me for this playlist first.';
    end if;
  end if;

  if (select count(*) from (
        select 1 from public.playlist_items i
        where i.playlist_id = new.playlist_id
        limit 200) items) >= 200 then
    raise exception 'A playlist can hold at most 200 quotes.'
      using errcode = 'QR002', hint = 'Remove a quote to add another.';
  end if;

  if v_playlist.visibility = 'public' then
    select q.* into v_quote from public.quotes q where q.id = new.quote_id;
    if found and not coalesce(
         v_quote.verified_starter_id is not null
           or (v_quote.creator_id = v_playlist.owner_id and v_quote.edited_from_id is null),
         false) then
      raise exception 'A public playlist can hold only Quoted Catalog quotes and quotes you added.'
        using errcode = 'insufficient_privilege',
              hint = 'Choose a quote you added or one from the Quoted Catalog.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.playlist_items_check_insert() from public, anon, authenticated;

create trigger playlist_items_check_insert
  before insert on public.playlist_items
  for each row execute function private.playlist_items_check_insert();

-- An item added, moved or removed (by the owner, or by a cascade when its
-- quote is deleted) moves the playlist's updated_at to the server clock, at
-- most once per transaction. SECURITY DEFINER: clients cannot write
-- updated_at. A playlist being deleted is already gone and is not touched.
create function private.playlist_items_bump_playlist()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.playlists p
     set updated_at = now()
   where p.id = case when tg_op = 'DELETE' then old.playlist_id else new.playlist_id end
     and p.updated_at < now();
  return null;
end;
$$;
revoke all on function private.playlist_items_bump_playlist() from public, anon, authenticated;

create trigger playlist_items_bump_playlist
  after insert or update or delete on public.playlist_items
  for each row execute function private.playlist_items_bump_playlist();

-- ---------------------------------------------------------------------------
-- 7. playlist_view
-- ---------------------------------------------------------------------------

-- How the caller may see a playlist: 'owner'; 'friend' (an accepted friend of
-- the owner, the playlist friends or public and not held, no block either
-- way); 'public' (anyone signed in, the playlist public and not held, no block
-- either way, and its owner still allowed to publish: private.user_can_publish);
-- null otherwise (signed out, unknown, private, held, blocked, not a friend). The one access rule for playlist_view and the save functions
-- (and later reports and profile_view). Called only by those SECURITY DEFINER
-- functions: no API role may execute it.
create function private.playlist_access(p_playlist uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when p.owner_id = v.uid then 'owner'
           when p.held_at is not null then null
           when exists (
             select 1 from public.blocks b
             where (b.blocker_id = p.owner_id and b.blocked_id = v.uid)
                or (b.blocker_id = v.uid and b.blocked_id = p.owner_id)
           ) then null
           when p.visibility in ('friends', 'public') and exists (
             select 1 from public.friendships f
             where f.status = 'accepted'
               and ((f.requester_id = v.uid and f.addressee_id = p.owner_id)
                 or (f.addressee_id = v.uid and f.requester_id = p.owner_id))
           ) then 'friend'
           when p.visibility = 'public' and private.user_can_publish(p.owner_id) then 'public'
         end
  from (select (select auth.uid()) as uid) v
  join public.playlists p on p.id = p_playlist
  where v.uid is not null
$$;
revoke all on function private.playlist_access(uuid) from public, anon, authenticated, service_role;

-- The items the caller may see, in no particular order (callers order by
-- item_position, added_at, handle): none without access; unverified items
-- holding a blocked term are skipped (a read-time check, so live edits and
-- terms added later are covered); a viewer whose only access is 'public' sees
-- only public-eligible items, so a username never reaches a stranger through
-- an item that stopped being eligible after it was added. handle is
-- md5(quote id, viewer) as a uuid, as in friend_favorites. The access rule is
-- worked out once per call (a materialized CTE: inlined, it would run for
-- every item). Returns the quote ids and creator ids, so only the SECURITY
-- DEFINER functions here call it.
create function private.playlist_visible_items(p_playlist uuid)
returns table (
  quote_id uuid,
  handle uuid,
  item_position integer,
  added_at timestamptz,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id integer,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text
)
language sql
stable
security definer
set search_path = ''
as $$
  with a as materialized (
    select private.playlist_access(p_playlist) as kind
  )
  select q.id,
         md5(q.id::text || ':' || (select auth.uid())::text)::uuid,
         i.position,
         i.added_at,
         q.body, q.body_format, q.author, q.source, q.verified_starter_id,
         q.creator_id, q.creator_username, q.edited_from_id, q.edited_from_username
  from a
  join public.playlists p on p.id = p_playlist
  join public.playlist_items i on i.playlist_id = p.id
  join public.quotes q on q.id = i.quote_id and q.owner_id = p.owner_id
  where a.kind is not null
    and (
      q.verified_starter_id is not null
      or not private.has_blocked_term(q.body || ' ' || coalesce(q.author, '') || ' ' || coalesce(q.source, ''))
    )
    and (
      a.kind <> 'public'
      or private.quote_is_public_eligible(p.owner_id, q.verified_starter_id, q.creator_id, q.edited_from_id)
    )
$$;
revoke all on function private.playlist_visible_items(uuid) from public, anon, authenticated, service_role;

-- The live, read-only view of one playlist, or null when the caller may not
-- see it (see private.playlist_access; the same null for every reason):
--   { "playlist": {id, title, visibility, updated_at, owner: {id, username, display_name}},
--     "items": [ {handle, position, body, body_format, author, source,
--                 verified_starter_id, creator_username, edited_from_username} ] }
-- Items are ordered by position; creator and edited-from usernames are null
-- for verified items ("Quoted Catalog"). Never a quote id, held_at or any
-- private profile column. SECURITY DEFINER to read past the owner-only
-- policies; it answers only through playlist_access.
create function private.playlist_view(p_playlist uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'playlist', jsonb_build_object(
      'id', p.id,
      'title', p.title,
      'visibility', p.visibility,
      'updated_at', p.updated_at,
      'owner', jsonb_build_object('id', o.id, 'username', o.username, 'display_name', o.display_name)
    ),
    'items', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'handle', v.handle,
                 'position', v.item_position,
                 'body', v.body,
                 'body_format', v.body_format,
                 'author', v.author,
                 'source', v.source,
                 'verified_starter_id', v.verified_starter_id,
                 'creator_username', case when v.verified_starter_id is null then v.creator_username end,
                 'edited_from_username', case when v.verified_starter_id is null then v.edited_from_username end
               )
               order by v.item_position, v.added_at, v.handle
             )
      from private.playlist_visible_items(p.id) v
    ), '[]'::jsonb)
  )
  from public.playlists p
  join public.profiles o on o.id = p.owner_id
  where p.id = p_playlist
    and private.playlist_access(p.id) is not null
$$;
revoke all on function private.playlist_view(uuid) from public, anon, service_role;
grant execute on function private.playlist_view(uuid) to authenticated;

create function public.playlist_view(p_playlist uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.playlist_view(p_playlist)
$$;
comment on function public.playlist_view(uuid) is
  'The live, read-only view of a playlist the caller may see (owner; accepted friend for friends or public; anyone signed in for public; never held or across a block), else null. Items carry a per-viewer handle for save_from_playlist. SECURITY INVOKER wrapper over private.playlist_view.';
revoke all on function public.playlist_view(uuid) from public, anon, service_role;
grant execute on function public.playlist_view(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. save_from_playlist and save_playlist_copy
-- ---------------------------------------------------------------------------

-- Saves one item of a playlist the caller can see (p_handle from
-- playlist_view) to the caller's Library: origin shared, the source's text,
-- creator and edited-from (never the playlist owner, unless they are the
-- creator). Refused with 42501, the same answer for every reason, unless
-- playlist_view shows that item to the caller right now. A p_id the caller
-- already owns returns that quote unchanged (an idempotent retry); a quote
-- with the same text and author already in the caller's Library is returned
-- unchanged instead of a duplicate (its id may differ from p_id).
create function private.save_from_playlist(
  p_playlist uuid,
  p_handle uuid,
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
  v_item record;
begin
  if v_uid is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;

  v_existing := private.caller_quote_for_retry(p_id);
  if v_existing.id is not null then
    return v_existing;
  end if;

  select v.* into v_item
    from private.playlist_visible_items(p_playlist) v
   where v.handle = p_handle;
  if not found then
    raise exception 'This quote is not available.' using errcode = 'insufficient_privilege';
  end if;

  select q.* into v_existing
    from public.quotes q
   where q.owner_id = v_uid
     and q.body = v_item.body
     and q.author is not distinct from v_item.author
   order by q.created_at, q.id
   limit 1;
  if found then
    return v_existing;
  end if;

  return private.insert_caller_quote(
    p_id, v_item.body, v_item.body_format, v_item.author, v_item.source, 'shared',
    v_item.creator_id, v_item.creator_username, v_item.edited_from_id, v_item.edited_from_username,
    p_in_reminders
  );
end;
$$;
revoke all on function private.save_from_playlist(uuid, uuid, uuid, boolean) from public, anon, service_role;
grant execute on function private.save_from_playlist(uuid, uuid, uuid, boolean) to authenticated;

create function public.save_from_playlist(
  p_playlist uuid,
  p_handle uuid,
  p_id uuid default null,
  p_in_reminders boolean default false
)
returns public.quotes
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.save_from_playlist(p_playlist, p_handle, p_id, p_in_reminders)
$$;
comment on function public.save_from_playlist(uuid, uuid, uuid, boolean) is
  'Saves one item of a playlist (its playlist_view handle) to the caller''s Library with origin shared and the original creator; returns the caller''s existing quote instead when one has the same text and author. 42501 unless playlist_view shows the item to the caller. SECURITY INVOKER wrapper over private.save_from_playlist.';
revoke all on function public.save_from_playlist(uuid, uuid, uuid, boolean) from public, anon, service_role;
grant execute on function public.save_from_playlist(uuid, uuid, uuid, boolean) to authenticated;

-- "Save a Copy": a new playlist owned by the caller, titled p_title or the
-- original title (word filter QR003 either way), visibility private, holding
-- the items playlist_view shows the caller, in order. An item whose text and
-- author the caller already holds reuses that quote; the others are inserted
-- (origin shared, creator and edited-from copied, not in the Reminders).
-- Refused with 42501 unless the caller may see the playlist. The playlist,
-- quote and item limits apply; any failure leaves nothing behind.
create function private.save_playlist_copy(p_playlist uuid, p_title text default null)
returns public.playlists
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_source public.playlists;
  v_copy public.playlists;
  v_title text;
  v_item record;
  v_quote_id uuid;
  v_position integer := 0;
begin
  if v_uid is null then
    raise exception 'Sign in to save playlists.' using errcode = 'insufficient_privilege';
  end if;

  select p.* into v_source
    from public.playlists p
   where p.id = p_playlist
     and private.playlist_access(p.id) is not null;
  if not found then
    raise exception 'This playlist is not available.' using errcode = 'insufficient_privilege';
  end if;

  v_title := coalesce(p_title, v_source.title);
  perform private.assert_allowed_text(v_title);

  insert into public.playlists (owner_id, title, visibility)
  values (v_uid, v_title, 'private')
  returning * into v_copy;

  for v_item in
    select v.*
    from private.playlist_visible_items(p_playlist) v
    order by v.item_position, v.added_at, v.handle
  loop
    select q.id into v_quote_id
      from public.quotes q
     where q.owner_id = v_uid
       and q.body = v_item.body
       and q.author is not distinct from v_item.author
     order by q.created_at, q.id
     limit 1;
    if not found then
      v_quote_id := (private.insert_caller_quote(
        null, v_item.body, v_item.body_format, v_item.author, v_item.source, 'shared',
        v_item.creator_id, v_item.creator_username, v_item.edited_from_id, v_item.edited_from_username,
        false
      )).id;
    end if;

    -- Two items can map to one held quote; the copy lists it once.
    insert into public.playlist_items (playlist_id, quote_id, position)
    values (v_copy.id, v_quote_id, v_position)
    on conflict (playlist_id, quote_id) do nothing;
    if found then
      v_position := v_position + 1;
    end if;
  end loop;

  return v_copy;
end;
$$;
revoke all on function private.save_playlist_copy(uuid, text) from public, anon, service_role;
grant execute on function private.save_playlist_copy(uuid, text) to authenticated;

create function public.save_playlist_copy(p_playlist uuid, p_title text default null)
returns public.playlists
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.save_playlist_copy(p_playlist, p_title)
$$;
comment on function public.save_playlist_copy(uuid, text) is
  'Copies a playlist the caller can see into a new private playlist of the caller''s (title p_title or the original), reusing quotes the caller already holds (same text and author) and saving the rest with their creators. 42501 unless playlist_view shows the playlist. SECURITY INVOKER wrapper over private.save_playlist_copy.';
revoke all on function public.save_playlist_copy(uuid, text) from public, anon, service_role;
grant execute on function public.save_playlist_copy(uuid, text) to authenticated;
