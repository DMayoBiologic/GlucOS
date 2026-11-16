# Forecast accuracy

GlucOS checks its forecasts in two ways and uses the results to get better as history builds up.

## 1. Replay (what the forecast would have said)

`ForecastBacktest` replays a forecast every half hour over the last 30 days. Each replay uses only
what was known at the time, including effect profiles fitted without that stretch. It then
compares each forecast with what glucose did 15–180 minutes later. Points with food, insulin or an
event logged before them are left out, because a forecast assumes nothing new happens. The results
set:

- the likely range (the 10th–90th percentile of past errors), and
- how far ahead each kind of forecast is shown: only as far as it beats "assume no change" by 5%.

The results appear on the Mac's Outlook page under **How Accurate It's Been**.

## 2. The forecast log (what the forecast did say)

`ForecastLedger` keeps one forecast per 15 minutes from each device (Mac and iPhone), exactly as
it was shown. Once the readings are in, it scores each one at 15, 30, 45, 60, 90, 120, 150 and 180
minutes, as far as the forecast looked. A forecast settles 20 minutes after its last point, which
allows for late readings and for food logged afterwards with an earlier time. A point is marked
`after_log` when a dose, a meal or an event (other than a wake-up) was logged between the forecast
and that point.

- On the device: `forecast-log.json` in the app group container, kept for 90 days. The Outlook
  page (**Forecasts You Were Shown**) and the iPhone home screen (**Forecast accuracy**) show the
  last 7 days. Once both periods have at least 20 checks, they also compare the last 7 days with
  the 3 weeks before.
- On the server: settled forecasts are uploaded with each logbook sync to `glucos.forecast_checks`
  through `public.forecast_push`. Uploads use the same signed-in session and row-level security as
  the logbook. Nothing is uploaded when logbook sync is off.

Queries (Supabase SQL editor or MCP, project `aqlbadbyjuoruwnwyfrc`):

```sql
-- Weekly accuracy by device and horizon; clean = nothing logged in between.
select * from glucos.forecast_accuracy where clean order by week desc, device, minutes;

-- Every scored point, e.g. to look at the misses.
select * from glucos.forecast_points order by issued_at desc limit 100;
```

## 3. Getting better with more data

- **Effects**: `EffectProfileLearner` refits how much the user's insulin and carbs move glucose
  every 3 hours and whenever the logbook changes. It uses up to 90 days of data and only uses a
  figure once it's reliable (at least 5 examples, standard error within 35%). Until then a forecast
  with insulin or carbs acting falls back to the trend alone, for 30 minutes. Logging every meal
  and dose is what gets it there.
- **Trend timing**: `ForecastTuner` replays the past 30 days with 8 trend timings: the trend fades
  over 15, 20, 30 or 45 minutes, measured over the last 15 or 20 minutes of readings. It switches
  from the standard timing (30 and 20, Loop's) only when the alternative has:
  - at least 120 checked points,
  - at least 3% less error on the same points, and
  - less error in both the earlier and the later half of the history.

  It is re-run with every relearn, so it can move again, or go back to the standard timing.
- **Range and horizon** follow the replay, so they tighten as accuracy improves and widen if it
  slips.
- **Mornings**: see [Mornings.md](Mornings.md).

The push relay's Live Activity forecast is still the standard trend-only one.

## 29. Should the range widen on a new sensor's first day or two? (16 Nov 2026)

Libre sensors are known to read noisier and less accurately on their first day, sometimes the
second, and the question was whether the forecast range should widen then instead of using the
same whole-day figure (§9) on every day of a sensor's life. **It can't be tested yet: there is
no first or second sensor day anywhere in the data. Nothing shipped; no app or relay code
changed.**

Nothing here touches dosing: the bolus calculator, insulin on board, sensitivity and carb
ratios were not read or changed.

**Why there's nothing to test.** The current sensor (Libre 2 Plus, 15-day life, from the relay's
`work.sensor`) started on 5 Nov at 20:59 Perth. `glucos.readings` starts on 10 Nov at 22:45, sensor
day 6, with no gap over 30 minutes since, so no sensor change has happened inside the history.
`glucos.forecast_checks` starts on 12 Nov, sensor day 7. Every scored forecast is from days 7–11
of the same sensor.

**What days 7–11 show.** Counting sensor days from the start time (a day runs 20:59 to 20:59
Perth), clean points only, as in §21:

| Sensor day | 15 min inside (n) | 15 min error | 30 min inside (n) | 30 min error | Jitter |
|---|---|---|---|---|---|
| 7 | 71% (21) | 11.2 | 60% (20) | 22.7 | 1.66 |
| 8 | 73% (63) | 13.9 | 72% (58) | 19.7 | 2.19 |
| 9 | 68% (44) | 13.2 | 73% (40) | 21.0 | 2.28 |
| 10 | 74% (102) | 19.4 | 70% (63) | 35.4 | 2.92 |
| 11 | 70% (69) | 21.6 | 77% (13) | 48.8 | 2.56 |

Error is the mean miss in mg/dL. Jitter is the mean |second difference| of live readings in
mg/dL, with LinkUp graph points dropped (§23). Coverage is flat across days 7–11. Errors grow
from day 9 on, but that follows what happened on those days (the 14–15 Nov meals and lows), not
the sensor's age, and this is the same day-to-day spread §19 found. Nothing here points to a
sensor-day effect in the middle of a sensor's life, and it says nothing about day 1.

**What already covers day 1.** The `recent` correction (§9) widens the range from the last 12
hours once 20 points have been scored. A noisy first day widens its own range from late on day 1,
without knowing the sensor is new. What it misses is the first several hours after warm-up.

**When to test.** This sensor ends on 20 Nov at 20:59 Perth, so the next one's day 1 is 20–21
Nov and day 2 is 21–22 Nov. One sensor start is one held-out fold, which is too few to fit a
day-1 factor and check it on days it hasn't seen. Run it after two or three sensor changes
(early to mid December): for each sensor start held out, learn the day-1 and day-2 widening from
the other starts with the §19 miss-ratio method, and compare against the shown ranges, including
`recent`, on the interval score. Look at the first 12 hours after warm-up apart from the rest of
day 1, since that is where `recent` can't help.

The relay overwrites `work.sensor` when a new sensor starts, and readings don't carry the
sensor, so each start time needs keeping. A sensor start shows in `glucos.readings` as a gap of
about an hour (the warm-up) and should be cross-checked against `work.sensor.activated`.
Sensor starts so far:

| Sensor start (Perth) | Life |
|---|---|
| 5 Nov 2026 20:59 | 15 days |

To rerun the table, with each start time in place of the one below:

    with p as (select floor(extract(epoch from c.issued_at - timestamptz '2026-11-05 12:59:22+00')
        / 86400)::int + 1 sday, (e->>'minutes')::int m, (e->>'actual')::float a,
        (e->>'lower')::float lo, (e->>'upper')::float up, (e->>'mgdl')::float f,
        coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e)
    select sday, m, count(*),
      avg((abs(a - f) <= case when a >= f or lo <= 39.5 then up - f else f - lo end)::int) inside,
      avg(abs(a - f)) error
    from p where a is not null and not al and m in (15, 30) group by 1, 2 order by 1, 2;
