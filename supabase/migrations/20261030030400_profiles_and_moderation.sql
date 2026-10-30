-- Profiles and moderation: one profile page per exact username, the auto-hold
-- after two reporters, suspensions from the SQL editor, and a moderation queue
-- that covers every report target. The last step of the social redesign's
-- data model (Stage 1).
-- Contract: docs/system-design.md sections 3 and 7, and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 (Profile,
-- Safety) and 3.
-- Tests: supabase/tests/database/20_reports_moderation.test.sql,
-- 21_profile_view.test.sql (plus the adjusted 00 and 05).
--
--  1. reports.target_kind: message, post, playlist, catalog_quote or profile,
--     server-owned (trigger reports_set_target_kind). It follows the target
--     id when one is set and stays when the target is deleted and its id
--     becomes null, so the queue still says what was reported.
--  2. The auto-hold (trigger reports_hold_target): once a post or playlist has
--     reports from two different people (its owner never counts), its held_at
--     is set and it disappears for everyone but its owner until the founder
--     clears it.
--  3. private.suspend_user(user, reason) and private.unsuspend_user(user), for
--     the founder in the SQL editor (no API role may run them). Suspending
--     holds every post and playlist of that person; social writes already
--     refuse a suspended caller (20261030030000 and later). Unsuspending
--     leaves held items held.
--  4. public.profile_view(username, before): the profile with exactly this
--     username, the caller's relationship to it, and the posts, playlists and
--     favorites the caller may see. Null when there is no such profile or
--     that person blocked the caller.
--  5. private.reports_to_review covers every target: its kind, ids, whether
--     it is gone or held, how many people reported it, the server's copy
--     (content_note included) and whether the reported user is suspended.
--
-- Existing rows: target_kind comes from the target id; a verified report with
-- no target left was about a share (only share reports could be verified
-- before 20261030030300), so it is a message report. Nothing is held.

-- ---------------------------------------------------------------------------
-- 1. reports.target_kind
-- ---------------------------------------------------------------------------
alter table public.reports
  add column target_kind text not null default 'profile';

update public.reports r
   set target_kind = case
         when r.message_id is not null then 'message'
         when r.post_id is not null then 'post'
         when r.playlist_id is not null then 'playlist'
         when r.starter_quote_id is not null then 'catalog_quote'
         when r.content_verified then 'message'
         else 'profile'
       end;

alter table public.reports
  add constraint reports_target_kind_valid
    check (target_kind in ('profile', 'message', 'post', 'playlist', 'catalog_quote')),
  add constraint reports_target_kind_matches check (
    (message_id is null or target_kind = 'message')
    and (post_id is null or target_kind = 'post')
    and (playlist_id is null or target_kind = 'playlist')
    and (starter_quote_id is null or target_kind = 'catalog_quote')
  );

comment on column public.reports.target_kind is
  'Server-owned (trigger reports_set_target_kind): what the report is about, message, post, playlist, catalog_quote or profile. It stays when the target is deleted and its id becomes null.';

-- Reporters read their own reports column by column (20261030030300): what
-- they filed, never the server's copy. The kind of target is what they filed.
grant select (target_kind) on table public.reports to authenticated;

-- Every role. On insert, the kind of the target id the report names (profile
-- when none); on a later change of a target id, the kind of the id that is
-- set, or the stored kind when the id became null (the target was deleted).
-- Reads only the row, so the secret key runs it too.
create function private.reports_set_target_kind()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.target_kind := case
    when new.message_id is not null then 'message'
    when new.post_id is not null then 'post'
    when new.playlist_id is not null then 'playlist'
    when new.starter_quote_id is not null then 'catalog_quote'
    when tg_op = 'INSERT' then 'profile'
    else old.target_kind
  end;
  return new;
end;
$$;
revoke all on function private.reports_set_target_kind() from public, anon, authenticated;

create trigger reports_set_target_kind
  before insert or update of message_id, post_id, playlist_id, starter_quote_id, target_kind on public.reports
  for each row execute function private.reports_set_target_kind();

-- ---------------------------------------------------------------------------
-- 2. The auto-hold
-- ---------------------------------------------------------------------------

-- AFTER INSERT, every role: a post or playlist reported by two different
-- people (not counting its owner) is held, unless it already is. A held item
-- disappears for everyone but its owner (the posts policy, post_access and
-- playlist_access) until the founder clears held_at. Every report counts,
-- reviewed or not, so a cleared item is held again by the next new reporter.
-- A per-target advisory lock makes two reports filed at the same moment see
-- each other: the second waits for the first to commit, and its count (a new
-- statement, so a new snapshot) includes it. SECURITY DEFINER: reporters
-- cannot write held_at. Holding a playlist moves its updated_at (its own
-- trigger); only the owner sees a held playlist.
create function private.reports_hold_target()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if new.post_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('quoted.hold.post:' || new.post_id::text, 0));
    update public.posts p
       set held_at = now()
     where p.id = new.post_id
       and p.held_at is null
       and (select count(distinct r.reporter_id)
              from public.reports r
             where r.post_id = p.id
               and r.reporter_id <> p.author_id) >= 2;
  elsif new.playlist_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('quoted.hold.playlist:' || new.playlist_id::text, 0));
    update public.playlists p
       set held_at = now()
     where p.id = new.playlist_id
       and p.held_at is null
       and (select count(distinct r.reporter_id)
              from public.reports r
             where r.playlist_id = p.id
               and r.reporter_id <> p.owner_id) >= 2;
  end if;
  return null;
end;
$$;
revoke all on function private.reports_hold_target() from public, anon, authenticated;

create trigger reports_hold_target
  after insert on public.reports
  for each row execute function private.reports_hold_target();

comment on column public.posts.held_at is
  'Server-owned (no client grant): set when two different people have reported the post (trigger reports_hold_target) and by private.suspend_user; a held post is hidden from everyone but its author until the founder clears it.';
comment on column public.playlists.held_at is
  'Server-owned (no client grant): set when two different people have reported the playlist (trigger reports_hold_target) and by private.suspend_user; a held playlist is hidden from everyone but its owner until the founder clears it.';

-- ---------------------------------------------------------------------------
-- 3. Suspensions
-- ---------------------------------------------------------------------------

-- The founder, in the SQL editor:
--   select * from private.suspend_user('<user id>', '<reason>');
-- Records the suspension (a second call replaces the reason and keeps the
-- first time) and holds every post and playlist of that person that is not
-- held yet; returns how many it held. From then on every social write of
-- theirs is refused (terms checks call private.caller_is_suspended): friend
-- requests and accepts, posts, messages, opening a conversation, playlists
-- others can see and their items. Their private Library keeps working, and
-- they can still delete their posts and narrow their playlists. An unknown
-- user fails with 23503. No API role may execute it.
create function private.suspend_user(p_user uuid, p_reason text)
returns table (posts_held integer, playlists_held integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  insert into private.suspensions (user_id, reason)
  values (p_user, p_reason)
  on conflict (user_id) do update set reason = excluded.reason;

  update public.posts p
     set held_at = now()
   where p.author_id = p_user
     and p.held_at is null;
  get diagnostics posts_held = row_count;

  update public.playlists p
     set held_at = now()
   where p.owner_id = p_user
     and p.held_at is null;
  get diagnostics playlists_held = row_count;

  return next;
end;
$$;
comment on function private.suspend_user(uuid, text) is
  'Founder only (SQL editor): suspends the account (every social write is refused) and holds all of its posts and playlists. Returns how many it held.';
revoke all on function private.suspend_user(uuid, text) from public, anon, authenticated, service_role;

-- The founder, in the SQL editor:
--   select private.unsuspend_user('<user id>');
-- Ends the suspension; true when there was one. Held posts and playlists stay
-- held: the founder clears each one by hand after checking it
-- (update public.posts set held_at = null where id = '...'). No API role may
-- execute it.
create function private.unsuspend_user(p_user uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  delete from private.suspensions s where s.user_id = p_user;
  return found;
end;
$$;
comment on function private.unsuspend_user(uuid) is
  'Founder only (SQL editor): ends a suspension. Held posts and playlists stay held until the founder clears them by hand.';
revoke all on function private.unsuspend_user(uuid) from public, anon, authenticated, service_role;

comment on table private.suspensions is
  'Suspended accounts: every social write is refused and their posts and playlists are held. The founder suspends with private.suspend_user and ends it with private.unsuspend_user, from the SQL editor.';

-- ---------------------------------------------------------------------------
-- 4. profile_view
-- ---------------------------------------------------------------------------

-- One profile page. The profile is found by exact username after
-- private.normalize_username (trimmed, one leading @ dropped, lowercased),
-- like find_profile; null when the caller is signed out, there is no such
-- profile, or that person blocked the caller (one answer for all three).
-- Otherwise:
--   { "profile": {id, username, display_name},
--     "relationship": "self" | "friend" | "incoming" | "outgoing" | "none" | "you_blocked",
--     "posts": [ {id, caption, body, body_format, author, source, verified_starter_id,
--                 creator_username, edited_from_username, audience, created_at} ],
--     "playlists": [ {id, title, visibility, item_count, updated_at} ],
--     "favorites": [ {id, body, body_format, author, source, verified_starter_id,
--                     creator_username, edited_from_username, favorited_at} ] | null }
--   you_blocked: the profile and relationship only, empty lists, favorites
--     null (the page offers Unblock).
--   posts: the 30 newest (older than p_before when given) the caller may see
--     under private.post_access: self, all of them; a friend, those not held
--     and not reported by the caller; anyone else, public ones, not held, not
--     reported by the caller and still public-eligible. Creator and
--     edited-from usernames are null for verified posts.
--   playlists: every one the caller may see under private.playlist_access
--     (self, all; a friend, friends or public, not held, not reported by the
--     caller; anyone else, public, not held, not reported), most recently
--     changed first. item_count is the number of items playlist_view shows
--     this caller.
--   favorites: self, their own 100 newest (their private Library, not
--     filtered); a friend, only when favorites_visibility is friends, exactly
--     what friend_favorites returns (blocked terms skip unverified ones);
--     anyone else, null. id is the per-viewer handle md5(quote id, viewer),
--     as in friend_favorites, never the quote id.
-- Never last_active_at, purge_exempt, favorites_visibility, terms, suspension,
-- held_at or any quote id. SECURITY DEFINER to read past the owner-only and
-- friends-only policies; it answers only through the access rules above.
create function private.profile_view(p_username text, p_before timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_profile public.profiles;
  v_relationship text;
  v_posts jsonb;
  v_playlists jsonb;
  v_favorites jsonb;
begin
  if v_uid is null then
    return null;
  end if;

  select p.* into v_profile
    from public.profiles p
   where p.username = private.normalize_username(p_username);
  if not found then
    return null;
  end if;

  if v_profile.id <> v_uid and exists (
       select 1 from public.blocks b
       where b.blocker_id = v_profile.id and b.blocked_id = v_uid
     ) then
    return null;
  end if;

  v_relationship := case
    when v_profile.id = v_uid then 'self'
    when exists (
      select 1 from public.blocks b
      where b.blocker_id = v_uid and b.blocked_id = v_profile.id
    ) then 'you_blocked'
    when exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = v_uid and f.addressee_id = v_profile.id)
          or (f.addressee_id = v_uid and f.requester_id = v_profile.id))
    ) then 'friend'
    when exists (
      select 1 from public.friendships f
      where f.status = 'pending' and f.requester_id = v_profile.id and f.addressee_id = v_uid
    ) then 'incoming'
    when exists (
      select 1 from public.friendships f
      where f.status = 'pending' and f.requester_id = v_uid and f.addressee_id = v_profile.id
    ) then 'outgoing'
    else 'none'
  end;

  if v_relationship = 'you_blocked' then
    return jsonb_build_object(
      'profile', jsonb_build_object('id', v_profile.id, 'username', v_profile.username,
                                    'display_name', v_profile.display_name),
      'relationship', v_relationship,
      'posts', '[]'::jsonb,
      'playlists', '[]'::jsonb,
      'favorites', null::jsonb
    );
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', x.id,
             'caption', x.caption,
             'body', x.body,
             'body_format', x.body_format,
             'author', x.author,
             'source', x.source,
             'verified_starter_id', x.verified_starter_id,
             'creator_username', case when x.verified_starter_id is null then x.creator_username end,
             'edited_from_username', case when x.verified_starter_id is null then x.edited_from_username end,
             'audience', x.audience,
             'created_at', x.created_at
           )
           order by x.created_at desc, x.id
         ), '[]'::jsonb)
    into v_posts
    from (
      select p.*
      from public.posts p
      where p.author_id = v_profile.id
        and (p_before is null or p.created_at < p_before)
        and private.post_access(p.id) is not null
      order by p.created_at desc, p.id
      limit 30
    ) x;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', p.id,
             'title', p.title,
             'visibility', p.visibility,
             'item_count', (select count(*) from private.playlist_visible_items(p.id)),
             'updated_at', p.updated_at
           )
           order by p.updated_at desc, p.id
         ), '[]'::jsonb)
    into v_playlists
    from public.playlists p
   where p.owner_id = v_profile.id
     and private.playlist_access(p.id) is not null;

  if v_relationship = 'self' then
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'id', md5(q.id::text || ':' || v_uid::text)::uuid,
               'body', q.body,
               'body_format', q.body_format,
               'author', q.author,
               'source', q.source,
               'verified_starter_id', q.verified_starter_id,
               'creator_username', case when q.verified_starter_id is null then q.creator_username end,
               'edited_from_username', case when q.verified_starter_id is null then q.edited_from_username end,
               'favorited_at', q.favorited_at
             )
             order by q.favorited_at desc, q.id
           ), '[]'::jsonb)
      into v_favorites
      from (
        select q.*
        from public.quotes q
        where q.owner_id = v_uid and q.is_favorite
        order by q.favorited_at desc, q.id
        limit 100
      ) q;
  elsif v_relationship = 'friend' and v_profile.favorites_visibility = 'friends' then
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'id', f.id,
               'body', f.body,
               'body_format', f.body_format,
               'author', f.author,
               'source', f.source,
               'verified_starter_id', f.verified_starter_id,
               'creator_username', f.creator_username,
               'edited_from_username', f.edited_from_username,
               'favorited_at', f.favorited_at
             )
             order by f.n
           ), '[]'::jsonb)
      into v_favorites
      from private.friend_favorites(v_profile.id)
           with ordinality as f (id, body, body_format, author, source, verified_starter_id,
                                 creator_username, edited_from_username, favorited_at, n);
  else
    v_favorites := null;
  end if;

  return jsonb_build_object(
    'profile', jsonb_build_object('id', v_profile.id, 'username', v_profile.username,
                                  'display_name', v_profile.display_name),
    'relationship', v_relationship,
    'posts', v_posts,
    'playlists', v_playlists,
    'favorites', v_favorites
  );
end;
$$;
revoke all on function private.profile_view(text, timestamptz) from public, anon, service_role;
grant execute on function private.profile_view(text, timestamptz) to authenticated;

create function public.profile_view(p_username text, p_before timestamptz default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.profile_view(p_username, p_before)
$$;
comment on function public.profile_view(text, timestamptz) is
  'One profile page by exact username: the profile, the caller''s relationship to it, and the posts (30 per page, older than p_before), playlists and favorites the caller may see. Null when there is no such profile or that person blocked the caller. SECURITY INVOKER wrapper over private.profile_view.';
revoke all on function public.profile_view(text, timestamptz) from public, anon, service_role;
grant execute on function public.profile_view(text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The moderation queue
-- ---------------------------------------------------------------------------

-- The founder's daily check (dashboard SQL editor), oldest first. Replaces the
-- version from 20261030030300 with what each target needs:
--   target_kind and target_deleted (the target id is null because the
--     message was unsent or the post or playlist deleted: an unsent message
--     is still in private.message_tombstones for 30 days);
--   target_held_at (a held post or playlist) and target_reporters (how many
--     different people reported this target);
--   the server's copy: content_body, content_author, content_source and
--     content_note (caption, message text or note, playlist title);
--   reported_user_suspended next to the per-user count.
-- security_invoker, and not granted to any API role.
drop view private.reports_to_review;
create view private.reports_to_review
with (security_invoker = true)
as
select
  r.id,
  r.created_at,
  date_trunc('minute', now() - r.created_at) as waiting,
  r.target_kind,
  r.target_kind <> 'profile'
    and num_nonnulls(r.message_id, r.post_id, r.playlist_id, r.starter_quote_id) = 0 as target_deleted,
  r.reason,
  r.details,
  r.content_verified,
  r.content_body,
  r.content_author,
  r.content_source,
  r.content_note,
  r.message_id,
  r.post_id,
  r.playlist_id,
  r.starter_quote_id,
  coalesce(post.held_at, playlist.held_at) as target_held_at,
  case
    when num_nonnulls(r.message_id, r.post_id, r.playlist_id, r.starter_quote_id) = 0 then null
    else (
      select count(distinct other.reporter_id)
      from public.reports other
      where other.message_id = r.message_id
         or other.post_id = r.post_id
         or other.playlist_id = r.playlist_id
         or other.starter_quote_id = r.starter_quote_id
    )
  end as target_reporters,
  r.reported_user_id,
  coalesce(reported.username, r.reported_username) as reported_username,
  r.reported_user_id is null and r.reported_username is not null as reported_account_deleted,
  exists (select 1 from private.suspensions s where s.user_id = r.reported_user_id) as reported_user_suspended,
  (
    select count(*)
    from public.reports other
    where other.reported_user_id = r.reported_user_id
       or (r.reported_user_id is null and other.reported_user_id is null
           and other.reported_username = r.reported_username)
  ) as reports_against_user,
  r.reporter_id,
  reporter.username as reporter_username
from public.reports r
left join public.posts post on post.id = r.post_id
left join public.playlists playlist on playlist.id = r.playlist_id
left join public.profiles reported on reported.id = r.reported_user_id
left join public.profiles reporter on reporter.id = r.reporter_id
where r.reviewed_at is null
order by r.created_at;

comment on view private.reports_to_review is
  'Reports waiting for review, oldest first: what was reported (target_kind, the ids, whether it is gone or held, how many people reported it), the server''s copy of the content and the people involved. Mark one done with: update public.reports set reviewed_at = now() where id = ...';

revoke all on table private.reports_to_review from public, anon, authenticated, service_role;
