-- Review fixes for the social redesign (Stage 1b): read marks that stop at
-- what the app showed, reports about gone items that are not lost as
-- duplicates (and at most three a day about one person), a playlist reorder
-- in one statement, and the quote messages you received read through an
-- index.
-- Contract: docs/system-design.md section 3 (conversation_members, reports,
-- playlist_items) and section 4.
-- Tests: supabase/tests/database/19_conversations_messages.test.sql (read
-- marks), 11_abuse_limits.test.sql (duplicate reports, the per-person
-- limit and reporters_against_user), 17_playlists.test.sql
-- (set_playlist_positions) and
-- 23_received_quotes.test.sql (received_quotes), plus the adjusted 00.
--
--  1. conversation_members.last_read_at: a client's value is kept, never
--     later than the server clock and never earlier than the stored value
--     (it never moves back and cannot be cleared). The app sends the time of
--     the newest message it has shown, so a message that arrives between its
--     last refresh and the mark stays unread. Before, any client value became
--     now(), which marked read messages the app had never fetched.
--     cleared_at ("Delete Conversation") still takes the server clock.
--     public.inbox_conversations() also returns the caller's last_read_at, so
--     the app can tell which messages it fetched are unread without another
--     read (and keep that offline with its cached Inbox).
--  2. reports_reporter_reported_target_key also compares the content of an
--     unverified report. When a reported message, post or playlist is
--     already gone (unsent, deleted or hidden), the app reports the person
--     instead with what it showed; two such reports about different gone
--     items from the same reporter and person are no longer one duplicate
--     (the second was refused with 23505 and its content lost). A second
--     report with the same content, and a second plain profile report (no
--     content), are still duplicates. Verified reports compare as before.
--     A profile report's content is the client's (nothing on the server
--     to check it against), so private.reports_enforce_limit also allows
--     one reporter at most 3 profile reports (target_kind 'profile') about
--     the same person in a rolling 24 hours (QR001), and
--     private.reports_to_review gains reporters_against_user (distinct
--     reporters) next to reports_against_user (reports), so one account
--     cannot pass for many.
--  3. public.set_playlist_positions(playlist, quote_ids, positions): writes
--     the given positions of one of the caller's playlists in one statement,
--     so a reorder lands whole or not at all. SECURITY INVOKER: the
--     playlist_items policies (owner only) and column grants apply exactly
--     as for a direct UPDATE; ids that are not in the playlist are skipped.
--  4. public.received_quotes(after_created_at, after_id, limit): the quote
--     messages other people sent the caller, across their conversations,
--     newest first, one keyset page at a time. It starts from the caller's
--     own conversation_members rows, so the messages index (conversation_id,
--     created_at desc, id) serves each conversation. The same read straight
--     from the table (kind=eq.quote&sender_id=neq.<me>) has no index path
--     under the messages RLS, whose conversations subquery stays a filter,
--     and read the whole table on every refresh. SECURITY INVOKER: the RLS of
--     conversation_members and messages decides what it returns, as for a
--     direct read, and it returns only the columns clients may read.
--
-- Existing rows: none change.

-- ---------------------------------------------------------------------------
-- 1. Read marks
-- ---------------------------------------------------------------------------

-- Replaces the version from 20261029090300_conversations_and_messages (grants
-- and trigger kept). Clients: a changed last_read_at keeps the client's time,
-- but never later than the server clock and never earlier than the stored
-- time; null keeps the stored time. A changed cleared_at becomes the server
-- clock, never earlier than the stored time; null keeps the stored time. The
-- server (the shares move) writes exact times. SECURITY INVOKER so
-- current_user tells clients apart.
create or replace function private.conversation_members_stamp_times()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;
  if new.last_read_at is distinct from old.last_read_at then
    new.last_read_at := case when new.last_read_at is null then old.last_read_at
                             else greatest(old.last_read_at, least(new.last_read_at, now())) end;
  end if;
  if new.cleared_at is distinct from old.cleared_at then
    new.cleared_at := case when new.cleared_at is null then old.cleared_at
                           else greatest(old.cleared_at, now()) end;
  end if;
  return new;
end;
$$;

comment on column public.conversation_members.last_read_at is
  'The member''s private read mark (their own badge): messages from the other member sent after it are unread. A client sets it to the time of the newest message it has shown; the server keeps that time, never later than its clock, and never moves it back or clears it (trigger conversation_members_stamp_times).';

-- The Inbox as in 20261029090300, plus the caller's own read mark (last
-- column). The return type changes, so the function is dropped and made
-- again, with the same grants.
drop function public.inbox_conversations();
create function public.inbox_conversations()
returns table (
  conversation_id uuid,
  other_id uuid,
  other_username text,
  other_display_name text,
  other_accepts_text_messages boolean,
  is_closed boolean,
  last_message_at timestamptz,
  last_message_kind text,
  last_message_preview text,
  last_message_sender_id uuid,
  unread_count integer,
  last_read_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.id,
         o.other_id,
         p.username,
         p.display_name,
         p.accepts_text_messages,
         c.closed_at is not null,
         lm.created_at,
         lm.kind,
         lm.preview,
         lm.sender_id,
         coalesce(u.unread, 0),
         me.last_read_at
  from public.conversations c
  join public.conversation_members me
    on me.conversation_id = c.id and me.user_id = (select auth.uid())
  cross join lateral (
    select case when c.user_a = (select auth.uid()) then c.user_b else c.user_a end as other_id
  ) o
  left join public.profiles p on p.id = o.other_id
  left join lateral (
    select m.created_at, m.kind, m.sender_id,
           left(case m.kind when 'text' then m.text when 'quote' then m.body else m.playlist_title end, 140) as preview
    from public.messages m
    where m.conversation_id = c.id
    order by m.created_at desc, m.id
    limit 1
  ) lm on true
  left join lateral (
    select count(*)::integer as unread
    from public.messages m
    where m.conversation_id = c.id
      and m.sender_id <> (select auth.uid())
      and (me.last_read_at is null or m.created_at > me.last_read_at)
  ) u on true
  where lm.created_at is not null or (c.last_message_at is null and me.cleared_at is null)
  order by coalesce(lm.created_at, c.created_at) desc, c.id
$$;
comment on function public.inbox_conversations() is
  'The caller''s Inbox: one row per conversation they may read, with the other member, the latest visible message, the unread count and the caller''s own last_read_at, newest first. SECURITY INVOKER: access control is the RLS of conversations, conversation_members, messages and profiles.';
revoke all on function public.inbox_conversations() from public, anon, service_role;
grant execute on function public.inbox_conversations() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Duplicate reports
-- ---------------------------------------------------------------------------

-- One report per reporter, reported user and target, as before (see
-- 20261029090300, section 11), and for an unverified report also per
-- content: a report about a person carries what the reporter saw when the
-- item itself was gone, and two different items are two reports. A verified
-- report compares no content (null). md5 keeps the key small; the four
-- columns are joined with a unit separator, so moving text between them
-- makes a different key.
drop index public.reports_reporter_reported_target_key;
create unique index reports_reporter_reported_target_key
  on public.reports (
    reporter_id, reported_user_id, message_id, post_id, playlist_id, starter_quote_id,
    (case when content_verified then null
          else md5(coalesce(content_body, '') || E'\x1f' || coalesce(content_author, '') || E'\x1f'
                   || coalesce(content_source, '') || E'\x1f' || coalesce(content_note, ''))
     end)
  )
  nulls not distinct
  where reporter_id is not null
    and (reported_user_id is not null or starter_quote_id is not null)
    and (message_id is not null or post_id is not null or playlist_id is not null
         or starter_quote_id is not null or not content_verified);

-- The content in that key is the client's for a profile report (no target:
-- reports_snapshot_target keeps what the reporter sent, unverified), so on
-- its own it would let one account file all of its 20 reports a day about
-- one person by varying content_note. Replaces the version from
-- 20261021090000 (trigger kept): as before, at most 20 reports per reporter
-- in a rolling 24 hours, and now also at most 3 profile reports (target_kind
-- 'profile', checked here before reports_set_target_kind runs, so a new row
-- is one by having no target) by one reporter about one person. Both under
-- the reporter's advisory lock, so parallel inserts cannot pass together.
-- SECURITY INVOKER: it counts the reporter's own rows through columns they
-- may read (reporter_id, reported_user_id, target_kind, created_at). A
-- report with a target is not counted: it names a message, post or
-- playlist the reporter can see, once each.
create or replace function private.reports_enforce_limit()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('quoted.reports:' || new.reporter_id::text, 0));
  if (select count(*) from (
        select 1 from public.reports r
        where r.reporter_id = new.reporter_id
          and r.created_at > now() - interval '24 hours'
        limit 20) recent) >= 20 then
    raise exception 'You can send at most 20 reports a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;
  if new.reported_user_id is not null
     and num_nonnulls(new.message_id, new.post_id, new.playlist_id, new.starter_quote_id) = 0
     and (select count(*) from (
            select 1 from public.reports r
            where r.reporter_id = new.reporter_id
              and r.reported_user_id = new.reported_user_id
              and r.target_kind = 'profile'
              and r.created_at > now() - interval '24 hours'
            limit 3) recent) >= 3 then
    raise exception 'You can report the same person at most 3 times a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;
  return new;
end;
$$;
revoke all on function private.reports_enforce_limit() from public, anon, authenticated;

-- The moderation queue as in 20261029090400, plus reporters_against_user:
-- how many different people reported the person (reports_against_user counts
-- reports, which one account can file several of). A view cannot gain a
-- column in the middle, so it is dropped and made again, with the same
-- (absent) grants.
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
  against.reports as reports_against_user,
  against.reporters as reporters_against_user,
  r.reporter_id,
  reporter.username as reporter_username
from public.reports r
left join public.posts post on post.id = r.post_id
left join public.playlists playlist on playlist.id = r.playlist_id
left join public.profiles reported on reported.id = r.reported_user_id
left join public.profiles reporter on reporter.id = r.reporter_id
cross join lateral (
  -- Deleted reporters (reporter_id null) count as reports but not as people.
  select count(*) as reports, count(distinct other.reporter_id) as reporters
  from public.reports other
  where other.reported_user_id = r.reported_user_id
     or (r.reported_user_id is null and other.reported_user_id is null
         and other.reported_username = r.reported_username)
) against
where r.reviewed_at is null
order by r.created_at;

comment on view private.reports_to_review is
  'Reports waiting for review, oldest first: what was reported (target_kind, the ids, whether it is gone or held, how many people reported it), the server''s copy of the content and the people involved (with how many reports, and how many different reporters, the reported person has). Mark one done with: update public.reports set reviewed_at = now() where id = ...';

revoke all on table private.reports_to_review from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Reordering a playlist in one statement
-- ---------------------------------------------------------------------------

-- Gives each quote in p_quote_ids the position at the same index of
-- p_positions, in one of the caller's playlists (the first occurrence of a
-- repeated quote wins). Quotes that are not in the playlist are skipped, and
-- anyone but the owner changes nothing (RLS). A negative or null position
-- fails the whole call. Returns the items it moved.
create function public.set_playlist_positions(p_playlist uuid, p_quote_ids uuid[], p_positions integer[])
returns setof public.playlist_items
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if coalesce(cardinality(p_quote_ids), 0) <> coalesce(cardinality(p_positions), 0) then
    raise exception 'Give one position for each quote.'
      using errcode = 'invalid_parameter_value';
  end if;
  return query
    update public.playlist_items as i
       set position = c.position
      from (
        select distinct on (t.quote_id) t.quote_id, t.position
        from unnest(p_quote_ids, p_positions) with ordinality as t(quote_id, position, ord)
        where t.quote_id is not null
        order by t.quote_id, t.ord
      ) c
     where i.playlist_id = p_playlist
       and i.quote_id = c.quote_id
    returning i.*;
end;
$$;
comment on function public.set_playlist_positions(uuid, uuid[], integer[]) is
  'Sets the positions of items in one of the caller''s playlists in one statement (quote_ids[i] gets positions[i]). Returns the items moved. SECURITY INVOKER (RLS applies).';
revoke all on function public.set_playlist_positions(uuid, uuid[], integer[]) from public, anon, service_role;
grant execute on function public.set_playlist_positions(uuid, uuid[], integer[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The quote messages you received, through an index
-- ---------------------------------------------------------------------------

-- "Shared with you" (and search and the inbox alerts) until the Inbox
-- screens: every quote message someone else sent the caller, across their
-- conversations, newest first (created_at desc, id). Pass the last row of a
-- page (p_after_created_at, p_after_id) for the next one; p_limit is 1 to
-- 1000 (default 500, PostgREST's max_rows is 1000). The join starts from the
-- caller's own conversation_members rows (conversation_members_user_id_idx),
-- so each conversation's messages come from
-- messages_conversation_id_created_at_id_idx; a direct read of messages
-- filtered on kind and sender has no index to start from. SECURITY INVOKER:
-- the RLS of conversation_members and messages applies exactly as for a
-- direct read (nothing before the caller's "Delete Conversation", nothing
-- they reported, nothing from someone who blocked them), and it returns only
-- the columns clients may read (not source_quote_id, source_post_id or
-- source_message_id). STABLE, so the app calls it as GET.
create function public.received_quotes(
  p_after_created_at timestamptz default null,
  p_after_id uuid default null,
  p_limit integer default 500
)
returns table (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  kind text,
  text text,
  note text,
  body text,
  body_format jsonb,
  author text,
  source text,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text,
  verified_starter_id smallint,
  starter_quote_id smallint,
  playlist_id uuid,
  playlist_title text,
  created_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.id, m.conversation_id, m.sender_id, m.kind, m.text, m.note, m.body, m.body_format, m.author,
         m.source, m.creator_id, m.creator_username, m.edited_from_id, m.edited_from_username,
         m.verified_starter_id, m.starter_quote_id, m.playlist_id, m.playlist_title, m.created_at
  from public.conversation_members me
  join public.messages m on m.conversation_id = me.conversation_id
  where me.user_id = (select auth.uid())
    and m.kind = 'quote'
    and m.sender_id <> (select auth.uid())
    and (p_after_created_at is null
         or m.created_at < p_after_created_at
         or (m.created_at = p_after_created_at and m.id > p_after_id))
  order by m.created_at desc, m.id
  limit greatest(1, least(coalesce(p_limit, 500), 1000))
$$;
comment on function public.received_quotes(timestamptz, uuid, integer) is
  'The quote messages other people sent the caller, across their conversations, newest first (created_at desc, id), one keyset page at a time (after p_after_created_at, p_after_id; p_limit 1 to 1000, default 500). Starts from the caller''s conversation_members rows so the messages index serves it. SECURITY INVOKER: the RLS of conversation_members and messages applies; only the columns clients may read.';
revoke all on function public.received_quotes(timestamptz, uuid, integer) from public, anon, service_role;
grant execute on function public.received_quotes(timestamptz, uuid, integer) to authenticated;
