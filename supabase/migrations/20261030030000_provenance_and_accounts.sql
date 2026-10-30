-- Provenance and accounts: who added each quote, a server-owned origin, terms
-- of use, suspensions, the word filter, retired usernames and private profile
-- columns. Step 1 of the social redesign.
-- Contract: docs/system-design.md section 3, and
-- docs/decisions/2026-10-28-social-redesign-council.md sections 2 and 3.
-- Tests: supabase/tests/database/16_provenance_accounts.test.sql (plus the
-- adjusted 00, 01, 02, 05, 08, 10, 11, 12, 14 and 15).
--
--  1. profiles gains unique (id, username) (the target of the provenance
--     foreign keys), accepts_text_messages, favorites_visibility (replaces
--     shows_favorites), terms_version and terms_accepted_at. Clients read only
--     id, username, display_name and accepts_text_messages; their own private
--     fields come from public.my_account(). Display names and new usernames
--     pass the word filter (QR003). A deleted profile's username is retired
--     for good.
--  2. Terms: private.current_terms_version(), public.accept_terms(version) and
--     private.has_accepted_terms(). Friend requests and accepts need accepted
--     terms and no suspension (the policies, plus friendships_check_terms so a
--     caller without terms gets one answer whatever the target).
--  3. private.suspensions (the founder suspends from the SQL editor; the
--     suspend function itself comes with posts and playlists in migration
--     20261030030400) and private.caller_is_suspended().
--  4. The word filter: private.blocked_terms (ships empty; the founder fills
--     it), kept as one pattern (private.blocked_term_pattern), matched against
--     folded text (private.filter_fold: look-alike letters, accents and
--     invisible characters do not get past it), private.has_blocked_term(text)
--     and QR003. The private Library is never filtered.
--  5. private.can_publish(): terms accepted, not suspended and an Apple
--     identity linked (private.user_can_publish, which the stranger read paths
--     later ask about an item's owner). False for everyone until Sign in with
--     Apple ships.
--  6. quotes gains the creator and edited-from pairs (composite foreign keys to
--     profiles (id, username), on delete set null). The server owns them and
--     origin: a direct insert may say manual or pasted only and makes the
--     caller the creator; an Undo re-insert takes back its provenance from a
--     one-day tombstone (new wording on Undo follows the edit rule); changing
--     another person's wording makes you the creator and them "edited from".
--     Insert and update become column grants. Tombstones: never replaced by
--     someone re-using the id, at most 200 per owner, purged daily (pg_cron
--     job purge-quote-tombstones), and a deleted account's name leaves them.
--     Quotes typed before choosing a username are credited when the profile
--     arrives. A server copy of a Quoted Catalog wording (a catalog_quotes row
--     that is not withdrawn: what quotes_set_verified seals) keeps no creator.
--  7. public.add_catalog_quotes and public.save_from_favorite: the only ways to
--     put a catalog quote or a friend's favorite in your Library. Catalog ids
--     are integers (20261028120000_catalog_corpus); only live rows are
--     offered, and a starter keeps origin starter while any other catalog row
--     gets origin catalog.
--  8. friend_favorites reads favorites_visibility, returns the creator and
--     edited-from usernames (null for verified quotes), skips unverified
--     favorites that hold a blocked term, and shows nothing of a suspended
--     account.
--  9. Accepted friendships are capped at 150 per person (QR002), checked after
--     the policies, so a refused insert tells nothing about anyone's count.
--
-- Existing rows: favorites_visibility is 'friends' where shows_favorites was
-- on, else 'private'. Quotes get a creator by origin (manual or pasted: the
-- owner; starter or catalog still verified: none; starter or catalog no longer
-- verified: the owner; shared: none, "Added by a person") without moving
-- updated_at. Nobody has
-- accepted terms yet, so every account sees the terms sheet before its next
-- friend request or accept.

-- ---------------------------------------------------------------------------
-- 1. The word filter (used by the profile guard below)
-- ---------------------------------------------------------------------------

-- Lowercase words or phrases: letters, digits, spaces, apostrophes and
-- hyphens, starting and ending with a letter or digit. No regex
-- metacharacters, so a term can be pasted into a pattern as it is.
create table private.blocked_terms (
  term text not null,
  added_at timestamptz not null default now(),
  constraint blocked_terms_pkey primary key (term),
  constraint blocked_terms_term_format check (term ~ '^[a-z0-9]([a-z0-9 ''-]*[a-z0-9])?$'),
  constraint blocked_terms_term_length check (char_length(term) between 2 and 60)
);
comment on table private.blocked_terms is
  'Words and phrases refused (QR003) in text other people can see: display names, new usernames, and later captions, messages and playlist titles. Ships empty; the founder adds terms in the SQL editor. Never applied to the private Library.';
revoke all on table private.blocked_terms from public, anon, authenticated, service_role;

-- The whole list as one regular expression, so a check is one match however
-- long the list grows (Postgres keeps only 32 compiled patterns, so one
-- pattern per term would be recompiled on every call past 32 terms). Rebuilt
-- by trigger blocked_terms_build_pattern whenever the list changes; no row
-- while the list is empty. Inside a term, each run of spaces, hyphens and
-- apostrophes matches any run of non-alphanumeric characters, or none, so
-- "heck no" also catches "heck  no", "heck-no", "heck\nno" and "heckno".
create table private.blocked_term_pattern (
  id boolean not null default true,
  pattern text not null,
  constraint blocked_term_pattern_pkey primary key (id),
  constraint blocked_term_pattern_single_row check (id)
);
comment on table private.blocked_term_pattern is
  'One row: private.blocked_terms as a single regular expression for private.has_blocked_term. Server-owned (trigger blocked_terms_build_pattern); no row while the list is empty.';
revoke all on table private.blocked_term_pattern from public, anon, authenticated, service_role;

create function private.blocked_terms_build_pattern()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  delete from private.blocked_term_pattern;
  insert into private.blocked_term_pattern (pattern)
  select '(^|[^[:alnum:]])('
         || string_agg(regexp_replace(t.term, '[ ''-]+', '[^[:alnum:]]*', 'g'), '|' order by t.term)
         || ')($|[^[:alnum:]])'
  from private.blocked_terms t
  having count(*) > 0;
  return null;
end;
$$;
revoke all on function private.blocked_terms_build_pattern() from public, anon, authenticated;

create trigger blocked_terms_build_pattern
  after insert or update or delete or truncate on private.blocked_terms
  for each statement execute function private.blocked_terms_build_pattern();

-- The text as the word filter reads it, so look-alike spellings of a term
-- match it: compatibility forms folded (NFKD: fullwidth and styled letters,
-- ligatures), lowercased, accents and other combining marks and invisible
-- format characters removed (soft hyphen, zero-width space and joiners, word
-- joiner, bidirectional marks, variation selectors, tags, Hangul fillers),
-- and the common Cyrillic, Greek and Latin look-alikes of a to y turned into
-- those letters. Only for matching: the stored text never changes. Plain
-- ASCII text (one byte per character) is only lowercased: nothing else would
-- change it, and the live views fold every item they show.
create function private.filter_fold(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when octet_length(p_text) = char_length(p_text) then lower(p_text)
    else translate(
      regexp_replace(
        lower(normalize(p_text, nfkd)),
        '[\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f'
          || '\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e'
          || '\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0\U000e0000-\U000e007f\U000e0100-\U000e01ef]',
        '', 'g'),
      -- Cyrillic: a e h i j k l o p c y x s d q w y; Greek: a e n i k v o p t u x y w;
      -- Latin: dotless i, dotless j, alpha, script g, iota.
      U&'\0430\0435\04bb\0456\0458\043a\04cf\043e\0440\0441\0443\0445\0455\0501\051b\051d\04af'
        || U&'\03b1\03b5\03b7\03b9\03ba\03bd\03bf\03c1\03c4\03c5\03c7\03b3\03c9'
        || U&'\0131\0237\0251\0261\0269',
      'aehijkl' || 'opcyxsdqwy'
        || 'aenikvoptuxyw'
        || 'ijagi')
  end
$$;
comment on function private.filter_fold(text) is
  'The text as private.has_blocked_term reads it: NFKD, lowercase, no combining marks or invisible format characters, and common look-alike letters folded to a to z.';
-- Only private.has_blocked_term (SECURITY DEFINER) calls it.
revoke all on function private.filter_fold(text) from public, anon, authenticated, service_role;

-- True when any blocked term occurs in the folded text as a whole word or
-- phrase (not inside a longer word). Null text is false, and so is any text
-- while the list is empty. SECURITY DEFINER because no API role can read the
-- list.
create function private.has_blocked_term(p_text text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_text is not null
    and exists (
      select 1
      from private.blocked_term_pattern bp
      where private.filter_fold(p_text) ~ bp.pattern
    )
$$;
comment on function private.has_blocked_term(text) is
  'True when the text (folded by private.filter_fold) contains a private.blocked_terms entry as a whole word or phrase. Used by the QR003 checks and the live views.';
revoke all on function private.has_blocked_term(text) from public, anon;
grant execute on function private.has_blocked_term(text) to authenticated, service_role;

-- Raises QR003 when any of the texts holds a blocked term. SECURITY INVOKER;
-- called by trigger functions, which run as the writing role.
create function private.assert_allowed_text(variadic p_texts text[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from unnest(p_texts) t where private.has_blocked_term(t)) then
    raise exception 'Quoted doesn''t allow some words in posts and messages.'
      using errcode = 'QR003', hint = 'Change the wording and try again.';
  end if;
end;
$$;
comment on function private.assert_allowed_text(text[]) is
  'Raises QR003 when any argument contains a blocked term (private.has_blocked_term).';
revoke all on function private.assert_allowed_text(text[]) from public, anon;
grant execute on function private.assert_allowed_text(text[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Retired usernames
-- ---------------------------------------------------------------------------
create table private.retired_usernames (
  username text not null,
  retired_at timestamptz not null default now(),
  constraint retired_usernames_pkey primary key (username)
);
comment on table private.retired_usernames is
  'Usernames of deleted profiles. No client can claim them again (profiles_guard_server_columns, is_username_available), so an old "Added by @name" never points to a new person.';
revoke all on table private.retired_usernames from public, anon, authenticated, service_role;

-- SECURITY DEFINER: the profile guard runs as the client, who cannot read the
-- table. It answers one yes or no, the same one is_username_available gives.
create function private.is_retired_username(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.retired_usernames r where r.username = lower(p_username))
$$;
comment on function private.is_retired_username(text) is
  'True when the username belonged to a deleted profile.';
revoke all on function private.is_retired_username(text) from public, anon, service_role;
grant execute on function private.is_retired_username(text) to authenticated;

-- Every deleted profile (account deletion, the purge, the founder) retires its
-- username. SECURITY DEFINER: the table has no API grants.
create function private.profiles_retire_username()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.username is not null then
    insert into private.retired_usernames (username)
    values (old.username)
    on conflict (username) do nothing;
  end if;
  return null;
end;
$$;
revoke all on function private.profiles_retire_username() from public, anon, authenticated;

create trigger profiles_retire_username
  after delete on public.profiles
  for each row execute function private.profiles_retire_username();

-- False for a reserved, retired or taken name, or one that fails the format
-- after normalizing. Replaces the version from 20261021090000 (grants kept).
create or replace function private.is_username_available(p_username text)
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
      and not private.is_retired_username(n.name)
      and not exists (select 1 from public.profiles p where p.username = n.name),
    false
  )
  from (select private.normalize_username(p_username) as name) n
$$;

comment on function public.is_username_available(text) is
  'Whether a new profile could take this username: false when reserved, retired, taken or not ^[a-z0-9_.]{3,20}$ after normalizing. SECURITY INVOKER wrapper over private.is_username_available.';

-- ---------------------------------------------------------------------------
-- 3. profiles: new columns, favorites_visibility, terms
-- ---------------------------------------------------------------------------
alter table public.profiles
  add constraint profiles_id_username_key unique (id, username),
  add column accepts_text_messages boolean not null default true,
  add column favorites_visibility text not null default 'private',
  add column terms_version smallint,
  add column terms_accepted_at timestamptz,
  add constraint profiles_favorites_visibility_valid check (favorites_visibility in ('private', 'friends')),
  add constraint profiles_terms_pair_valid check ((terms_version is null) = (terms_accepted_at is null));

comment on column public.profiles.accepts_text_messages is
  '"Friends can text me". Off stops text messages to this person; quotes and playlists still arrive. Readable by anyone who can read the profile.';
comment on column public.profiles.favorites_visibility is
  'Who may see this user''s favorites: private (default) or friends (public.friend_favorites). Own-only: clients read it through public.my_account().';
comment on column public.profiles.terms_version is
  'The Terms of use version this user accepted. Server-owned (trigger profiles_guard_server_columns); set only by public.accept_terms. Own-only: read through public.my_account().';
comment on column public.profiles.terms_accepted_at is
  'When the user accepted terms_version. Server-owned (trigger profiles_guard_server_columns); set only by public.accept_terms.';

update public.profiles set favorites_visibility = 'friends' where shows_favorites;

-- friend_favorites read shows_favorites; both are recreated in section 9.
drop function public.friend_favorites(uuid);
drop function private.friend_favorites(uuid);
alter table public.profiles drop column shows_favorites;

-- Clients read only the public face of a profile. Their own private fields
-- (last_active_at stays server-only) come from public.my_account().
revoke select, insert, update on table public.profiles from authenticated;
grant select (id, username, display_name, accepts_text_messages) on table public.profiles to authenticated;
grant insert (id, username, display_name) on table public.profiles to authenticated;
grant update (display_name, accepts_text_messages, favorites_visibility) on table public.profiles to authenticated;

-- Clients (anything that is not postgres, the secret key or supabase_admin)
-- cannot claim a reserved or retired username, cannot use a blocked term in
-- a new username or a display name (QR003), and cannot write last_active_at,
-- purge_exempt or the terms columns: on insert they become now(), false and
-- null, on update they keep their stored values. The column grants already
-- refuse those columns; this guard is the second line. SECURITY INVOKER on
-- purpose: current_user is the role writing the row, which is postgres inside
-- the SECURITY DEFINER functions (touch_activity, accept_terms). An update
-- checks the display name only when it changes, so a name that a later list
-- catches never stops someone from changing their privacy settings.
create or replace function private.profiles_guard_server_columns()
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
    if private.is_reserved_username(new.username) or private.is_retired_username(new.username) then
      raise exception 'username "%" is reserved', new.username
        using errcode = 'unique_violation',
              constraint = 'profiles_username_reserved',
              schema = 'public',
              table = 'profiles',
              column = 'username';
    end if;
    perform private.assert_allowed_text(new.username, new.display_name);
    new.last_active_at := now();
    new.purge_exempt := false;
    new.terms_version := null;
    new.terms_accepted_at := null;
  else
    if new.display_name is distinct from old.display_name then
      perform private.assert_allowed_text(new.display_name);
    end if;
    new.last_active_at := old.last_active_at;
    new.purge_exempt := old.purge_exempt;
    new.terms_version := old.terms_version;
    new.terms_accepted_at := old.terms_accepted_at;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Terms of use
-- ---------------------------------------------------------------------------

-- Bump this (a new migration with create or replace) when the Terms of use
-- change; everyone then accepts again before their next social write.
create function private.current_terms_version()
returns smallint
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 1::smallint
$$;
comment on function private.current_terms_version() is
  'The Terms of use version users must accept. Bump it when the Terms of use change.';
revoke all on function private.current_terms_version() from public, anon;
grant execute on function private.current_terms_version() to authenticated, service_role;

-- True when the caller's profile has accepted the current terms. SECURITY
-- DEFINER: terms_version is not readable by clients. Answers only for the
-- caller.
create function private.has_accepted_terms()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.terms_version >= private.current_terms_version()
  )
$$;
comment on function private.has_accepted_terms() is
  'True when the caller accepted the current Terms of use. Required by every social write.';
revoke all on function private.has_accepted_terms() from public, anon, service_role;
grant execute on function private.has_accepted_terms() to authenticated;

create function private.accept_terms(p_version smallint)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'Sign in to accept the terms.' using errcode = 'insufficient_privilege';
  end if;
  if p_version is distinct from private.current_terms_version() then
    raise exception 'Unknown terms version.' using errcode = 'invalid_parameter_value';
  end if;
  update public.profiles
     set terms_version = p_version,
         terms_accepted_at = now()
   where id = v_uid;
  if not found then
    raise exception 'Choose a username before accepting the terms.'
      using errcode = 'no_data_found';
  end if;
end;
$$;
revoke all on function private.accept_terms(smallint) from public, anon, service_role;
grant execute on function private.accept_terms(smallint) to authenticated;

create function public.accept_terms(p_version smallint)
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.accept_terms(p_version)
$$;
comment on function public.accept_terms(smallint) is
  'Records that the caller accepted this Terms of use version (it must be the current one, else 22023). SECURITY INVOKER wrapper over private.accept_terms.';
revoke all on function public.accept_terms(smallint) from public, anon, service_role;
grant execute on function public.accept_terms(smallint) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Suspensions
-- ---------------------------------------------------------------------------
create table private.suspensions (
  user_id uuid not null,
  reason text not null,
  suspended_at timestamptz not null default now(),
  constraint suspensions_pkey primary key (user_id),
  constraint suspensions_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade,
  constraint suspensions_reason_length check (char_length(reason) between 1 and 500),
  constraint suspensions_reason_not_blank check (not private.is_blank(reason))
);
comment on table private.suspensions is
  'Suspended accounts: every social write is refused. The founder suspends with private.suspend_user (added with posts and playlists) from the SQL editor.';
revoke all on table private.suspensions from public, anon, authenticated, service_role;

create function private.caller_is_suspended()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.suspensions s where s.user_id = (select auth.uid()))
$$;
comment on function private.caller_is_suspended() is
  'True when the caller''s account is suspended. Answers only for the caller.';
revoke all on function private.caller_is_suspended() from public, anon, service_role;
grant execute on function private.caller_is_suspended() to authenticated;

-- Raises 42501 unless the caller accepted the current terms and is not
-- suspended. Social write triggers call it for clients before their other
-- checks, so a caller without terms gets this one answer whatever the target
-- (a blocked pair must not answer differently from anyone else).
create function private.assert_can_socialize()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not private.has_accepted_terms() then
    raise exception 'Accept the Terms of use first.'
      using errcode = 'insufficient_privilege', hint = 'Read and accept the Terms of use, then try again.';
  end if;
  if private.caller_is_suspended() then
    raise exception 'This account is suspended.'
      using errcode = 'insufficient_privilege', hint = 'Contact support.';
  end if;
end;
$$;
comment on function private.assert_can_socialize() is
  'Raises 42501 unless the caller accepted the current Terms of use and is not suspended.';
revoke all on function private.assert_can_socialize() from public, anon, service_role;
grant execute on function private.assert_can_socialize() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Publishing gate and my_account
-- ---------------------------------------------------------------------------

-- "Anyone with your username" needs this. Public stays off until Sign in with
-- Apple linking ships (founder to-do): every account is anonymous today, so
-- no one has an Apple identity and this is false for everyone. The rule for
-- any one account: it accepted the current terms, is not suspended and has an
-- Apple identity linked. The read paths for strangers (private.post_access,
-- private.playlist_access) ask it about the owner on every read, so a public
-- item stops reaching strangers as soon as its owner no longer qualifies (an
-- unlinked Apple identity, terms that moved on). Called only by SECURITY
-- DEFINER functions: no API role may execute it.
create function private.user_can_publish(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = p_user
        and p.terms_version >= private.current_terms_version()
    )
    and not exists (select 1 from private.suspensions s where s.user_id = p_user)
    and exists (
      select 1
      from auth.identities i
      where i.user_id = p_user
        and i.provider = 'apple'
    )
$$;
comment on function private.user_can_publish(uuid) is
  'True when this account may have public items: current terms accepted, not suspended and a linked Apple identity. Checked when an item becomes public (private.can_publish) and on every stranger''s read.';
revoke all on function private.user_can_publish(uuid) from public, anon, authenticated, service_role;

create function private.can_publish()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.user_can_publish((select auth.uid()))
$$;
comment on function private.can_publish() is
  'True when the caller may make something public: terms accepted, not suspended and a linked Apple identity (private.user_can_publish). Public stays off until Sign in with Apple linking ships (founder to-do).';
revoke all on function private.can_publish() from public, anon, service_role;
grant execute on function private.can_publish() to authenticated;

-- The caller's own account: one row, or none when signed out or without a
-- profile. Never last_active_at or purge_exempt.
create function private.my_account()
returns table (
  id uuid,
  username text,
  display_name text,
  accepts_text_messages boolean,
  favorites_visibility text,
  terms_version smallint,
  terms_accepted_at timestamptz,
  current_terms_version smallint,
  is_suspended boolean,
  can_publish boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name, p.accepts_text_messages, p.favorites_visibility,
         p.terms_version, p.terms_accepted_at, private.current_terms_version(),
         private.caller_is_suspended(), private.can_publish()
  from public.profiles p
  where p.id = (select auth.uid())
$$;
revoke all on function private.my_account() from public, anon, service_role;
grant execute on function private.my_account() to authenticated;

create function public.my_account()
returns table (
  id uuid,
  username text,
  display_name text,
  accepts_text_messages boolean,
  favorites_visibility text,
  terms_version smallint,
  terms_accepted_at timestamptz,
  current_terms_version smallint,
  is_suspended boolean,
  can_publish boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select a.id, a.username, a.display_name, a.accepts_text_messages, a.favorites_visibility,
         a.terms_version, a.terms_accepted_at, a.current_terms_version, a.is_suspended, a.can_publish
  from private.my_account() a
$$;
comment on function public.my_account() is
  'The caller''s own profile with its private fields (favorites_visibility, terms, suspension, can_publish): one row, none when there is no profile. SECURITY INVOKER wrapper over private.my_account.';
revoke all on function public.my_account() from public, anon, service_role;
grant execute on function public.my_account() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. quotes: provenance
-- ---------------------------------------------------------------------------
alter table public.quotes
  add column creator_id uuid,
  add column creator_username text,
  add column edited_from_id uuid,
  add column edited_from_username text,
  add constraint quotes_creator_id_fkey foreign key (creator_id, creator_username)
    references public.profiles (id, username) on delete set null,
  add constraint quotes_edited_from_id_fkey foreign key (edited_from_id, edited_from_username)
    references public.profiles (id, username) on delete set null,
  add constraint quotes_creator_pair_valid check ((creator_id is null) = (creator_username is null)),
  add constraint quotes_edited_from_pair_valid check ((edited_from_id is null) = (edited_from_username is null));

create index quotes_creator_id_creator_username_idx on public.quotes (creator_id, creator_username);
create index quotes_edited_from_id_edited_from_username_idx on public.quotes (edited_from_id, edited_from_username);

comment on column public.quotes.origin is
  'How the quote came into this Library. Server-owned (trigger quotes_set_provenance): a direct insert may say manual or pasted only; starter and catalog are set by public.add_catalog_quotes, and shared by the save functions; an Undo re-insert takes it back from its tombstone. Clients cannot update it.';
comment on column public.quotes.creator_id is
  'Server-owned (trigger quotes_set_provenance / quotes_apply_edit_rule): the account that brought this wording into Quoted ("Added by"). Null for catalog quotes and when unknown or deleted ("Added by a person").';
comment on column public.quotes.creator_username is
  'Server-owned (trigger quotes_set_provenance / quotes_apply_edit_rule): creator_id''s username; the pair is a foreign key to profiles (id, username), so deleting that account clears both.';
comment on column public.quotes.edited_from_id is
  'Server-owned (trigger quotes_set_provenance / quotes_apply_edit_rule): the previous creator, when the owner changed another person''s wording ("Edited from"). Null when the old row was verified.';
comment on column public.quotes.edited_from_username is
  'Server-owned (trigger quotes_set_provenance / quotes_apply_edit_rule): edited_from_id''s username; cleared with it when that account is deleted.';

-- Clients write only these columns. Sending owner_id, origin on update, the
-- provenance pairs, verified_starter_id or a timestamp fails with 42501.
revoke insert, update on table public.quotes from authenticated;
grant insert (id, body, body_format, author, source, origin, rotation_position, is_favorite)
  on table public.quotes to authenticated;
grant update (body, body_format, author, source, rotation_position, is_favorite)
  on table public.quotes to authenticated;

-- Tombstones: the provenance of a quote its owner deleted in the last day, so
-- the app's Undo (a re-insert with the same id) gets back its creator, edited
-- from and origin without the client ever writing them. The wording is kept
-- only as a hash (wording_md5) plus whether the row was verified: a re-insert
-- with different words is treated as "restore, then edit" (the edit rule), so
-- a tombstone can never put someone else's name on new words.
create table private.quote_tombstones (
  id uuid not null,
  owner_id uuid not null,
  origin text not null,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text,
  wording_md5 text not null,
  was_verified boolean not null,
  deleted_at timestamptz not null default now(),
  constraint quote_tombstones_pkey primary key (id),
  constraint quote_tombstones_owner_id_fkey foreign key (owner_id) references auth.users (id) on delete cascade
);
create index quote_tombstones_owner_id_deleted_at_idx on private.quote_tombstones (owner_id, deleted_at);
comment on table private.quote_tombstones is
  'Provenance of quotes their owner deleted in the last day, for Undo (trigger quotes_keep_tombstone, taken by quotes_set_provenance). Holds a hash of the wording, never the text. At most the 200 newest per owner; rows older than a day go on the owner''s next delete and daily (pg_cron job purge-quote-tombstones). A deleted account''s name is cleared from everyone''s rows (trigger profiles_clear_tombstone_names).';
revoke all on table private.quote_tombstones from public, anon, authenticated, service_role;

-- The hash that tells an Undo with the same words from one with new words.
create function private.wording_md5(p_body text, p_author text, p_source text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select md5(jsonb_build_array(p_body, p_author, p_source)::text)
$$;
revoke all on function private.wording_md5(text, text, text) from public, anon, authenticated, service_role;

-- A client deleting their own quote leaves a tombstone. Cascades from account
-- deletion and the purge have no matching auth.uid() (and run inside another
-- trigger), so they skip it. Quote ids are global: a tombstone that belongs to
-- someone else and is less than a day old is never replaced, so re-using
-- another person's deleted id cannot spoil their Undo (that person's id would
-- have to be known). The owner keeps at most their 200 newest tombstones, none
-- older than a day, so deleting in a loop cannot grow the table. SECURITY
-- DEFINER: the table has no API grants.
create function private.quotes_keep_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is distinct from old.owner_id or pg_trigger_depth() > 1 then
    return old;
  end if;

  insert into private.quote_tombstones as t
    (id, owner_id, origin, creator_id, creator_username, edited_from_id, edited_from_username,
     wording_md5, was_verified, deleted_at)
  values
    (old.id, old.owner_id, old.origin, old.creator_id, old.creator_username,
     old.edited_from_id, old.edited_from_username,
     private.wording_md5(old.body, old.author, old.source), old.verified_starter_id is not null, now())
  on conflict (id) do update
    set owner_id = excluded.owner_id,
        origin = excluded.origin,
        creator_id = excluded.creator_id,
        creator_username = excluded.creator_username,
        edited_from_id = excluded.edited_from_id,
        edited_from_username = excluded.edited_from_username,
        wording_md5 = excluded.wording_md5,
        was_verified = excluded.was_verified,
        deleted_at = excluded.deleted_at
    where t.owner_id = excluded.owner_id
       or t.deleted_at <= now() - interval '1 day';

  delete from private.quote_tombstones t
   where t.owner_id = old.owner_id
     and (t.deleted_at <= now() - interval '1 day'
          or t.id in (select x.id
                        from private.quote_tombstones x
                       where x.owner_id = old.owner_id
                       order by x.deleted_at desc, x.id desc
                      offset 200));

  return old;
end;
$$;
revoke all on function private.quotes_keep_tombstone() from public, anon, authenticated;

create trigger quotes_keep_tombstone
  before delete on public.quotes
  for each row execute function private.quotes_keep_tombstone();

-- Deletes tombstones older than a day (Undo is over by then); returns how
-- many. pg_cron runs it daily, so an owner who never deletes again keeps
-- nothing for long. p_now exists for tests; the schedule uses now().
create function private.purge_quote_tombstones(p_now timestamptz default now())
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from private.quote_tombstones t
   where t.deleted_at <= p_now - interval '1 day';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
comment on function private.purge_quote_tombstones(timestamptz) is
  'Deletes quote Undo tombstones older than a day. Scheduled daily by pg_cron (purge-quote-tombstones).';
revoke all on function private.purge_quote_tombstones(timestamptz) from public, anon, authenticated, service_role;

-- Daily at 03:43 UTC, like purge-inactive-anonymous: only where pg_cron
-- exists; otherwise the migration still applies and says so. Check with:
-- select jobname, schedule, command from cron.job;
do $do$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning 'pg_cron is not available, so private.purge_quote_tombstones() is not scheduled';
    return;
  end if;
  begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      create extension pg_cron;
    end if;
    perform cron.schedule(
      'purge-quote-tombstones',
      '43 3 * * *',
      'select private.purge_quote_tombstones()'
    );
  exception when others then
    raise warning 'pg_cron could not schedule purge-quote-tombstones: % (%)', sqlerrm, sqlstate;
  end;
end
$do$;

-- A deleted profile's id and username leave everyone's tombstones, as they
-- leave everyone's quotes (the provenance foreign keys set them null).
-- SECURITY DEFINER: the table has no API grants.
create function private.profiles_clear_tombstone_names()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.quote_tombstones t
     set creator_id = null, creator_username = null
   where t.creator_id = old.id;
  update private.quote_tombstones t
     set edited_from_id = null, edited_from_username = null
   where t.edited_from_id = old.id;
  return null;
end;
$$;
revoke all on function private.profiles_clear_tombstone_names() from public, anon, authenticated;

create trigger profiles_clear_tombstone_names
  after delete on public.profiles
  for each row execute function private.profiles_clear_tombstone_names();

-- Takes (deletes) the caller's own tombstone for this id when it is less than
-- a day old, and returns the provenance the re-inserted row gets:
--   same wording, or the caller created it: the stored origin, creator and
--     edited-from (a pair whose account is gone comes back null);
--   new wording of someone else's quote: the edit rule, as if the caller had
--     restored it and then edited it. The caller becomes the creator, and the
--     old creator "edited from" (nobody when the old row was verified).
-- No row when there is no such tombstone. SECURITY DEFINER; answers only for
-- the caller's own tombstones.
create function private.take_quote_tombstone(p_id uuid, p_body text, p_author text, p_source text)
returns table (
  origin text,
  creator_id uuid,
  creator_username text,
  edited_from_id uuid,
  edited_from_username text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_tomb private.quote_tombstones;
begin
  delete from private.quote_tombstones t
   where t.id = p_id
     and t.owner_id = v_uid
     and t.deleted_at > now() - interval '1 day'
  returning t.* into v_tomb;
  if not found then
    return;
  end if;

  -- A pair whose account is gone becomes null (the foreign key would refuse it).
  if not exists (select 1 from public.profiles p
                 where p.id = v_tomb.creator_id and p.username = v_tomb.creator_username) then
    v_tomb.creator_id := null;
    v_tomb.creator_username := null;
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_tomb.edited_from_id and p.username = v_tomb.edited_from_username) then
    v_tomb.edited_from_id := null;
    v_tomb.edited_from_username := null;
  end if;

  origin := v_tomb.origin;
  if v_tomb.wording_md5 = private.wording_md5(p_body, p_author, p_source)
     or v_tomb.creator_id is not distinct from v_uid then
    creator_id := v_tomb.creator_id;
    creator_username := v_tomb.creator_username;
    edited_from_id := v_tomb.edited_from_id;
    edited_from_username := v_tomb.edited_from_username;
  else
    if v_tomb.was_verified then
      edited_from_id := null;
      edited_from_username := null;
    else
      edited_from_id := v_tomb.creator_id;
      edited_from_username := v_tomb.creator_username;
    end if;
    select p.id, p.username into creator_id, creator_username
      from public.profiles p
     where p.id = v_uid;
  end if;
  return next;
end;
$$;
revoke all on function private.take_quote_tombstone(uuid, text, text, text) from public, anon, service_role;
grant execute on function private.take_quote_tombstone(uuid, text, text, text) to authenticated;

-- BEFORE INSERT. Server path (postgres, the secret key, supabase_admin: the
-- save functions and the dashboard): keeps the given creator and edited-from,
-- nulling a pair whose account no longer exists, and nulling both pairs when
-- the wording is a Quoted Catalog quote (a catalog row that is not withdrawn,
-- matched as private.set_verified_starter does): the copy is verified and shows
-- "Quoted Catalog", so the hidden name of whoever typed or corrected that
-- wording never travels with it. Client path: an Undo re-insert takes its
-- origin and provenance back from the tombstone (with new wording, under the
-- edit rule); anything else must say manual or pasted and is credited to the
-- caller. SECURITY INVOKER so current_user tells the two paths apart.
create function private.quotes_set_provenance()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tomb record;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    if exists (
      select 1
      from public.catalog_quotes c
      where md5(c.body) = md5(new.body)
        and c.status <> 'withdrawn'
        and c.body = new.body
        and c.author is not distinct from new.author
        and c.source is not distinct from new.source
    ) then
      new.creator_id := null;
      new.creator_username := null;
      new.edited_from_id := null;
      new.edited_from_username := null;
    end if;
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
    return new;
  end if;

  select * into v_tomb from private.take_quote_tombstone(new.id, new.body, new.author, new.source);
  if found then
    new.origin := v_tomb.origin;
    new.creator_id := v_tomb.creator_id;
    new.creator_username := v_tomb.creator_username;
    new.edited_from_id := v_tomb.edited_from_id;
    new.edited_from_username := v_tomb.edited_from_username;
    return new;
  end if;

  if new.origin is null or new.origin not in ('manual', 'pasted') then
    raise exception 'origin "%" is set by the server', new.origin
      using errcode = 'insufficient_privilege',
            hint = 'Insert manual or pasted quotes only. Catalog and friends'' quotes are saved through the save functions.';
  end if;

  new.creator_id := null;
  new.creator_username := null;
  select p.id, p.username
    into new.creator_id, new.creator_username
    from public.profiles p
   where p.id = (select auth.uid());
  new.edited_from_id := null;
  new.edited_from_username := null;
  return new;
end;
$$;
revoke all on function private.quotes_set_provenance() from public, anon, authenticated;

create trigger quotes_set_provenance
  before insert on public.quotes
  for each row execute function private.quotes_set_provenance();

-- BEFORE UPDATE, client path only. The server-owned columns keep their stored
-- values. Changing the body, author or source of a quote someone else created
-- (or that has no creator) makes the owner the creator; the previous creator
-- becomes "edited from", or nobody when the old row was verified (a catalog
-- quote). A formatting-only change (body_format) and the owner editing their
-- own quote change nothing. Runs before quotes_set_verified, so
-- old.verified_starter_id is the stored value.
create function private.quotes_apply_edit_rule()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;

  new.origin := old.origin;
  new.creator_id := old.creator_id;
  new.creator_username := old.creator_username;
  new.edited_from_id := old.edited_from_id;
  new.edited_from_username := old.edited_from_username;

  if (new.body, new.author, new.source) is distinct from (old.body, old.author, old.source)
     and old.creator_id is distinct from old.owner_id then
    if old.verified_starter_id is not null then
      new.edited_from_id := null;
      new.edited_from_username := null;
    else
      new.edited_from_id := old.creator_id;
      new.edited_from_username := old.creator_username;
    end if;
    new.creator_id := null;
    new.creator_username := null;
    select p.id, p.username
      into new.creator_id, new.creator_username
      from public.profiles p
     where p.id = old.owner_id;
  end if;
  return new;
end;
$$;
revoke all on function private.quotes_apply_edit_rule() from public, anon, authenticated;

create trigger quotes_apply_edit_rule
  before update on public.quotes
  for each row execute function private.quotes_apply_edit_rule();

-- Backfill, by origin. quotes_set_updated_at is paused so the backfill does
-- not look like an edit.
alter table public.quotes disable trigger quotes_set_updated_at;
update public.quotes q
   set creator_id = p.id,
       creator_username = p.username
  from public.profiles p
 where p.id = q.owner_id
   and (q.origin in ('manual', 'pasted')
        or (q.origin in ('starter', 'catalog') and q.verified_starter_id is null));
alter table public.quotes enable trigger quotes_set_updated_at;

-- The Library works before a username is chosen, so an anonymous account can
-- type quotes (or change a catalog quote's words) while it has no profile to
-- credit: they get no creator. When the profile arrives, those quotes become
-- the owner's, by the same rule as the backfill above: manual or pasted
-- quotes, and starter or catalog quotes that are no longer verified, with no
-- creator and no edited-from. A quote with an edited-from keeps its unknown creator (that
-- may be a deleted account). Their updated_at moves (quotes_set_updated_at).
-- SECURITY DEFINER: clients cannot write the creator.
create function private.profiles_credit_own_quotes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.quotes q
     set creator_id = new.id,
         creator_username = new.username
   where q.owner_id = new.id
     and q.creator_id is null
     and q.edited_from_id is null
     and (q.origin in ('manual', 'pasted')
          or (q.origin in ('starter', 'catalog') and q.verified_starter_id is null));
  return null;
end;
$$;
revoke all on function private.profiles_credit_own_quotes() from public, anon, authenticated;

create trigger profiles_credit_own_quotes
  after insert on public.profiles
  for each row execute function private.profiles_credit_own_quotes();

-- ---------------------------------------------------------------------------
-- 8. Save functions: the only way into a Library with someone else's creator
-- ---------------------------------------------------------------------------

-- For an idempotent retry: the caller's quote with this id, or null when no
-- quote has it. An id that belongs to someone else fails like the primary key.
-- Called only by the save functions (no API role may execute it).
create function private.caller_quote_for_retry(p_id uuid)
returns public.quotes
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.quotes;
begin
  if p_id is null then
    return null;
  end if;
  select q.* into v_row from public.quotes q where q.id = p_id;
  if not found then
    return null;
  end if;
  if v_row.owner_id is distinct from (select auth.uid()) then
    raise exception 'duplicate key value violates unique constraint "quotes_pkey"'
      using errcode = 'unique_violation',
            constraint = 'quotes_pkey',
            schema = 'public',
            table = 'quotes';
  end if;
  return v_row;
end;
$$;
revoke all on function private.caller_quote_for_retry(uuid) from public, anon, authenticated, service_role;

-- Inserts one quote owned by the caller with the given content and
-- provenance. p_in_reminders puts it at the end of the caller's Reminders.
-- The triggers still apply: the 5000 limit, the verified check, and (server
-- path) a provenance pair whose account is gone becomes null. Called only by
-- the save functions.
create function private.insert_caller_quote(
  p_id uuid,
  p_body text,
  p_body_format jsonb,
  p_author text,
  p_source text,
  p_origin text,
  p_creator_id uuid,
  p_creator_username text,
  p_edited_from_id uuid,
  p_edited_from_username text,
  p_in_reminders boolean
)
returns public.quotes
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_position integer;
  v_row public.quotes;
begin
  if v_uid is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_in_reminders, false) then
    -- The same per-owner lock as quotes_enforce_limit and quotes_place_in_rotation.
    perform pg_advisory_xact_lock(hashtextextended('quoted.quotes:' || v_uid::text, 0));
    select coalesce(max(q.rotation_position) + 1, 0)
      into v_position
      from public.quotes q
     where q.owner_id = v_uid;
  end if;

  insert into public.quotes (
    id, owner_id, body, body_format, author, source, origin, rotation_position,
    creator_id, creator_username, edited_from_id, edited_from_username
  )
  values (
    coalesce(p_id, gen_random_uuid()), v_uid, p_body, coalesce(p_body_format, '[]'::jsonb), p_author, p_source,
    p_origin, v_position, p_creator_id, p_creator_username, p_edited_from_id, p_edited_from_username
  )
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function private.insert_caller_quote(uuid, text, jsonb, text, text, text, uuid, text, uuid, text, boolean)
  from public, anon, authenticated, service_role;

-- One quote per catalog id, in array order: origin starter for an onboarding
-- starter and catalog for any other catalog row, no creator ("Quoted
-- Catalog"), verified by the trigger. Only live rows are offered (retired and
-- withdrawn ones are not: 23503, like an unknown id), so a batch quote
-- (id > 60) is saved as readily as a starter. p_ids gives the client's ids
-- (one per catalog id) so a retry returns the quotes it already made.
-- p_in_reminders appends them to the Reminders in order.
create function private.add_catalog_quotes(
  p_starter_ids integer[],
  p_ids uuid[] default null,
  p_in_reminders boolean default false
)
returns setof public.quotes
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer := coalesce(cardinality(p_starter_ids), 0);
  v_catalog public.catalog_quotes;
  v_existing public.quotes;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;
  if p_ids is not null and cardinality(p_ids) <> v_count then
    raise exception 'p_ids must have one id per catalog id.' using errcode = 'invalid_parameter_value';
  end if;

  for i in 1 .. v_count loop
    v_existing := private.caller_quote_for_retry(p_ids[i]);
    if v_existing.id is not null then
      return next v_existing;
      continue;
    end if;

    select c.* into v_catalog
      from public.catalog_quotes c
     where c.id = p_starter_ids[i]
       and c.status = 'live';
    if not found then
      raise exception 'catalog quote % does not exist', coalesce(p_starter_ids[i]::text, 'null')
        using errcode = 'foreign_key_violation';
    end if;

    return next private.insert_caller_quote(
      p_ids[i], v_catalog.body, v_catalog.body_format, v_catalog.author, v_catalog.source,
      case when v_catalog.is_starter then 'starter' else 'catalog' end,
      null, null, null, null, p_in_reminders
    );
  end loop;
  return;
end;
$$;
revoke all on function private.add_catalog_quotes(integer[], uuid[], boolean) from public, anon, service_role;
grant execute on function private.add_catalog_quotes(integer[], uuid[], boolean) to authenticated;

create function public.add_catalog_quotes(
  p_starter_ids integer[],
  p_ids uuid[] default null,
  p_in_reminders boolean default false
)
returns setof public.quotes
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.add_catalog_quotes(p_starter_ids, p_ids, p_in_reminders)
$$;
comment on function public.add_catalog_quotes(integer[], uuid[], boolean) is
  'Saves live Quoted Catalog quotes (catalog_quotes ids) to the caller''s Library (origin starter for a starter, catalog otherwise; no creator), in order; p_ids makes a retry return the same rows; p_in_reminders appends them to the Reminders. Unknown or not live catalog id: 23503. SECURITY INVOKER wrapper over private.add_catalog_quotes.';
revoke all on function public.add_catalog_quotes(integer[], uuid[], boolean) from public, anon, service_role;
grant execute on function public.add_catalog_quotes(integer[], uuid[], boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. friend_favorites and save_from_favorite
-- ---------------------------------------------------------------------------

-- A friend's favorites: at most 100, newest first. Empty unless the caller and
-- p_user are accepted friends, neither has blocked the other, p_user's
-- favorites_visibility is 'friends' and p_user is not suspended (a suspended
-- account's items others can see are held). Unverified favorites holding a blocked
-- term are skipped. The creator and edited-from usernames are null for
-- verified quotes ("Quoted Catalog"). SECURITY DEFINER to read past the
-- owner-only quotes policy; it answers only for that one friend and returns
-- only these columns. id is md5(quote id, viewer) as a uuid: stable for one
-- viewer, different for each, and never the quote's primary key.
create function private.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id integer,
  creator_username text,
  edited_from_username text,
  favorited_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select md5(q.id::text || ':' || (select auth.uid())::text)::uuid,
         q.body, q.body_format, q.author, q.source, q.verified_starter_id,
         case when q.verified_starter_id is null then q.creator_username end,
         case when q.verified_starter_id is null then q.edited_from_username end,
         q.favorited_at
  from public.quotes q
  join public.profiles p on p.id = q.owner_id
  where (select auth.uid()) is not null
    and q.owner_id = p_user
    and p_user <> (select auth.uid())
    and q.is_favorite
    and p.favorites_visibility = 'friends'
    and not exists (select 1 from private.suspensions s where s.user_id = p_user)
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
    and (
      q.verified_starter_id is not null
      or not private.has_blocked_term(q.body || ' ' || coalesce(q.author, '') || ' ' || coalesce(q.source, ''))
    )
  order by q.favorited_at desc, q.id
  limit 100
$$;

revoke all on function private.friend_favorites(uuid) from public, anon, service_role;
-- The public wrapper and private.save_from_favorite run it; the private
-- schema is not exposed by the Data API.
grant execute on function private.friend_favorites(uuid) to authenticated;

create function public.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id integer,
  creator_username text,
  edited_from_username text,
  favorited_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select f.id, f.body, f.body_format, f.author, f.source, f.verified_starter_id,
         f.creator_username, f.edited_from_username, f.favorited_at
  from private.friend_favorites(p_user) f
$$;
comment on function public.friend_favorites(uuid) is
  'An accepted friend''s favorite quotes (at most 100, newest first) when their favorites_visibility is friends and they are not suspended; empty otherwise. Creator usernames are null for verified quotes. SECURITY INVOKER wrapper over private.friend_favorites.';

revoke all on function public.friend_favorites(uuid) from public, anon, service_role;
grant execute on function public.friend_favorites(uuid) to authenticated;

-- Saves one of a friend's favorites (p_handle from friend_favorites) to the
-- caller's Library: origin shared, the source's text and its creator and
-- edited-from (never the friend, unless they are the creator). Refused with
-- 42501, the same answer for every reason, unless friend_favorites would
-- return that handle to the caller right now. A p_id the caller already owns
-- returns that quote unchanged (an idempotent retry).
create function private.save_from_favorite(
  p_friend uuid,
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
  v_source public.quotes;
begin
  if v_uid is null then
    raise exception 'Sign in to save quotes.' using errcode = 'insufficient_privilege';
  end if;

  v_existing := private.caller_quote_for_retry(p_id);
  if v_existing.id is not null then
    return v_existing;
  end if;

  if not exists (select 1 from private.friend_favorites(p_friend) f where f.id = p_handle) then
    raise exception 'This quote is not available.' using errcode = 'insufficient_privilege';
  end if;

  select q.* into v_source
    from public.quotes q
   where q.owner_id = p_friend
     and q.is_favorite
     and md5(q.id::text || ':' || v_uid::text)::uuid = p_handle;
  if not found then
    raise exception 'This quote is not available.' using errcode = 'insufficient_privilege';
  end if;

  return private.insert_caller_quote(
    p_id, v_source.body, v_source.body_format, v_source.author, v_source.source, 'shared',
    v_source.creator_id, v_source.creator_username, v_source.edited_from_id, v_source.edited_from_username,
    p_in_reminders
  );
end;
$$;
revoke all on function private.save_from_favorite(uuid, uuid, uuid, boolean) from public, anon, service_role;
grant execute on function private.save_from_favorite(uuid, uuid, uuid, boolean) to authenticated;

create function public.save_from_favorite(
  p_friend uuid,
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
  select * from private.save_from_favorite(p_friend, p_handle, p_id, p_in_reminders)
$$;
comment on function public.save_from_favorite(uuid, uuid, uuid, boolean) is
  'Saves a friend''s favorite (its friend_favorites handle) to the caller''s Library with origin shared and the original creator. 42501 unless friend_favorites shows it to the caller. SECURITY INVOKER wrapper over private.save_from_favorite.';
revoke all on function public.save_from_favorite(uuid, uuid, uuid, boolean) from public, anon, service_role;
grant execute on function public.save_from_favorite(uuid, uuid, uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Friendships: terms, suspension and the 150-friend cap
-- ---------------------------------------------------------------------------
drop policy "friendships: request as yourself, pending, not blocked" on public.friendships;
create policy "friendships: request as yourself, pending, not blocked, terms"
  on public.friendships for insert to authenticated
  with check (
    requester_id = (select auth.uid())
    and status = 'pending'
    and not private.is_blocked_pair(requester_id, addressee_id)
    and (select private.has_accepted_terms())
    and not (select private.caller_is_suspended())
  );

-- Only the addressee, only pending -> accepted, with accepted terms and no
-- suspension. Column grants limit the writable columns to status (and
-- responded_at, which the trigger overrides).
drop policy "friendships: addressee accepts a pending request" on public.friendships;
create policy "friendships: addressee accepts a pending request, with terms"
  on public.friendships for update to authenticated
  using (addressee_id = (select auth.uid()) and status = 'pending')
  with check (
    addressee_id = (select auth.uid())
    and status = 'accepted'
    and (select private.has_accepted_terms())
    and not (select private.caller_is_suspended())
  );

-- The policies above are the rule. This BEFORE trigger (it sorts before
-- friendships_enforce_limits; the friend cap runs after the row is written)
-- only makes a client without terms, or a suspended one, fail first and the
-- same way for every target: otherwise a request to a blocked pair (23503
-- from friendships_enforce_limits) would answer differently from one to
-- anyone else (42501 from the policy). SECURITY INVOKER so current_user tells
-- clients apart.
create function private.friendships_check_terms()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;
  perform private.assert_can_socialize();
  return new;
end;
$$;
revoke all on function private.friendships_check_terms() from public, anon, authenticated;

create trigger friendships_check_terms
  before insert or update of status on public.friendships
  for each row execute function private.friendships_check_terms();

-- Each person keeps at most 150 accepted friends. Checked whenever a row
-- becomes accepted, for every role. AFTER the row is written, so the policies
-- have already refused a client's row they do not allow: a client cannot use
-- an insert the policy refuses (status accepted) to learn whether someone
-- has 150 friends. SECURITY DEFINER: the other party's friendships are not
-- readable by the caller, and this guards no client column. Locks both people
-- (in a fixed order, so two accepts cannot deadlock), and counts each one's
-- accepted rows explicitly, not counting this row.
create function private.friendships_enforce_friend_cap()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_party uuid;
begin
  if new.status is distinct from 'accepted' or (tg_op = 'UPDATE' and old.status = 'accepted') then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('quoted.friends:' || least(new.requester_id, new.addressee_id)::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('quoted.friends:' || greatest(new.requester_id, new.addressee_id)::text, 0));

  foreach v_party in array array[new.requester_id, new.addressee_id] loop
    if (select count(*) from (
          select 1
          from public.friendships f
          where (f.requester_id = v_party or f.addressee_id = v_party)
            and f.status = 'accepted'
            and f.id <> new.id
          limit 150) accepted) >= 150 then
      raise exception 'Quoted keeps circles to 150 friends.'
        using errcode = 'QR002', hint = 'Remove a friend first.';
    end if;
  end loop;
  return null;
end;
$$;
revoke all on function private.friendships_enforce_friend_cap() from public, anon, authenticated;

create trigger friendships_enforce_friend_cap
  after insert or update of status on public.friendships
  for each row execute function private.friendships_enforce_friend_cap();
