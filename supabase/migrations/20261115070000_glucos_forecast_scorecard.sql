-- GlucOS forecast scorecard: the numbers on the Insights card ("How close the forecasts were"),
-- per device, for the last 7 days, so they can be checked against what the apps show. Clean
-- points only (nothing logged before the reading), at 15, 30 and 60 minutes, next to assuming no
-- change. Any device that records into glucos.forecast_checks appears, including the push relay's
-- Lock Screen forecasts (device 'relay'). See docs/ForecastAccuracy.md.

create or replace view glucos.forecast_scorecard with (security_invoker = true) as
select
  user_id,
  device,
  case when device = 'relay' then 'Lock Screen' else device end as shown_on,
  minutes,
  count(*) as checks,
  round(avg(abs(actual - predicted))::numeric, 1) as mae_mgdl,
  round(avg(abs(actual - start_mgdl))::numeric, 1) as no_change_mae_mgdl,
  round((avg(abs(actual - predicted)) / 18.0182)::numeric, 2) as mae_mmol,
  round((avg(abs(actual - start_mgdl)) / 18.0182)::numeric, 2) as no_change_mae_mmol,
  round(100.0 * avg(case when actual between lower and upper then 1 else 0 end), 0) as inside_range_pct,
  -- Whether the card would show this horizon (ForecastScorecard.minimumChecks).
  count(*) >= 30 as enough_checks
from glucos.forecast_points
where not after_log
  and minutes in (15, 30, 60)
  and issued_at >= now() - interval '7 days'
group by user_id, device, minutes;

revoke all on glucos.forecast_scorecard from public, anon;
grant select on glucos.forecast_scorecard to authenticated;
