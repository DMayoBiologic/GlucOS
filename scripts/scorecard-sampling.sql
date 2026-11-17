-- Is the forecast scorecard biased by when checks happen? (ForecastAccuracy.md §70)
-- Read only; run against the Supabase project (e.g. via the Supabase MCP execute_sql).
-- Compares the clean points the apps recorded (glucos.forecast_checks, iPhone and Mac, extras
-- included as on the card) with a replay at every live reading over the same span: the engine's
-- trend line (20-min least-squares slope clamped at ±4 mg/dL/min, 30-min fade, gain 0.55) and
-- "no change", scored at 15/30/60 min against the live reading in the target minute (±1 min),
-- clean = no meal/dose/insulin/food logged after the moment up to the target.
-- Cells: Perth time-of-day block (night 0–6, morning 6–12, afternoon 12–18, evening 18–24) ×
-- trend band (|slope| < 1 steady, 1–2 moving, >= 2 fast, mg/dL/min).
-- One line per device × horizon × cell:
--   device,minutes,tod,band, all_n,all_fc,all_nc, atrec_n,atrec_fc,atrec_nc, rec_n,rec_fc,rec_nc,rec_inside
-- all_* = replay at every reading; atrec_* = replay at the recorded moments (same model, the
-- apps' timing); rec_* = what the card counts. Fields after a zero count are left out.
-- Feed the output (';'-separated) to scripts/scorecard-sampling.py.
with r as materialized (select at, mgdl from glucos.readings where trend > 0),
logs as materialized (select to_timestamp((payload->>'timestamp')::float) t from glucos.logbook
  where not deleted and kind in ('meal','dose','insulin','food') and payload->>'timestamp' is not null),
span as (select min(issued_at) lo, max(issued_at) hi from glucos.forecast_checks where device in ('iPhone','Mac')),
rm as materialized (select distinct on (floor(extract(epoch from at)/60)) floor(extract(epoch from at)/60)::bigint mn, at, mgdl
  from r order by floor(extract(epoch from at)/60), at),
m as materialized (
  select r.at, floor(extract(epoch from r.at)/60)::bigint mn, r.mgdl g0,
    (select greatest(-4, least(4, regr_slope(q.mgdl, extract(epoch from q.at) / 60))) from glucos.readings q
      where q.trend > 0 and q.at between r.at - interval '20 min' and r.at
      having max(extract(epoch from q.at)) - min(extract(epoch from q.at)) >= 540) tr
  from r, span where r.at >= span.lo and r.at <= span.hi
),
hz as (select unnest(array[15, 30, 60]) hm),
rp as materialized (
  select m.at, m.mn, m.g0, m.tr, hz.hm,
    least(401, greatest(39, m.g0 + 0.55 * m.tr * (least(hz.hm, 30) - least(hz.hm, 30) ^ 2 / 60.0))) fc,
    coalesce(a0.mgdl, a1.mgdl, a2.mgdl) actual
  from m cross join hz
  left join rm a0 on a0.mn = m.mn + hz.hm
  left join rm a1 on a1.mn = m.mn + hz.hm + 1
  left join rm a2 on a2.mn = m.mn + hz.hm - 1
  where m.tr is not null
    and not exists (select 1 from logs l where l.t > m.at and l.t <= m.at + make_interval(mins => hz.hm))
),
rpc as materialized (
  select *, case when h < 6 then 'night' when h < 12 then 'morning' when h < 18 then 'afternoon' else 'evening' end tod,
    case when abs(tr) < 1 then 'steady' when abs(tr) < 2 then 'moving' else 'fast' end band
  from (select *, extract(hour from at at time zone 'Australia/Perth') h from rp where actual is not null) x
),
recc as materialized (
  select *, case when h < 6 then 'night' when h < 12 then 'morning' when h < 18 then 'afternoon' else 'evening' end tod,
    case when abs(tr) < 1 then 'steady' when abs(tr) < 2 then 'moving' else 'fast' end band
  from (select f.device, f.issued_at, floor(extract(epoch from f.issued_at)/60)::bigint mn, f.start_mgdl,
      f.trend_per_minute tr, (p->>'minutes')::int hm, (p->>'mgdl')::float fc, (p->>'actual')::float actual,
      (p->>'lower')::float lo, (p->>'upper')::float hi,
      coalesce((p->>'after_log')::boolean, (p->>'afterLog')::boolean, false) al,
      extract(hour from f.issued_at at time zone 'Australia/Perth') h
    from glucos.forecast_checks f, jsonb_array_elements(f.points) p
    where f.device in ('iPhone','Mac') and (p->>'minutes')::int in (15, 30, 60)) x
  where actual is not null and not al
),
atrec as (
  select c.device, c.hm, c.tod, c.band, x.fc, x.g0, x.actual
  from recc c join lateral (select rpc.fc, rpc.g0, rpc.actual from rpc
    where rpc.hm = c.hm and rpc.mn in (c.mn, c.mn - 1, c.mn + 1) order by abs(rpc.mn - c.mn) limit 1) x on true
),
a1 as (select hm, tod, band, count(*) n, avg(abs(actual-fc)) fc, avg(abs(actual-g0)) nc from rpc group by 1,2,3),
a2 as (select device, hm, tod, band, count(*) n, avg(abs(actual-fc)) fc, avg(abs(actual-g0)) nc from atrec group by 1,2,3,4),
a3 as (select device, hm, tod, band, count(*) n, avg(abs(actual-fc)) fc, avg(abs(actual-start_mgdl)) nc,
  avg((actual between lo and hi)::int) inr from recc group by 1,2,3,4)
select string_agg(concat_ws(',', d.device, a1.hm, a1.tod, a1.band, a1.n, round(a1.fc::numeric,1), round(a1.nc::numeric,1),
  coalesce(a2.n,0), round(a2.fc::numeric,1), round(a2.nc::numeric,1), coalesce(a3.n,0), round(a3.fc::numeric,1),
  round(a3.nc::numeric,1), round(a3.inr::numeric,3)), ';' order by d.device, a1.hm, a1.tod, a1.band) out
from a1 cross join (values ('iPhone'), ('Mac')) d(device)
left join a2 on a2.device = d.device and a2.hm = a1.hm and a2.tod = a1.tod and a2.band = a1.band
left join a3 on a3.device = d.device and a3.hm = a1.hm and a3.tod = a1.tod and a3.band = a1.band;
