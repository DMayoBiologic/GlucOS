-- Range coverage in the 2 h after an activity-like fall (docs/ForecastAccuracy.md §108), against the
-- app's own accuracy log. Same definition as scripts/activity-falls.py: a live reading (trend > 0)
-- 80-180, Perth 06:00-22:00, 20-min least-squares slope <= -1 mg/dL/min, no reading above 180 in the
-- 60 min before, no rapid dose in the 3 h before and no meal in the 2 h before. A forecast is "after"
-- when one such reading landed in the 2 h up to its issue time. Clean shown points only (nothing logged
-- before the reading came in). Bias = actual - forecast. Score = width + 10 x distance outside.
-- Run in the Supabase SQL editor.
with r as (select at, mgdl::float g,
    regr_slope(mgdl::float, extract(epoch from at) / 60) over w20 slope,
    max(mgdl) over w60 max60
  from glucos.readings where trend > 0
  window w20 as (order by at range between interval '20 minutes' preceding and current row),
         w60 as (order by at range between interval '60 minutes' preceding and current row)),
logs as (select to_timestamp((payload->>'timestamp')::float) ts, kind from glucos.logbook
  where not deleted and payload->>'timestamp' is not null
    and (kind = 'meal' or (kind = 'dose' and payload->>'kind' = 'rapid'))),
falls as (select at from r
  where g between 80 and 180 and slope <= -1 and max60 <= 180
    and extract(hour from at at time zone 'Australia/Perth') between 6 and 21
    and not exists (select 1 from logs where kind = 'dose' and ts between r.at - interval '3 hours' and r.at)
    and not exists (select 1 from logs where kind = 'meal' and ts between r.at - interval '2 hours' and r.at)),
p as (select c.issued_at t, (e->>'minutes')::int m, (e->>'mgdl')::float f, (e->>'lower')::float lo,
    (e->>'upper')::float hi, (e->>'actual')::float a,
    extract(hour from c.issued_at at time zone 'Australia/Perth') between 6 and 21 awake,
    exists (select 1 from falls where falls.at between c.issued_at - interval '2 hours' and c.issued_at) aft
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e
  where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean, (e->>'afterLog')::boolean, false)
    and coalesce(e->>'shown', 'true') = 'true' and (e->>'minutes')::int in (15, 30, 60))
select m, case when aft then 'after' when awake then 'awake rest' else 'night rest' end grp, count(*) n,
  count(distinct (t at time zone 'Australia/Perth')::date) days,
  round(avg(abs(a - f))::numeric, 1) mae, round(avg(a - f)::numeric, 1) bias,
  round(100 * avg((a between lo and hi)::int)::numeric) inside, round(100 * avg((a < lo)::int)::numeric) below,
  round(100 * avg((a > hi)::int)::numeric) above, round(avg(hi - lo + 10 * greatest(lo - a, a - hi, 0))::numeric, 1) score
from p group by 1, 2 order by 1, 2;
