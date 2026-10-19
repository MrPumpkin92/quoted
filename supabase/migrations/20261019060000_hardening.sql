-- Hardening after the 2026-10-19 engineering review. Contract: docs/system-design.md
-- section 3. Tests: supabase/tests/database/08_hardening.test.sql (and the
-- adjusted 00-07).
--
--  1. body_format is validated run by run and capped in bytes (quotes, shares,
--     starter_quotes), so a row can no longer carry megabytes of junk.
--  2. Text the app trims (body, author, source, display_name, note, details)
--     must contain something other than whitespace on the server too.
--  3. Timestamps are server-owned: created_at is always the server clock on
--     insert and never changes afterwards; quotes.updated_at is the server
--     clock; shares.seen_at and saved_at take the server clock, first time wins.
--  4. events is anonymous: no user_id, and created_at is rounded to the hour.
--  5. reports survive the deletion of either account (the ids become null),
--     record whether the snapshot was copied from the share by the server
--     (content_verified), keep the reported username, and carry reviewed_at
--     for the moderation queue.
--  6. private.reports_to_review lists the reports waiting for review (the
--     founder's daily check; docs/system-design.md section 7).
--
-- Like every migration here it runs once, inside one transaction. It also
-- cleans existing rows that the new checks would reject (blank optional text
-- becomes null, an invalid body_format becomes '[]'), so it applies cleanly to
-- a database that already holds data. A whitespace-only quote or share body
-- cannot be repaired automatically; if one exists the push fails on
-- quotes_body_not_blank or shares_body_not_blank and names the row's table.

-- ---------------------------------------------------------------------------
-- 1. Validators used by CHECK constraints (private schema, search_path = '')
-- ---------------------------------------------------------------------------

-- True when `value` is empty or only Unicode White_Space: the characters the
-- app trims (Swift .whitespacesAndNewlines and Character.isWhitespace). The
-- server is never stricter than the app: anything the app accepts has a
-- character outside this set. Null in, null out, so nullable columns pass.
create function private.is_blank(value text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(
    value,
    E' \t\n\u000B\f\r'
      || U&'\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000'
  ) = ''
$$;
comment on function private.is_blank(text) is
  'True when the text is empty or only Unicode White_Space (what the app trims). Used by *_not_blank checks.';

-- The body_format contract (docs/system-design.md, "Rich-text format"): a JSON
-- array of at most 200 runs, each an object with integer `start` and `length`
-- (0-4000, the most UTF-16 units a 2000-character body can have) and optional
-- boolean `bold`, `italic`, `underline`; no other keys. The whole value is at
-- most 16384 bytes as text. Every array the app writes fits: its runs are
-- sorted, non-overlapping and inside a body of at most 4000 UTF-16 units, so
-- even 200 runs with every flag set print as about 16000 bytes. Null in, null
-- out.
create function private.is_valid_body_format(runs jsonb)
returns boolean
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  run jsonb;
  run_key text;
  run_value jsonb;
begin
  if runs is null then
    return null;
  end if;
  if jsonb_typeof(runs) <> 'array' then
    return false;
  end if;
  if jsonb_array_length(runs) > 200 then
    return false;
  end if;
  if octet_length(runs::text) > 16384 then
    return false;
  end if;

  for run in select value from jsonb_array_elements(runs) loop
    if jsonb_typeof(run) <> 'object' then
      return false;
    end if;
    if not (run ? 'start' and run ? 'length') then
      return false;
    end if;
    for run_key, run_value in select key, value from jsonb_each(run) loop
      if run_key in ('start', 'length') then
        -- A plain non-negative integer of at most four digits, then <= 4000.
        if jsonb_typeof(run_value) <> 'number' then
          return false;
        end if;
        if run_value::text !~ '^[0-9]{1,4}$' then
          return false;
        end if;
        if run_value::text::integer > 4000 then
          return false;
        end if;
      elsif run_key in ('bold', 'italic', 'underline') then
        if jsonb_typeof(run_value) <> 'boolean' then
          return false;
        end if;
      else
        return false;
      end if;
    end loop;
  end loop;

  return true;
end;
$$;
comment on function private.is_valid_body_format(jsonb) is
  'The body_format contract: <= 200 runs of {start, length, bold?, italic?, underline?}, <= 16384 bytes. Used by *_body_format_valid checks.';

-- CHECK constraints run with the privileges of whoever writes the row, so the
-- roles that write these tables need EXECUTE. Neither function reads data.
revoke all on function private.is_blank(text) from public, anon;
revoke all on function private.is_valid_body_format(jsonb) from public, anon;
grant execute on function private.is_blank(text) to authenticated, service_role;
grant execute on function private.is_valid_body_format(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Repair existing rows the new checks would reject
-- ---------------------------------------------------------------------------
update public.profiles set display_name = null where private.is_blank(display_name);
update public.quotes set author = null where private.is_blank(author);
update public.quotes set source = null where private.is_blank(source);
update public.quotes set body_format = '[]'::jsonb where not private.is_valid_body_format(body_format);
update public.shares set author = null where private.is_blank(author);
update public.shares set source = null where private.is_blank(source);
update public.shares set note = null where private.is_blank(note);
update public.shares set body_format = '[]'::jsonb where not private.is_valid_body_format(body_format);
update public.starter_quotes set source = null where private.is_blank(source);
update public.starter_quotes set body_format = '[]'::jsonb where not private.is_valid_body_format(body_format);
update public.reports set details = null where private.is_blank(details);

-- ---------------------------------------------------------------------------
-- 3. body_format and non-blank text checks
-- ---------------------------------------------------------------------------
alter table public.profiles
  add constraint profiles_display_name_not_blank check (not private.is_blank(display_name));

alter table public.quotes
  drop constraint quotes_body_format_array,
  add constraint quotes_body_format_valid check (private.is_valid_body_format(body_format)),
  add constraint quotes_body_not_blank check (not private.is_blank(body)),
  add constraint quotes_author_not_blank check (not private.is_blank(author)),
  add constraint quotes_source_not_blank check (not private.is_blank(source));

alter table public.shares
  drop constraint shares_body_format_array,
  add constraint shares_body_format_valid check (private.is_valid_body_format(body_format)),
  add constraint shares_body_not_blank check (not private.is_blank(body)),
  add constraint shares_author_not_blank check (not private.is_blank(author)),
  add constraint shares_source_not_blank check (not private.is_blank(source)),
  add constraint shares_note_not_blank check (not private.is_blank(note));

alter table public.starter_quotes
  drop constraint starter_quotes_body_format_check,
  add constraint starter_quotes_body_format_valid check (private.is_valid_body_format(body_format)),
  add constraint starter_quotes_body_not_blank check (not private.is_blank(body)),
  add constraint starter_quotes_author_not_blank check (not private.is_blank(author)),
  add constraint starter_quotes_source_not_blank check (not private.is_blank(source));

alter table public.reports
  add constraint reports_details_not_blank check (not private.is_blank(details));

comment on column public.quotes.body_format is
  'Sorted, non-overlapping UTF-16 runs: [{start,length,bold?,italic?,underline?}], checked by private.is_valid_body_format. See docs/system-design.md.';

-- ---------------------------------------------------------------------------
-- 4. Server-owned timestamps
-- ---------------------------------------------------------------------------

-- created_at is the server clock on insert, whatever the client sent. Applies
-- to every role, the secret key included.
create function private.stamp_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := now();
  return new;
end;
$$;
revoke all on function private.stamp_created_at() from public, anon, authenticated;

-- created_at never changes after insert (profiles and quotes have
-- table-level UPDATE grants; the other tables' grants already exclude it).
create function private.keep_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := old.created_at;
  return new;
end;
$$;
revoke all on function private.keep_created_at() from public, anon, authenticated;

-- events: rounded down to the hour, so a row cannot be matched to the API
-- request (and so the user) that wrote it by its exact time.
create function private.events_stamp_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := date_trunc('hour', now());
  return new;
end;
$$;
revoke all on function private.events_stamp_created_at() from public, anon, authenticated;

-- shares.seen_at and saved_at: the recipient says "now", the server says when
-- now is. The first time wins (a later write keeps the stored time); setting
-- null clears it.
create function private.shares_stamp_seen_saved()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.seen_at is not null then
    new.seen_at := coalesce(old.seen_at, now());
  end if;
  if new.saved_at is not null then
    new.saved_at := coalesce(old.saved_at, now());
  end if;
  return new;
end;
$$;
revoke all on function private.shares_stamp_seen_saved() from public, anon, authenticated;

create trigger profiles_stamp_created_at
  before insert on public.profiles
  for each row execute function private.stamp_created_at();
create trigger profiles_keep_created_at
  before update on public.profiles
  for each row execute function private.keep_created_at();

create trigger quotes_stamp_created_at
  before insert on public.quotes
  for each row execute function private.stamp_created_at();
create trigger quotes_keep_created_at
  before update on public.quotes
  for each row execute function private.keep_created_at();
-- updated_at is the server clock on insert too, not only on update.
drop trigger quotes_set_updated_at on public.quotes;
create trigger quotes_set_updated_at
  before insert or update on public.quotes
  for each row execute function private.set_updated_at();

create trigger friendships_stamp_created_at
  before insert on public.friendships
  for each row execute function private.stamp_created_at();

create trigger blocks_stamp_created_at
  before insert on public.blocks
  for each row execute function private.stamp_created_at();

create trigger shares_stamp_created_at
  before insert on public.shares
  for each row execute function private.stamp_created_at();
create trigger shares_stamp_seen_saved
  before update on public.shares
  for each row execute function private.shares_stamp_seen_saved();

create trigger reports_stamp_created_at
  before insert on public.reports
  for each row execute function private.stamp_created_at();

create trigger events_stamp_created_at
  before insert on public.events
  for each row execute function private.events_stamp_created_at();

-- ---------------------------------------------------------------------------
-- 5. events: anonymous
-- ---------------------------------------------------------------------------
-- Dropping the column also drops events_user_id_fkey and events_user_id_idx,
-- and turns existing rows anonymous. The policy referenced the column, so it
-- goes first.
drop policy "events: insert own" on public.events;
alter table public.events drop column user_id;

create policy "events: log a known event"
  on public.events for insert to authenticated
  with check (name in ('web_search_tap'));

comment on table public.events is
  'Anonymous product analytics: an event name and the hour it happened. No user id, no search term.';

-- ---------------------------------------------------------------------------
-- 6. reports: kept after account deletion, verified flag, moderation fields
-- ---------------------------------------------------------------------------
alter table public.reports
  drop constraint reports_reporter_id_fkey,
  drop constraint reports_reported_user_id_fkey,
  alter column reporter_id drop not null,
  alter column reported_user_id drop not null,
  add constraint reports_reporter_id_fkey
    foreign key (reporter_id) references public.profiles (id) on delete set null,
  add constraint reports_reported_user_id_fkey
    foreign key (reported_user_id) references public.profiles (id) on delete set null,
  add column content_verified boolean not null default false,
  add column reported_username text,
  add column reviewed_at timestamptz;

comment on column public.reports.reporter_id is
  'Who filed the report. Null once that account is deleted; the report itself is kept.';
comment on column public.reports.reported_user_id is
  'Who was reported. Null once that account is deleted; reported_username and the snapshot are kept.';
comment on column public.reports.content_verified is
  'True only when the server copied the snapshot from a share the reported user sent the reporter. Set by trigger; clients cannot set it.';
comment on column public.reports.reported_username is
  'The reported user''s username when the report was filed. Set by trigger.';
comment on column public.reports.reviewed_at is
  'When the developer reviewed the report. Null = waiting in private.reports_to_review. Clients cannot set it.';

-- Existing rows: a snapshot stored while share_id is still set was copied by
-- the trigger from 20261019050000_report_snapshot.sql.
update public.reports
   set content_verified = true
 where share_id is not null and content_body is not null;
update public.reports r
   set reported_username = p.username
  from public.profiles p
 where p.id = r.reported_user_id;

-- Still SECURITY INVOKER: the share and the profile are read with the
-- reporter's own RLS. Now also: both parties are required at insert (the ids
-- become nullable only so deletion can null them), the share must be one the
-- reported user sent the reporter for the snapshot to count as verified, and
-- the server-owned columns are reset whatever the client sent.
create or replace function private.reports_snapshot_share()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.reporter_id is null or new.reported_user_id is null then
    raise exception 'a report needs reporter_id and reported_user_id'
      using errcode = 'not_null_violation';
  end if;

  new.content_verified := false;
  new.reviewed_at := null;
  new.reported_username := null;

  select p.username
    into new.reported_username
    from public.profiles p
   where p.id = new.reported_user_id;

  if new.share_id is not null then
    -- No matching row sets the three snapshot columns to null.
    select s.body, s.author, s.source
      into new.content_body, new.content_author, new.content_source
      from public.shares s
     where s.id = new.share_id
       and s.sender_id = new.reported_user_id
       and s.recipient_id = new.reporter_id;
    new.content_verified := found;
  end if;

  return new;
end;
$$;
revoke all on function private.reports_snapshot_share() from public, anon, authenticated;

-- Moderation queue for the founder's daily check (dashboard SQL editor):
--   select * from private.reports_to_review;
--   update public.reports set reviewed_at = now() where id = '<id>';
-- security_invoker, so it never widens access: only roles that can already
-- read every report (postgres in the SQL editor) see every row. Not granted to
-- any API role, and the private schema is not exposed by the Data API.
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
  r.share_id,
  r.reported_user_id,
  coalesce(reported.username, r.reported_username) as reported_username,
  r.reported_user_id is null as reported_account_deleted,
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
  'Reports waiting for review, oldest first. Mark one done with: update public.reports set reviewed_at = now() where id = ...';

revoke all on table private.reports_to_review from public, anon, authenticated, service_role;

-- The queue reads unreviewed reports oldest first.
create index reports_unreviewed_created_at_idx on public.reports (created_at)
  where reviewed_at is null;
