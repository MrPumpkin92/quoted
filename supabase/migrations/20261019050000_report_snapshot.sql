-- Reports keep a copy of the reported content. Contract: docs/system-design.md
-- section 3.
--
-- A block deletes every share between the pair, and reports.share_id is
-- `on delete set null`, so without a copy the reviewer loses what was reported.
-- The snapshot columns hold the share's body, author and source as they were
-- when the report was filed.
--
-- When share_id is set, a BEFORE INSERT trigger copies the snapshot from the
-- share and discards whatever the client sent, so a reporter cannot attach
-- invented content to a real share. When share_id is null (a user report, or a
-- share that was already gone when the report was filed), the client's snapshot
-- is kept as sent: it is the reporter's account of what they saw.
--
-- Grants and RLS policies are unchanged. The table-level select and insert
-- grants to authenticated (and the full grants to service_role) already cover
-- new columns, and the insert policy still pins reporter_id and checks share_id.

alter table public.reports
  add column content_body text,
  add column content_author text,
  add column content_source text,
  add constraint reports_content_body_length check (char_length(content_body) <= 2000),
  add constraint reports_content_author_length check (char_length(content_author) <= 200),
  add constraint reports_content_source_length check (char_length(content_source) <= 200);

comment on column public.reports.content_body is
  'Snapshot of the reported content. Copied from the share by trigger when share_id is set; kept after the share is deleted.';
comment on column public.reports.content_author is
  'Snapshot of the reported share''s author. Copied from the share by trigger when share_id is set.';
comment on column public.reports.content_source is
  'Snapshot of the reported share''s source. Copied from the share by trigger when share_id is set.';

-- SECURITY INVOKER on purpose: the share is read with the reporter's own RLS,
-- so the trigger can only copy content the reporter can already read. If the
-- share is not visible (or does not exist) the snapshot becomes null, and the
-- insert policy or the foreign key then rejects the row anyway.
create function private.reports_snapshot_share()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.share_id is not null then
    -- No matching row sets all three targets to null.
    select s.body, s.author, s.source
      into new.content_body, new.content_author, new.content_source
      from public.shares s
     where s.id = new.share_id;
  end if;
  return new;
end;
$$;
revoke all on function private.reports_snapshot_share() from public, anon, authenticated;

-- Insert only. The foreign key's `on delete set null` is an UPDATE, and it must
-- leave the snapshot alone.
create trigger reports_snapshot_share
  before insert on public.reports
  for each row execute function private.reports_snapshot_share();
