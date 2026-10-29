-- Forwarding: a quote message can be made from a post or from another quote
-- message the sender can see, so Send on someone else's quote (a Feed card, a
-- received message) no longer has to save it to the sender's Library first.
-- The design critique's fix P2-7 ("Forwarding fills your Library without
-- asking"), the "record §3 change" in docs/ui-spec.md §11 (Send sheet).
-- Contract: docs/system-design.md section 3 (messages), and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 (Inbox,
-- Safety) and 3.
-- Tests: supabase/tests/database/22_forward_quotes.test.sql (plus the
-- adjusted 00).
--
--  1. public.messages gains source_post_id (→ posts) and source_message_id
--     (→ messages), each on delete set null and checked at commit like the
--     other message foreign keys, with sparse indexes. Clients may send them
--     but not read them back (column grants, as source_quote_id): a recipient
--     never learns the id of a post or of a message in someone else's
--     conversation. Text and playlist messages carry neither
--     (messages_kind_shape).
--  2. A quote message has exactly one source: source_quote_id,
--     starter_quote_id, source_post_id or source_message_id (23514,
--     messages_one_source).
--  3. messages_build_snapshot copies a forwarded quote's snapshot (body,
--     body_format, author, source, the creator and edited-from pairs and
--     verified_starter_id; never the caption or the note) through
--     private.forwardable_snapshot, which answers only for the caller:
--       post: private.post_access is not null (the author; an accepted friend
--         with no block; a stranger reaching a public post as profile_view
--         would) and the post is not held, not even for its author (the app
--         disables Send on a held post, as the server already refuses a held
--         playlist to its owner);
--       message: a quote message the caller can read right now
--         (private.caller_can_read_message: a member, newer than their
--         cleared_at, no block against them, not reported by them).
--     Every refusal, an unknown id and a text or playlist message included,
--     is the same 42501 "This quote is not available.". The copy is checked
--     against the catalog as it is at forward time, never as the source
--     stored it (the source may predate a catalog addition or correction), as
--     saving it and sending that would. The existing rules still apply: a
--     verified snapshot keeps neither pair, and an unverified one passes the
--     word filter (QR003) as any other. The server roles never forward
--     (42501): they have no caller to answer for.
--
-- Existing rows: none change (both columns start null for every message).

-- ---------------------------------------------------------------------------
-- 1. The columns
-- ---------------------------------------------------------------------------
alter table public.messages
  add column source_post_id uuid,
  add column source_message_id uuid,
  add constraint messages_source_post_id_fkey foreign key (source_post_id) references public.posts (id)
    on delete set null
    deferrable initially deferred,
  add constraint messages_source_message_id_fkey foreign key (source_message_id) references public.messages (id)
    on delete set null
    deferrable initially deferred,
  drop constraint messages_kind_shape,
  -- What each kind carries. The links (source_quote_id, starter_quote_id,
  -- source_post_id, source_message_id, playlist_id) may become null later
  -- through their foreign keys.
  add constraint messages_kind_shape check (
    case kind
      when 'text' then text is not null and note is null and body is null and playlist_title is null
                       and source_quote_id is null and starter_quote_id is null and playlist_id is null
                       and source_post_id is null and source_message_id is null
      when 'quote' then text is null and body is not null and playlist_title is null and playlist_id is null
      when 'playlist' then text is null and note is null and body is null and playlist_title is not null
                           and source_quote_id is null and starter_quote_id is null
                           and source_post_id is null and source_message_id is null
    end
  );

-- Sparse, like the other message links (most messages are not forwards).
create index messages_source_post_id_idx on public.messages (source_post_id) where source_post_id is not null;
create index messages_source_message_id_idx on public.messages (source_message_id)
  where source_message_id is not null;

comment on column public.messages.source_post_id is
  'The post a forwarded quote message was copied from (trigger messages_build_snapshot, through private.forwardable_snapshot); null once that post is deleted, while the copy stays. Not readable by clients (no column grant).';
comment on column public.messages.source_message_id is
  'The quote message a forwarded quote message was copied from (trigger messages_build_snapshot, through private.forwardable_snapshot); null once that message is unsent or deleted, while the copy stays. Not readable by clients (no column grant).';

-- Clients send both, like source_quote_id, and read neither: the select grant
-- from 20261029090300 lists its columns and stays as it is.
grant insert (source_post_id, source_message_id) on table public.messages to authenticated;

-- ---------------------------------------------------------------------------
-- 2. What the caller may forward
-- ---------------------------------------------------------------------------

-- The snapshot of the one post (p_post) or quote message (p_message) the
-- caller may forward: a post they may see (private.post_access) that is not
-- held, or a quote message they can read right now
-- (private.caller_can_read_message). One row, or none, the same for every
-- reason (unknown, someone else's, held, reported, blocked, cleared, a text or
-- playlist message, or both arguments set). SECURITY DEFINER because those
-- rules are definer helpers no API role may execute and a stranger reaches a
-- public post outside the posts policy. It answers only for auth.uid() and
-- returns only columns the caller could read through posts, messages or
-- profile_view anyway. messages_build_snapshot (SECURITY INVOKER) calls it
-- for clients; executable by authenticated only.
create function private.forwardable_snapshot(p_post uuid, p_message uuid)
returns table (
  body text,
  body_format jsonb,
  author text,
  source text,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text,
  verified_starter_id smallint
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.body, p.body_format, p.author, p.source, p.creator_id, p.creator_username,
         p.edited_from_id, p.edited_from_username, p.verified_starter_id
  from public.posts p
  where p_message is null
    and p.id = p_post
    and p.held_at is null
    and private.post_access(p.id) is not null
  union all
  select m.body, m.body_format, m.author, m.source, m.creator_id, m.creator_username,
         m.edited_from_id, m.edited_from_username, m.verified_starter_id
  from public.messages m
  where p_post is null
    and m.id = p_message
    and m.kind = 'quote'
    and private.caller_can_read_message(m.id)
$$;
comment on function private.forwardable_snapshot(uuid, uuid) is
  'The quote snapshot of a post (private.post_access, not held) or quote message (private.caller_can_read_message) the caller may forward; no row otherwise, the same for every reason. Answers only for the caller. Called by messages_build_snapshot.';
revoke all on function private.forwardable_snapshot(uuid, uuid) from public, anon, service_role;
grant execute on function private.forwardable_snapshot(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The snapshot trigger
-- ---------------------------------------------------------------------------

-- Replaces the version from 20261029090300_conversations_and_messages (grants
-- kept; the trigger stays). BEFORE INSERT, every role. Clients, in this order
-- (each refusal 42501 unless noted), so nothing about a conversation leaks to
-- anyone outside it:
--   accepted terms and no suspension (one answer whatever the target);
--   the conversation, read with the caller's own rights (a member the other
--     one did not block), and the caller as sender: else "not available";
--   open, accepted friends, no block either way: else "closed".
-- Then, for every role:
--   the sender is one of the pair;
--   quote: the server roles never forward (source_post_id or
--     source_message_id: 42501); exactly one of source_quote_id (the
--     sender's own quote; someone else's and an unknown one fail the same
--     way), starter_quote_id (23503 when unknown), source_post_id and
--     source_message_id (a post or quote message the client may forward,
--     private.forwardable_snapshot; every other one "This quote is not
--     available.") (23514, messages_one_source), and the server copies body,
--     body_format, author, source, the creator and edited-from pairs and
--     verified_starter_id (for a forward, verified_starter_id is looked up in
--     the catalog again instead). Only the server can send a body (no client grant):
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
create or replace function private.messages_build_snapshot()
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
  v_forward record;
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
    if not v_client and (new.source_post_id is not null or new.source_message_id is not null) then
      raise exception 'Only a signed-in person can forward a post or a message.'
        using errcode = 'insufficient_privilege',
              hint = 'Send source_quote_id or starter_quote_id instead.';
    end if;

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
      if num_nonnulls(new.source_quote_id, new.starter_quote_id, new.source_post_id, new.source_message_id) <> 1 then
        raise exception 'A quote message holds exactly one quote: one of yours or one from the Quoted Catalog.'
          using errcode = 'check_violation',
                constraint = 'messages_one_source',
                schema = 'public',
                table = 'messages',
                hint = 'Send exactly one of source_quote_id, starter_quote_id, source_post_id and source_message_id.';
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
      elsif new.starter_quote_id is not null then
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
      elsif v_client then
        -- A forward (the server roles were refused above).
        select f.* into v_forward
          from private.forwardable_snapshot(new.source_post_id, new.source_message_id) f;
        if not found then
          raise exception 'This quote is not available.'
            using errcode = 'insufficient_privilege';
        end if;
        new.body := v_forward.body;
        new.body_format := v_forward.body_format;
        new.author := v_forward.author;
        new.source := v_forward.source;
        new.creator_id := v_forward.creator_id;
        new.creator_username := v_forward.creator_username;
        new.edited_from_id := v_forward.edited_from_id;
        new.edited_from_username := v_forward.edited_from_username;
        -- Checked against the catalog as it is now, never as the post or
        -- message stored it: a wording added to the catalog since then goes
        -- as "Quoted Catalog" (the pairs are nulled below and the word filter
        -- skips it), and one the catalog corrected since then loses its seal,
        -- as saving it first would (quotes_set_verified).
        new.verified_starter_id := (
          select s.id
          from public.starter_quotes s
          where s.body = new.body
            and s.author is not distinct from new.author
            and s.source is not distinct from new.source
          order by s.id
          limit 1
        );
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
