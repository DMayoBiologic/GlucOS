-- Forecast error and range coverage in the first hour after a gap in readings ends
-- (docs/ForecastAccuracy.md §86). Gaps use the app's rule from PR #388 (Sources/Shared/ReadingGaps.swift):
-- a step of 10 min or more between stored readings, except LinkUp's 15-min history step (±90 s).
-- kind 'r388' uses every stored reading (live + 15-min history); kind 'live' uses live readings only
-- (trend > 0), so stretches LinkUp filled with 15-min history count as gaps too.
-- A point's window is the time from the latest gap end (of that kind) to issue: g0_30, g30_60,
-- 'normal' when no gap of that kind ended in the 2 h before issue (60-120 min after is dropped).
-- clean = nothing logged between issue and the horizon (after_log false); shown points only.
-- Bias = actual - line. Score = width + 10 x distance outside (80% interval score), lower is better.
-- Run in the Supabase SQL editor.
with ra as (select extract(epoch from at)::bigint t, trend from glucos.readings),
s as (select 'r388' kind, t, lag(t) over (order by t) p from ra
      union all select 'live', t, lag(t) over (order by t) from ra where trend > 0),
gaps as (select kind, p gs, t ge from s where t - p >= 600 and abs(t - p - 900) > 90),
p as (select extract(epoch from c.issued_at)::bigint t, left(c.device,1) dev, (e->>'minutes')::int m,
        (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float hi, (e->>'actual')::float a,
        c.start_mgdl s0, not coalesce((e->>'after_log')::boolean,false) clean,
        coalesce(e->>'shown','true') = 'true' sh
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e
      where (e->>'minutes')::int in (15,30,60) and e->>'actual' is not null),
k as (select unnest(array['r388','live']) kind),
g as (select k.kind, p.*, (select max(ge) from gaps where gaps.kind = k.kind and ge <= p.t and ge > p.t - 7200) ge
      from p cross join k),
g2 as (select g.*, case when ge is null then 'normal' when t - ge < 1800 then 'g0_30'
         when t - ge < 3600 then 'g30_60' else 'g60_120' end win from g)
select kind, m, win, count(*) n, count(distinct ge) gaps, round(avg(abs(a-f))::numeric,1) mae,
  round(avg(abs(a-s0))::numeric,1) mae_nochange, round(avg(a-f)::numeric,1) bias,
  round(100*avg((a between lo and hi)::int)) ins, round(100*avg((a<lo)::int)) below,
  round(100*avg((a>hi)::int)) above, round(avg(hi-lo + 10*greatest(lo-a, a-hi, 0))::numeric,1) sc
from g2 where sh and clean and win <> 'g60_120' group by kind, m, win order by kind, m, win;

-- Input for scripts/post-gap-forecast.py (clean shown points, both kinds; same WITH as above):
-- select string_agg(concat_ws(',', kind, t, dev, m, round(f::numeric,1), round(lo::numeric,1),
--   round(hi::numeric,1), round(a::numeric,1), coalesce(ge,0), win), ';' order by kind, t, m)
-- from g2 where sh and clean and win <> 'g60_120';
