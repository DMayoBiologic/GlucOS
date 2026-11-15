-- GlucOS forecast accuracy, overnight: the push relay keeps the forecast its Lock Screen card
-- showed every 15 minutes in glucos.forecast_checks as device 'relay' (supabase/functions/relay/
-- ledger.ts), and the database scores it from glucos.readings. The Mac and the iPhone only record
-- while the Mac is awake or the app is open, so until now the nights had no checks at all.
--
-- Scoring follows Sources/Engine/ForecastLedger.swift: a point's actual is the reading at its time
-- (GlucoseSeries.value(at:)), and it's `after_log` when a dose, a meal or an event other than
-- waking up was logged after the forecast and before the point.

-- The reading at a moment: exact, else straight between the readings either side when they're at
-- most 20 minutes apart, else the nearest within 5 minutes, else null.
create or replace function glucos.reading_at(target timestamptz)
returns double precision
language sql
stable
set search_path = ''
as $$
  with b as (select at, mgdl from glucos.readings where at < target order by at desc limit 1),
       a as (select at, mgdl from glucos.readings where at >= target order by at limit 1)
  select case
    when (select at from a) = target then (select mgdl from a)
    when (select a.at - b.at from a, b) <= interval '20 minutes' then
      (select b.mgdl + (a.mgdl - b.mgdl) * extract(epoch from target - b.at) / extract(epoch from a.at - b.at) from a, b)
    else
      (select n.mgdl from (select * from a union all select * from b) n
       where abs(extract(epoch from n.at - target)) <= 300
       order by abs(extract(epoch from n.at - target)) limit 1)
  end
$$;

-- Fills in the actual reading and after_log of every point whose time has come, in the owner's
-- relay forecasts from the last `since` (the relay's forecast reaches 30 minutes ahead, the apps'
-- settle 20 minutes after their last point; four hours leaves room for late readings and logs).
-- Returns how many forecasts changed.
create or replace function glucos.score_relay_forecasts(owner uuid, since interval default interval '4 hours')
returns integer
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  with logs as (
    select to_timestamp((l.payload ->> 'timestamp')::float8) as at
    from glucos.logbook l
    where l.user_id = owner and not l.deleted and jsonb_typeof(l.payload -> 'timestamp') = 'number'
      and (l.kind in ('dose', 'meal')
           or (l.kind = 'context' and not coalesce(l.payload -> 'tags' ? 'wokeUp', false)))
  ),
  scored as (
    select f.id,
           jsonb_agg(
             case when t.target > now() then p.v
             else (p.v - 'actual' - 'after_log')
                  || jsonb_strip_nulls(jsonb_build_object('actual', glucos.reading_at(t.target)))
                  || jsonb_build_object('after_log',
                       exists (select 1 from logs where logs.at > f.issued_at and logs.at < t.target))
             end order by p.i) as points
    from glucos.forecast_checks f
    cross join lateral jsonb_array_elements(f.points) with ordinality as p(v, i)
    cross join lateral (select f.issued_at + make_interval(mins => (p.v ->> 'minutes')::int) as target) t
    where f.user_id = owner and f.device = 'relay' and f.issued_at > now() - since
    group by f.id
  )
  update glucos.forecast_checks f
  set points = s.points, received_at = now()
  from scored s
  where f.user_id = owner and f.id = s.id and f.points is distinct from s.points;

  get diagnostics n = row_count;
  return n;
end;
$$;

-- Only the relay (connected as the database owner) runs these.
revoke all on function glucos.reading_at(timestamptz) from public, anon, authenticated;
revoke all on function glucos.score_relay_forecasts(uuid, interval) from public, anon, authenticated;
