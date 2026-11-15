-- GlucOS forecast accuracy per app version. Each forecast now carries the version of the app (or
-- the relay) that showed it, so a release's effect on accuracy can be read on its own instead of
-- mixed into a week of older builds. Rows from before this have no version (null).
-- See docs/ForecastAccuracy.md §14.

alter table glucos.forecast_checks
  add column if not exists app_version text check (app_version is null or length(app_version) <= 32);

-- Push: as before, plus app_version. Sending a forecast again keeps the version it was first sent with.
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
    (user_id, id, issued_at, device, basis, start_mgdl, trend_per_minute, points, limitations, calibrated, tuned, morning,
     app_version)
  select distinct on (e.id)
         uid, e.id, to_timestamp(e.issued), left(e.device, 32), e.basis, e.start_mgdl, e.trend,
         e.points, coalesce(array(select jsonb_array_elements_text(e.limitations)), '{}'),
         coalesce(e.calibrated, false), coalesce(e.tuned, false), coalesce(e.morning, false),
         nullif(left(e.app_version, 32), '')
  from jsonb_to_recordset(entries)
       as e(id uuid, issued double precision, device text, basis text, start_mgdl double precision,
            trend double precision, points jsonb, limitations jsonb, calibrated boolean, tuned boolean, morning boolean,
            app_version text)
  where e.id is not null and e.issued is not null and e.device is not null and e.basis is not null
    and e.start_mgdl is not null and e.trend is not null and jsonb_typeof(e.points) = 'array'
    and (e.limitations is null or jsonb_typeof(e.limitations) = 'array')
  order by e.id
  on conflict (user_id, id) do update
    set points = excluded.points,
        app_version = coalesce(f.app_version, excluded.app_version),
        received_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.forecast_push(jsonb) from public, anon;
grant execute on function public.forecast_push(jsonb) to authenticated;

-- One row per scored point, now with the version (appended: a view's columns can only grow at the end).
create or replace view glucos.forecast_points with (security_invoker = true) as
select
  f.user_id, f.id, f.device, f.basis, f.issued_at, f.issued_at at time zone 'Australia/Perth' as issued_perth,
  f.calibrated, f.tuned, f.morning, f.limitations, f.start_mgdl,
  (p ->> 'minutes')::int as minutes,
  (p ->> 'mgdl')::float8 as predicted,
  (p ->> 'lower')::float8 as lower,
  (p ->> 'upper')::float8 as upper,
  (p ->> 'actual')::float8 as actual,
  coalesce((p ->> 'after_log')::boolean, false) as after_log,
  f.app_version
from glucos.forecast_checks f
cross join lateral jsonb_array_elements(f.points) p
where p ? 'actual' and jsonb_typeof(p -> 'actual') = 'number';

-- The Insights card's figures per device and version, over the last 30 days: the same clean
-- 15/30/60-minute points as glucos.forecast_scorecard, so a release can be compared with the one
-- before it. `app_version` null is forecasts from before versions were kept.
create or replace view glucos.forecast_scorecard_by_version with (security_invoker = true) as
select
  user_id,
  device,
  case when device = 'relay' then 'Lock Screen' else device end as shown_on,
  app_version,
  minutes,
  min(issued_at) as first_issued,
  max(issued_at) as last_issued,
  count(*) as checks,
  round(avg(abs(actual - predicted))::numeric, 1) as mae_mgdl,
  round(avg(abs(actual - start_mgdl))::numeric, 1) as no_change_mae_mgdl,
  round((avg(abs(actual - predicted)) / 18.0182)::numeric, 2) as mae_mmol,
  round((avg(abs(actual - start_mgdl)) / 18.0182)::numeric, 2) as no_change_mae_mmol,
  round(100.0 * avg(case when actual between lower and upper then 1 else 0 end), 0) as inside_range_pct,
  count(*) >= 30 as enough_checks
from glucos.forecast_points
where not after_log
  and minutes in (15, 30, 60)
  and issued_at >= now() - interval '30 days'
group by user_id, device, app_version, minutes;

revoke all on glucos.forecast_scorecard_by_version from public, anon;
grant select on glucos.forecast_scorecard_by_version to authenticated;
