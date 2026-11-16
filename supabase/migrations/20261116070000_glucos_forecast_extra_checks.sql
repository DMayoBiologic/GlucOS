-- GlucOS forecast checks every 5 minutes. The Mac and iPhone now keep a forecast every 5 minutes
-- while fresh readings come in, not every 15, so a release gets enough checks to judge. The
-- quarter-hour ones (at least 15 minutes after the last such one) are what they always kept; the
-- ones in between arrive with extra = true. The views count both, as the apps' Insights card
-- does. Filter `not extra` for a series spaced as before (to compare with older weeks, or with
-- the relay, which still keeps one per 15 minutes). Older app versions don't send it: false.
-- Forecasts can also now arrive before they settle (once their first hour is scored) and again
-- when they do; the conflict update below already replaces their points.
-- See docs/ForecastAccuracy.md §35.

alter table glucos.forecast_checks
  add column if not exists extra boolean not null default false;

-- Push: as before, plus extra.
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
     app_version, extra)
  select distinct on (e.id)
         uid, e.id, to_timestamp(e.issued), left(e.device, 32), e.basis, e.start_mgdl, e.trend,
         e.points, coalesce(array(select jsonb_array_elements_text(e.limitations)), '{}'),
         coalesce(e.calibrated, false), coalesce(e.tuned, false), coalesce(e.morning, false),
         nullif(left(e.app_version, 32), ''), coalesce(e.extra, false)
  from jsonb_to_recordset(entries)
       as e(id uuid, issued double precision, device text, basis text, start_mgdl double precision,
            trend double precision, points jsonb, limitations jsonb, calibrated boolean, tuned boolean, morning boolean,
            app_version text, extra boolean)
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
