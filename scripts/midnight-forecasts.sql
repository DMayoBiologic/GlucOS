-- §109 (docs/ForecastAccuracy.md): forecasts whose horizon crosses local midnight.
-- Run in the Supabase SQL editor (or execute_sql). Perth has no daylight saving, so the
-- day boundary is fixed at 16:00 UTC; change the zone to test another one.

-- 1. Accuracy by group. A cross: the target falls on the next Perth day. B: issued 23:00–00:59
--    without crossing. C: issued 21:00–22:59 or 01:00–02:59. D: every other hour.
with p as (
 select c.device, c.issued_at, (e->>'minutes')::int m, (e->>'mgdl')::float f, (e->>'lower')::float lo,
  (e->>'upper')::float hi, (e->>'actual')::float a, c.start_mgdl s,
  (not coalesce((e->>'after_log')::boolean,false)) clean, (coalesce(e->>'shown','true')='true') shown,
  extract(hour from c.issued_at at time zone 'Australia/Perth')::int h,
  ((c.issued_at at time zone 'Australia/Perth')::date
    <> ((c.issued_at + make_interval(mins=>(e->>'minutes')::int)) at time zone 'Australia/Perth')::date) crosses
 from glucos.forecast_checks c, jsonb_array_elements(c.points) e
 where (e->>'minutes')::int in (15,30,60) and e->>'actual' is not null)
select case when device='relay' then 'relay' else 'app' end dev, m,
 case when crosses then 'A cross' when h in (23,0) then 'B 23-01 no cross'
      when h in (21,22,1,2) then 'C neighbours' else 'D other' end grp,
 count(*) n, count(distinct (issued_at at time zone 'Australia/Perth')::date) days,
 round(avg(abs(a-f))::numeric,1) mae, round(avg(abs(a-s))::numeric,1) nochg, round(avg(a-f)::numeric,1) bias,
 round(100*avg(case when a between lo and hi then 1 else 0 end)::numeric,0) inside
from p where clean and shown group by 1,2,3 order by 1,2,3;

-- 2. Scoring check: each point's stored `actual` against the stored readings interpolated at
--    its target time (only targets with a reading on both sides within 20 minutes).
with p as (
 select c.device, c.issued_at, c.app_version is null old, (e->>'minutes')::int m, (e->>'actual')::float a,
  c.issued_at + make_interval(mins=>(e->>'minutes')::int) tgt,
  ((c.issued_at at time zone 'Australia/Perth')::date
    <> ((c.issued_at + make_interval(mins=>(e->>'minutes')::int)) at time zone 'Australia/Perth')::date) crosses,
  extract(hour from c.issued_at at time zone 'Australia/Perth')::int h
 from glucos.forecast_checks c, jsonb_array_elements(c.points) e
 where e->>'actual' is not null and (e->>'minutes')::int in (15,30,60)),
q as (select p.*, b.at bt, b.mgdl bm, n.at nt, n.mgdl nm from p
 left join lateral (select at, mgdl from glucos.readings where at <= p.tgt and at > p.tgt - interval '20 min'
   order by at desc limit 1) b on true
 left join lateral (select at, mgdl from glucos.readings where at > p.tgt and at < p.tgt + interval '20 min'
   order by at limit 1) n on true),
r as (select *, bm + (nm-bm)*extract(epoch from tgt-bt)/nullif(extract(epoch from nt-bt),0) interp
  from q where nt is not null and bt is not null)
select device, old, case when crosses then 'cross' when h in (22,23,0,1) then '22-02' else 'other' end g,
 count(*) n, round(avg(abs(a-interp))::numeric,2) mad, round(avg(a-interp)::numeric,2) bias,
 count(*) filter (where abs(a-interp) > 10) over10
from r group by 1,2,3 order by 1,2,3;
