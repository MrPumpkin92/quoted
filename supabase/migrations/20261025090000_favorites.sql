-- Favorites, and a friend's profile that shows them.
-- Contract: docs/system-design.md section 3. Tests:
-- supabase/tests/database/15_favorites.test.sql.
--
-- 1. quotes gains is_favorite (the owner's heart) and favorited_at, which a
--    trigger owns: it is now() when a quote becomes a favorite, kept while it
--    stays one, and null otherwise. Whatever a client sends for it is replaced.
-- 2. profiles gains shows_favorites, off by default. Quotes stay private to
--    their owner (the quotes policies are unchanged). Only when the owner turns
--    this on can an accepted friend read the owner's favorites, and only through
--    public.friend_favorites: no other quote, and no column beyond the quote's
--    text, its attribution, its verification and when it was favorited. Its id
--    is a handle for that viewer, not the quote's key, so a friend can't use it
--    to probe or take the row (for example during the owner's Undo).

alter table public.quotes
  add column is_favorite boolean not null default false,
  add column favorited_at timestamptz;

comment on column public.quotes.is_favorite is 'The owner''s heart. Friends can read favorites only through public.friend_favorites, and only when the owner''s profile has shows_favorites.';
comment on column public.quotes.favorited_at is 'Server-owned (trigger quotes_stamp_favorited_at): when the quote became a favorite, else null.';

alter table public.profiles
  add column shows_favorites boolean not null default false;

comment on column public.profiles.shows_favorites is 'Whether accepted friends may see this user''s favorite quotes (public.friend_favorites). Off by default.';

create function private.quotes_stamp_favorited_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_favorite then
    new.favorited_at := case
      when tg_op = 'UPDATE' and old.is_favorite then old.favorited_at
      else now()
    end;
  else
    new.favorited_at := null;
  end if;
  return new;
end;
$$;
revoke all on function private.quotes_stamp_favorited_at() from public, anon, authenticated;

create trigger quotes_stamp_favorited_at
  before insert or update of is_favorite, favorited_at on public.quotes
  for each row execute function private.quotes_stamp_favorited_at();

-- A friend's profile lists favorites newest first.
create index quotes_owner_id_favorited_at_idx on public.quotes (owner_id, favorited_at desc)
  where is_favorite;

-- A friend's favorites: at most 100, newest first. Empty unless the caller and
-- p_user are accepted friends, neither has blocked the other, and p_user has
-- shows_favorites on. SECURITY DEFINER to read past the owner-only quotes
-- policy; it answers only for that one friend and returns only these columns.
-- id is md5(quote id, viewer) as a uuid: stable for one viewer, different for
-- each, and never the quote's primary key.
create function private.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id smallint,
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
-- The public wrapper runs as the caller, so the caller needs EXECUTE here. The
-- private schema is not exposed by the Data API.
grant execute on function private.friend_favorites(uuid) to authenticated;

create function public.friend_favorites(p_user uuid)
returns table (
  id uuid,
  body text,
  body_format jsonb,
  author text,
  source text,
  verified_starter_id smallint,
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
