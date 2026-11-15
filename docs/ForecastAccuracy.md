# Forecast accuracy

GlucOS checks its forecasts in two ways and uses the results to get better as history builds up.

## 1. Replay (what the forecast would have said)

`ForecastBacktest` replays a forecast every 15 minutes over the last 30 days. Each replay uses only
what was known at the time, including effect profiles fitted without that stretch. It then
compares each forecast with what glucose did 15–180 minutes later. Points with food, insulin or an
event logged before them are left out, because a forecast assumes nothing new happens. Stretches
filled in later from LibreLinkUp's 15-minute history (the Mac was asleep) are left out too, unless
they're most of what there is: their trend is smoother than anything a live forecast sees, and on
the first day of history they made following the trend look far better than it is. The results
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
- **Trend strength**: a Libre trend measured over the last 20 minutes of one-minute readings
  carries on at only about half strength (Declan's: 55–70%), so following it in full made the
  15-minute forecast worse than assuming no change. `ForecastTuner` first fits how much of the
  trend actually carried on: it replays once with the trend and once without, which separates the
  trend's part of each forecast, and the share of it that happened is a least-squares slope at 15
  and 30 minutes. It's fitted on the earlier and the later half of the history and the larger is
  used, kept within 25–100% and rounded to 5%. It's used only with at least 120 checked points
  and when the typical error is no worse in either half. The forecast then carries forward that
  share of the trend (`ForecastTuning.trendGain`); the trend itself is still shown as measured.
- **Trend timing**: at that strength, `ForecastTuner` then tries 8 trend timings: the trend fades
  over 15, 20, 30 or 45 minutes, measured over the last 15 or 20 minutes of readings. It switches
  from the standard timing (30 and 20, Loop's) only when the alternative has:
  - at least 120 checked points,
  - at least 3% less error on the same points, with each horizon (15, 30 and 60 minutes, trend
    forecasts only as far as they're shown) counting equally, and
  - less error in both the earlier and the later half of the history.

  It is re-run with every relearn, so it can move again, or go back to the standard timing.
- **Fresh logs**: in the first hour after a meal with carbs or a fast-acting dose
  (`GlucoseForecaster.freshLogWindow`), most of its effect is still to come and when it starts
  varies. The replay checks insulin-and-carb forecasts made that soon after a log on their own
  (`ForecastCalibration.freshModel`). Until those beat "no change" by 5% at 15 minutes, a forecast
  in that hour follows the trend alone, for 30 minutes, and says so (`ForecastLimitation.freshLog`).
  Once they do, it models the meal or dose with their own range and horizon. On Declan's history
  they haven't yet: in that hour the model was no better than no change and ran 10–16 mg/dL high.
- **Range and horizon** follow the replay, so they tighten as accuracy improves and widen if it
  slips.
- **Range from what was shown**: the replay's range can be more confident than the forecasts
  turn out to be live (and model forecasts use the cautious default until they're checked). Each
  device checks the forecasts it actually showed (`ForecastLedger.rangeScale`): once there are 40
  scored points from the last 14 days, it widens the range until it would have held 4 readings
  in 5, per kind of forecast (or across both kinds while one has fewer than 40), and per checked
  horizon once that horizon has 25 points of its own (interpolated between horizons). One figure
  per kind had left the range too narrow at 15 and 45 minutes. It never narrows the range and
  widens it at most 2.5 times. Each point is measured against its range before any earlier
  widening (each point records its own, `ForecastRecord.Point.scale`), so the figure settles
  instead of compounding. The Outlook page says when the range has been widened. The forecast line
  itself never moves.
- **Short history**: the held-out profiles for the replay split the history there actually is into
  5 stretches, so a new user's insulin-and-carb forecasts get checked (and given a measured range
  and horizon) within days rather than after 30.

## 4. The logbook as the engine sees it

`LogCleanup.mealsWithoutRepeats` drops a meal that repeats one logged within the previous 45
minutes: same food (same description, or the same foods picked from the list) and carbs within
10%. The earliest entry is kept. This catches one meal logged on two devices, which otherwise
doubles the carbs in the forecast and in "carbs on board" and halves the carb effect the learner
fits. Meals without carbs are never merged. The logbook itself is never changed.

Measured on 14 Nov 2026 by replaying the Swift engine over the readings and logbook on the server
(3.8 days):

| | Before | After |
| --- | --- | --- |
| Learnt insulin effect | 12.4 ± 4.6 mg/dL per unit, not reliable | 19.2 ± 4.7, reliable |
| Learnt carb effect | 1.2 ± 0.6 mg/dL per gram, not reliable | 2.8 ± 0.8, reliable |
| Forecast while insulin or carbs act | trend only, 30 min | insulin and carbs, checked, 60 min |
| Error at 60 min while insulin or carbs act | not checked | ±30.7 mg/dL (no change: ±34.3) |

One repeated breakfast was what kept both effects below the reliability bar. The forecasts shown
on the Mac had landed inside their range 64–69% of the time at 30–60 minutes, against the 80% the
range promises; the iPhone's trend forecasts 63–68%.

Mornings: see [Mornings.md](Mornings.md).

## 5. Short-range accuracy (14 Nov 2026)

`glucos.forecast_accuracy` for the week of 9 Nov showed the 15-minute forecast not beating "no
change" (iPhone 10.1 against 9.2 mg/dL, Mac 13.8 against 14.4), forecasts made in the hour after a
log doing worse than no change, and the range holding 62–67% of readings at some horizons against
80%. The changes above (trend strength, 15-minute replay of live readings only, the fresh-log
fallback, per-horizon range) were checked by replaying the server's 4 days of readings and logbook
the way the apps live through them: walking forward, relearning every 3 hours, logging a forecast
every 15 minutes, widening from that log, and scoring each one (`Tests/EngineTests/LiveReplayTests.swift`,
run with `GLUCOS_REPLAY_DIR`). Clean points, typical error in mg/dL:

| | Before | After | No change |
| --- | --- | --- | --- |
| All forecasts, 15 min | 13.1 | 12.1 | 12.7 |
| All forecasts, 30 min | 20.1 | 19.6 | 21.1 |
| In the hour after a log, 15 min | 20.7 | 18.2 | 18.3 |
| Trend forecasts inside their range, 15 / 30 min | 74 / 75% | 76 / 75% | |

The remaining gap at 15 minutes is mostly the half hour to an hour after a meal, when glucose is
about to turn and neither the trend nor the logged meal says when. Insulin-and-carb forecasts now
look 45 minutes ahead rather than 60 on this history, because checked on live readings alone
they beat no change only that far.

## 6. The push relay

The relay's Live Activity forecast is trend-only (it has no logbook), but it now learns the same
way as the apps: every 3 hours it fits the trend's strength and timing to the last 14 days of its
own one-minute readings (`tuneTrend` in `supabase/functions/relay/core.ts`, a port of
`ForecastTuner`) and replays them every 15 minutes for the range and horizon. The parity fixture
(`RelayParityTests`) covers a tuned timing and a tuned strength.

## 7. Forecasts with a log after them (15 Nov 2026)

`glucos.forecast_accuracy` for the week of 9 Nov showed Mac insulin-and-carb forecasts with
something logged afterwards (`clean = false`) at a bias of +17 / +23 / +27 mg/dL at 30 / 45 / 60
minutes, worse than no change, and inside their range 55–59% of the time. Bias is actual −
forecast, so these forecasts ran **low**: glucose ended up higher than they said.

Replaying the server's 4.6 days of readings and logbook (`LiveReplayTests`, with
`GLUCOS_REPLAY_VERBOSE=3` to list every insulin-and-carb forecast and every forecast with a log
after it, at 15–120 minutes; clean trend-only forecasts are left out) gives the same figures (+12 / +20 / +26), and
the listing shows where they come from. Nearly every one is a forecast made before food that
hadn't been eaten yet: a burrito bowl logged after a low (forecast 45, actual 207 an hour on), a
sports drink for a low, and a late rise after a burger that a correction dose then answered. A
forecast says what happens if nothing else is eaten or dosed, so it can't see those, and
`clean = false` points are kept out of the range widening, the backtest and the tuner on
purpose. They are not a forecasting fault to tune away.

The clean points by time since the last meal or fast dose (replay, mg/dL):

| Since the log | 30 min error | No change | Bias | Inside range |
| --- | --- | --- | --- | --- |
| Under 30 min | 33.2 | 33.4 | +4.0 | 55% |
| 30–60 min | 24.4 | 19.9 | −11.2 | 68% |
| 1–2 h | 13.1 | 18.7 | +8.8 | 87% |
| 2–4 h | 17.4 | 21.7 | −5.7 | 81% |
| Over 4 h | 15.9 | 17.9 | −0.3 | 80% |

Two changes were tried for the first hour, and neither went in:

- **A separate range for trend forecasts in the hour after a log**, from backtest checks made
  that soon after a log. Inside-range rose from 48% to 68% at 15 minutes in the first half hour,
  but fell at 30 minutes in the half hour after that, and taking those checks out of the quiet-time
  range narrowed it below 80% (82% → 79% at 15 minutes). Overall coverage went down.
- **A trend strength fitted to the hour after a log** (as `trendGain`, from those checks alone,
  allowed down to none). Forced to 0, 30-minute error in the 30–60 minute window fell from 24.4 to
  19.0, but rose in the first half hour, and the fitted version gained nothing overall
  (30 minutes: 17.6 → 17.8). The tuner only had enough after-log checks for it in some relearns.

There were about ten logged meals in the history, so a few dozen checks per bucket. Both are
worth trying again once there are a few weeks of logged meals. The quickest way to improve these
forecasts is to log meals: 2026-11-14 and 15 have four fast doses (1.5–10 U) with no meal logged
near them, and the forecast then expects the full drop from the insulin. GlucOS now asks about
doses like these ([DoseQuestion.md](DoseQuestion.md)); one marked as for a meal is treated as food
it can't count.

Uploads: `forecast_checks` arrive every 15 minutes from the Mac while it's awake, and from the
iPhone while the app is open, about 1–2 hours after the forecast (each waits for its last checked
point plus 20 minutes). The Mac's quiet stretch, 2026-11-14 18:42 to 2026-11-15 03:31 UTC
(02:42–11:31 on 15 Nov in Perth), lines up with Declan asleep and then not yet at the Mac: the
logbook has him waking at 10:59 Perth time, and the Mac's first forecast came 32 minutes later.
The iPhone's own gap was shorter (its forecasts stopped at 02:21 and started again at 08:42 Perth
time, the times they were made), because the iPhone records a forecast whenever the app is open.
No uploads were missed.
