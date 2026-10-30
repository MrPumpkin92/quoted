-- Catalog corpus (M1): the 60 starter quotes become the first rows of one
-- verified catalog that later batches extend. Plan:
-- docs/catalog-population-plan.md section 6. Contract: docs/system-design.md
-- section 3. Tests: supabase/tests/database/16_catalog.test.sql (and 00, 01,
-- 04, 06, 08, 14).
--
-- 1. Ids widen to integer. The seal triggers are dropped first: Postgres
--    refuses to change the type of a column a trigger definition names.
-- 2. starter_quotes is renamed catalog_quotes, with its constraints and policy.
-- 3. catalog_authors and catalog_works hold what the public-domain rule needs:
--    death years and the edition actually checked.
-- 4. catalog_quotes gains starter, theme, lifecycle and provenance columns.
--    Every row is at most 280 characters. A non-starter must name its author,
--    work and the exact text it was checked against; the 60 starters get
--    theirs in a later migration (M2), so those stay nullable for them.
-- 5. public.starter_quotes becomes a view of the live starters only, so builds
--    4-6 (which read it in full during onboarding) keep seeing exactly 60.
-- 6. The seal reads catalog_quotes (every row that isn't withdrawn) through a
--    unique md5(body) index.
-- 7. friend_favorites returns the widened id.
-- 8. Catalog text is frozen and never deleted. Batches and corrections go
--    through private.catalog_reseal, catalog_withdraw, catalog_set_replacement
--    and catalog_unstar, which only migrations run.
-- 9. quotes.origin accepts 'catalog'.
-- The wire name verified_starter_id never changes: builds up to 6 select it.

-- ---------------------------------------------------------------------------
-- 1. Widen ids to integer
-- ---------------------------------------------------------------------------
drop trigger quotes_set_verified on public.quotes;
drop trigger shares_set_verified on public.shares;
alter table public.quotes drop constraint quotes_verified_starter_id_fkey;
alter table public.shares drop constraint shares_verified_starter_id_fkey;

alter table public.starter_quotes
  alter column id type integer,
  alter column sort_order type integer;
alter table public.quotes alter column verified_starter_id type integer;
alter table public.shares alter column verified_starter_id type integer;

-- ---------------------------------------------------------------------------
-- 2. Rename
-- ---------------------------------------------------------------------------
alter table public.starter_quotes rename to catalog_quotes;
alter table public.catalog_quotes rename constraint starter_quotes_pkey to catalog_quotes_pkey;
alter table public.catalog_quotes rename constraint starter_quotes_author_check to catalog_quotes_author_check;
alter table public.catalog_quotes rename constraint starter_quotes_author_not_blank to catalog_quotes_author_not_blank;
alter table public.catalog_quotes rename constraint starter_quotes_body_check to catalog_quotes_body_check;
alter table public.catalog_quotes rename constraint starter_quotes_body_format_valid to catalog_quotes_body_format_valid;
alter table public.catalog_quotes rename constraint starter_quotes_body_not_blank to catalog_quotes_body_not_blank;
alter table public.catalog_quotes rename constraint starter_quotes_source_check to catalog_quotes_source_check;
alter table public.catalog_quotes rename constraint starter_quotes_source_location_length to catalog_quotes_source_location_length;
alter table public.catalog_quotes rename constraint starter_quotes_source_not_blank to catalog_quotes_source_not_blank;
alter table public.catalog_quotes rename constraint starter_quotes_source_url_https to catalog_quotes_source_url_https;
-- Only starters have an onboarding position (partial unique index below).
alter table public.catalog_quotes drop constraint starter_quotes_sort_order_key;
alter table public.catalog_quotes alter column sort_order drop not null;
alter policy "starter_quotes: authenticated users can read" on public.catalog_quotes
  rename to "catalog_quotes: authenticated users can read";

comment on table public.catalog_quotes is
  'Verified public-domain quotes: the 60 onboarding starters (is_starter) and the catalog batches. Each was checked word for word against a pinned edition (docs/catalog-sources.md). Read-only for clients; rows arrive only through migrations.';

-- ---------------------------------------------------------------------------
-- 3. Authors and works
-- ---------------------------------------------------------------------------
create table public.catalog_authors (
  id integer primary key,
  slug text not null,
  name text not null,
  died_year integer,
  constraint catalog_authors_id_positive check (id > 0),
  constraint catalog_authors_slug_key unique (slug),
  constraint catalog_authors_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 80),
  constraint catalog_authors_name_length check (char_length(name) between 1 and 200),
  constraint catalog_authors_name_not_blank check (not private.is_blank(name)),
  constraint catalog_authors_died_year_range check (died_year between -3000 and 2100)
);
comment on table public.catalog_authors is 'People credited in the catalog. name is the exact author string quotes carry (part of the seal key).';
comment on column public.catalog_authors.died_year is 'Year of death (negative for BCE; the latest plausible year when uncertain). Null means living or unknown, which fails the public-domain rule.';

-- One row per edition or translation whose wording the catalog uses.
create table public.catalog_works (
  id integer primary key,
  author_id integer not null,
  citation text not null,
  edition_year integer not null,
  translator text,
  reporter text,
  contributors_last_died_year integer,
  gutenberg_id integer,
  constraint catalog_works_id_positive check (id > 0),
  constraint catalog_works_author_id_fkey foreign key (author_id) references public.catalog_authors (id),
  constraint catalog_works_author_citation_key unique (author_id, citation),
  constraint catalog_works_citation_length check (char_length(citation) between 1 and 200),
  constraint catalog_works_citation_not_blank check (not private.is_blank(citation)),
  constraint catalog_works_edition_year_range check (edition_year between -3000 and 2100),
  constraint catalog_works_translator_length check (char_length(translator) between 1 and 200),
  constraint catalog_works_reporter_length check (char_length(reporter) between 1 and 200),
  constraint catalog_works_contributors_died check (
    (translator is null and reporter is null) = (contributors_last_died_year is null)),
  constraint catalog_works_contributors_died_range check (contributors_last_died_year between -3000 and 2100),
  constraint catalog_works_gutenberg_id_positive check (gutenberg_id > 0)
);
create index catalog_works_author_id_idx on public.catalog_works (author_id);
comment on table public.catalog_works is 'The edition or translation a quote was checked against. citation is the exact source string quotes carry (part of the seal key, frozen).';
comment on column public.catalog_works.edition_year is 'Year the text actually used (this edition or translation) was first published: the US rule.';
comment on column public.catalog_works.contributors_last_died_year is 'Latest death year among the translator and the reporter; null when there is neither.';
comment on column public.catalog_works.gutenberg_id is 'Project Gutenberg ebook number of the pinned text, when it is on Gutenberg.';

-- ---------------------------------------------------------------------------
-- 4. New catalog_quotes columns
-- ---------------------------------------------------------------------------
alter table public.catalog_quotes
  alter column source set not null,
  add column is_starter boolean not null default false,
  add column author_id integer,
  add column work_id integer,
  add column speaker text,
  add column themes text[] not null default '{}',
  add column status text not null default 'live',
  add column withdrawn_at timestamptz,
  add column withdrawn_reason text,
  add column replaced_by integer,
  add column rights_note text,
  add column checked_ebook_id integer,
  add column checked_wikisource_oldid bigint,
  add column checked_body_sha256 text,
  add column checked_start integer,
  add column checked_end integer,
  add column match_kind text,
  add column checked_at timestamptz,
  add column verifier_version text,
  add column added_at timestamptz not null default now();

update public.catalog_quotes set is_starter = true;

-- Themes for the 60, as drafted in docs/new-quotes-theme-tags.csv.
update public.catalog_quotes c
set themes = v.themes
from (values
  (1, array['self', 'courage']), (2, array['courage']), (3, array['courage']), (4, array['time', 'purpose']),
  (5, array['courage', 'self']), (6, array['self']), (7, array['courage']), (8, array['purpose', 'time']),
  (9, array['self']), (10, array['calm', 'nature']), (11, array['calm', 'time']), (12, array['calm']),
  (13, array['self', 'courage']), (14, array['purpose']), (15, array['courage']), (16, array['love']),
  (17, array['courage', 'self']), (18, array['purpose', 'love']), (19, array['nature']), (20, array['love', 'purpose']),
  (21, array['calm']), (22, array['nature', 'courage']), (23, array['calm', 'courage']), (24, array['purpose']),
  (25, array['love']), (26, array['courage', 'time']), (27, array['nature', 'calm']), (28, array['courage']),
  (29, array['self']), (30, array['courage']), (31, array['nature']), (32, array['love', 'calm']),
  (33, array['courage', 'nature']), (34, array['nature']), (35, array['self']), (36, array['purpose', 'love']),
  (37, array['nature', 'time']), (38, array['self']), (39, array['self', 'calm']), (40, array['courage', 'self']),
  (41, array['courage', 'purpose']), (42, array['love', 'nature']), (43, array['courage']), (44, array['nature']),
  (45, array['self', 'love']), (46, array['purpose', 'courage']), (47, array['courage', 'self']), (48, array['nature', 'time']),
  (49, array['time', 'calm']), (50, array['self', 'nature']), (51, array['self']), (52, array['love', 'purpose']),
  (53, array['calm', 'nature']), (54, array['courage', 'purpose']), (55, array['nature', 'self']), (56, array['nature', 'love']),
  (57, array['purpose']), (58, array['nature', 'time']), (59, array['self', 'calm']), (60, array['love'])
) as v (id, themes)
where c.id = v.id;

alter table public.catalog_quotes
  add constraint catalog_quotes_author_id_fkey foreign key (author_id) references public.catalog_authors (id),
  add constraint catalog_quotes_work_id_fkey foreign key (work_id) references public.catalog_works (id),
  add constraint catalog_quotes_replaced_by_fkey foreign key (replaced_by) references public.catalog_quotes (id),
  add constraint catalog_quotes_body_length check (char_length(body) <= 280),
  add constraint catalog_quotes_sort_order_starter check (is_starter = (sort_order is not null)),
  add constraint catalog_quotes_sort_order_positive check (sort_order > 0),
  add constraint catalog_quotes_themes_valid check (
    themes <@ array['courage', 'calm', 'time', 'love', 'nature', 'purpose', 'self']::text[]
    and cardinality(themes) between 1 and 3),
  add constraint catalog_quotes_status_valid check (status in ('live', 'retired', 'withdrawn')),
  add constraint catalog_quotes_withdrawn_fields check (
    (status = 'withdrawn') = (withdrawn_at is not null)
    and (status = 'withdrawn') = (withdrawn_reason is not null)),
  add constraint catalog_quotes_withdrawn_reason_length check (
    char_length(withdrawn_reason) between 1 and 500 and not private.is_blank(withdrawn_reason)),
  add constraint catalog_quotes_replaced_by_valid check (
    replaced_by is null or (status = 'withdrawn' and replaced_by <> id)),
  add constraint catalog_quotes_speaker_length check (
    char_length(speaker) between 1 and 100 and not private.is_blank(speaker)),
  add constraint catalog_quotes_rights_note_length check (
    char_length(rights_note) between 1 and 500 and not private.is_blank(rights_note)),
  -- Starters are exempt until M2 writes their authors, works and provenance.
  add constraint catalog_quotes_attribution check (is_starter or (author_id is not null and work_id is not null)),
  add constraint catalog_quotes_provenance check (
    is_starter or (
      num_nonnulls(checked_ebook_id, checked_wikisource_oldid) = 1
      and num_nulls(checked_body_sha256, checked_start, checked_end, match_kind, checked_at, verifier_version) = 0)),
  add constraint catalog_quotes_provenance_values check (
    (checked_ebook_id is null or checked_ebook_id > 0)
    and (checked_wikisource_oldid is null or checked_wikisource_oldid > 0)
    and (checked_body_sha256 is null or checked_body_sha256 ~ '^[0-9a-f]{64}$')
    and (checked_start is null or checked_start >= 0)
    and (checked_end is null or checked_end > checked_start)
    and (match_kind is null or match_kind in ('exact', 'elided', 'reviewed'))
    and (verifier_version is null or verifier_version ~ '^[0-9a-f]{7,40}$'));

create unique index catalog_quotes_starter_sort_order_key on public.catalog_quotes (sort_order)
  where sort_order is not null;
-- The seal's lookup, and the rule that no two current rows share a body.
create unique index catalog_quotes_body_md5_key on public.catalog_quotes (md5(body))
  where status <> 'withdrawn';
-- Foreign key columns lead an index (00_schema).
create index catalog_quotes_author_id_idx on public.catalog_quotes (author_id);
create index catalog_quotes_work_id_idx on public.catalog_quotes (work_id);
create index catalog_quotes_replaced_by_idx on public.catalog_quotes (replaced_by) where replaced_by is not null;

comment on column public.catalog_quotes.is_starter is 'One of the onboarding starter quotes (sort_order is its position).';
comment on column public.catalog_quotes.author_id is 'The credited person (Socrates for the Apology line), whose name equals author.';
comment on column public.catalog_quotes.work_id is 'The edition checked, whose citation equals source.';
comment on column public.catalog_quotes.speaker is 'The character who speaks the line, when it is not the author''s own voice.';
comment on column public.catalog_quotes.themes is '1-3 of courage, calm, time, love, nature, purpose, self.';
comment on column public.catalog_quotes.status is 'live, retired (no longer offered; users keep the seal) or withdrawn (the wording or credit was wrong; the seal comes off). Rows are never deleted.';
comment on column public.catalog_quotes.replaced_by is 'For a withdrawn row, the live row with the corrected wording (set only by private.catalog_set_replacement).';
comment on column public.catalog_quotes.rights_note is 'Why a row that fails the strict public-domain rule ships anyway, with the date it clears.';
comment on column public.catalog_quotes.checked_ebook_id is 'Project Gutenberg ebook the body was checked against (or checked_wikisource_oldid; exactly one).';
comment on column public.catalog_quotes.checked_wikisource_oldid is 'Wikisource mainspace revision the body was checked against. Transcluded Page: revisions are pinned in supabase/catalog/.';
comment on column public.catalog_quotes.checked_body_sha256 is 'SHA-256 of the UTF-8 text checked: the Gutenberg body between the START and END markers, LF line endings.';
comment on column public.catalog_quotes.checked_start is 'Start of the matched span, in code points into the checked text.';
comment on column public.catalog_quotes.checked_end is 'End of the matched span (exclusive), in code points into the checked text.';
comment on column public.catalog_quotes.match_kind is 'exact (the source span, typography normalised), elided (ordered segments joined by " … ") or reviewed (a judgement call recorded in supabase/catalog/).';
comment on column public.catalog_quotes.verifier_version is 'Git tree id of scripts/catalog at the verifier run (git rev-parse <commit>:scripts/catalog).';

-- ---------------------------------------------------------------------------
-- Grants and RLS for the new tables. Supabase's default privileges grant the
-- API roles everything on new objects, so strip them first.
-- ---------------------------------------------------------------------------
revoke all on table public.catalog_authors, public.catalog_works from public, anon, authenticated, service_role;
grant select on table public.catalog_authors, public.catalog_works to authenticated;
grant select, insert, update, delete on table public.catalog_authors, public.catalog_works to service_role;
alter table public.catalog_authors enable row level security;
alter table public.catalog_works enable row level security;
create policy "catalog_authors: authenticated users can read"
  on public.catalog_authors for select to authenticated using (true);
create policy "catalog_works: authenticated users can read"
  on public.catalog_works for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- 5. The starter_quotes view: live starters only
-- ---------------------------------------------------------------------------
-- Builds 4-6 read this in full during onboarding. The filter is what keeps
-- them at 60 rows as the catalog grows (without it they would list the whole
-- catalog, cut at the API's row limit).
create view public.starter_quotes with (security_invoker = true) as
  select id, body, body_format, author, source, sort_order, source_location, source_url
  from public.catalog_quotes
  where is_starter and status = 'live';
comment on view public.starter_quotes is 'The live onboarding starter quotes (catalog_quotes where is_starter). Kept for builds up to 6; read-only.';
revoke all on table public.starter_quotes from public, anon, authenticated, service_role;
grant select on table public.starter_quotes to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. The seal reads the catalog
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER: catalog_quotes is readable by every signed-in user (and by
-- the secret key), which is all the lookup needs. Retired rows still seal;
-- withdrawn rows never do.
create or replace function private.set_verified_starter()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  new.verified_starter_id := (
    select c.id
    from public.catalog_quotes c
    where md5(c.body) = md5(new.body)
      and c.status <> 'withdrawn'
      and c.body = new.body
      and c.author is not distinct from new.author
      and c.source is not distinct from new.source
    order by c.id
    limit 1
  );
  return new;
end;
$$;
revoke all on function private.set_verified_starter() from public, anon, authenticated;

create trigger quotes_set_verified
  before insert or update of body, author, source, verified_starter_id on public.quotes
  for each row execute function private.set_verified_starter();

create trigger shares_set_verified
  before insert or update of body, author, source, verified_starter_id on public.shares
  for each row execute function private.set_verified_starter();

alter table public.quotes
  add constraint quotes_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.catalog_quotes (id) on delete set null;
alter table public.shares
  add constraint shares_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.catalog_quotes (id) on delete set null;

comment on column public.quotes.verified_starter_id is 'Server-owned: the catalog quote this row''s body, author and source match exactly, else null (trigger quotes_set_verified). The name predates the catalog and never changes.';
comment on column public.shares.verified_starter_id is 'Server-owned: the catalog quote this share''s body, author and source match exactly, else null (trigger shares_set_verified). The name predates the catalog and never changes.';

-- ---------------------------------------------------------------------------
-- 7. friend_favorites returns the widened id (create or replace can't change
--    a return type). Same body, columns and grants as 20261025090000.
-- ---------------------------------------------------------------------------
drop function public.friend_favorites(uuid);
drop function private.friend_favorites(uuid);

create function private.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id integer,
  favorited_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select md5(q.id::text || ':' || (select auth.uid())::text)::uuid,
         q.body, q.body_format, q.author, q.source, q.verified_starter_id, q.favorited_at
  from public.quotes q
  join public.profiles p on p.id = q.owner_id
  where (select auth.uid()) is not null
    and q.owner_id = p_user
    and p_user <> (select auth.uid())
    and q.is_favorite
    and p.shows_favorites
    and exists (
      select 1
      from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = (select auth.uid()) and f.addressee_id = p_user)
          or (f.addressee_id = (select auth.uid()) and f.requester_id = p_user))
    )
    and not exists (
      select 1
      from public.blocks b
      where (b.blocker_id = p_user and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = p_user)
    )
  order by q.favorited_at desc, q.id
  limit 100
$$;

revoke all on function private.friend_favorites(uuid) from public, anon, service_role;
grant execute on function private.friend_favorites(uuid) to authenticated;

create function public.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id integer,
  favorited_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select f.id, f.body, f.body_format, f.author, f.source, f.verified_starter_id, f.favorited_at
  from private.friend_favorites(p_user) f
$$;
comment on function public.friend_favorites(uuid) is
  'An accepted friend''s favorite quotes (at most 100, newest first) when they have shows_favorites on; empty otherwise. SECURITY INVOKER wrapper over private.friend_favorites.';

revoke all on function public.friend_favorites(uuid) from public, anon, service_role;
grant execute on function public.friend_favorites(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Lifecycle
-- ---------------------------------------------------------------------------
-- id, body, author and source are the seal's key, so they never change: a
-- wrong row is withdrawn and, if needed, replaced by a new one. Withdrawal is
-- final, and replaced_by is set only by private.catalog_set_replacement.
create function private.catalog_quotes_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old_replaced_by integer;
begin
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.body is distinct from old.body
       or new.author is distinct from old.author or new.source is distinct from old.source then
      raise exception 'catalog quote % is frozen: id, body, author and source never change (withdraw it instead)', old.id
        using errcode = '42501';
    end if;
    if old.status = 'withdrawn' and new.status <> 'withdrawn' then
      raise exception 'catalog quote % is withdrawn, which is final', old.id using errcode = '42501';
    end if;
    v_old_replaced_by := old.replaced_by;
  end if;
  if new.replaced_by is distinct from v_old_replaced_by
     and coalesce(current_setting('quoted.catalog_set_replacement', true), '') <> 'on' then
    raise exception 'replaced_by is set only by private.catalog_set_replacement' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.catalog_quotes_guard() from public, anon, authenticated, service_role;

create trigger catalog_quotes_guard
  before insert or update on public.catalog_quotes
  for each row execute function private.catalog_quotes_guard();

create function private.catalog_quotes_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'catalog quotes are never deleted (withdraw instead)' using errcode = '42501';
end;
$$;
revoke all on function private.catalog_quotes_no_delete() from public, anon, authenticated, service_role;

create trigger catalog_quotes_no_delete
  before delete on public.catalog_quotes
  for each row execute function private.catalog_quotes_no_delete();
create trigger catalog_quotes_no_truncate
  before truncate on public.catalog_quotes
  for each statement execute function private.catalog_quotes_no_delete();

-- Recompute the seal on every quote and share that points at, or exactly
-- matches, one of p_ids. quotes_set_updated_at is paused so a reseal doesn't
-- look like an edit (as in 20261024090000); quotes writes wait until the
-- migration commits. Every batch migration ends with this.
create function private.catalog_reseal(p_ids integer[])
returns table (quotes_rechecked integer, shares_rechecked integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_quotes integer;
  v_shares integer;
begin
  alter table public.quotes disable trigger quotes_set_updated_at;
  update public.quotes q
  set verified_starter_id = null
  where q.verified_starter_id = any (p_ids)
     or exists (
       select 1 from public.catalog_quotes c
       where c.id = any (p_ids) and c.body = q.body
         and c.author is not distinct from q.author and c.source is not distinct from q.source
     );
  get diagnostics v_quotes = row_count;
  alter table public.quotes enable trigger quotes_set_updated_at;

  update public.shares sh
  set verified_starter_id = null
  where sh.verified_starter_id = any (p_ids)
     or exists (
       select 1 from public.catalog_quotes c
       where c.id = any (p_ids) and c.body = sh.body
         and c.author is not distinct from sh.author and c.source is not distinct from sh.source
     );
  get diagnostics v_shares = row_count;

  return query select v_quotes, v_shares;
end;
$$;
revoke all on function private.catalog_reseal(integer[]) from public, anon, authenticated, service_role;

-- Take the seal off a row whose wording or credit turned out wrong. The row
-- stays (users keep the quote; a later notice can find them). Idempotent: a
-- second call keeps the first date and reason.
create function private.catalog_withdraw(p_id integer, p_reason text)
returns table (quotes_rechecked integer, shares_rechecked integer)
language plpgsql
volatile
set search_path = ''
as $$
begin
  update public.catalog_quotes
  set status = 'withdrawn',
      withdrawn_at = coalesce(withdrawn_at, now()),
      withdrawn_reason = coalesce(withdrawn_reason, p_reason)
  where id = p_id;
  if not found then
    raise exception 'no catalog quote %', p_id using errcode = 'P0002';
  end if;
  return query select * from private.catalog_reseal(array[p_id]);
end;
$$;
revoke all on function private.catalog_withdraw(integer, text) from public, anon, authenticated, service_role;

-- Point a withdrawn row at the live row with the corrected wording.
create function private.catalog_set_replacement(p_old integer, p_new integer)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if not exists (select 1 from public.catalog_quotes where id = p_old and status = 'withdrawn') then
    raise exception 'catalog quote % is not withdrawn', p_old using errcode = '22023';
  end if;
  if not exists (select 1 from public.catalog_quotes where id = p_new and status = 'live') then
    raise exception 'catalog quote % is not live', p_new using errcode = '22023';
  end if;
  perform set_config('quoted.catalog_set_replacement', 'on', true);
  update public.catalog_quotes set replaced_by = p_new where id = p_old;
  perform set_config('quoted.catalog_set_replacement', '', true);
end;
$$;
revoke all on function private.catalog_set_replacement(integer, integer) from public, anon, authenticated, service_role;

-- Free a retired starter's onboarding slot for a replacement. It needs its
-- author, work and provenance first (catalog_quotes_attribution and
-- catalog_quotes_provenance apply once it is no longer a starter).
create function private.catalog_unstar(p_id integer)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  update public.catalog_quotes
  set is_starter = false, sort_order = null
  where id = p_id and is_starter and status = 'retired';
  if not found then
    raise exception 'catalog quote % is not a retired starter', p_id using errcode = '22023';
  end if;
end;
$$;
revoke all on function private.catalog_unstar(integer) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Origin
-- ---------------------------------------------------------------------------
alter table public.quotes
  drop constraint quotes_origin_valid,
  add constraint quotes_origin_valid check (origin in ('manual', 'starter', 'shared', 'pasted', 'catalog'));

-- PostgREST: pick up the renamed table, the view and the new tables now.
notify pgrst, 'reload schema';
