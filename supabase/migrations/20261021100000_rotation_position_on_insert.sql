-- quotes: the server places a new quote in the Rotation.
-- Contract: docs/system-design.md section 3 (quotes). Tests:
-- supabase/tests/database/13_rotation_position.test.sql.
--
-- The app asks for the position after the last Rotation quote it knows of.
-- Its copy can be stale (another device added reminders since the last
-- refresh, or the library had not loaded yet), and the starter and shared
-- saves read the end of the Rotation before a separate insert. Either way two
-- quotes could share a position, and the new one sorted into the middle of
-- the Rotation instead of joining its end.
--
-- Now a requested position that another of the owner's quotes already holds
-- moves to the end of the owner's Rotation (max + 1). A free position is kept,
-- so a restore (Undo of a delete) returns to its place when nothing took it.
-- The trigger takes the same per-owner advisory lock as quotes_enforce_limit,
-- so two concurrent inserts cannot both take the same end position, and is
-- VOLATILE plpgsql, so it sees the rows earlier in the same bulk insert (the
-- starter pack). A row whose id already exists is left alone: an upsert would
-- carry a moved position into its update, and an insert fails on the primary
-- key (the app's idempotent retry).
--
-- SECURITY INVOKER: the caller's RLS shows all of their own quotes, which is
-- every row the position depends on.

create function private.quotes_place_in_rotation()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  if new.rotation_position is null
     or exists (select 1 from public.quotes q where q.id = new.id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quoted.quotes:' || new.owner_id::text, 0));
  if exists (
    select 1 from public.quotes q
    where q.owner_id = new.owner_id and q.rotation_position = new.rotation_position
  ) then
    new.rotation_position := (
      select coalesce(max(q.rotation_position) + 1, 0)
      from public.quotes q
      where q.owner_id = new.owner_id
    );
  end if;
  return new;
end;
$$;
revoke all on function private.quotes_place_in_rotation() from public, anon, authenticated;

create trigger quotes_place_in_rotation
  before insert on public.quotes
  for each row execute function private.quotes_place_in_rotation();
