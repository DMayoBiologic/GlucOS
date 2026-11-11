-- GlucOS logbook sync: insulin, food, site changes, context tags and presets, shared between the
-- Mac app and the iPhone app.
--
-- Each device keeps its own copy and works offline; it pushes the entries it changed and pulls
-- what changed elsewhere. One row per entry, last writer wins on the device's edit time, and a
-- delete is kept as a tombstone so it reaches the other devices.
--
-- Who: every row belongs to a Supabase Auth user. The `account` edge function signs a device in
-- with its LibreLinkUp login (the account both apps already use), so there's nothing new to set
-- up. Row-level security limits each user to their own rows. The table is in `glucos`, which the
-- Data API doesn't expose; devices reach it only through the two functions in `public` below,
-- which run with the caller's rights, so RLS applies to them too.

create sequence if not exists glucos.logbook_rev;

create table if not exists glucos.logbook (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id uuid not null,
  -- dose, meal, siteChange, context, preset. Free text so a newer app can add kinds.
  kind text not null check (kind ~ '^[A-Za-z]{1,32}$'),
  -- The entry as the apps encode it. Null once deleted.
  payload jsonb check (payload is null or (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 16384)),
  deleted boolean not null default false,
  -- When a device last changed it (that device's clock, capped at a few minutes past the
  -- server's). Decides which edit wins.
  modified_at timestamptz not null,
  -- Server-assigned change counter; devices pull everything above the last one they saw.
  rev bigint not null default nextval('glucos.logbook_rev'),
  device text check (device is null or length(device) <= 64),
  primary key (user_id, id)
);

create index if not exists logbook_user_rev on glucos.logbook (user_id, rev);

alter table glucos.logbook enable row level security;

drop policy if exists "own rows: read" on glucos.logbook;
drop policy if exists "own rows: add" on glucos.logbook;
drop policy if exists "own rows: change" on glucos.logbook;
create policy "own rows: read" on glucos.logbook for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own rows: add" on glucos.logbook for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "own rows: change" on glucos.logbook for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- No delete policy: deletes are tombstones, so every device hears about them.

grant usage on schema glucos to authenticated;
grant select, insert, update on glucos.logbook to authenticated;
grant usage on sequence glucos.logbook_rev to authenticated;

-- Push: upserts the given entries, keeping whichever edit is newer, and returns the highest rev
-- the caller now has. Each entry: {id, kind, payload, deleted, modified (Unix seconds), device}.
create or replace function public.logbook_push(entries jsonb)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  latest bigint;
begin
  if uid is null then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  if jsonb_typeof(entries) <> 'array' or jsonb_array_length(entries) > 500 then
    raise exception 'entries must be an array of at most 500' using errcode = '22023';
  end if;

  insert into glucos.logbook as l (user_id, id, kind, payload, deleted, modified_at, device)
  select distinct on (e.id)
         uid, e.id, e.kind,
         case when e.deleted then null else e.payload end,
         e.deleted,
         least(to_timestamp(e.modified), now() + interval '5 minutes'),
         left(e.device, 64)
  from jsonb_to_recordset(entries)
       as e(id uuid, kind text, payload jsonb, deleted boolean, modified double precision, device text)
  where e.id is not null and e.kind is not null and e.modified is not null and e.deleted is not null
  order by e.id, e.modified desc
  on conflict (user_id, id) do update
    set kind = excluded.kind,
        payload = excluded.payload,
        deleted = excluded.deleted,
        modified_at = excluded.modified_at,
        device = excluded.device,
        rev = nextval('glucos.logbook_rev')
    where l.modified_at < excluded.modified_at;

  select coalesce(max(rev), 0) into latest from glucos.logbook where user_id = uid;
  return latest;
end;
$$;

-- Pull: the caller's entries changed after `since`, oldest change first, at most `max_rows`.
create or replace function public.logbook_pull(since bigint default 0, max_rows integer default 500)
returns table (id uuid, kind text, payload jsonb, deleted boolean, modified double precision, rev bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select l.id, l.kind, l.payload, l.deleted, extract(epoch from l.modified_at)::float8, l.rev
  from glucos.logbook l
  where l.user_id = (select auth.uid()) and l.rev > since
  order by l.rev
  limit least(greatest(max_rows, 1), 1000);
$$;

revoke all on function public.logbook_push(jsonb) from public, anon;
revoke all on function public.logbook_pull(bigint, integer) from public, anon;
grant execute on function public.logbook_push(jsonb) to authenticated;
grant execute on function public.logbook_pull(bigint, integer) to authenticated;
