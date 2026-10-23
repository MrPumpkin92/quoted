-- Abuse limits, profile privacy and cleanup of abandoned anonymous accounts.
-- Contract: docs/system-design.md sections 3 (data model), 6 (limits) and 7
-- (retention). Tests: supabase/tests/database/11_abuse_limits.test.sql and
-- 12_profile_privacy_cleanup.test.sql (plus the adjusted 01, 02, 07 and 10).
--
-- From the 2026-10-21 audit and council decision:
--
--  A. Profiles are no longer a public directory. A signed-in user reads their
--     own row and the profiles linked to them by a friendship (either side,
--     any status), a share (either side) or a block they made. Everyone else is
--     reached only by exact username through public.find_profile, and
--     public.is_username_available answers the onboarding question.
--  B. Per-account write limits, checked by BEFORE INSERT triggers:
--       quotes        5000 per owner                          QR002
--       friendships   20 requests per requester per 24 hours  QR001
--                     50 outgoing pending at once             QR001
--       shares        100 per sender per 24 hours             QR001
--       reports       20 per reporter per 24 hours            QR001
--                     one per reporter + reported user + share (23505)
--       events        30 per user per clock hour              QR001
--     QR002 is an account total, QR001 a rate (it clears with time or, for
--     pending requests, when they are answered or cancelled).
--  C. Usernames are immutable once set, and reserved names cannot be claimed
--     by clients.
--  D. A friend request to or from a blocked pair fails exactly like one to a
--     user that does not exist (23503 on friendships_addressee_id_fkey).
--  E. profiles.last_active_at (stamped by public.touch_activity at most every
--     12 hours) and profiles.purge_exempt (server-owned), and a daily pg_cron
--     job, private.purge_inactive_anonymous, that deletes anonymous accounts
--     that never chose a username within 7 days or have been inactive for 365.
--
-- Rows already on the server: existing profiles get last_active_at = now()
-- (the time of this migration) and purge_exempt = false. Existing usernames,
-- reserved or not, are kept; the reserved list applies to new profiles only.
-- If the hosted database already holds two reports by the same reporter about
-- the same user and share, creating reports_reporter_reported_share_key fails
-- and names the index; resolve those rows by hand, then push again.

-- ---------------------------------------------------------------------------
-- 0. Username helpers (IMMUTABLE, read no data)
-- ---------------------------------------------------------------------------

-- What the app's Username.normalize does: trim Unicode White_Space (the set
-- private.is_blank strips), drop one leading "@", lowercase.
create function private.normalize_username(p_username text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select lower(regexp_replace(
    btrim(
      p_username,
      E' \t\n\u000B\f\r'
        || U&'\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000'
    ),
    '^@', ''
  ))
$$;
comment on function private.normalize_username(text) is
  'Trims Unicode White_Space, drops one leading @ and lowercases, like the app''s Username.normalize.';

-- Names a client cannot claim, compared case-insensitively. The founder can
-- still give one to an account from the SQL editor (for example the App Review
-- helper, quotedhelper).
create function private.is_reserved_username(p_username text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select lower(p_username) = any (array[
    'quoted', 'quotedapp', 'quotedhelper', 'support', 'help', 'admin', 'administrator',
    'official', 'moderator', 'mod', 'staff', 'team', 'system', 'root', 'security',
    'privacy', 'legal', 'abuse', 'null', 'undefined', 'me', 'you', 'everyone'
  ])
$$;
comment on function private.is_reserved_username(text) is
  'True for usernames clients cannot claim (case-insensitive). Checked on profile insert by clients and by is_username_available.';

revoke all on function private.normalize_username(text) from public, anon;
revoke all on function private.is_reserved_username(text) from public, anon;
grant execute on function private.normalize_username(text) to authenticated, service_role;
grant execute on function private.is_reserved_username(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- E (columns). Activity and the purge exemption
-- ---------------------------------------------------------------------------
-- now() is evaluated once here, so every existing row gets the migration time.
alter table public.profiles
  add column last_active_at timestamptz not null default now(),
  add column purge_exempt boolean not null default false;

comment on column public.profiles.last_active_at is
  'When the account was last in use: set on insert and by public.touch_activity (at most every 12 hours). Server-owned. Read by private.purge_inactive_anonymous.';
comment on column public.profiles.purge_exempt is
  'True keeps an anonymous account from private.purge_inactive_anonymous (for example the App Review helper). Only postgres and the secret key can change it.';

-- ---------------------------------------------------------------------------
-- C and E (triggers). Reserved names, server-owned columns, immutable usernames
-- ---------------------------------------------------------------------------

-- Clients (anon, authenticated, and anything else that is not postgres, the
-- secret key or supabase_admin) cannot claim a reserved username and cannot
-- write last_active_at or purge_exempt: on insert they become now() and false,
-- on update they keep their stored values, like created_at. SECURITY INVOKER
-- on purpose: current_user is the role writing the row, which is postgres
-- inside the SECURITY DEFINER private.touch_activity.
create function private.profiles_guard_server_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- Reported as "taken" (23505), which is what the app shows for it.
    if private.is_reserved_username(new.username) then
      raise exception 'username "%" is reserved', new.username
        using errcode = 'unique_violation',
              constraint = 'profiles_username_reserved',
              schema = 'public',
              table = 'profiles',
              column = 'username';
    end if;
    new.last_active_at := now();
    new.purge_exempt := false;
  else
    new.last_active_at := old.last_active_at;
    new.purge_exempt := old.purge_exempt;
  end if;
  return new;
end;
$$;
revoke all on function private.profiles_guard_server_columns() from public, anon, authenticated;

create trigger profiles_guard_server_columns
  before insert or update on public.profiles
  for each row execute function private.profiles_guard_server_columns();

-- A username never changes once set, for every role. AFTER UPDATE on purpose:
-- the format check (23514) and uniqueness (23505) still report first, and a
-- valid, free new name is then refused with 42501. Founder escape hatch for a
-- handle that must go: delete the account (Authentication > Users).
create function private.profiles_reject_username_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'usernames cannot be changed once set'
    using errcode = 'insufficient_privilege',
          hint = 'Choose a username once, when the profile is created.';
end;
$$;
revoke all on function private.profiles_reject_username_change() from public, anon, authenticated;

create trigger profiles_username_immutable
  after update of username on public.profiles
  for each row
  when (old.username is distinct from new.username)
  execute function private.profiles_reject_username_change();

-- ---------------------------------------------------------------------------
-- A. Profile visibility, exact lookup and availability
-- ---------------------------------------------------------------------------
drop policy "profiles: authenticated users can read all profiles" on public.profiles;

-- Your own row, plus everyone linked to you by a friendship (either side, any
-- status), a share (either side) or a block you made. Each subquery is
-- uncorrelated (evaluated once per statement) and runs under the caller's own
-- RLS on that table, which already allows exactly these rows. Every embed the
-- app uses resolves: friendship requester/addressee, inbox sender, sent
-- recipient, blocked profile. One exception: the row an INSERT ... RETURNING
-- creates is not yet visible to the policy in the same statement, so a new
-- request to a stranger returns addressee = null (the app already holds that
-- profile from find_profile).
create policy "profiles: read your own and linked profiles"
  on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or id in (select f.addressee_id from public.friendships f where f.requester_id = (select auth.uid()))
    or id in (select f.requester_id from public.friendships f where f.addressee_id = (select auth.uid()))
    or id in (select s.recipient_id from public.shares s where s.sender_id = (select auth.uid()))
    or id in (select s.sender_id from public.shares s where s.recipient_id = (select auth.uid()))
    or id in (select b.blocked_id from public.blocks b where b.blocker_id = (select auth.uid()))
  );

-- Exact lookup by username: at most one row, never the caller, nothing when
-- either side has blocked the other (so a lookup cannot reveal a block).
-- SECURITY DEFINER to see past the narrowed policy; it only ever answers for
-- one exact, normalized username.
create function private.find_profile(p_username text)
returns table (id uuid, username text, display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name
  from public.profiles p
  where (select auth.uid()) is not null
    and p.username = private.normalize_username(p_username)
    and p.id <> (select auth.uid())
    and not exists (
      select 1
      from public.blocks b
      where (b.blocker_id = p.id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = p.id)
    )
  limit 1
$$;

-- False for a reserved name, a name in use, or one that fails the
-- profiles_username_format check after normalizing.
create function private.is_username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select auth.uid()) is not null
      and n.name ~ '^[a-z0-9_.]{3,20}$'
      and not private.is_reserved_username(n.name)
      and not exists (select 1 from public.profiles p where p.username = n.name),
    false
  )
  from (select private.normalize_username(p_username) as name) n
$$;

revoke all on function private.find_profile(text) from public, anon, service_role;
revoke all on function private.is_username_available(text) from public, anon, service_role;
-- The public wrappers run as the caller, so the caller needs EXECUTE here. The
-- private schema is not exposed by the Data API, so these are reachable only
-- through the wrappers.
grant execute on function private.find_profile(text) to authenticated;
grant execute on function private.is_username_available(text) to authenticated;

create function public.find_profile(p_username text)
returns table (id uuid, username text, display_name text)
language sql
stable
security invoker
set search_path = ''
as $$
  select f.id, f.username, f.display_name from private.find_profile(p_username) f
$$;
comment on function public.find_profile(text) is
  'The profile with exactly this username (trimmed, one leading @ dropped, lowercased): at most one row, none for yourself or a blocked pair. SECURITY INVOKER wrapper over private.find_profile.';

create function public.is_username_available(p_username text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select private.is_username_available(p_username)
$$;
comment on function public.is_username_available(text) is
  'Whether a new profile could take this username: false when reserved, taken or not ^[a-z0-9_.]{3,20}$ after normalizing. SECURITY INVOKER wrapper over private.is_username_available.';

revoke all on function public.find_profile(text) from public, anon, service_role;
revoke all on function public.is_username_available(text) from public, anon, service_role;
grant execute on function public.find_profile(text) to authenticated;
grant execute on function public.is_username_available(text) to authenticated;

-- The report snapshot reads the reported user's username as the reporter
-- (private.reports_snapshot_share is SECURITY INVOKER). Under the narrowed
-- policy a reporter may not see that profile (a user report without any link),
-- so this second BEFORE INSERT trigger, which sorts after
-- reports_snapshot_share, takes the username with definer rights. It reads one
-- column of the one profile the row names, and a trigger function cannot be
-- called directly.
create function private.reports_snapshot_username()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select p.username
    into new.reported_username
    from public.profiles p
   where p.id = new.reported_user_id;
  return new;
end;
$$;
revoke all on function private.reports_snapshot_username() from public, anon, authenticated;

create trigger reports_snapshot_username
  before insert on public.reports
  for each row execute function private.reports_snapshot_username();

-- ---------------------------------------------------------------------------
-- E. Activity
-- ---------------------------------------------------------------------------
-- Stamps the caller's own last_active_at, at most once every 12 hours, so a
-- launch or foreground costs at most one write per half day.
create function private.touch_activity()
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update public.profiles
     set last_active_at = now()
   where id = (select auth.uid())
     and last_active_at < now() - interval '12 hours'
$$;
revoke all on function private.touch_activity() from public, anon, service_role;
grant execute on function private.touch_activity() to authenticated;

create function public.touch_activity()
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.touch_activity()
$$;
comment on function public.touch_activity() is
  'Marks the caller''s account as in use (profiles.last_active_at = now() when it is older than 12 hours). SECURITY INVOKER wrapper over private.touch_activity.';

revoke all on function public.touch_activity() from public, anon, service_role;
grant execute on function public.touch_activity() to authenticated;

-- ---------------------------------------------------------------------------
-- B. Write limits
-- ---------------------------------------------------------------------------
-- Each trigger takes a transaction-scoped advisory lock per actor, so two
-- concurrent requests from one account cannot both pass the last free slot,
-- and is VOLATILE plpgsql, so it sees the rows earlier in the same bulk insert.
-- The counts use the caller's own RLS (SECURITY INVOKER): an owner, requester,
-- sender or reporter can read all of their own rows. Only rows that still
-- exist count: a cancelled, declined or blocked request, or a deleted share,
-- frees its slot. The limits apply to every role, the secret key included.

-- Supporting indexes. Each replaces a single-column index on the same leading
-- (foreign key) column.
create index friendships_requester_id_created_at_idx on public.friendships (requester_id, created_at);
drop index public.friendships_requester_id_idx;
create index shares_sender_id_created_at_idx on public.shares (sender_id, created_at);
drop index public.shares_sender_id_idx;
create index reports_reporter_id_created_at_idx on public.reports (reporter_id, created_at);
drop index public.reports_reporter_id_idx;
-- quotes(owner_id, created_at desc) already serves the quote count.

-- quotes: 5000 per owner. A row whose id already exists is left to the
-- primary key (23505), so the app's idempotent retry of an insert whose answer
-- was lost is not mistaken for a new quote; an upsert of an existing id adds
-- nothing either.
create function private.quotes_enforce_limit()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  if exists (select 1 from public.quotes q where q.id = new.id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.quotes:' || new.owner_id::text, 0));
  if (select count(*) from (select 1 from public.quotes q where q.owner_id = new.owner_id limit 5000) mine) >= 5000 then
    raise exception 'You can keep at most 5000 quotes.'
      using errcode = 'QR002', hint = 'Delete some quotes to add new ones.';
  end if;
  return new;
end;
$$;
revoke all on function private.quotes_enforce_limit() from public, anon, authenticated;

create trigger quotes_enforce_limit
  before insert on public.quotes
  for each row execute function private.quotes_enforce_limit();

-- friendships: 20 requests per rolling 24 hours and 50 pending at once, then
-- (D) a blocked pair fails exactly like an unknown addressee. That check runs
-- after the limits because the real foreign key check also runs after every
-- BEFORE trigger. Message and detail are what Postgres reports to a client
-- for friendships_addressee_id_fkey (RLS is on, so the key value is left out).
-- private.is_blocked_pair answers only for pairs that include the caller.
create function private.friendships_enforce_limits()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('quoted.friendships:' || new.requester_id::text, 0));

  if (select count(*) from (
        select 1 from public.friendships f
        where f.requester_id = new.requester_id
          and f.created_at > now() - interval '24 hours'
        limit 20) recent) >= 20 then
    raise exception 'You can send at most 20 friend requests a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;

  if (select count(*) from (
        select 1 from public.friendships f
        where f.requester_id = new.requester_id
          and f.status = 'pending'
        limit 50) waiting) >= 50 then
    raise exception 'You can have at most 50 friend requests waiting for an answer.'
      using errcode = 'QR001', hint = 'Cancel some requests or wait for answers.';
  end if;

  if private.is_blocked_pair(new.requester_id, new.addressee_id) then
    raise exception 'insert or update on table "friendships" violates foreign key constraint "friendships_addressee_id_fkey"'
      using errcode = 'foreign_key_violation',
            detail = 'Key is not present in table "profiles".',
            constraint = 'friendships_addressee_id_fkey',
            schema = 'public',
            table = 'friendships';
  end if;

  return new;
end;
$$;
revoke all on function private.friendships_enforce_limits() from public, anon, authenticated;

create trigger friendships_enforce_limits
  before insert on public.friendships
  for each row execute function private.friendships_enforce_limits();

-- shares: 100 per sender per rolling 24 hours (one row per recipient). An
-- existing id is left to the primary key, as for quotes.
create function private.shares_enforce_limit()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  if exists (select 1 from public.shares s where s.id = new.id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.shares:' || new.sender_id::text, 0));
  if (select count(*) from (
        select 1 from public.shares s
        where s.sender_id = new.sender_id
          and s.created_at > now() - interval '24 hours'
        limit 100) recent) >= 100 then
    raise exception 'You can share at most 100 quotes a day.'
      using errcode = 'QR001', hint = 'Try again tomorrow.';
  end if;
  return new;
end;
$$;
revoke all on function private.shares_enforce_limit() from public, anon, authenticated;

create trigger shares_enforce_limit
  before insert on public.shares
  for each row execute function private.shares_enforce_limit();

-- reports: 20 per reporter per rolling 24 hours.
create function private.reports_enforce_limit()
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
  return new;
end;
$$;
revoke all on function private.reports_enforce_limit() from public, anon, authenticated;

create trigger reports_enforce_limit
  before insert on public.reports
  for each row execute function private.reports_enforce_limit();

-- One report per reporter, reported user and share (a user report has share
-- null, and NULLS NOT DISTINCT makes a second one a duplicate). Rows leave the
-- index once the facts it compares are gone, so later deletions never collide:
-- a deleted account nulls reporter_id or reported_user_id, and a deleted share
-- (a block deletes them) nulls share_id on a verified report. Without the
-- predicate, reporting two shares from someone and then blocking them would
-- make the block fail.
create unique index reports_reporter_reported_share_key
  on public.reports (reporter_id, reported_user_id, share_id) nulls not distinct
  where reporter_id is not null
    and reported_user_id is not null
    and (share_id is not null or not content_verified);

-- events: 30 per user per clock hour. events has no user column (it is
-- anonymous), so the count lives in a private table: one row per user with
-- the current hour and a counter, never readable by clients, gone when the
-- account is deleted. Rows from earlier hours are deleted on the next event by
-- anyone, so the table holds at most the users who logged an event this hour
-- (plus the ones from the last hour anything was logged).
create table private.event_rate_limits (
  user_id uuid not null,
  window_start timestamptz not null,
  event_count integer not null,
  constraint event_rate_limits_pkey primary key (user_id),
  constraint event_rate_limits_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade
);
comment on table private.event_rate_limits is
  'Per-user event counter for the current hour (rate limit for public.events). Earlier hours are deleted as events arrive.';
revoke all on table private.event_rate_limits from public, anon, authenticated, service_role;

-- SECURITY DEFINER: clients have no access to the counter table. Order: count
-- the caller's own row first (an upsert on its primary key, which serializes
-- one user's requests), then clear other users' stale rows with SKIP LOCKED,
-- so this never waits on a row another request holds and cannot deadlock.
-- Without a user (postgres, secret key) there is no limit.
create function private.events_enforce_limit()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_hour timestamptz := date_trunc('hour', now());
  v_count integer;
begin
  if v_user is null then
    return new;
  end if;

  insert into private.event_rate_limits as r (user_id, window_start, event_count)
  values (v_user, v_hour, 1)
  on conflict (user_id) do update
    set event_count = case when r.window_start = excluded.window_start then r.event_count + 1 else 1 end,
        window_start = excluded.window_start
  returning r.event_count into v_count;

  if v_count > 30 then
    raise exception 'Too many events this hour.'
      using errcode = 'QR001', hint = 'Try again later.';
  end if;

  delete from private.event_rate_limits r
   where r.user_id in (
     select o.user_id
     from private.event_rate_limits o
     where o.window_start < v_hour
     for update skip locked
   );

  return new;
end;
$$;
revoke all on function private.events_enforce_limit() from public, anon, authenticated;

create trigger events_enforce_limit
  before insert on public.events
  for each row execute function private.events_enforce_limit();

-- ---------------------------------------------------------------------------
-- E. Purge of abandoned anonymous accounts
-- ---------------------------------------------------------------------------
create table private.purge_runs (
  id bigint generated always as identity,
  ran_at timestamptz not null default now(),
  rule_a_count integer not null,
  rule_b_count integer not null,
  aborted boolean not null,
  constraint purge_runs_pkey primary key (id)
);
comment on table private.purge_runs is
  'One row per private.purge_inactive_anonymous run: accounts matched by rule A (no profile after 7 days) and rule B (inactive 365 days), and whether the run was aborted by the cap (then nothing was deleted).';
revoke all on table private.purge_runs from public, anon, authenticated, service_role;

-- Deletes from auth.users only anonymous accounts (is_anonymous = true):
--   Rule A: no profile, and created more than 7 days before p_now.
--   Rule B: a profile whose last_active_at is more than 365 days before p_now,
--           and not purge_exempt.
-- Email accounts are never touched. If more than p_max_deletes accounts match,
-- nothing is deleted and the run is recorded as aborted (a bug or a clock
-- problem should not wipe the user base). The foreign keys do the rest:
-- profiles and quotes cascade from auth.users, the social rows from profiles,
-- reports keep their rows with the ids set to null, and the username is free
-- again. Rows are locked FOR UPDATE SKIP LOCKED, so an account that is being
-- touched (touch_activity) or is creating its profile right now is skipped
-- until the next run. p_now exists for tests; the schedule uses now().
create function private.purge_inactive_anonymous(
  p_now timestamptz default now(),
  p_max_deletes integer default 500
)
returns private.purge_runs
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_rule_a uuid[];
  v_rule_b uuid[];
  v_run private.purge_runs;
begin
  if p_now is null or p_max_deletes is null or p_max_deletes < 0 then
    raise exception 'p_now must be set and p_max_deletes must be 0 or more'
      using errcode = 'invalid_parameter_value';
  end if;

  select coalesce(array_agg(a.id), '{}')
    into v_rule_a
    from (
      select u.id
      from auth.users u
      where u.is_anonymous is true
        and u.created_at < p_now - interval '7 days'
        and not exists (select 1 from public.profiles p where p.id = u.id)
      for update of u skip locked
    ) a;

  select coalesce(array_agg(b.id), '{}')
    into v_rule_b
    from (
      select u.id
      from auth.users u
      join public.profiles p on p.id = u.id
      where u.is_anonymous is true
        and p.last_active_at < p_now - interval '365 days'
        and not p.purge_exempt
      for update of u, p skip locked
    ) b;

  if cardinality(v_rule_a) + cardinality(v_rule_b) > p_max_deletes then
    insert into private.purge_runs (rule_a_count, rule_b_count, aborted)
    values (cardinality(v_rule_a), cardinality(v_rule_b), true)
    returning * into v_run;
    raise warning 'purge_inactive_anonymous aborted: % accounts matched, the cap is %',
      cardinality(v_rule_a) + cardinality(v_rule_b), p_max_deletes;
    return v_run;
  end if;

  -- The rows are locked, so they still match; is_anonymous is checked again
  -- anyway, because this statement must never delete an email account.
  delete from auth.users u
   where u.id = any (v_rule_a || v_rule_b)
     and u.is_anonymous is true;

  insert into private.purge_runs (rule_a_count, rule_b_count, aborted)
  values (cardinality(v_rule_a), cardinality(v_rule_b), false)
  returning * into v_run;
  return v_run;
end;
$$;
comment on function private.purge_inactive_anonymous(timestamptz, integer) is
  'Deletes abandoned anonymous accounts (no profile after 7 days, or inactive 365 days and not purge_exempt); aborts without deleting when more than p_max_deletes match. Logs to private.purge_runs. Scheduled daily by pg_cron (purge-inactive-anonymous).';
revoke all on function private.purge_inactive_anonymous(timestamptz, integer) from public, anon, authenticated, service_role;

-- Daily at 03:17 UTC. pg_cron runs the job as the role that scheduled it
-- (postgres, the function's owner). cron.schedule with an existing name
-- updates that job, so this is safe to run again. Where pg_cron is missing
-- (or cannot be created), the migration still applies and says so; then
-- schedule it by hand. Check with: select jobname, schedule, command from cron.job;
do $do$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning 'pg_cron is not available, so private.purge_inactive_anonymous() is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
    perform cron.schedule(
      'purge-inactive-anonymous',
      '17 3 * * *',
      'select private.purge_inactive_anonymous()'
    );
  exception when others then
    raise warning 'pg_cron could not schedule purge-inactive-anonymous: % (%)', sqlerrm, sqlstate;
  end;
end
$do$;
