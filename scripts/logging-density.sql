-- Forecast error and range coverage by how well the last 24 h were logged (docs/ForecastAccuracy.md §81).
-- Clean shown 30/60-min points (nothing logged before the reading came in), §40/§41 widenings applied
-- to points drawn before those versions (as scripts/adaptive-range.py), records with no version from
-- after 16 Nov 09:33 UTC left out. Level from non-deleted Logbook entries in the 24 h before issue:
-- well = 3+ meals and 2+ rapid doses, sparse = 0-1 meals or no rapid dose, mid = the rest.
-- c = held-out (leave-one-day-out) sparse-only widening: 80th percentile of sparse miss ratios on
-- the other days (needs 30+), clamped to >= 1. ins2/sc2 = inside/score with it. Score = width + 10 x
-- distance outside (80% interval score), lower is better. ntrain = sparse ratios the held-out fit had
-- on the other days (under 30 means c = 1 because it couldn't fit, not because it was clamped).
-- Ratios follow ratio() in scripts/adaptive-range.py: a clipped side borrows the other side, and a
-- point with either side 0.5 mg/dL or narrower gets no ratio. An app_version that isn't dotted
-- integers of up to 9 digits each can't be compared with the §40/§41 cutoffs (or would overflow
-- int), so that record is left out.
-- The level is retrospective: it counts Logbook entries as they stand now by their event time, so an
-- entry logged late (timestamped before the forecast) still counts. The logbook has no creation time
-- (modified_at moves on every edit), so "as known at issue" can't be rebuilt.
-- Period: Perth issue dates in params (§81 ran 12-18 Nov 2026); the lookback reaches 24 h before.
-- Run in the Supabase SQL editor.
with params as (select date '2026-11-12' d_from, date '2026-11-18' d_to),
lb as (select to_timestamp((payload->>'timestamp')::float) ts, kind, coalesce(payload->>'kind','') k
            from glucos.logbook where not deleted and payload->>'timestamp' is not null),
raw as (select c.issued_at t, to_char(c.issued_at at time zone 'Australia/Perth','MM-DD') d, left(c.device,1) dev,
          c.start_mgdl s, (e->>'minutes')::int m, (e->>'mgdl')::float f, (e->>'lower')::float lo0,
          (e->>'upper')::float hi0, (e->>'actual')::float a, coalesce(c.app_version,'0') ver,
          coalesce(array_to_string(c.limitations,'|'),'') lim
        from glucos.forecast_checks c, jsonb_array_elements(c.points) e
        where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean,false)
          and coalesce(e->>'shown','true')='true' and (e->>'minutes')::int in (30,60)
          and (c.issued_at at time zone 'Australia/Perth')::date between (select d_from from params) and (select d_to from params)),
v as (select *, string_to_array(ver,'.')::int[] vv from raw
      where ver ~ '^[0-9]{1,9}(\.[0-9]{1,9})*$' and not (ver='0' and extract(epoch from t) >= 1794821580)),
dr as (select *,
  least(401, f + (hi0-f) * case when s<80 and lim not like '%lowTreatment%'
        and vv < case dev when 'r' then array[2,17,0] else array[1,30,0] end
        then case m when 30 then 3.3 else 3.6 end else 1 end) hi,
  greatest(39, f - (f-lo0) * case when s>180 and dev in ('M','i') and vv < array[1,31,0] and m=60 then 1.7 else 1 end) lo
  from v),
q as (select dr.*,
  (select count(*) filter (where kind='meal') from lb where lb.ts between dr.t - interval '24 hours' and dr.t) meals,
  (select count(*) filter (where kind='dose' and k='rapid') from lb where lb.ts between dr.t - interval '24 hours' and dr.t) rapid
  from dr),
sides as (select *, case when meals>=3 and rapid>=2 then 'well' when meals<=1 or rapid=0 then 'sparse' else 'mid' end lvl,
  hi>=399.5 ch, lo<=40.5 cl from q),
r as (select *, case when ch and cl then null
       when least(case when ch then f-lo else hi-f end, case when cl then hi-f else f-lo end) <= 0.5 then null
       when a>=f then (a-f)/(case when ch then f-lo else hi-f end)
       else (f-a)/(case when cl then hi-f else f-lo end) end ratio from sides),
cf as (select m, d, (select case when count(*) filter (where o.ratio is not null) >= 30
        then greatest(1, percentile_cont(0.8) within group (order by o.ratio)) else 1 end
        from r o where o.lvl='sparse' and o.m=x.m and o.d<>x.d) c,
       (select count(o.ratio) from r o where o.lvl='sparse' and o.m=x.m and o.d<>x.d) ntrain
       from (select distinct m, d from r where lvl='sparse') x),
w as (select r.*, coalesce(cf.c,1) c, cf.ntrain, least(401, r.f+(r.hi-r.f)*coalesce(cf.c,1)) hi2,
        greatest(39, r.f-(r.f-r.lo)*coalesce(cf.c,1)) lo2
      from r left join cf on cf.m=r.m and cf.d=r.d and r.lvl='sparse')
select m, lvl, d, count(*) n, round(max(c)::numeric,2) c, max(ntrain) ntrain, round(avg(abs(a-f))::numeric,1) mae,
  round(avg(a-f)::numeric,1) bias, round(100*avg((a between lo and hi)::int)::numeric) ins,
  round(100*avg((a>hi)::int)::numeric) above, round(avg(hi-lo + 10*greatest(lo-a,a-hi,0))::numeric,1) sc,
  round(100*avg((a between lo2 and hi2)::int)::numeric) ins2,
  round(avg(hi2-lo2 + 10*greatest(lo2-a,a-hi2,0))::numeric,1) sc2,
  count(*) filter (where a<70) nlow, count(*) filter (where a<70 and a between lo and hi) lowin,
  count(*) filter (where a<70 and a between lo2 and hi2) lowin2
from w group by grouping sets ((m,lvl),(m,lvl,d)) order by m, lvl, d nulls first;
