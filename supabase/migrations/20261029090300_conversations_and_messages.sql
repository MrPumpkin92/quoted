-- Conversations and messages: 1:1 conversations between accepted friends,
-- with text, quote and playlist messages that only the two members can read.
-- Today's shares move in and the shares table is dropped. Reports can now name
-- a message, a post, a playlist or a Quoted Catalog quote. Step 3 of the
-- social redesign.
-- Contract: docs/system-design.md section 3, and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 (Inbox,
-- Safety) and 3.
-- Tests: supabase/tests/database/19_conversations_messages.test.sql (every
-- endpoint refuses a non-participant), 19b_share_migration.test.sql (the move
-- of shares, rerun on fixtures), plus the ported 00, 03, 04, 05, 07, 08, 10,
-- 11, 12, 14 and 18.
--
--  1. public.conversations: one per pair (user_a < user_b), created only by
--     public.open_conversation for accepted friends with no block either way.
--     last_message_at and closed_at are server-owned. Read by its two members,
--     except by a member the other one blocked.
--  2. public.conversation_members: one row per member with last_read_at (the
--     private badge) and cleared_at ("Delete Conversation", for you only).
--     Each person reads and updates only their own row and only those two
--     columns; the server clock sets them and they never move back.
--  3. public.messages: text (1-1000), quote (a server-built snapshot from the
--     sender's own quote or the catalog, optional note 1-280) or playlist (the
--     sender's own playlist that friends can see, with a copy of its title).
--     Clients send only id, conversation_id, kind, text, note, source_quote_id,
--     starter_quote_id and playlist_id, read every column but source_quote_id,
--     and delete only their own (unsend). No update. Read: a member, for
--     messages newer than their cleared_at, unless the other member blocked
--     them or they reported the message. Send: a member and accepted friend,
--     the conversation open, no block either way, terms accepted, not
--     suspended. Text needs the recipient's accepts_text_messages (QR004);
--     text, notes, playlist titles and unverified snapshots pass the word
--     filter (QR003). A verified snapshot keeps no creator or edited-from.
--     300 per sender per rolling 24 hours, unsent ones included (QR001). An
--     unsent message is kept 30 days in private.message_tombstones for
--     moderation (pg_cron job purge-message-tombstones), its id cannot be
--     reused, and last_message_at moves back to the latest message left. The
--     unsend policy holds the read rule itself.
--  4. public.open_conversation(friend) (a social write: terms, no
--     suspension), public.inbox_conversations() and
--     public.save_from_message(message).
--  5. Unfriending closes the pair's conversation (read-only for both); a new
--     accepted friendship reopens it unless a block exists. A block deletes
--     the friendship and closes the conversation; it deletes no message.
--  6. Profiles linked by a conversation are readable (replaces the share
--     link); a block you make back no longer shows you a profile whose owner
--     blocked you.
--  7. Shares become quote messages (private.move_shares_to_messages), then
--     public.shares, its triggers and the move function go.
--  8. reports: post_id, message_id, playlist_id and starter_quote_id (each on
--     delete set null, at most one per report; none is a profile report),
--     content_note, the reasons copyright and wrong_wording (catalog only).
--     The reporter must be able to see the target and name its author,
--     sender or owner. The server copies the content (trigger
--     reports_snapshot_target), which the reporter cannot read back (column
--     grants). A reported post, message or playlist disappears for its
--     reporter.
--  9. The foreign keys of messages and the four report targets are checked at
--     commit (deferrable initially deferred), so one statement can delete many
--     accounts (the purge) without tripping over its own cascade.
--
-- Existing rows: every share becomes a quote message with the same id,
-- created_at, note, snapshot and verification, in one conversation per pair
-- (closed unless the pair are accepted friends now). The creator is the
-- sender only when share.quote_id still points to the sender's own manual or
-- pasted quote. Each member's last_read_at is the latest seen_at among the
-- shares they received in that pair. reports.share_id becomes message_id.
-- saved_at is dropped: nobody sees "Saved" any more.

-- ---------------------------------------------------------------------------
-- 1. conversations
-- ---------------------------------------------------------------------------
create table public.conversations (
  id uuid not null default gen_random_uuid(),
  user_a uuid not null,
  user_b uuid not null,
  created_at timestamptz not null default now(),
  last_message_at timestamptz,
  closed_at timestamptz,
  constraint conversations_pkey primary key (id),
  constraint conversations_user_a_fkey foreign key (user_a) references public.profiles (id) on delete cascade,
  constraint conversations_user_b_fkey foreign key (user_b) references public.profiles (id) on delete cascade,
  constraint conversations_users_ordered check (user_a < user_b),
  constraint conversations_pair_key unique (user_a, user_b)
);

-- conversations_pair_key leads with user_a (its foreign key index).
create index conversations_user_b_idx on public.conversations (user_b);

comment on table public.conversations is
  'A 1:1 conversation between two people (user_a < user_b). Created only by public.open_conversation for accepted friends. Read by its two members, except by a member the other one blocked. No client writes.';
comment on column public.conversations.created_at is
  'Server-owned (trigger conversations_stamp_created_at).';
comment on column public.conversations.last_message_at is
  'Server-owned (trigger messages_touch_conversation): when the latest message still in the conversation was sent. An unsend recomputes it, so it never shows when an unsent message was sent; null until the first message and once every message is unsent.';
comment on column public.conversations.closed_at is
  'Server-owned: set when the pair stop being friends or one blocks the other (read-only for both), cleared when they become friends again with no block (friendships_reopen_conversation, open_conversation).';

revoke all on table public.conversations from public, anon, authenticated, service_role;
grant select on table public.conversations to authenticated;
grant select, insert, update, delete on table public.conversations to service_role;

alter table public.conversations enable row level security;

-- ---------------------------------------------------------------------------
-- 2. conversation_members
-- ---------------------------------------------------------------------------
create table public.conversation_members (
  conversation_id uuid not null,
  user_id uuid not null,
  last_read_at timestamptz,
  cleared_at timestamptz,
  constraint conversation_members_pkey primary key (conversation_id, user_id),
  constraint conversation_members_conversation_id_fkey foreign key (conversation_id)
    references public.conversations (id) on delete cascade,
  constraint conversation_members_user_id_fkey foreign key (user_id) references public.profiles (id) on delete cascade
);

-- The primary key leads with conversation_id (its foreign key index).
create index conversation_members_user_id_idx on public.conversation_members (user_id);

comment on table public.conversation_members is
  'One row per member of a conversation (both are created with it). Each person reads and updates only their own row; nobody reads the other person''s.';
comment on column public.conversation_members.last_read_at is
  'The member''s private read mark (their own badge). A client update takes the server clock and never moves it back or clears it (trigger conversation_members_stamp_times).';
comment on column public.conversation_members.cleared_at is
  '"Delete Conversation": the member no longer reads messages sent up to this time. A client update takes the server clock and never moves it back or clears it (trigger conversation_members_stamp_times).';

revoke all on table public.conversation_members from public, anon, authenticated, service_role;
grant select on table public.conversation_members to authenticated;
grant update (last_read_at, cleared_at) on table public.conversation_members to authenticated;
grant select, insert, update, delete on table public.conversation_members to service_role;

alter table public.conversation_members enable row level security;

-- ---------------------------------------------------------------------------
-- 3. messages
-- ---------------------------------------------------------------------------
-- Every foreign key of messages, and the four report targets, is checked at
-- commit (deferrable initially deferred); the referential actions themselves
-- still run at once. When one statement deletes several accounts (the purge),
-- Postgres re-checks every foreign key of a row that the cascade updates twice
-- in one transaction, and with immediate checks it could look at a message or
-- post that the cascade has already deleted, before the set null that clears
-- it runs, and fail the whole purge. Client inserts never rely on these
-- checks: the triggers and policies refuse an unknown conversation, quote,
-- playlist, message, post or catalog quote first.
create table public.messages (
  id uuid not null default gen_random_uuid(),
  conversation_id uuid not null,
  sender_id uuid not null default auth.uid(),
  kind text not null,
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
  source_quote_id uuid,
  starter_quote_id smallint,
  playlist_id uuid,
  playlist_title text,
  created_at timestamptz not null default now(),
  constraint messages_pkey primary key (id),
  constraint messages_conversation_id_fkey foreign key (conversation_id)
    references public.conversations (id) on delete cascade
    deferrable initially deferred,
  constraint messages_sender_id_fkey foreign key (sender_id) references public.profiles (id) on delete cascade
    deferrable initially deferred,
  constraint messages_creator_id_fkey foreign key (creator_id, creator_username)
    references public.profiles (id, username) on delete set null
    deferrable initially deferred,
  constraint messages_edited_from_id_fkey foreign key (edited_from_id, edited_from_username)
    references public.profiles (id, username) on delete set null
    deferrable initially deferred,
  constraint messages_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.starter_quotes (id) on delete set null
    deferrable initially deferred,
  constraint messages_source_quote_id_fkey foreign key (source_quote_id) references public.quotes (id) on delete set null
    deferrable initially deferred,
  constraint messages_starter_quote_id_fkey foreign key (starter_quote_id)
    references public.starter_quotes (id) on delete set null
    deferrable initially deferred,
  constraint messages_playlist_id_fkey foreign key (playlist_id) references public.playlists (id) on delete set null
    deferrable initially deferred,
  constraint messages_kind_valid check (kind in ('text', 'quote', 'playlist')),
  constraint messages_text_length check (char_length(text) between 1 and 1000),
  constraint messages_text_not_blank check (not private.is_blank(text)),
  constraint messages_note_length check (char_length(note) between 1 and 280),
  constraint messages_note_not_blank check (not private.is_blank(note)),
  constraint messages_body_length check (char_length(body) between 1 and 2000),
  constraint messages_body_not_blank check (not private.is_blank(body)),
  constraint messages_body_format_valid check (private.is_valid_body_format(body_format)),
  constraint messages_author_length check (char_length(author) <= 200),
  constraint messages_author_not_blank check (not private.is_blank(author)),
  constraint messages_source_length check (char_length(source) <= 200),
  constraint messages_source_not_blank check (not private.is_blank(source)),
  constraint messages_playlist_title_length check (char_length(playlist_title) between 1 and 60),
  constraint messages_playlist_title_not_blank check (not private.is_blank(playlist_title)),
  constraint messages_creator_pair_valid check ((creator_id is null) = (creator_username is null)),
  constraint messages_edited_from_pair_valid check ((edited_from_id is null) = (edited_from_username is null)),
  -- A snapshot is all or nothing: body and body_format together, and nothing
  -- else of a quote without a body.
  constraint messages_snapshot_shape check (
    (body is null) = (body_format is null)
    and (body is not null
         or (author is null and source is null and creator_id is null and edited_from_id is null
             and verified_starter_id is null))
  ),
  -- What each kind carries. The links (source_quote_id, starter_quote_id,
  -- playlist_id) may become null later through their foreign keys.
  constraint messages_kind_shape check (
    case kind
      when 'text' then text is not null and note is null and body is null and playlist_title is null
                       and source_quote_id is null and starter_quote_id is null and playlist_id is null
      when 'quote' then text is null and body is not null and playlist_title is null and playlist_id is null
      when 'playlist' then text is null and note is null and body is null and playlist_title is not null
                           and source_quote_id is null and starter_quote_id is null
    end
  )
);

-- A conversation's messages, newest first (also covers the conversation_id
-- foreign key).
create index messages_conversation_id_created_at_id_idx on public.messages (conversation_id, created_at desc, id);
-- The daily limit (also covers the sender_id foreign key).
create index messages_sender_id_created_at_idx on public.messages (sender_id, created_at);
-- The other foreign keys are sparse (most messages are text).
create index messages_source_quote_id_idx on public.messages (source_quote_id) where source_quote_id is not null;
create index messages_starter_quote_id_idx on public.messages (starter_quote_id) where starter_quote_id is not null;
create index messages_playlist_id_idx on public.messages (playlist_id) where playlist_id is not null;
create index messages_verified_starter_id_idx on public.messages (verified_starter_id)
  where verified_starter_id is not null;
create index messages_creator_id_creator_username_idx on public.messages (creator_id, creator_username)
  where creator_id is not null;
create index messages_edited_from_id_edited_from_username_idx on public.messages (edited_from_id, edited_from_username)
  where edited_from_id is not null;

comment on table public.messages is
  'A message in a conversation: text, a quote snapshot or a playlist link. Only the two members read it. No edits; the sender may unsend (delete), which keeps a copy in private.message_tombstones for 30 days. Limit: 300 per sender per 24 hours (QR001).';
comment on column public.messages.kind is
  'text, quote or playlist. Each kind carries only its own columns (messages_kind_shape).';
comment on column public.messages.text is
  'A text message, 1 to 1000 characters. Refused (QR004) when the recipient turned off accepts_text_messages; checked against the word filter (QR003, trigger messages_build_snapshot).';
comment on column public.messages.note is
  'Optional note on a quote message, 1 to 280 characters. Checked against the word filter (QR003).';
comment on column public.messages.body is
  'Server-owned snapshot (trigger messages_build_snapshot) of the quote''s wording at send time, as are body_format, author, source, the creator and edited-from pairs and verified_starter_id. Checked against the word filter unless verified.';
comment on column public.messages.creator_id is
  'Server-owned (trigger messages_build_snapshot): the quote''s creator at send time ("Added by"); null for verified quotes ("Quoted Catalog", edited-from too) and when unknown or deleted.';
comment on column public.messages.source_quote_id is
  'The sender''s own quote a quote message was made from; null once that quote is deleted. Not readable by clients (no column grant).';
comment on column public.messages.playlist_id is
  'The sender''s playlist a playlist message links to (friends or public when sent); null once it is deleted. The recipient opens it through public.playlist_view.';
comment on column public.messages.playlist_title is
  'Server-owned (trigger messages_build_snapshot): the playlist''s title when it was sent, shown once the playlist is no longer available.';
comment on column public.messages.created_at is
  'Server-owned (trigger messages_stamp_created_at).';

-- Clients send only these columns and read every column but source_quote_id;
-- sender_id comes from auth.uid(). No update for anyone but the server.
revoke all on table public.messages from public, anon, authenticated, service_role;
grant select (id, conversation_id, sender_id, kind, text, note, body, body_format, author, source,
              creator_id, creator_username, edited_from_id, edited_from_username, verified_starter_id,
              starter_quote_id, playlist_id, playlist_title, created_at)
  on table public.messages to authenticated;
grant insert (id, conversation_id, kind, text, note, source_quote_id, starter_quote_id, playlist_id)
  on table public.messages to authenticated;
grant delete on table public.messages to authenticated;
grant select, insert, update, delete on table public.messages to service_role;

alter table public.messages enable row level security;

-- Unsent messages, kept for moderation. SECURITY DEFINER triggers write it;
-- no API role can read it. Gone with the sender's account.
create table private.message_tombstones (
  id uuid not null,
  conversation_id uuid,
  sender_id uuid not null,
  payload jsonb not null,
  deleted_at timestamptz not null default now(),
  constraint message_tombstones_pkey primary key (id),
  constraint message_tombstones_sender_id_fkey foreign key (sender_id) references public.profiles (id) on delete cascade
);
-- The daily limit counts a sender's recent unsends (also covers the sender_id
-- foreign key).
create index message_tombstones_sender_id_deleted_at_idx on private.message_tombstones (sender_id, deleted_at);
create index message_tombstones_deleted_at_idx on private.message_tombstones (deleted_at);
comment on table private.message_tombstones is
  'A copy (payload, the whole row as jsonb) of every message deleted directly (an unsend, or the founder), kept 30 days for moderation (trigger messages_keep_tombstone; pg_cron job purge-message-tombstones). Cascades from account deletion leave none. Gone with the sender''s account.';
revoke all on table private.message_tombstones from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. reports: the new targets (the rest of the rework is in section 11)
-- ---------------------------------------------------------------------------
alter table public.reports
  add column post_id uuid,
  add column message_id uuid,
  add column playlist_id uuid,
  add column starter_quote_id smallint,
  add column content_note text,
  add constraint reports_post_id_fkey foreign key (post_id) references public.posts (id) on delete set null
    deferrable initially deferred,
  add constraint reports_message_id_fkey foreign key (message_id) references public.messages (id) on delete set null
    deferrable initially deferred,
  add constraint reports_playlist_id_fkey foreign key (playlist_id) references public.playlists (id) on delete set null
    deferrable initially deferred,
  add constraint reports_starter_quote_id_fkey foreign key (starter_quote_id)
    references public.starter_quotes (id) on delete set null
    deferrable initially deferred,
  add constraint reports_content_note_length check (char_length(content_note) <= 1000),
  add constraint reports_content_note_not_blank check (not private.is_blank(content_note)),
  add constraint reports_one_target check (num_nonnulls(post_id, message_id, playlist_id, starter_quote_id) <= 1),
  add constraint reports_catalog_has_no_user check (starter_quote_id is null or reported_user_id is null),
  drop constraint reports_reason_valid,
  add constraint reports_reason_valid
    check (reason in ('spam', 'harassment', 'inappropriate', 'copyright', 'wrong_wording', 'other'));

create index reports_post_id_idx on public.reports (post_id) where post_id is not null;
create index reports_message_id_idx on public.reports (message_id) where message_id is not null;
create index reports_playlist_id_idx on public.reports (playlist_id) where playlist_id is not null;
create index reports_starter_quote_id_idx on public.reports (starter_quote_id) where starter_quote_id is not null;

comment on column public.reports.post_id is
  'The reported post; null once it is deleted (the snapshot stays). At most one of post_id, message_id, playlist_id and starter_quote_id is set; none means a report about reported_user_id''s profile.';
comment on column public.reports.message_id is
  'The reported message; null once it is unsent or deleted (the snapshot stays, and an unsent message is in private.message_tombstones for 30 days).';
comment on column public.reports.playlist_id is
  'The reported playlist; null once it is deleted.';
comment on column public.reports.starter_quote_id is
  'The reported Quoted Catalog quote (for example wrong_wording); such a report names no user.';
comment on column public.reports.content_note is
  'Server-owned for a target report (trigger reports_snapshot_target): the post''s caption, the message''s text or note, or the playlist''s title when the report was filed. A profile report keeps what the reporter sent.';
comment on column public.reports.content_verified is
  'True only when the server copied the snapshot from the target, which the reported user wrote (trigger reports_snapshot_target); for a message, only when the reporter is in its conversation. Clients cannot set it.';

-- ---------------------------------------------------------------------------
-- 5. Access helpers
-- ---------------------------------------------------------------------------

-- True when p_a or p_b has blocked the caller. SECURITY DEFINER because a user
-- cannot read blocks made by someone else; it answers only about blocks
-- against the caller (as private.is_blocked_pair does). The conversations
-- policy calls it.
create function private.caller_blocked_by(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.blocks b
    where b.blocked_id = (select auth.uid())
      and b.blocker_id in (p_a, p_b)
  )
$$;
comment on function private.caller_blocked_by(uuid, uuid) is
  'True when either user has blocked the caller. Answers only about blocks against the caller.';
revoke all on function private.caller_blocked_by(uuid, uuid) from public, anon, service_role;
grant execute on function private.caller_blocked_by(uuid, uuid) to authenticated;

-- True when the caller has reported this message (or post, or playlist): the
-- item disappears for its reporter at once. SECURITY INVOKER (a reporter reads
-- their own reports), so a policy can inline it; it filters by the caller
-- explicitly, so it is also right inside SECURITY DEFINER functions.
create function private.caller_reported_message(p_message uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.reports r
    where r.message_id = p_message and r.reporter_id = (select auth.uid())
  )
$$;
comment on function private.caller_reported_message(uuid) is
  'True when the caller has reported this message.';
revoke all on function private.caller_reported_message(uuid) from public, anon, service_role;
grant execute on function private.caller_reported_message(uuid) to authenticated;

-- Replaces the placeholder from 20261029090200_posts (grants kept): the posts
-- policy and private.post_access pick it up.
create or replace function private.caller_reported_post(p_post uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.reports r
    where r.post_id = p_post and r.reporter_id = (select auth.uid())
  )
$$;
comment on function private.caller_reported_post(uuid) is
  'True when the caller has reported this post.';

create function private.caller_reported_playlist(p_playlist uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.reports r
    where r.playlist_id = p_playlist and r.reporter_id = (select auth.uid())
  )
$$;
comment on function private.caller_reported_playlist(uuid) is
  'True when the caller has reported this playlist.';
revoke all on function private.caller_reported_playlist(uuid) from public, anon, service_role;
grant execute on function private.caller_reported_playlist(uuid) to authenticated;

-- Replaces the version from 20261029090100_playlists (grants kept): a
-- playlist the caller reported also disappears for them (playlist_view, the
-- saves, and anything else built on this rule). A public playlist reaches a
-- stranger only while its owner may still publish (private.user_can_publish).
create or replace function private.playlist_access(p_playlist uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when p.owner_id = v.uid then 'owner'
           when p.held_at is not null then null
           when private.caller_reported_playlist(p.id) then null
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

-- The messages select rule, for SECURITY DEFINER code (save_from_message):
-- the caller is a member, the message is newer than their cleared_at, neither
-- member blocked the caller, and the caller has not reported it. Keep in step
-- with the policy "messages: members read, unless blocked or reported".
-- Called only by SECURITY DEFINER functions: no API role may execute it.
create function private.caller_can_read_message(p_message uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = (select auth.uid())
    where m.id = p_message
      and (cm.cleared_at is null or m.created_at > cm.cleared_at)
      and not exists (
        select 1 from public.blocks b
        where b.blocked_id = (select auth.uid()) and b.blocker_id in (c.user_a, c.user_b)
      )
      and not exists (
        select 1 from public.reports r
        where r.message_id = m.id and r.reporter_id = (select auth.uid())
      )
  )
$$;
revoke all on function private.caller_can_read_message(uuid) from public, anon, authenticated, service_role;

-- Whether the caller may report this target and name p_user as its author,
-- sender or owner (the reports insert policy). SECURITY DEFINER: a member
-- reports a message even after the other member blocked them (they no longer
-- read it), and a stranger reports a public post they reached through
-- profile_view. Each answers only for the caller.
--   message: the caller is a member of its conversation (even closed, even
--     cleared) and p_user sent it;
--   post: private.post_access is 'friend' or 'public' and p_user wrote it;
--   playlist: private.playlist_access is 'friend' or 'public' and p_user
--     owns it.
create function private.caller_can_report_message(p_message uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = (select auth.uid())
    where m.id = p_message
      and m.sender_id = p_user
      and m.sender_id <> (select auth.uid())
  )
$$;
revoke all on function private.caller_can_report_message(uuid, uuid) from public, anon, service_role;
grant execute on function private.caller_can_report_message(uuid, uuid) to authenticated;

create function private.caller_can_report_post(p_post uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts p
    where p.id = p_post
      and p.author_id = p_user
      and private.post_access(p.id) in ('friend', 'public')
  )
$$;
revoke all on function private.caller_can_report_post(uuid, uuid) from public, anon, service_role;
grant execute on function private.caller_can_report_post(uuid, uuid) to authenticated;

create function private.caller_can_report_playlist(p_playlist uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.playlists p
    where p.id = p_playlist
      and p.owner_id = p_user
      and private.playlist_access(p.id) in ('friend', 'public')
  )
$$;
revoke all on function private.caller_can_report_playlist(uuid, uuid) from public, anon, service_role;
grant execute on function private.caller_can_report_playlist(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Row Level Security
-- ---------------------------------------------------------------------------

-- The one access rule for a conversation: the caller is one of the pair and
-- neither member has blocked them (in practice, the other member: nobody can
-- block themselves). The member and message policies, and the profiles
-- policy, read conversations under this rule.
create policy "conversations: members read, unless blocked by the other"
  on public.conversations for select to authenticated
  using (
    (select auth.uid()) in (user_a, user_b)
    and not private.caller_blocked_by(user_a, user_b)
  );

create policy "conversation_members: read your own row"
  on public.conversation_members for select to authenticated
  using (
    user_id = (select auth.uid())
    and conversation_id in (select c.id from public.conversations c)
  );

-- Column grants limit the writable columns to last_read_at and cleared_at;
-- trigger conversation_members_stamp_times puts them on the server clock.
create policy "conversation_members: update your own row"
  on public.conversation_members for update to authenticated
  using (
    user_id = (select auth.uid())
    and conversation_id in (select c.id from public.conversations c)
  )
  with check (
    user_id = (select auth.uid())
    and conversation_id in (select c.id from public.conversations c)
  );

-- A member, for messages newer than their cleared_at, in a conversation they
-- may read (not blocked by the other member), unless they reported the
-- message. The conversations subquery is uncorrelated (evaluated once per
-- statement). Keep in step with private.caller_can_read_message.
create policy "messages: members read, unless blocked or reported"
  on public.messages for select to authenticated
  using (
    conversation_id in (select c.id from public.conversations c)
    and exists (
      select 1
      from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = (select auth.uid())
        and (m.cleared_at is null or messages.created_at > m.cleared_at)
    )
    and not private.caller_reported_message(messages.id)
  );

-- Sending is a social write. The snapshot is already built by
-- messages_build_snapshot when this check runs.
create policy "messages: members send to an open conversation"
  on public.messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and (select private.has_accepted_terms())
    and not (select private.caller_is_suspended())
    and exists (
      select 1
      from public.conversations c
      join public.conversation_members m on m.conversation_id = c.id and m.user_id = (select auth.uid())
      where c.id = messages.conversation_id
        and c.closed_at is null
        and exists (
          select 1 from public.friendships f
          where f.status = 'accepted'
            and least(f.requester_id, f.addressee_id) = c.user_a
            and greatest(f.requester_id, f.addressee_id) = c.user_b
        )
        and not private.is_blocked_pair(c.user_a, c.user_b)
    )
  );

-- Unsend: the sender's own messages that they can still read, gone for both.
-- The read rule is spelled out here because Postgres adds the select policy to
-- a DELETE only when the statement reads a column: without it, a sender whom
-- the other member blocked could erase, with an unfiltered DELETE, the
-- messages the blocker keeps to report from. (A sender cannot report their
-- own message, so the reported part of the read rule never applies.)
create policy "messages: sender unsends"
  on public.messages for delete to authenticated
  using (
    sender_id = (select auth.uid())
    and conversation_id in (select c.id from public.conversations c)
    and exists (
      select 1
      from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = (select auth.uid())
        and (m.cleared_at is null or messages.created_at > m.cleared_at)
    )
  );

-- ---------------------------------------------------------------------------
-- 7. Triggers: conversations and members
-- ---------------------------------------------------------------------------
create trigger conversations_stamp_created_at
  before insert on public.conversations
  for each row execute function private.stamp_created_at();

-- Every role: a member row belongs to one of the conversation's two people.
create function private.conversation_members_check_member()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.conversations c
    where c.id = new.conversation_id and new.user_id in (c.user_a, c.user_b)
  ) then
    raise exception 'Only the two people in a conversation can be its members.'
      using errcode = 'check_violation',
            constraint = 'conversation_members_in_pair',
            schema = 'public',
            table = 'conversation_members';
  end if;
  return new;
end;
$$;
revoke all on function private.conversation_members_check_member() from public, anon, authenticated;

create trigger conversation_members_check_member
  before insert on public.conversation_members
  for each row execute function private.conversation_members_check_member();

-- Clients: a changed last_read_at or cleared_at becomes the server clock,
-- never earlier than the stored time, and null keeps the stored time. The
-- server (the shares move) writes exact times. SECURITY INVOKER so
-- current_user tells clients apart.
create function private.conversation_members_stamp_times()
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
                             else greatest(old.last_read_at, now()) end;
  end if;
  if new.cleared_at is distinct from old.cleared_at then
    new.cleared_at := case when new.cleared_at is null then old.cleared_at
                           else greatest(old.cleared_at, now()) end;
  end if;
  return new;
end;
$$;
revoke all on function private.conversation_members_stamp_times() from public, anon, authenticated;

create trigger conversation_members_stamp_times
  before update on public.conversation_members
  for each row execute function private.conversation_members_stamp_times();

-- ---------------------------------------------------------------------------
-- 8. Triggers: messages
-- ---------------------------------------------------------------------------

-- BEFORE INSERT, every role. Clients, in this order (each refusal 42501
-- unless noted), so nothing about a conversation leaks to anyone outside it:
--   accepted terms and no suspension (one answer whatever the target);
--   the conversation, read with the caller's own rights (a member the other
--     one did not block), and the caller as sender: else "not available";
--   open, accepted friends, no block either way: else "closed".
-- Then, for every role:
--   the sender is one of the pair;
--   quote: exactly one of source_quote_id (the sender's own quote; someone
--     else's and an unknown one fail the same way) and starter_quote_id
--     (23503 when unknown) (23514, messages_one_source), and the server copies
--     body, body_format, author, source, the creator and edited-from pairs and
--     verified_starter_id. Only the server can send a body (no client grant):
--     a server-supplied snapshot (the shares move) is kept, re-verified
--     against the catalog, with a pair whose account is gone nulled. A
--     verified snapshot keeps neither pair: it shows "Quoted Catalog", and the
--     hidden name of whoever typed or corrected that wording must not reach
--     the recipient;
--   playlist: the sender's own playlist, friends or public, not held; its
--     title is copied;
--   text: the recipient's accepts_text_messages, else QR004.
-- Clients last: text, note, playlist title and an unverified snapshot pass
-- the word filter (QR003).
-- SECURITY INVOKER so current_user tells clients apart and the sender's quote
-- and playlist are read with their own rights. Every private.* call sits in a
-- client-only block: the secret key (service_role) has no USAGE on the private
-- schema, and a statement is resolved only when it runs.
create function private.messages_build_snapshot()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_client boolean := current_user not in ('postgres', 'service_role', 'supabase_admin');
  v_conversation public.conversations;
  v_recipient uuid;
  v_quote public.quotes;
  v_starter public.starter_quotes;
  v_playlist public.playlists;
  v_accepts boolean;
begin
  if v_client then
    perform private.assert_can_socialize();
  end if;

  select c.* into v_conversation from public.conversations c where c.id = new.conversation_id;
  if not found
     or new.sender_id is null
     or new.sender_id not in (v_conversation.user_a, v_conversation.user_b)
     or (v_client and new.sender_id is distinct from (select auth.uid())) then
    raise exception 'This conversation is not available.'
      using errcode = 'insufficient_privilege';
  end if;
  v_recipient := case when new.sender_id = v_conversation.user_a then v_conversation.user_b
                      else v_conversation.user_a end;

  if v_client then
    if v_conversation.closed_at is not null
       or not exists (
         select 1 from public.friendships f
         where f.status = 'accepted'
           and least(f.requester_id, f.addressee_id) = v_conversation.user_a
           and greatest(f.requester_id, f.addressee_id) = v_conversation.user_b
       )
       or private.is_blocked_pair(v_conversation.user_a, v_conversation.user_b) then
      raise exception 'This conversation is closed.'
        using errcode = 'insufficient_privilege', hint = 'You can send messages only to friends.';
    end if;
  end if;

  if new.kind = 'quote' then
    if not v_client and new.body is not null then
      new.body_format := coalesce(new.body_format, '[]'::jsonb);
      if new.creator_id is not null and not exists (
        select 1 from public.profiles p where p.id = new.creator_id and p.username = new.creator_username
      ) then
        new.creator_id := null;
        new.creator_username := null;
      end if;
      if new.edited_from_id is not null and not exists (
        select 1 from public.profiles p where p.id = new.edited_from_id and p.username = new.edited_from_username
      ) then
        new.edited_from_id := null;
        new.edited_from_username := null;
      end if;
      new.verified_starter_id := (
        select s.id
        from public.starter_quotes s
        where s.body = new.body
          and s.author is not distinct from new.author
          and s.source is not distinct from new.source
        order by s.id
        limit 1
      );
    else
      if (new.source_quote_id is null) = (new.starter_quote_id is null) then
        raise exception 'A quote message holds exactly one quote: one of yours or one from the Quoted Catalog.'
          using errcode = 'check_violation',
                constraint = 'messages_one_source',
                schema = 'public',
                table = 'messages',
                hint = 'Send source_quote_id or starter_quote_id, not both.';
      end if;

      if new.source_quote_id is not null then
        select q.* into v_quote
          from public.quotes q
         where q.id = new.source_quote_id
           and q.owner_id = new.sender_id;
        if not found then
          raise exception 'You can send only quotes from your Library or the Quoted Catalog.'
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
    end if;
    if new.verified_starter_id is not null then
      new.creator_id := null;
      new.creator_username := null;
      new.edited_from_id := null;
      new.edited_from_username := null;
    end if;
  elsif new.kind = 'playlist' then
    select p.* into v_playlist
      from public.playlists p
     where p.id = new.playlist_id
       and p.owner_id = new.sender_id;
    if not found or v_playlist.visibility = 'private' then
      raise exception 'You can send only your own playlists that friends can see.'
        using errcode = 'insufficient_privilege', hint = 'Choose Friends for this playlist first.';
    end if;
    if v_playlist.held_at is not null then
      raise exception 'This playlist is hidden while it is reviewed.'
        using errcode = 'insufficient_privilege', hint = 'Contact support.';
    end if;
    new.playlist_title := v_playlist.title;
  elsif new.kind = 'text' then
    select p.accepts_text_messages into v_accepts from public.profiles p where p.id = v_recipient;
    if not coalesce(v_accepts, false) then
      raise exception 'This friend receives quotes only.'
        using errcode = 'QR004', hint = 'Send a quote or a playlist instead.';
    end if;
  end if;

  if v_client then
    if new.kind = 'quote' and new.verified_starter_id is null then
      perform private.assert_allowed_text(
        new.text, new.note, new.playlist_title,
        new.body || ' ' || coalesce(new.author, '') || ' ' || coalesce(new.source, '')
      );
    else
      perform private.assert_allowed_text(new.text, new.note, new.playlist_title);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.messages_build_snapshot() from public, anon, authenticated;

create trigger messages_build_snapshot
  before insert on public.messages
  for each row execute function private.messages_build_snapshot();

-- 300 messages per sender per rolling 24 hours (QR001), every role, counting
-- the messages unsent since (their copies in private.message_tombstones), so
-- unsending makes no room for more the same day. SECURITY DEFINER: a sender
-- cannot read all of their own messages (cleared, reported, or in a
-- conversation the other member blocked them from), so a count under their
-- RLS would be too low, and the tombstones have no API grants. It filters by
-- sender_id explicitly (messages_build_snapshot has already refused a client
-- sending as someone else) and guards no client column. An id that already
-- exists is left to the primary key (23505); an id whose message was unsent
-- in the last 30 days fails the same way, so a tombstone is never
-- overwritten.
create function private.messages_enforce_limit()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.messages m where m.id = new.id) then
    return new;
  end if;
  if exists (select 1 from private.message_tombstones t where t.id = new.id) then
    raise exception 'duplicate key value violates unique constraint "messages_pkey"'
      using errcode = 'unique_violation',
            constraint = 'messages_pkey',
            schema = 'public',
            table = 'messages';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.messages:' || new.sender_id::text, 0));
  if (select count(*) from (
        select 1 from public.messages m
        where m.sender_id = new.sender_id
          and m.created_at > now() - interval '24 hours'
        limit 300) recent)
     + (select count(*) from (
        select 1 from private.message_tombstones t
        where t.sender_id = new.sender_id
          and t.deleted_at > now() - interval '24 hours'
          and (t.payload ->> 'created_at')::timestamptz > now() - interval '24 hours'
        limit 300) unsent) >= 300 then
    raise exception 'You can send at most 300 messages a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;
  return new;
end;
$$;
revoke all on function private.messages_enforce_limit() from public, anon, authenticated;

create trigger messages_enforce_limit
  before insert on public.messages
  for each row execute function private.messages_enforce_limit();

create trigger messages_stamp_created_at
  before insert on public.messages
  for each row execute function private.stamp_created_at();

-- The conversation's last_message_at. AFTER INSERT it moves up to the new
-- message. AFTER DELETE (an unsend, or the founder) it is worked out again
-- from the messages left, so an unsent message leaves no sign of when it was
-- sent (gone for both). A cascade (a deleted conversation, or an account,
-- which deletes its conversations too) finds no conversation left to update.
-- SECURITY DEFINER: clients cannot update conversations.
create function private.messages_touch_conversation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.conversations c
       set last_message_at = greatest(c.last_message_at, new.created_at)
     where c.id = new.conversation_id;
  else
    update public.conversations c
       set last_message_at = (select max(m.created_at) from public.messages m where m.conversation_id = c.id)
     where c.id = old.conversation_id;
  end if;
  return null;
end;
$$;
revoke all on function private.messages_touch_conversation() from public, anon, authenticated;

create trigger messages_touch_conversation
  after insert or delete on public.messages
  for each row execute function private.messages_touch_conversation();

-- BEFORE DELETE: a message deleted directly (an unsend, or the founder) is
-- copied into private.message_tombstones. Cascades (account deletion) run
-- inside another trigger and leave none. SECURITY DEFINER: the table has no
-- API grants.
create function private.messages_keep_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return old;
  end if;
  insert into private.message_tombstones (id, conversation_id, sender_id, payload)
  values (old.id, old.conversation_id, old.sender_id, to_jsonb(old))
  on conflict (id) do nothing;
  return old;
end;
$$;
revoke all on function private.messages_keep_tombstone() from public, anon, authenticated;

create trigger messages_keep_tombstone
  before delete on public.messages
  for each row execute function private.messages_keep_tombstone();

-- Deletes tombstones older than 30 days; returns how many. pg_cron runs it
-- daily. p_now exists for tests; the schedule uses now().
create function private.purge_message_tombstones(p_now timestamptz default now())
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from private.message_tombstones t
   where t.deleted_at < p_now - interval '30 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
comment on function private.purge_message_tombstones(timestamptz) is
  'Deletes unsent-message copies older than 30 days. Scheduled daily by pg_cron (purge-message-tombstones).';
revoke all on function private.purge_message_tombstones(timestamptz) from public, anon, authenticated, service_role;

-- Daily at 03:41 UTC, like purge-inactive-anonymous: only where pg_cron
-- exists; otherwise the migration still applies and says so. Check with:
-- select jobname, schedule, command from cron.job;
do $do$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning 'pg_cron is not available, so private.purge_message_tombstones() is not scheduled';
    return;
  end if;
  begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      create extension pg_cron;
    end if;
    perform cron.schedule(
      'purge-message-tombstones',
      '41 3 * * *',
      'select private.purge_message_tombstones()'
    );
  exception when others then
    raise warning 'pg_cron could not schedule purge-message-tombstones: % (%)', sqlerrm, sqlstate;
  end;
end
$do$;

-- ---------------------------------------------------------------------------
-- 9. Friendships and blocks
-- ---------------------------------------------------------------------------

-- Unfriending (deleting an accepted friendship) closes the pair's
-- conversation: read-only for both. SECURITY DEFINER: clients cannot update
-- conversations.
create function private.friendships_close_conversation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'accepted' then
    update public.conversations c
       set closed_at = now()
     where c.user_a = least(old.requester_id, old.addressee_id)
       and c.user_b = greatest(old.requester_id, old.addressee_id)
       and c.closed_at is null;
  end if;
  return null;
end;
$$;
revoke all on function private.friendships_close_conversation() from public, anon, authenticated;

create trigger friendships_close_conversation
  after delete on public.friendships
  for each row execute function private.friendships_close_conversation();

-- A friendship that becomes accepted reopens the pair's conversation, unless
-- either has blocked the other. SECURITY DEFINER, as above.
create function private.friendships_reopen_conversation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'accepted' and (tg_op = 'INSERT' or old.status is distinct from 'accepted') then
    update public.conversations c
       set closed_at = null
     where c.user_a = least(new.requester_id, new.addressee_id)
       and c.user_b = greatest(new.requester_id, new.addressee_id)
       and c.closed_at is not null
       and not exists (
         select 1 from public.blocks b
         where (b.blocker_id = new.requester_id and b.blocked_id = new.addressee_id)
            or (b.blocker_id = new.addressee_id and b.blocked_id = new.requester_id)
       );
  end if;
  return null;
end;
$$;
revoke all on function private.friendships_reopen_conversation() from public, anon, authenticated;

create trigger friendships_reopen_conversation
  after insert or update of status on public.friendships
  for each row execute function private.friendships_reopen_conversation();

-- A block removes the pair's friendship (pending or accepted) and closes
-- their conversation. It deletes no message: the blocker keeps the
-- conversation read-only, to report from it, and the blocked person loses
-- read access (the policies). Unblocking does not reopen it; a new accepted
-- friendship does. Replaces the version from 20261019040000_core_schema,
-- which deleted the pair's shares. SECURITY DEFINER; new.blocker_id is pinned
-- to auth.uid() by the blocks insert policy.
create or replace function private.blocks_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friendships f
  where least(f.requester_id, f.addressee_id) = least(new.blocker_id, new.blocked_id)
    and greatest(f.requester_id, f.addressee_id) = greatest(new.blocker_id, new.blocked_id);

  update public.conversations c
     set closed_at = now()
   where c.user_a = least(new.blocker_id, new.blocked_id)
     and c.user_b = greatest(new.blocker_id, new.blocked_id)
     and c.closed_at is null;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Profiles linked by a conversation; the RPCs
-- ---------------------------------------------------------------------------

-- Your own row, plus everyone linked to you by a friendship (either side, any
-- status), a block you made, or a conversation you may read (either member).
-- Replaces the version from 20261021090000, whose share link goes with the
-- shares table. Each subquery runs under the caller's own RLS: a person who
-- blocked you is no longer linked by your conversation, nor by a block you
-- make back (blocking them would otherwise show you their live profile and
-- tell you that they blocked you).
drop policy "profiles: read your own and linked profiles" on public.profiles;
create policy "profiles: read your own and linked profiles"
  on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or id in (select f.addressee_id from public.friendships f where f.requester_id = (select auth.uid()))
    or id in (select f.requester_id from public.friendships f where f.addressee_id = (select auth.uid()))
    or id in (select b.blocked_id from public.blocks b
              where b.blocker_id = (select auth.uid())
                and not private.caller_blocked_by(b.blocked_id, b.blocked_id))
    or id in (select c.user_b from public.conversations c where c.user_a = (select auth.uid()))
    or id in (select c.user_a from public.conversations c where c.user_b = (select auth.uid()))
  );

-- Returns the caller's conversation with an accepted friend (no block either
-- way), creating it and both member rows if missing and reopening it if it
-- was closed. Opening a conversation is a social write (the friend sees it in
-- their Inbox): accepted terms and no suspension first. Refused with 42501,
-- the same answer for "not a friend", "blocked", "pending" and "unknown".
create function private.open_conversation(p_friend uuid)
returns public.conversations
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_row public.conversations;
begin
  if v_uid is null then
    raise exception 'Sign in to send messages.' using errcode = 'insufficient_privilege';
  end if;
  perform private.assert_can_socialize();

  if p_friend is null
     or p_friend = v_uid
     or not exists (
       select 1 from public.friendships f
       where f.status = 'accepted'
         and least(f.requester_id, f.addressee_id) = least(v_uid, p_friend)
         and greatest(f.requester_id, f.addressee_id) = greatest(v_uid, p_friend)
     )
     or exists (
       select 1 from public.blocks b
       where (b.blocker_id = v_uid and b.blocked_id = p_friend)
          or (b.blocker_id = p_friend and b.blocked_id = v_uid)
     ) then
    raise exception 'This person is not available.'
      using errcode = 'insufficient_privilege', hint = 'You can send messages only to friends.';
  end if;

  insert into public.conversations (user_a, user_b)
  values (least(v_uid, p_friend), greatest(v_uid, p_friend))
  on conflict on constraint conversations_pair_key do nothing;

  select c.* into v_row
    from public.conversations c
   where c.user_a = least(v_uid, p_friend)
     and c.user_b = greatest(v_uid, p_friend)
   for update;

  if v_row.closed_at is not null then
    update public.conversations c
       set closed_at = null
     where c.id = v_row.id
    returning c.* into v_row;
  end if;

  insert into public.conversation_members (conversation_id, user_id)
  values (v_row.id, v_uid), (v_row.id, p_friend)
  on conflict on constraint conversation_members_pkey do nothing;

  return v_row;
end;
$$;
revoke all on function private.open_conversation(uuid) from public, anon, service_role;
grant execute on function private.open_conversation(uuid) to authenticated;

create function public.open_conversation(p_friend uuid)
returns public.conversations
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.open_conversation(p_friend)
$$;
comment on function public.open_conversation(uuid) is
  'The caller''s conversation with an accepted friend (no block either way), created or reopened as needed. Needs accepted terms and no suspension; 42501 otherwise, the same for every other reason. SECURITY INVOKER wrapper over private.open_conversation.';
revoke all on function public.open_conversation(uuid) from public, anon, service_role;
grant execute on function public.open_conversation(uuid) to authenticated;

-- The Inbox: one row per conversation the caller may read, with the other
-- member's public profile, whether it is closed, the latest message the caller
-- can see (time, kind, sender and a 140-character preview: the text, the
-- quote's body or the playlist's title) and how many messages from the other
-- member are newer than the caller's last_read_at. Conversations with no
-- visible message are left out, unless they have none at all (just opened,
-- or every message unsent) and the caller never cleared them.
-- Newest first. SECURITY INVOKER: every read goes through RLS, so it shows
-- exactly what the tables show the caller.
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
  unread_count integer
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
         coalesce(u.unread, 0)
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
  'The caller''s Inbox: one row per conversation they may read, with the other member, the latest visible message and the unread count, newest first. SECURITY INVOKER: access control is the RLS of conversations, conversation_members, messages and profiles.';
revoke all on function public.inbox_conversations() from public, anon, service_role;
grant execute on function public.inbox_conversations() to authenticated;

-- Saves a quote message's quote to the caller's Library: origin shared, the
-- message's snapshot with its creator and edited-from (never the sender,
-- unless they are the creator). Refused with 42501, the same answer for every
-- reason, unless it is a quote message the caller can read right now
-- (private.caller_can_read_message). Saving into your own Library is private,
-- so it needs no terms. A p_id the caller already owns returns that quote
-- unchanged (an idempotent retry).
create function private.save_from_message(
  p_message uuid,
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
  v_message public.messages;
begin
  if v_uid is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;

  v_existing := private.caller_quote_for_retry(p_id);
  if v_existing.id is not null then
    return v_existing;
  end if;

  select m.* into v_message
    from public.messages m
   where m.id = p_message
     and m.kind = 'quote'
     and private.caller_can_read_message(m.id);
  if not found then
    raise exception 'This message is not available.' using errcode = 'insufficient_privilege';
  end if;

  return private.insert_caller_quote(
    p_id, v_message.body, v_message.body_format, v_message.author, v_message.source, 'shared',
    v_message.creator_id, v_message.creator_username, v_message.edited_from_id, v_message.edited_from_username,
    p_in_reminders
  );
end;
$$;
revoke all on function private.save_from_message(uuid, uuid, boolean) from public, anon, service_role;
grant execute on function private.save_from_message(uuid, uuid, boolean) to authenticated;

create function public.save_from_message(
  p_message uuid,
  p_id uuid default null,
  p_in_reminders boolean default false
)
returns public.quotes
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.save_from_message(p_message, p_id, p_in_reminders)
$$;
comment on function public.save_from_message(uuid, uuid, boolean) is
  'Saves a quote message''s quote to the caller''s Library with origin shared and the original creator and edited-from. 42501 unless the caller can read that quote message. SECURITY INVOKER wrapper over private.save_from_message.';
revoke all on function public.save_from_message(uuid, uuid, boolean) from public, anon, service_role;
grant execute on function public.save_from_message(uuid, uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Shares move into messages
-- ---------------------------------------------------------------------------

-- Moves every share into a quote message (same id), oldest first, and points
-- reports at the messages. Re-runnable: a share whose message exists is
-- skipped, an existing conversation or member row is reused (a member's
-- last_read_at only moves forward). This migration calls it once, before it
-- drops public.shares and reports.share_id. No API role may execute it.
--   conversations: one per pair, closed unless the pair are accepted friends
--     now (a block deletes the friendship, so blocked pairs are closed);
--   members: both people; last_read_at is the latest seen_at among the
--     shares that person received in the pair (null if none);
--   messages: kind quote with the share's id, created_at, note and snapshot;
--     verified_starter_id is recomputed from the same wording (what the
--     share stored); the creator is the sender only when share.quote_id still
--     points to the sender's own manual or pasted quote, else nobody;
--     source_quote_id is share.quote_id when it is still the sender's quote.
--     Each insert takes the server clock and is then given the share's time,
--     one by one, so the 300-a-day limit sees the real times;
--   conversations get last_message_at (and created_at) from their messages;
--   reports.message_id = share_id where that message exists.
-- Returns how many shares were moved. Dropped at the end of this migration,
-- once public.shares is gone (it could only fail afterwards);
-- 19b_share_migration.test.sql recreates a verbatim copy to rerun the move on
-- fixtures, so keep the two identical.
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
comment on function private.move_shares_to_messages() is
  'One-time move of public.shares into quote messages, run and then dropped by 20261029090300_conversations_and_messages.';
revoke all on function private.move_shares_to_messages() from public, anon, authenticated, service_role;

-- The move queues deferred foreign key checks (messages, reports.message_id).
-- Switching those constraints to immediate runs the checks now, because
-- ALTER TABLE refuses a table with pending trigger events (section 12 alters
-- reports); switching them back keeps the rest of the transaction as usual.
-- Inside the DO block, so it applies to this migration's transaction however
-- the runner wraps the file.
do $do$
begin
  perform private.move_shares_to_messages();
  set constraints
    public.messages_conversation_id_fkey, public.messages_sender_id_fkey, public.messages_creator_id_fkey,
    public.messages_edited_from_id_fkey, public.messages_verified_starter_id_fkey,
    public.messages_source_quote_id_fkey, public.messages_starter_quote_id_fkey,
    public.messages_playlist_id_fkey, public.reports_message_id_fkey
    immediate;
  set constraints
    public.messages_conversation_id_fkey, public.messages_sender_id_fkey, public.messages_creator_id_fkey,
    public.messages_edited_from_id_fkey, public.messages_verified_starter_id_fkey,
    public.messages_source_quote_id_fkey, public.messages_starter_quote_id_fkey,
    public.messages_playlist_id_fkey, public.reports_message_id_fkey
    deferred;
end
$do$;

-- ---------------------------------------------------------------------------
-- 12. Reports: the rework, and shares go
-- ---------------------------------------------------------------------------

-- The insert policy and the moderation queue named shares and share_id.
drop policy "reports: file as yourself" on public.reports;
drop view private.reports_to_review;
drop index public.reports_reporter_reported_share_key;
alter table public.reports drop column share_id;

-- Whatever the client sent: the reporter and (unless it is about a catalog
-- quote) the reported user are required, wrong_wording is for catalog quotes
-- only, and the server-owned columns are reset. For a target, the content is
-- copied from the server row when the reported user wrote it (for a message,
-- also only when the reporter is in its conversation) and content_verified
-- says whether it was; otherwise the content is null. A profile report keeps
-- the reporter's own account, unverified. Every role, the secret key
-- included. SECURITY DEFINER: a reporter may no longer read what they report
-- (a message after the other member blocked them, a stranger's public post).
-- The insert policy decides whether a client may file the row at all; it is
-- checked after this trigger, so a refused row never shows its copy. Sorts
-- before reports_snapshot_username, which then fills reported_username.
create function private.reports_snapshot_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message public.messages;
  v_post public.posts;
  v_playlist public.playlists;
  v_starter public.starter_quotes;
begin
  if new.reporter_id is null then
    raise exception 'a report needs reporter_id' using errcode = 'not_null_violation';
  end if;
  if new.reported_user_id is null and new.starter_quote_id is null then
    raise exception 'a report needs reported_user_id unless it is about a Quoted Catalog quote'
      using errcode = 'not_null_violation';
  end if;
  if new.reason = 'wrong_wording' and new.starter_quote_id is null then
    raise exception 'wrong_wording is only for Quoted Catalog quotes'
      using errcode = 'check_violation',
            constraint = 'reports_wrong_wording_catalog_only',
            schema = 'public',
            table = 'reports';
  end if;

  new.content_verified := false;
  new.reviewed_at := null;
  new.reported_username := null;

  if new.message_id is not null then
    select m.* into v_message
      from public.messages m
     where m.id = new.message_id
       and m.sender_id = new.reported_user_id
       and exists (
         select 1 from public.conversation_members cm
         where cm.conversation_id = m.conversation_id and cm.user_id = new.reporter_id
       );
    new.content_verified := found;
    new.content_body := v_message.body;
    new.content_author := v_message.author;
    new.content_source := v_message.source;
    new.content_note := coalesce(v_message.text, v_message.note, v_message.playlist_title);
  elsif new.post_id is not null then
    select p.* into v_post
      from public.posts p
     where p.id = new.post_id
       and p.author_id = new.reported_user_id;
    new.content_verified := found;
    new.content_body := v_post.body;
    new.content_author := v_post.author;
    new.content_source := v_post.source;
    new.content_note := v_post.caption;
  elsif new.playlist_id is not null then
    select p.* into v_playlist
      from public.playlists p
     where p.id = new.playlist_id
       and p.owner_id = new.reported_user_id;
    new.content_verified := found;
    new.content_body := null;
    new.content_author := null;
    new.content_source := null;
    new.content_note := v_playlist.title;
  elsif new.starter_quote_id is not null then
    select s.* into v_starter
      from public.starter_quotes s
     where s.id = new.starter_quote_id;
    new.content_verified := found;
    new.content_body := v_starter.body;
    new.content_author := v_starter.author;
    new.content_source := v_starter.source;
    new.content_note := null;
  end if;

  return new;
end;
$$;
revoke all on function private.reports_snapshot_target() from public, anon, authenticated;

create trigger reports_snapshot_target
  before insert on public.reports
  for each row execute function private.reports_snapshot_target();

drop trigger reports_snapshot_share on public.reports;
drop function private.reports_snapshot_share();

-- The reporter is the caller, and the target is one they may report (see the
-- private.caller_can_report_* helpers), naming its author, sender or owner:
-- a message in one of their conversations; a post or playlist they can see;
-- any Quoted Catalog quote, naming nobody; or, with no target, a profile.
create policy "reports: file as yourself, about what you can see"
  on public.reports for insert to authenticated
  with check (
    reporter_id = (select auth.uid())
    and coalesce(
      case
        when message_id is not null then private.caller_can_report_message(message_id, reported_user_id)
        when post_id is not null then private.caller_can_report_post(post_id, reported_user_id)
        when playlist_id is not null then private.caller_can_report_playlist(playlist_id, reported_user_id)
        when starter_quote_id is not null then reported_user_id is null
        else reported_user_id is not null
      end,
      false)
  );

-- What a reporter reads back of their own reports: what they filed, never the
-- server's copy (content_body, content_author, content_source, content_note,
-- content_verified), reported_username or reviewed_at. The copy is evidence
-- for the founder, taken with definer rights from rows the reporter may no
-- longer read (a message after the other member blocked them, or one their
-- Delete Conversation hid): reading it back would reopen those rows to them,
-- one report each. The app files reports without reading them back. The
-- insert grant stays table-wide: reports_snapshot_target overwrites every
-- server-owned column.
revoke select on table public.reports from authenticated;
grant select (id, reporter_id, reported_user_id, reason, details, created_at,
              post_id, message_id, playlist_id, starter_quote_id)
  on table public.reports to authenticated;

-- One report per reporter, reported user and target (a profile report has no
-- target, a catalog report no user; NULLS NOT DISTINCT makes a second one a
-- duplicate). Rows leave the index once the facts it compares are gone, so
-- later deletions never collide: a deleted account nulls reporter_id or
-- reported_user_id, and a deleted target (an unsent message, a deleted post
-- or playlist) nulls its id on a verified report. Without the predicate,
-- reporting two messages from someone and then seeing both unsent would
-- make the second unsend fail. Replaces reports_reporter_reported_share_key.
create unique index reports_reporter_reported_target_key
  on public.reports (reporter_id, reported_user_id, message_id, post_id, playlist_id, starter_quote_id)
  nulls not distinct
  where reporter_id is not null
    and (reported_user_id is not null or starter_quote_id is not null)
    and (message_id is not null or post_id is not null or playlist_id is not null
         or starter_quote_id is not null or not content_verified);

-- Moderation queue for the founder's daily check (dashboard SQL editor), as in
-- 20261019060000_hardening, now with the four targets and content_note in
-- place of share_id. security_invoker, and not granted to any API role.
create view private.reports_to_review
with (security_invoker = true)
as
select
  r.id,
  r.created_at,
  date_trunc('minute', now() - r.created_at) as waiting,
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
  r.reported_user_id,
  coalesce(reported.username, r.reported_username) as reported_username,
  r.reported_user_id is null and r.reported_username is not null as reported_account_deleted,
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
left join public.profiles reported on reported.id = r.reported_user_id
left join public.profiles reporter on reporter.id = r.reporter_id
where r.reviewed_at is null
order by r.created_at;

comment on view private.reports_to_review is
  'Reports waiting for review, oldest first, with the target ids and the server''s copy of the content. Mark one done with: update public.reports set reviewed_at = now() where id = ...';

revoke all on table private.reports_to_review from public, anon, authenticated, service_role;

-- shares is gone: its policies, triggers and indexes go with it. Its trigger
-- functions go too; private.set_verified_starter stays (quotes use it). The
-- move ran above and would only fail from now on.
drop table public.shares;
drop function private.shares_stamp_seen_saved();
drop function private.shares_enforce_limit();
drop function private.move_shares_to_messages();
