-- Forecast error and range coverage by how well the last 24 h were logged (docs/ForecastAccuracy.md §81).
-- Clean shown 30/60-min points (nothing logged before the reading came in), §40/§41 widenings applied
-- to points drawn before those versions (as scripts/adaptive-range.py), records with no version from
-- after 16 Nov 09:33 UTC left out. Level from non-deleted Logbook entries in the 24 h before issue:
-- well = 3+ meals and 2+ rapid doses, sparse = 0-1 meals or no rapid dose, mid = the rest.
-- c = held-out (leave-one-day-out) sparse-only widening: 80th percentile of sparse miss ratios on
-- the other days (needs 30+), clamped to >= 1. ins2/sc2 = inside/score with it. Score = width + 10 x
-- distance outside (80% interval score), lower is better. Run in the Supabase SQL editor.
with lb as (select to_timestamp((payload->>'timestamp')::float) ts, kind, coalesce(payload->>'kind','') k
            from glucos.logbook where not deleted and payload->>'timestamp' is not null),
raw as (select c.issued_at t, to_char(c.issued_at at time zone 'Australia/Perth','MM-DD') d, left(c.device,1) dev,
          c.start_mgdl s, (e->>'minutes')::int m, (e->>'mgdl')::float f, (e->>'lower')::float lo0,
          (e->>'upper')::float hi0, (e->>'actual')::float a, coalesce(c.app_version,'0') ver,
          coalesce(array_to_string(c.limitations,'|'),'') lim
        from glucos.forecast_checks c, jsonb_array_elements(c.points) e
        where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean,false)
          and coalesce(e->>'shown','true')='true' and (e->>'minutes')::int in (30,60)),
v as (select *, string_to_array(ver,'.')::int[] vv from raw where not (ver='0' and extract(epoch from t) >= 1794821580)),
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
r as (select *, case when meals>=3 and rapid>=2 then 'well' when meals<=1 or rapid=0 then 'sparse' else 'mid' end lvl,
  case when hi>=399.5 and lo<=40.5 then null when hi>=399.5 then abs(a-f)/nullif(f-lo,0)
       when lo<=40.5 then abs(a-f)/nullif(hi-f,0) when a>=f then (a-f)/nullif(hi-f,0)
       else (f-a)/nullif(f-lo,0) end ratio from q),
cf as (select m, d, (select case when count(*) filter (where o.ratio is not null) >= 30
        then greatest(1, percentile_cont(0.8) within group (order by o.ratio)) else 1 end
        from r o where o.lvl='sparse' and o.m=x.m and o.d<>x.d) c
       from (select distinct m, d from r where lvl='sparse') x),
w as (select r.*, coalesce(cf.c,1) c, least(401, r.f+(r.hi-r.f)*coalesce(cf.c,1)) hi2,
        greatest(39, r.f-(r.f-r.lo)*coalesce(cf.c,1)) lo2
      from r left join cf on cf.m=r.m and cf.d=r.d and r.lvl='sparse')
select m, lvl, d, count(*) n, round(max(c)::numeric,2) c, round(avg(abs(a-f))::numeric,1) mae,
  round(avg(a-f)::numeric,1) bias, round(100*avg((a between lo and hi)::int)::numeric) ins,
  round(100*avg((a>hi)::int)::numeric) above, round(avg(hi-lo + 10*greatest(lo-a,a-hi,0))::numeric,1) sc,
  round(100*avg((a between lo2 and hi2)::int)::numeric) ins2,
  round(avg(hi2-lo2 + 10*greatest(lo2-a,a-hi2,0))::numeric,1) sc2,
  count(*) filter (where a<70) nlow, count(*) filter (where a<70 and a between lo and hi) lowin,
  count(*) filter (where a<70 and a between lo2 and hi2) lowin2
from w group by grouping sets ((m,lvl),(m,lvl,d)) order by m, lvl, d nulls first;
