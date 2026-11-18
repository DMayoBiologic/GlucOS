-- Forecast error after small logged meals (docs/ForecastAccuracy.md §83), against the app's own
-- accuracy log. Clean shown 30/60-min points (nothing logged before the reading came in).
-- Groups by the latest non-deleted meal in the 3 h 10 min before issue (the carb curve's reach):
--   small   <= 10 g carbs (0 g included: food logged without carbs)
--   light   10-20 g
--   meal    > 20 g
--   none    no meal in reach
-- Bias = actual - forecast (positive = the reading ended higher than the line). Range as drawn.
-- Period: Perth issue dates in params. Run as is in the Supabase SQL editor.
with params as (select date '2026-11-11' d_from, date '2026-11-18' d_to),
meals as (select to_timestamp((payload->>'timestamp')::float) ts, coalesce((payload->>'carbs')::float, 0) carbs
          from glucos.logbook where not deleted and kind = 'meal' and payload->>'timestamp' is not null),
pts as (select c.issued_at t, to_char(c.issued_at at time zone 'Australia/Perth','MM-DD') d, c.basis,
          c.start_mgdl s, (e->>'minutes')::int m, (e->>'mgdl')::float f,
          (e->>'lower')::float lo, (e->>'upper')::float hi, (e->>'actual')::float a
        from glucos.forecast_checks c, jsonb_array_elements(c.points) e
        where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean,false)
          and coalesce(e->>'shown','true')='true' and (e->>'minutes')::int in (30,60)
          and (c.issued_at at time zone 'Australia/Perth')::date between (select d_from from params) and (select d_to from params)),
g as (select p.*, ml.carbs, extract(epoch from p.t - ml.ts)/60 since,
        case when ml.ts is null then 'none' when ml.carbs <= 10 then 'small' when ml.carbs <= 20 then 'light' else 'meal' end grp
      from pts p left join lateral (select * from meals where ts <= p.t and ts > p.t - interval '190 minutes'
                                    order by ts desc limit 1) ml on true)
select m, grp, basis, count(*) n, count(distinct d) days, round(avg(since)::numeric) mins_after,
  round(avg(abs(a-f))::numeric,1) mae, round(avg(abs(a-s))::numeric,1) no_change, round(avg(a-f)::numeric,1) bias,
  round(100*avg((a between lo and hi)::int)::numeric) inside, round(100*avg((a<lo)::int)::numeric) below,
  round(100*avg((a>hi)::int)::numeric) above, count(*) filter (where a < 70) n_low
from g group by grouping sets ((m, grp), (m, grp, basis)) order by m, grp, basis nulls first;
