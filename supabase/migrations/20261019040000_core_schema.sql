-- Quoted core schema. Contract: docs/system-design.md section 3.
--
-- Every table in public has RLS enabled and explicit grants. Nothing is granted
-- to anon. New Supabase projects (and all projects from 2026-10-30) no longer
-- auto-expose new public tables to the Data API, so the grants below are what
-- makes each table reachable, and they also strip the local default grants so
-- the local stack and the hosted project behave the same.
--
-- SECURITY DEFINER code lives only in the unexposed `private` schema.

-- ---------------------------------------------------------------------------
-- private schema (not in [api].schemas, so PostgREST never exposes it)
-- ---------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon;
-- RLS policies call private.is_blocked_pair as the invoking role.
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid not null,
  username text not null,
  display_name text,
  created_at timestamptz not null default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_id_fkey foreign key (id) references auth.users (id) on delete cascade,
  constraint profiles_username_key unique (username),
  constraint profiles_username_format check (username ~ '^[a-z0-9_.]{3,20}$'),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 50)
);
comment on table public.profiles is 'Public handle per auth user. Created by the client after the first sign-in.';

-- ---------------------------------------------------------------------------
-- quotes
-- ---------------------------------------------------------------------------
create table public.quotes (
  id uuid not null default gen_random_uuid(),
  owner_id uuid not null default auth.uid(),
  body text not null,
  body_format jsonb not null default '[]'::jsonb,
  author text,
  source text,
  origin text not null default 'manual',
  rotation_position integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quotes_pkey primary key (id),
  constraint quotes_owner_id_fkey foreign key (owner_id) references auth.users (id) on delete cascade,
  constraint quotes_body_length check (char_length(body) between 1 and 2000),
  constraint quotes_body_format_array check (
    jsonb_typeof(body_format) = 'array' and jsonb_array_length(body_format) <= 200
  ),
  constraint quotes_author_length check (char_length(author) <= 200),
  constraint quotes_source_length check (char_length(source) <= 200),
  constraint quotes_origin_valid check (origin in ('manual', 'starter', 'shared', 'pasted')),
  constraint quotes_rotation_position_nonnegative check (rotation_position >= 0)
);
comment on column public.quotes.body_format is 'Sorted, non-overlapping UTF-16 runs: [{start,length,bold?,italic?,underline?}]. See docs/system-design.md.';
comment on column public.quotes.rotation_position is 'Order in the owner''s Rotation; null = not in the Rotation.';

-- Library query (also covers the owner_id foreign key).
create index quotes_owner_id_created_at_idx on public.quotes (owner_id, created_at desc);
-- Rotation query.
create index quotes_owner_id_rotation_position_idx on public.quotes (owner_id, rotation_position)
  where rotation_position is not null;

-- ---------------------------------------------------------------------------
-- friendships
-- ---------------------------------------------------------------------------
create table public.friendships (
  id uuid not null default gen_random_uuid(),
  requester_id uuid not null default auth.uid(),
  addressee_id uuid not null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friendships_pkey primary key (id),
  constraint friendships_requester_id_fkey foreign key (requester_id) references public.profiles (id) on delete cascade,
  constraint friendships_addressee_id_fkey foreign key (addressee_id) references public.profiles (id) on delete cascade,
  constraint friendships_status_valid check (status in ('pending', 'accepted')),
  constraint friendships_not_self check (requester_id <> addressee_id)
);

-- One row per unordered pair, whoever asked first.
create unique index friendships_pair_key on public.friendships
  (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_requester_id_idx on public.friendships (requester_id);
create index friendships_addressee_id_idx on public.friendships (addressee_id);

-- ---------------------------------------------------------------------------
-- blocks
-- ---------------------------------------------------------------------------
create table public.blocks (
  blocker_id uuid not null default auth.uid(),
  blocked_id uuid not null,
  created_at timestamptz not null default now(),
  constraint blocks_pkey primary key (blocker_id, blocked_id),
  constraint blocks_blocker_id_fkey foreign key (blocker_id) references public.profiles (id) on delete cascade,
  constraint blocks_blocked_id_fkey foreign key (blocked_id) references public.profiles (id) on delete cascade,
  constraint blocks_not_self check (blocker_id <> blocked_id)
);

-- blocker_id is covered by the primary key.
create index blocks_blocked_id_idx on public.blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- shares
-- ---------------------------------------------------------------------------
create table public.shares (
  id uuid not null default gen_random_uuid(),
  sender_id uuid not null default auth.uid(),
  recipient_id uuid not null,
  quote_id uuid,
  body text not null,
  body_format jsonb not null default '[]'::jsonb,
  author text,
  source text,
  note text,
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  saved_at timestamptz,
  constraint shares_pkey primary key (id),
  constraint shares_sender_id_fkey foreign key (sender_id) references public.profiles (id) on delete cascade,
  constraint shares_recipient_id_fkey foreign key (recipient_id) references public.profiles (id) on delete cascade,
  constraint shares_quote_id_fkey foreign key (quote_id) references public.quotes (id) on delete set null,
  constraint shares_body_length check (char_length(body) between 1 and 2000),
  constraint shares_body_format_array check (
    jsonb_typeof(body_format) = 'array' and jsonb_array_length(body_format) <= 200
  ),
  constraint shares_author_length check (char_length(author) <= 200),
  constraint shares_source_length check (char_length(source) <= 200),
  constraint shares_note_length check (char_length(note) <= 280),
  constraint shares_not_self check (sender_id <> recipient_id)
);
comment on table public.shares is 'A snapshot of a quote sent to a friend. The recipient never reads the sender''s quotes table.';

create index shares_sender_id_idx on public.shares (sender_id);
-- "Shared with you" inbox (also covers the recipient_id foreign key).
create index shares_recipient_id_created_at_idx on public.shares (recipient_id, created_at desc);
create index shares_quote_id_idx on public.shares (quote_id);

-- ---------------------------------------------------------------------------
-- reports
-- ---------------------------------------------------------------------------
create table public.reports (
  id uuid not null default gen_random_uuid(),
  reporter_id uuid not null default auth.uid(),
  share_id uuid,
  reported_user_id uuid not null,
  reason text not null,
  details text,
  created_at timestamptz not null default now(),
  constraint reports_pkey primary key (id),
  constraint reports_reporter_id_fkey foreign key (reporter_id) references public.profiles (id) on delete cascade,
  constraint reports_share_id_fkey foreign key (share_id) references public.shares (id) on delete set null,
  constraint reports_reported_user_id_fkey foreign key (reported_user_id) references public.profiles (id) on delete cascade,
  constraint reports_reason_valid check (reason in ('spam', 'harassment', 'inappropriate', 'other')),
  constraint reports_details_length check (char_length(details) <= 500),
  constraint reports_not_self check (reporter_id <> reported_user_id)
);
comment on table public.reports is 'UGC reports (App Store 1.2). Reviewed by the developer in the dashboard.';

create index reports_reporter_id_idx on public.reports (reporter_id);
create index reports_share_id_idx on public.reports (share_id);
create index reports_reported_user_id_idx on public.reports (reported_user_id);

-- ---------------------------------------------------------------------------
-- starter_quotes (seeded by a later migration so it exists on hosted too)
-- ---------------------------------------------------------------------------
create table public.starter_quotes (
  id smallint primary key,
  body text not null check (char_length(body) between 1 and 2000),
  body_format jsonb not null default '[]'::jsonb check (jsonb_typeof(body_format) = 'array'),
  author text not null check (char_length(author) between 1 and 200),
  source text check (char_length(source) <= 200),
  sort_order smallint not null unique
);
comment on table public.starter_quotes is 'Public-domain starter pack offered during onboarding. Read-only for clients.';

-- ---------------------------------------------------------------------------
-- events (product analytics; the search term is never stored)
-- ---------------------------------------------------------------------------
create table public.events (
  id bigint generated always as identity,
  user_id uuid not null default auth.uid(),
  name text not null,
  created_at timestamptz not null default now(),
  constraint events_pkey primary key (id),
  constraint events_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade,
  constraint events_name_valid check (name in ('web_search_tap'))
);

create index events_user_id_idx on public.events (user_id);

-- ---------------------------------------------------------------------------
-- Functions and triggers (private schema, search_path = '')
-- ---------------------------------------------------------------------------

-- True when either user has blocked the other. SECURITY DEFINER because a
-- user cannot read blocks made by someone else. Only answers for pairs that
-- include the caller, so it cannot be used to probe other people's blocks.
create function private.is_blocked_pair(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) in (a, b)
    and exists (
      select 1
      from public.blocks bl
      where (bl.blocker_id = a and bl.blocked_id = b)
         or (bl.blocker_id = b and bl.blocked_id = a)
    );
$$;
revoke all on function private.is_blocked_pair(uuid, uuid) from public, anon;
grant execute on function private.is_blocked_pair(uuid, uuid) to authenticated;

-- quotes.updated_at
create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function private.set_updated_at() from public, anon, authenticated;

create trigger quotes_set_updated_at
  before update on public.quotes
  for each row execute function private.set_updated_at();

-- friendships.responded_at is server-owned: null on insert, stamped when a
-- pending request is accepted.
create function private.friendships_set_responded_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.responded_at := null;
  elsif old.status = 'pending' and new.status = 'accepted' then
    new.responded_at := now();
  else
    new.responded_at := old.responded_at;
  end if;
  return new;
end;
$$;
revoke all on function private.friendships_set_responded_at() from public, anon, authenticated;

create trigger friendships_set_responded_at
  before insert or update on public.friendships
  for each row execute function private.friendships_set_responded_at();

-- A block removes the friendship (pending or accepted) and every share between
-- the pair, in both directions. SECURITY DEFINER so the cleanup does not depend
-- on the delete policies of friendships and shares. new.blocker_id is already
-- pinned to auth.uid() by the blocks insert policy.
create function private.blocks_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friendships f
  where least(f.requester_id, f.addressee_id) = least(new.blocker_id, new.blocked_id)
    and greatest(f.requester_id, f.addressee_id) = greatest(new.blocker_id, new.blocked_id);

  delete from public.shares s
  where (s.sender_id = new.blocker_id and s.recipient_id = new.blocked_id)
     or (s.sender_id = new.blocked_id and s.recipient_id = new.blocker_id);

  return null;
end;
$$;
revoke all on function private.blocks_after_insert() from public, anon, authenticated;

create trigger blocks_after_insert
  after insert on public.blocks
  for each row execute function private.blocks_after_insert();

-- ---------------------------------------------------------------------------
-- Grants. Strip whatever default privileges the environment applied, then
-- grant exactly what the RLS policies below are written for.
-- ---------------------------------------------------------------------------
revoke all on table
  public.profiles, public.quotes, public.friendships, public.blocks,
  public.shares, public.reports, public.starter_quotes, public.events
  from public, anon, authenticated, service_role;
revoke all on sequence public.events_id_seq from public, anon, authenticated, service_role;

grant select, insert, update on table public.profiles to authenticated;
grant select, insert, update, delete on table public.quotes to authenticated;
grant select, insert, delete on table public.friendships to authenticated;
grant update (status, responded_at) on table public.friendships to authenticated;
grant select, insert, delete on table public.blocks to authenticated;
grant select, insert, delete on table public.shares to authenticated;
grant update (seen_at, saved_at) on table public.shares to authenticated;
grant select, insert on table public.reports to authenticated;
grant select on table public.starter_quotes to authenticated;
grant insert on table public.events to authenticated;

-- Secret key / service role (Edge Functions, dashboard tooling). Bypasses RLS.
grant select, insert, update, delete on table
  public.profiles, public.quotes, public.friendships, public.blocks,
  public.shares, public.reports, public.starter_quotes, public.events
  to service_role;
grant usage, select on sequence public.events_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.quotes enable row level security;
alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
alter table public.shares enable row level security;
alter table public.reports enable row level security;
alter table public.starter_quotes enable row level security;
alter table public.events enable row level security;

-- profiles: usernames are public handles; you write only your own row.
create policy "profiles: authenticated users can read all profiles"
  on public.profiles for select to authenticated
  using (true);

create policy "profiles: insert own"
  on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

create policy "profiles: update own"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- quotes: owner only.
create policy "quotes: select own"
  on public.quotes for select to authenticated
  using (owner_id = (select auth.uid()));

create policy "quotes: insert own"
  on public.quotes for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy "quotes: update own"
  on public.quotes for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "quotes: delete own"
  on public.quotes for delete to authenticated
  using (owner_id = (select auth.uid()));

-- friendships
create policy "friendships: either party can read"
  on public.friendships for select to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));

create policy "friendships: request as yourself, pending, not blocked"
  on public.friendships for insert to authenticated
  with check (
    requester_id = (select auth.uid())
    and status = 'pending'
    and not private.is_blocked_pair(requester_id, addressee_id)
  );

-- Only the addressee, only pending -> accepted. Column grants limit the
-- writable columns to status (and responded_at, which the trigger overrides).
create policy "friendships: addressee accepts a pending request"
  on public.friendships for update to authenticated
  using (addressee_id = (select auth.uid()) and status = 'pending')
  with check (addressee_id = (select auth.uid()) and status = 'accepted');

create policy "friendships: either party can delete"
  on public.friendships for delete to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));

-- blocks: blocker only.
create policy "blocks: blocker can read"
  on public.blocks for select to authenticated
  using (blocker_id = (select auth.uid()));

create policy "blocks: block as yourself"
  on public.blocks for insert to authenticated
  with check (blocker_id = (select auth.uid()));

create policy "blocks: blocker can unblock"
  on public.blocks for delete to authenticated
  using (blocker_id = (select auth.uid()));

-- shares
create policy "shares: sender or recipient can read"
  on public.shares for select to authenticated
  using ((select auth.uid()) in (sender_id, recipient_id));

create policy "shares: send to an accepted friend, own quote only"
  on public.shares for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and seen_at is null
    and saved_at is null
    and exists (
      select 1
      from public.friendships f
      where least(f.requester_id, f.addressee_id) = least(shares.sender_id, shares.recipient_id)
        and greatest(f.requester_id, f.addressee_id) = greatest(shares.sender_id, shares.recipient_id)
        and f.status = 'accepted'
    )
    and (
      shares.quote_id is null
      or exists (
        select 1
        from public.quotes q
        where q.id = shares.quote_id
          and q.owner_id = (select auth.uid())
      )
    )
  );

-- Column grants limit the writable columns to seen_at and saved_at.
create policy "shares: recipient marks seen or saved"
  on public.shares for update to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

create policy "shares: sender or recipient can delete"
  on public.shares for delete to authenticated
  using ((select auth.uid()) in (sender_id, recipient_id));

-- reports: insert and read your own. A share_id must be a share you received
-- from the reported user.
create policy "reports: read own"
  on public.reports for select to authenticated
  using (reporter_id = (select auth.uid()));

create policy "reports: file as yourself"
  on public.reports for insert to authenticated
  with check (
    reporter_id = (select auth.uid())
    and (
      reports.share_id is null
      or exists (
        select 1
        from public.shares s
        where s.id = reports.share_id
          and s.recipient_id = (select auth.uid())
          and s.sender_id = reports.reported_user_id
      )
    )
  );

-- starter_quotes: read-only for clients.
create policy "starter_quotes: authenticated users can read"
  on public.starter_quotes for select to authenticated
  using (true);

-- events: insert your own; no client reads.
create policy "events: insert own"
  on public.events for insert to authenticated
  with check (user_id = (select auth.uid()));
