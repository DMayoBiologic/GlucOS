-- Forecast error and range coverage after meals logged with no rapid insulin within 30 minutes
-- either side (docs/ForecastAccuracy.md §101), against the app's own accuracy log.
-- Clean shown 30/60-min points (nothing logged before the reading came in) issued from the meal to
-- 3 h after it. Groups: unbolused = no rapid dose from 30 min before to 30 min after the meal,
-- bolused = one or more. Low treatments are not split out here (scripts/unbolused-meals.py does
-- that, along with double logs and stopping at the next meal or dose).
-- Bias = actual - forecast (+ = the line ran low). Run in the Supabase SQL editor.
with ml as (select (payload->>'timestamp')::float t, (payload->>'carbs')::float g, payload->>'food' food
  from glucos.logbook where not deleted and kind = 'meal'),
ds as (select (payload->>'timestamp')::float t from glucos.logbook
  where not deleted and kind = 'dose' and payload->>'kind' = 'rapid'),
mg as (select ml.*, case when exists (select 1 from ds where abs(ds.t - ml.t) <= 1800)
  then 'bolused' else 'unbolused' end grp from ml),
p as (select extract(epoch from c.issued_at) t, (e->>'minutes')::int m, (e->>'mgdl')::float f,
    (e->>'actual')::float a, (e->>'lower')::float lo, (e->>'upper')::float hi, c.basis
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e
  where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean, false)
    and coalesce(e->>'shown', 'true') = 'true' and (e->>'minutes')::int in (30, 60))
select mg.grp, p.m, to_char(to_timestamp(mg.t) at time zone 'Australia/Perth', 'DD Mon HH24:MI') meal,
  mg.g carbs, left(mg.food, 24) food, count(*) pts, round(avg(p.a - p.f)::numeric, 1) bias,
  round(100 * avg((p.a between p.lo and p.hi)::int)::numeric) inside_pct,
  round(100 * avg((p.a > p.hi)::int)::numeric) above_pct,
  sum((p.basis = 'trendInsulinCarbs')::int) model_pts
from mg join p on p.t between mg.t and mg.t + 10800
group by grouping sets ((mg.grp, p.m), (mg.grp, p.m, mg.t, mg.g, mg.food))
order by mg.grp, p.m, mg.t nulls first;
