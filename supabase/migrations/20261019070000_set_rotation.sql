-- public.set_rotation: writes the caller's Rotation order in one statement.
-- Contract: docs/system-design.md section 3 (quotes) and section 4 (Rotation
-- writes). Tests: supabase/tests/database/09_set_rotation.test.sql.
--
-- Replaces the client-side upsert that carried every Rotation quote's content
-- (from the app's copy) to change one integer per row. That upsert grew with
-- the Rotation, could overwrite an edit made on another device with a stale
-- copy, and re-inserted a quote deleted elsewhere (which the client then had
-- to delete again). This function takes only ids:
--
--   ordered  the Rotation in order. The caller's quotes among them get
--            positions 0..n-1 in that order (first occurrence wins; ids that
--            are not the caller's, or no longer exist, are skipped without
--            leaving a gap).
--   removed  quotes that leave the Rotation (rotation_position = null). An id
--            that is also in `ordered` stays in the Rotation.
--
-- Quotes in neither list are not touched. It returns the rows it updated.
--
-- SECURITY INVOKER: it runs as the caller, so the quotes RLS policies (owner
-- only) and the table grants apply exactly as for a direct UPDATE. Nothing is
-- inserted, so a quote deleted elsewhere is never resurrected, and no content
-- column is written. updated_at moves through the existing trigger.

create function public.set_rotation(ordered uuid[], removed uuid[] default '{}')
returns setof public.quotes
language sql
volatile
security invoker
set search_path = ''
as $$
  with requested as (
    select t.id, min(t.ord) as first_ord
    from unnest(coalesce(ordered, '{}'::uuid[])) with ordinality as t(id, ord)
    where t.id is not null
    group by t.id
  ),
  positioned as (
    -- Number only the caller's existing quotes, so a skipped id leaves no gap.
    select r.id, (row_number() over (order by r.first_ord) - 1)::integer as position
    from requested r
    join public.quotes q on q.id = r.id
    where q.owner_id = (select auth.uid())
  ),
  leaving as (
    select distinct l.id
    from unnest(coalesce(removed, '{}'::uuid[])) as l(id)
    where l.id is not null
      and not exists (select 1 from requested r where r.id = l.id)
  ),
  changes as (
    select id, position from positioned
    union all
    select id, null::integer from leaving
  )
  update public.quotes as q
     set rotation_position = c.position
    from changes c
   where q.id = c.id
     and q.owner_id = (select auth.uid())
  returning q.*
$$;

comment on function public.set_rotation(uuid[], uuid[]) is
  'Sets the caller''s Rotation: `ordered` gets rotation_position 0..n-1 (own quotes only, no gaps), `removed` gets null. Returns the updated rows. SECURITY INVOKER (RLS applies).';

revoke all on function public.set_rotation(uuid[], uuid[]) from public, anon;
grant execute on function public.set_rotation(uuid[], uuid[]) to authenticated, service_role;
