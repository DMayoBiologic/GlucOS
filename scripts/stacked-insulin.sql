-- Forecast error and range coverage after stacked rapid insulin (docs/ForecastAccuracy.md §85).
-- A point belongs to the latest non-deleted rapid (or ultra-rapid) dose in the 4 h before issue.
-- That dose is stacked (s60) when the rapid dose before it is at most 60 min earlier, near-stacked
-- (s90) at 61-90 min, single otherwise; points with no rapid dose in 4 h are "none".
-- clean = nothing logged between issue and the horizon (after_log false); shown points only.
-- Bias = actual - line. Score = width + 10 x distance outside (80% interval score), lower is better.
-- Run in the Supabase SQL editor.
with d as (select (payload->>'timestamp')::float ts from glucos.logbook
           where not deleted and kind = 'dose' and payload->>'kind' in ('rapid','ultraRapid')),
d2 as (select ts, (select max(ts) from d p where p.ts < d.ts) prev from d),
p as (select extract(epoch from c.issued_at)::bigint t, left(c.device,1) dev, (e->>'minutes')::int m,
        (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float hi, (e->>'actual')::float a,
        not coalesce((e->>'after_log')::boolean,false) clean, coalesce(e->>'shown','true') = 'true' sh
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e
      where (e->>'minutes')::int in (30,60) and e->>'actual' is not null),
g as (select p.*, (select ts from d2 where d2.ts <= p.t and d2.ts > p.t - 14400 order by ts desc limit 1) anc from p),
g2 as (select g.*, case when anc is null then 'none' else (select case when ts - prev <= 3600 then 's60'
         when ts - prev <= 5400 then 's90' else 'single' end from d2 where d2.ts = g.anc) end grp from g)
select m, grp, clean, count(*) n, count(distinct anc) doses, round(avg(abs(a-f))::numeric,1) mae,
  round(avg(a-f)::numeric,1) bias, round(100*avg((a between lo and hi)::int)) ins,
  round(100*avg((a<lo)::int)) below, round(100*avg((a>hi)::int)) above,
  round(avg(hi-lo + 10*greatest(lo-a, a-hi, 0))::numeric,1) sc, count(*) filter (where a < 70) nlow
from g2 where sh group by m, grp, clean order by m, grp, clean desc;

-- Input for scripts/stacked-insulin.py (clean shown points after stacked and near-stacked pairs):
-- select string_agg(concat_ws(',', t, dev, m, round(f::numeric,1), round(lo::numeric,1),
--   round(hi::numeric,1), round(a::numeric,1), anc::bigint, grp), ';' order by t)
-- from g2 where sh and clean and grp in ('s60','s90');
