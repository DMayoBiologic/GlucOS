-- Forecast error and range coverage after correction-only rapid doses (docs/ForecastAccuracy.md §87).
-- Correction: a non-deleted rapid (or ultra-rapid) dose with no meal logged within 60 min either side,
-- taken while the reading at the dose was above 180 mg/dL. Meal-covered: a rapid dose with a meal
-- within 60 min either side. A point belongs to the latest rapid dose in the 3 h before issue; a
-- correction point is dropped (grp 'mixed') when a meal was logged between the dose and issue.
-- clean = nothing logged between issue and the horizon (after_log false); shown points only.
-- Bias = actual - line. Score = width + 10 x distance outside (80% interval score), lower is better.
-- Run in the Supabase SQL editor.
with d as (select (payload->>'timestamp')::float ts from glucos.logbook
           where not deleted and kind = 'dose' and payload->>'kind' in ('rapid','ultraRapid')),
ml as (select (payload->>'timestamp')::float ts from glucos.logbook where not deleted and kind = 'meal'),
dc as (select d.ts,
         (select mgdl from glucos.readings r where r.at <= to_timestamp(d.ts) + interval '5 min'
          order by r.at desc limit 1) bg,
         exists (select 1 from ml where abs(ml.ts - d.ts) <= 3600) meal
       from d),
dk as (select ts, case when meal then 'meal' when bg > 180 then 'correction' else 'other' end kind from dc),
p as (select extract(epoch from c.issued_at)::bigint t, left(c.device,1) dev, (e->>'minutes')::int m,
        (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float hi, (e->>'actual')::float a,
        c.start_mgdl s, not coalesce((e->>'after_log')::boolean,false) clean,
        coalesce(e->>'shown','true') = 'true' sh
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e
      where (e->>'minutes')::int in (30,60) and e->>'actual' is not null),
g as materialized (select p.*, (select ts from dk where dk.ts <= p.t and dk.ts > p.t - 10800
                   order by ts desc limit 1) anc from p),
g2 as (select g.*, case when anc is null then 'none'
         else (select case when kind = 'correction' and exists (select 1 from ml where ml.ts > g.anc and ml.ts <= g.t)
                      then 'mixed' else kind end from dk where dk.ts = g.anc) end grp,
         case when anc is null then null when g.t - anc < 3600 then '0-60' else '60-180' end since from g)
select m, grp, since, count(*) n, count(distinct anc) doses, round(avg(abs(a-f))::numeric,1) mae,
  round(avg(abs(a-s))::numeric,1) nochange, round(avg(a-f)::numeric,1) bias,
  round(100*avg((a between lo and hi)::int)) ins, round(100*avg((a<lo)::int)) below,
  round(100*avg((a>hi)::int)) above, round(avg(hi-lo + 10*greatest(lo-a, a-hi, 0))::numeric,1) sc
from g2 where sh and clean group by grouping sets ((m, grp), (m, grp, since)) order by m, grp, since nulls first;

-- Input for scripts/correction-doses.py (clean shown points after correction and meal-covered doses):
-- replace the summary SELECT above with this one (it needs the same WITH):
-- select string_agg(concat_ws(',', t, dev, m, round(f::numeric,1), round(lo::numeric,1),
--   round(hi::numeric,1), round(a::numeric,1), anc::bigint, grp, round(s::numeric,1)), ';' order by t)
-- from g2 where sh and clean and grp in ('correction','meal');
