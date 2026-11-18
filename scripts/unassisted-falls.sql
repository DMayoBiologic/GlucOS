-- Forecast error and range coverage on falls back from above range with no rapid dose logged in the
-- 3 h before (docs/ForecastAccuracy.md §82), against the app's own accuracy log.
-- Clean shown 30/60-min points (nothing logged before the reading came in), §40/§41 widenings applied
-- to points drawn before those versions (as scripts/logging-density.sql, §81), records with no version
-- from after 16 Nov 09:33 UTC left out.
-- Groups (same as scripts/unassisted-falls.py): fall = trend_per_minute <= -1; from high = a reading
-- above 180 in glucos.readings in the 60 min before issue and start >= 120; unassisted = from high
-- with no non-deleted rapid dose timestamped in the 3 h before issue; dosed = from high with one;
-- other = the remaining falls. Bias = actual - forecast. Score = width + 10 x distance outside
-- (80% interval score), lower is better.
-- Period: Perth issue dates in params (§82 ran 11-18 Nov 2026). Run in the Supabase SQL editor.
with params as (select date '2026-11-11' d_from, date '2026-11-18' d_to),
doses as (select to_timestamp((payload->>'timestamp')::float) ts from glucos.logbook
          where not deleted and kind = 'dose' and payload->>'kind' = 'rapid' and payload->>'timestamp' is not null),
raw as (select c.issued_at t, to_char(c.issued_at at time zone 'Australia/Perth','MM-DD') d, left(c.device,1) dev,
          c.start_mgdl s, c.trend_per_minute tr, (e->>'minutes')::int m, (e->>'mgdl')::float f,
          (e->>'lower')::float lo0, (e->>'upper')::float hi0, (e->>'actual')::float a,
          coalesce(c.app_version,'0') ver, coalesce(array_to_string(c.limitations,'|'),'') lim
        from glucos.forecast_checks c, jsonb_array_elements(c.points) e
        where e->>'actual' is not null and not coalesce((e->>'after_log')::boolean,false)
          and coalesce(e->>'shown','true')='true' and (e->>'minutes')::int in (30,60)
          and c.trend_per_minute <= -1
          and (c.issued_at at time zone 'Australia/Perth')::date between (select d_from from params) and (select d_to from params)),
v as (select *, string_to_array(ver,'.')::int[] vv from raw
      where ver ~ '^[0-9]{1,9}(\.[0-9]{1,9})*$' and not (ver='0' and extract(epoch from t) >= 1794821580)),
dr as (select *,
  least(401, f + (hi0-f) * case when s<80 and lim not like '%lowTreatment%'
        and vv < case dev when 'r' then array[2,17,0] else array[1,30,0] end
        then case m when 30 then 3.3 else 3.6 end else 1 end) hi,
  greatest(39, f - (f-lo0) * case when s>180 and dev in ('M','i') and vv < array[1,31,0] and m=60 then 1.7 else 1 end) lo
  from v),
g as (select dr.*,
  case when s >= 120 and (select max(mgdl) from glucos.readings r where r.at between dr.t - interval '60 minutes' and dr.t) > 180
       then case when exists (select 1 from doses where ts between dr.t - interval '3 hours' and dr.t) then 'dosed' else 'unassisted' end
       else 'other' end grp
  from dr)
select m, grp, d, count(*) n, round(avg(s)::numeric) start, round(avg(tr)::numeric,2) trend,
  round(avg(abs(a-f))::numeric,1) mae, round(avg(a-f)::numeric,1) bias,
  round(100*avg((a between lo and hi)::int)::numeric) ins, round(100*avg((a<lo)::int)::numeric) below,
  round(100*avg((a>hi)::int)::numeric) above, round(avg(hi-lo + 10*greatest(lo-a,a-hi,0))::numeric,1) sc,
  count(*) filter (where a<70) nlow, count(*) filter (where a<70 and a between lo and hi) lowin
from g group by grouping sets ((m,grp),(m,grp,d)) order by m, grp, d nulls first;
