-- GlucOS forecast accuracy: every forecast the apps showed (at most one per 15 minutes per
-- device), with the reading that followed at each checked horizon. The apps keep the same log on
-- the device (Sources/Engine/ForecastLedger.swift) and send each forecast once it's settled.
-- See docs/ForecastAccuracy.md.
--
-- Like the logbook, rows belong to the signed-in Supabase user (the LibreLinkUp-backed sync
-- session) and row-level security keeps each user to their own. Devices reach the table only
-- through `public.forecast_push`, which runs with the caller's rights.

create table if not exists glucos.forecast_checks (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id uuid not null,
  issued_at timestamptz not null,
  received_at timestamptz not null default now(),
  device text not null check (length(device) <= 32),
  -- trend or trendInsulinCarbs.
  basis text not null check (basis ~ '^[A-Za-z]{1,32}$'),
  start_mgdl double precision not null,
  trend_per_minute double precision not null,
  -- [{minutes, mgdl, lower, upper, actual, after_log}], one per checked horizon.
  points jsonb not null check (jsonb_typeof(points) = 'array' and pg_column_size(points) <= 8192),
  limitations text[] not null default '{}',
  calibrated boolean not null,
  tuned boolean not null,
  morning boolean not null,
  primary key (user_id, id)
);

create index if not exists forecast_checks_issued on glucos.forecast_checks (user_id, issued_at desc);

alter table glucos.forecast_checks enable row level security;

drop policy if exists "own rows: read" on glucos.forecast_checks;
drop policy if exists "own rows: add" on glucos.forecast_checks;
drop policy if exists "own rows: change" on glucos.forecast_checks;
create policy "own rows: read" on glucos.forecast_checks for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own rows: add" on glucos.forecast_checks for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "own rows: change" on glucos.forecast_checks for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update on glucos.forecast_checks to authenticated;

-- Push: stores the given forecasts (sending one again replaces it). Returns how many it took.
create or replace function public.forecast_push(entries jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  n integer;
begin
  if uid is null then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  if jsonb_typeof(entries) <> 'array' or jsonb_array_length(entries) > 500 then
    raise exception 'entries must be an array of at most 500' using errcode = '22023';
  end if;

  insert into glucos.forecast_checks as f
    (user_id, id, issued_at, device, basis, start_mgdl, trend_per_minute, points, limitations, calibrated, tuned, morning)
  select distinct on (e.id)
         uid, e.id, to_timestamp(e.issued), left(e.device, 32), e.basis, e.start_mgdl, e.trend,
         e.points, coalesce(array(select jsonb_array_elements_text(e.limitations)), '{}'),
         coalesce(e.calibrated, false), coalesce(e.tuned, false), coalesce(e.morning, false)
  from jsonb_to_recordset(entries)
       as e(id uuid, issued double precision, device text, basis text, start_mgdl double precision,
            trend double precision, points jsonb, limitations jsonb, calibrated boolean, tuned boolean, morning boolean)
  where e.id is not null and e.issued is not null and e.device is not null and e.basis is not null
    and e.start_mgdl is not null and e.trend is not null and jsonb_typeof(e.points) = 'array'
    and (e.limitations is null or jsonb_typeof(e.limitations) = 'array')
  order by e.id
  on conflict (user_id, id) do update
    set points = excluded.points,
        received_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.forecast_push(jsonb) from public, anon;
grant execute on function public.forecast_push(jsonb) to authenticated;

-- One row per scored point.
create or replace view glucos.forecast_points with (security_invoker = true) as
select
  f.user_id, f.id, f.device, f.basis, f.issued_at, f.issued_at at time zone 'Australia/Perth' as issued_perth,
  f.calibrated, f.tuned, f.morning, f.limitations, f.start_mgdl,
  (p ->> 'minutes')::int as minutes,
  (p ->> 'mgdl')::float8 as predicted,
  (p ->> 'lower')::float8 as lower,
  (p ->> 'upper')::float8 as upper,
  (p ->> 'actual')::float8 as actual,
  coalesce((p ->> 'after_log')::boolean, false) as after_log
from glucos.forecast_checks f
cross join lateral jsonb_array_elements(f.points) p
where p ? 'actual' and jsonb_typeof(p -> 'actual') = 'number';

-- Accuracy by week (Perth), device, basis and horizon. `clean` is nothing logged in between, the
-- forecast's own job; the rest include food or insulin that came after the forecast.
create or replace view glucos.forecast_accuracy with (security_invoker = true) as
select
  user_id,
  date_trunc('week', issued_perth)::date as week,
  device, basis, minutes, not after_log as clean,
  count(*) as checks,
  round(avg(abs(actual - predicted))::numeric, 1) as mae_mgdl,
  round(avg(abs(actual - start_mgdl))::numeric, 1) as no_change_mae_mgdl,
  round(avg(actual - predicted)::numeric, 1) as bias_mgdl,
  round(100.0 * avg(case when actual between lower and upper then 1 else 0 end), 0) as inside_range_pct,
  round(100.0 * avg(case when abs(actual - predicted) <= greatest(15, 0.15 * actual) then 1 else 0 end), 0) as within_15_pct
from glucos.forecast_points
group by user_id, week, device, basis, minutes, not after_log;

revoke all on glucos.forecast_points, glucos.forecast_accuracy from public, anon;
grant select on glucos.forecast_points, glucos.forecast_accuracy to authenticated;
