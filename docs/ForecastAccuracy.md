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

`ForecastLedger` keeps one forecast per 15 minutes from each app (Mac and iPhone; the relay keeps its own, below), exactly as
it was shown. Once the readings are in, it scores each one at 15, 30, 45, 60, 90, 120, 150 and 180
minutes, as far as the forecast looked. A forecast settles 20 minutes after its last point, which
allows for late readings and for food logged afterwards with an earlier time. A point is marked
`after_log` when a dose, a meal or an event (other than a wake-up) was logged between the forecast
and that point.
Settled forecasts from the last 12 hours have `after_log` checked again whenever logs change,
because an entry can be logged hours later with an earlier time ("Did you treat this low?",
[LowTreatmentQuestion.md](LowTreatmentQuestion.md)); one that changes is uploaded again.

- On the device: `forecast-log.json` in the app group container, kept for 90 days. The Outlook
  page (**Forecasts You Were Shown**) shows the last 7 days at every checked horizon. Once both
  periods have at least 20 checks, it and the iPhone also compare the last 7 days with the 3 weeks
  before.
- **How close the forecasts were** (`ForecastScorecard`, in Insights on the Mac and iPhone and at
  the top of the Outlook page's card): the typical error at 15, 30 and 60 minutes next to assuming
  no change on the same forecasts, and how often the reading landed inside the likely range
  against the 8 in 10 it aims for. Only this device's forecasts with nothing logged before the
  reading count. A horizon needs 30 checks (about 8 hours of forecasts) to show, and the card stays
  hidden until 15 minutes has them. It describes how the forecast has done and never says what to
  do. `glucos.forecast_scorecard` gives the same figures per device on the server, including the
  relay's Lock Screen forecasts (device `relay`) once it records them.
- On the server: settled forecasts are uploaded with each logbook sync to `glucos.forecast_checks`
  through `public.forecast_push`. Uploads use the same signed-in session and row-level security as
  the logbook. Nothing is uploaded when logbook sync is off.
- From the relay, all night: the push relay keeps the forecast its Lock Screen card and followers
  were shown, every 15 minutes, as device `relay` (`supabase/functions/relay/ledger.ts`). It runs
  every minute whether or not the Mac is awake or the app is open, so these rows cover the hours
  the apps miss. The database scores them from `glucos.readings` with the same rules as the apps
  (`glucos.score_relay_forecasts`, every 5 minutes, over the last 4 hours), and `after_log` comes
  from the synced logbook. The relay's forecast is trend only and looks 30 minutes ahead, so it
  has 15- and 30-minute points. Rows belong to the owner's sync user (found from the LibreLinkUp
  login), so nothing is kept until the apps have signed in to sync once.

Queries (Supabase SQL editor or MCP, project `aqlbadbyjuoruwnwyfrc`):

```sql
-- Weekly accuracy by device and horizon; clean = nothing logged in between.
select * from glucos.forecast_accuracy where clean order by week desc, device, minutes;

-- Accuracy by Perth hour of day, all devices together: the relay's rows fill the night.
select extract(hour from issued_perth) as hour, minutes, count(*) as checks,
       round(avg(abs(actual - predicted))::numeric, 1) as mae_mgdl,
       round(avg(abs(actual - start_mgdl))::numeric, 1) as no_change_mae_mgdl
from glucos.forecast_points where not after_log group by 1, 2 order by 1, 2;

-- What the Insights card shows, per device (last 7 days, clean, 15/30/60 min).
select * from glucos.forecast_scorecard order by device, minutes;

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
  itself never moves. Since 15 Nov 2026 it also widens forecasts that start with glucose moving
  fast on their own, widens the range the same day when the last 12 hours miss more often, and
  counts ranges cut off at the sensor's limit; the relay does the same (§9).
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
point plus 20 minutes). Since round 30 (§35) both keep one every 5 minutes and send each once its
first hour is scored, then again when it settles. The Mac's quiet stretch, 2026-11-14 18:42 to 2026-11-15 03:31 UTC
(02:42–11:31 on 15 Nov in Perth), lines up with Declan asleep and then not yet at the Mac: the
logbook has him waking at 10:59 Perth time, and the Mac's first forecast came 32 minutes later.
The iPhone's own gap was shorter (its forecasts stopped at 02:21 and started again at 08:42 Perth
time, the times they were made), because the iPhone records a forecast whenever the app is open.
No uploads were missed.

Follow-ups shipped with this round (v0.39.0): the relay now records and scores its own Lock Screen
forecast every 15 minutes (device `relay`, #72), so nights are covered whether or not the Mac or
the iPhone app is awake; `glucos.forecast_scorecard` lists every device side by side and Insights
shows the user's own figures (#71); and a dose with no food near it now asks whether it was for a
meal (#73, docs/DoseQuestion.md), which addresses the unlogged-meal cause above at the source.

## 8. Drawn only as far as it holds, live (15 Nov 2026)

The replay (§1) sets how far ahead each kind of forecast may look, but it judges forecasts GlucOS
*would* have made from history. On 15 Nov the Insights card showed the iPhone's own forecasts
losing to no change at 60 minutes (47.7 against 39.8 mg/dL, 28 checks) while the replay still
allowed that far. So each device now also cuts the forecast back by its own live record
(`ForecastLedger.liveHorizon`, `ForecastLiveHorizon`):

- Per kind of forecast (trend, insulin-and-carbs), over the last 7 days of this device's forecast
  log (the same week the card shows), clean points only, at each checked horizon in turn.
- A drawn horizon is cut once it has 30 checks and its error is at least 5% more than no change's
  (what the card calls "further off than no change"). Everything after it goes too. "About the same"
  (within 5%) leaves it as it is, so the 15-minute iPhone figure (14.8 against 14.4) doesn't hide
  the forecast.
- A cut horizon comes back once its error is at least 5% less than no change's (the replay's own
  bar), and stays cut while it has fewer than 30 checks. Between the two it stays as it is, so it
  doesn't flicker.
- The forecast is still worked out to the replay's limit. The part past the cut is never drawn,
  alerted on, put in the widget or shared (`GlucoseForecast.unshown`), but it's kept in the
  forecast log with `"shown": false` on its points, so the cut horizon goes on being scored and can
  earn its way back. When 15 minutes itself is cut, there's no forecast ("Past forecasts haven't
  been accurate enough to show one") and the whole forecast is logged as not shown
  (`ForecastFailure.unshown`). The Outlook detail says why (`ForecastLimitation.liveHorizon`).
- The relay does the same for the Lock Screen from its own `relay` rows (`liveHorizon` in
  `core.ts`, worked out each time it scores, kept in `work.forecastLog.live`). Its forecast only
  reaches 30 minutes, so in practice it can drop to 15 minutes or to none.

The scorecard and `glucos.forecast_scorecard` count the points that weren't drawn, which is what
shows a cut horizon recovering. Range widening counts them too: their range was worked out the
same way.

## 9. Ranges that hold 8 in 10 (15 Nov 2026)

`glucos.forecast_scorecard` on 15 Nov showed readings inside the range 54–75% of the time on every
device and horizon (Mac 75 / 71 / 66% at 15 / 30 / 60 minutes, iPhone 69 / 68 / 54%, Lock Screen
71%), against the 80% the range promises. The widening from shown forecasts was running, but
replaying the server's history (`LiveReplayTests`, which now prints the hit rate by day with the
30-minute range width) showed three reasons it couldn't catch up:

- **It learnt too slowly.** Every point of the last 14 days counted the same, and the errors grew
  through the week (15-minute error ±14 mg/dL over the history, ±19.5 over the last two days). The
  figure trailed the misses by days: 64 / 62 / 58% at 15 / 30 / 60 minutes on the last day.
- **Fast-moving glucose missed about half the time.** With the trend at 2 mg/dL a minute or more,
  52–54% of readings landed inside the range (server, 7 days), against 75–83% below that. One
  figure for both widened the steady forecasts for the sake of the fast ones and still left the
  fast ones short.
- **Ranges cut off at the sensor's limit were left out**, 9–21% of points at 30–60 minutes, and
  they are the volatile ones.

The cap (2.5×) wasn't the problem: raising it to 4 changed nothing on its own.

`ForecastLedger.rangeScale` now works out three things, each measured against the range the one
before would have drawn, so none of them double-counts:

1. The steady figure, as before, from forecasts that started with glucose moving less than
   1.5 mg/dL a minute (`ForecastRangeScale.fastTrendPerMinute`, between the single and double
   arrows).
2. A figure for the fast ones (`fastTrend`), once there are 25 of their points.
3. A figure for the last 12 hours alone (`recent`), once there are 20 of their points, so a bad
   day widens the range that day and lets go of it 12 hours later.

Their product is capped at 4× (`totalMaximum`). Where the range was cut off on one side, the other
side's width stands in for it. It still never narrows the range.

Walk-forward replay of the server's 4.6 days, clean points, inside the range:

| | 15 min | 30 min | 60 min | 30-min range, last day |
| --- | --- | --- | --- | --- |
| Before, whole history | 74% | 77% | 63% | 70 mg/dL |
| After, whole history | 80% | 81% | 70% | 96 mg/dL |
| Before, last day | 64% | 62% | 58% | |
| After, last day | 76% | 81% | 74% | |

The 60-minute figure rests on 40 points, so it is the least settled. The price is a wider range on
bad days: ±2.7 mmol/L at 30 minutes on 15 Nov rather than ±1.9, which is what those days were
actually like.

**The relay** had no widening at all: its range was the replay's alone. It now does the same from
its own ledger (`rangeScaleFrom` in `supabase/functions/relay/core.ts`, worked out after each
scoring from its `glucos.forecast_checks` rows, kept in `relay.work.forecastLog.rangeScale`), and
records each point's widening as `scale` in the points JSON so the figure settles. Replaying the
relay's forecast the same way: 72 / 76% at 15 / 30 minutes before, 80 / 82% after. Relay 2.7.0.

## 10. The iPhone learns from one-minute readings too (15 Nov 2026)

`glucos.forecast_scorecard` on 15 Nov had the iPhone's 15-minute forecast doing no better than no
change (15.5 against 15.0 mg/dL, 84 checks) while the Mac's beat it (16.6 against 18.6). Both run
the same engine; what differs is the history each has:

- **The Mac** is awake for hours at a time, polling every minute, so its history (one reading per
  5-minute slot) is live readings, and the replay uses only those (§1).
- **The iPhone** is opened for a minute or two at a time (96 forecasts in 4 days, most of them on
  their own). Its history is LibreLinkUp's 15-minute graph plus the reading or two it saw while
  open. Fewer than half its replay points come from live readings, so the replay falls back to all
  of them, and on a 15-minute graph the trend carries on far more than a one-minute trend does.
  `ForecastTuner` fitted the trend's strength at 90–100% there (often failing to tune at all,
  which is why the iPhone's `tuned` flag came and went) against 55–70% on the Mac. The forecast on
  opening then followed the trend too far.

So the iPhone now fills its history from the push relay, which polls every minute whether or not
the app is open and keeps those readings in `glucos.readings`: `GET /v1/history?since=` (relay
2.9.0, at most 30 days back) returns them, and on every open and background refresh the phone asks
for what's new since the last time (`PhoneServices.fillHistoryFromRelay`), before fetching from
LibreLinkUp. They fill the 5-minute slots the graph leaves empty (`GlucoseStore.mergeHistory`), and
an hour or more of new ones makes the outlook relearn straight away. The forecast drawn on opening
also gets its trend from those readings rather than from two graph points. Without a relay (a
follower, or the relay not set up) nothing changes.

Replayed the way the iPhone lives through it (`LiveReplayTests` with `GLUCOS_REPLAY_OPENS` set to
its 96 forecast times: history is the 15-minute graph plus readings within a few minutes of each
open; `GLUCOS_REPLAY_FULL=1` gives it every reading, as the relay now does). Clean points, typical
error in mg/dL:

| | 15 min | No change | 30 min | No change | Trend strength fitted |
| --- | --- | --- | --- | --- | --- |
| Before (graph + opens) | 14.8 | 15.2 | 26.4 | 28.7 | 90–100% |
| After (relay readings) | 13.8 | 15.3 | 25.1 | 27.5 | 55% |

With the fuller history the replay holds trend-only forecasts to the same bar as on the Mac, so
the iPhone now draws fewer of them in quiet stretches (48 of the 78 openings had a forecast, as
against all 78): at those times they were checked as no better than no change, and the Mac already
leaves them out. Forcing the strength to 55% on the old history (`GLUCOS_REPLAY_GAIN=0.55`) also
gave 13.7 against 15.2, which confirms the strength was the fault; the relay's readings are what
let the phone measure it itself.

## 11. The relay's range learnt from its one-minute replay (15 Nov 2026)

`glucos.forecast_scorecard` on 15 Nov had the relay's Lock Screen forecast at 25.0 mg/dL against
27.0 for no change at 15 minutes, with only 58% of readings inside its range, against 68–74% for
the apps. Two things were behind those figures:

- **The error is the day, not the relay.** All 33 checks came from one day (the ledger started on
  15 Nov), and a fast-moving one. Over the same hours the Mac's 15-minute forecast was 23.2 against
  26.6 and the iPhone's 24.4 against 27.9: the relay's 24.7 against 27.2 is as good a share of no
  change as theirs. The relay already learns the trend's strength from its one-minute readings
  (`tuneTrend`, 45–55% for Declan), and a replay over every timing and strength (window 10–20,
  fade 15–60 minutes, strength 30–100%, a separate strength for fast trends) found nothing more
  than 1–2% better, less than the tuner's 3% bar. So the trend is left as it is.
- **The range had nothing to widen it.** Its range is the replay's 10th–90th percentile over two
  weeks, and the widening from §9 (`rangeScaleFrom`) needs 40 scored points of the relay's own
  before it does anything. On a new ledger, or after a gap, that is most of a day of ranges that
  are too narrow on exactly the days that need them wider.

So the relay now works the same widening out from its replay as well (`replayRangeScale` in
`supabase/functions/relay/core.ts`). Each relearn (every 3 hours) replays its forecast every 15
minutes over the last 14 days of one-minute readings; each replayed forecast at the horizons it
draws (15 and 30 minutes) gets the range `forecast` would have drawn, and `rangeScaleFrom` works
the steady, fast-trend and last-12-hours figures out from those just as it does from the ledger.
The result is kept as `calibration.rangeScale`, and `effectiveRangeScale` draws with the ledger's
widening when there is one and the replay's until then. Points record the widening they were drawn
with as before, so the ledger's figure still settles rather than compounding. Nothing about the
live horizon (§8) or the ledger's own widening (§9) changed; the replay only feeds them. The apps
keep their ledgers going, so they don't need it, and the parity test leaves it out. Relay 2.10.0.

Walk-forward replay (`scripts/relay-replay.ts`, which lives through the readings the way the relay
does: forecasts every 15 minutes, relearns every 3 hours, widens and cuts from a ledger it scores
itself). Clean points:

| | 15 min inside | 30 min inside | 15 min range | 30 min range |
| --- | --- | --- | --- | --- |
| 15 Nov, ledger new that morning (as it went live), before | 76% | 69% | 48 mg/dL | 72 mg/dL |
| 15 Nov, ledger new that morning, after | 88% | 75% | 60 mg/dL | 90 mg/dL |
| 11–15 Nov, ledger a day old, before | 83% | 85% | 44 mg/dL | 81 mg/dL |
| 11–15 Nov, ledger a day old, after | 83% | 85% | 45 mg/dL | 81 mg/dL |

The first two rows draw every horizon at every origin (`UNGATED=1`, 34 and 32 points) so that the
range is judged on a whole day; drawn as the relay would have, 15 minutes went from 73% to 91% of
11 points. Once the ledger has enough of its own it takes over, so a settled ledger is unchanged.
Typical error is the same before and after: only the range changed.

To run it, export `glucos.readings` as `[[t, mgdl], …]` into `readings.json` and the log times
(doses, meals, events other than waking, as `glucos.score_relay_forecasts` counts them) into
`log.json`, then `GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/relay-replay.ts`.
`LEDGER_FROM`, `WIDEN=ledger|replay|both|none`, `UNGATED=1`, `GAIN=x` and `LIST=1` are the knobs.

## 12. Insulin with no meal logged, checked on its own (15 Nov 2026)

On 15 Nov the iPhone's insulin-and-carb forecasts were losing to no change at 60 minutes (47.7
against 39.8 mg/dL), which is why §8 cut them back to 45, and the Mac's were only just ahead
(48.1 against 49.9). The question was whether fitting the user's own carb absorption and insulin
timing would fix the hour after meals.

**Fitting personal timing didn't help.** A walk-forward prototype over the server's 5 days of
one-minute readings (all there is: `glucos.readings` starts on 10 Nov, not 14 days back) tried 45
timings (carbs absorbed over 90–300 minutes, starting 0–30 minutes after eating, insulin peaking
at 55–100 minutes), refitting the timing and both effects every 3 hours from what was known then.
Clean insulin-and-carb points, typical error in mg/dL:

| | 45 min | 60 min |
| --- | --- | --- |
| Standard timing, the engine's learnt effects | 34.7 | 40.6 |
| Standard timing, effects refitted every 3 h | 37.7 | 44.5 |
| Personal timing and effects, refitted every 3 h | 38.2 | 45.8 |
| No change | 37.4 | 43.3 |

The chosen timing swung from 90 to 300 minutes between refits, and the fit often set both effects
to zero: with every dose given at a meal, the carbs' rise and the insulin's fall can't be told
apart from eight meals. Retrospective correction (adding the last 30 minutes' miss) was tried
again and made every horizon worse, as in §3. None of this went in.

**The losses aren't after meals.** Splitting the live forecasts (`glucos.forecast_points`, last 7
days, clean points) by whether a meal with carbs was logged in the 4 hours before:

| | After a meal, 45 / 60 min | No change | Insulin, no meal, 45 / 60 min | No change |
| --- | --- | --- | --- | --- |
| iPhone | 19.4 / 26.8 | 27.7 / 31.1 | 52.5 / 65.7 | 39.3 / 47.3 |
| Mac | 31.0 / 36.1 | 34.8 / 40.8 | 50.9 / 66.2 | 53.4 / 63.5 |

Forecasts after a logged meal beat no change on both devices. Forecasts with insulin acting and no
meal, mostly corrections, ran 25 mg/dL low on the iPhone: they expected the full drop from the
insulin, and food that wasn't logged (a hypo treated with 2026-11-15's 10 U correction acting, for
one) took glucose up instead. Lumped together, those cost the meals their hour.

**What changed.** An insulin-and-carb forecast with fast insulin acting and no logged carbs being
absorbed is now its own kind (`ForecastLimitation.insulinOnly`, `GlucoseForecast.insulinOnly`):

- The replay checks it apart (`ForecastCalibration.insulinOnly`), so the forecasts after meals
  (`byBasis[.trendInsulinCarbs]`) set their own horizon and range from their own checks.
- Until its own checks say otherwise, it's drawn only 30 minutes ahead, as far as the trend
  (`GlucoseForecaster.insulinOnlyUncheckedHorizon`).
- The live cut (§8) judges it apart too (`ForecastLiveHorizon.insulinOnly`, from records carrying
  the `insulinOnly` limitation code). Records from before this change don't carry it, so for up to
  a week the meal forecasts' live figure still includes the old insulin-only ones.
- The caveat says "Insulin only: no meal logged, so drawn only as far as these have held."

Walk-forward replay of the server's 5 days (`LiveReplayTests`, which now lists the two kinds
apart), clean points:

| | Before: 45 min | No change | 60 min | No change | After: 45 min | No change | 60 min | No change |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| After a meal | 27.2 | 34.7 | 38.6 | 50.6 | 23.4 | 31.2 | 25.5 | 33.2 |
| Insulin only | 41.1 | 41.4 | 50.8 | 50.0 | not drawn | | not drawn | |
| All insulin-and-carb forecasts | 34.5 | 38.2 | 46.2 | 50.2 | 23.4 | 31.2 | 25.5 | 33.2 |
| Last 2 days | 50.9 | 49.9 | 60.1 | 58.5 | not drawn | | not drawn | |

Drawn 45- and 60-minute forecasts now beat no change by about a quarter, and the ones that lost
(insulin alone, and the last two days, which were mostly corrections) aren't drawn past 30
minutes. The price is fewer long forecasts: 17–18 drawn at 45–60 minutes rather than 53–67,
because the meal forecasts need 30 checks of their own at a horizon before the replay allows it.
These figures rest on about ten meals; they'll firm up as more are logged. 15- and 30-minute
figures are unchanged (14.5 / 22.5 against 14.8 / 23.5).

## 13. Earlier warning before lows (15 Nov 2026)

The question: how early do the forecast-based low alerts ("Low predicted in about N min") warn
before readings go under 70 mg/dL, how many lows get no warning, and how many alerts are false
alarms?

**What there is to measure.** `glucos.readings` starts on 10 Nov, so there are 5 days, not 14,
and 110 hours of one-minute readings to tick through. The relay's ledger only starts on 15 Nov (35
checks) and the apps' `forecast_checks` are one forecast per 15 minutes, too sparse to time an
alert: Mac snapshots predicted a low 6 times (4 followed by a low within 45 minutes), the iPhone's
4 times (1), the relay's once (0). So the measure is a walk-forward replay of the relay itself,
`scripts/low-alert-replay.ts`: every minute it forecasts from the hour before, relearns every 3
hours, cuts the drawn horizon from its own ledger (§8), and runs the alert rules as the tick does.
A low starts at the first reading under 70 and ends after 15 minutes back above. It counts as
warned if a predicted-low alert came in the hour before it started; an alert is a false alarm if
no reading goes under 70 in the 45 minutes after it.

**What it found.** All six lows were warned, but late: a median of 6 minutes ahead, mean 8.2. The
"warn me ahead by 20 minutes" setting wasn't what limited it. On 92% of ticks the relay draws its
trend only 15 minutes ahead (the replay says the trend doesn't beat no change at 30 minutes on
average), and the alert only looked at what was drawn, so lows were looked for 15 minutes ahead
whatever the setting. One alert in 18 was a false alarm (15 Nov 06:11, a fall from 237 that
levelled at 86).

**Tried and rejected** (same replay, lows looked for 30 minutes along the trend; base: 6 minutes
ahead median, 1 false alarm):

| Change | Median / mean warning | False alarms |
| --- | --- | --- |
| Trend at full strength for alerts | 13 / 17.7 min | 12 |
| Crossing read 15% toward the range's lower edge | 12 / 14.8 min | 4 |
| …and confirmed on 2 ticks in a row | 11 / 13.8 min | 2 |
| Crossing read 30% toward the lower edge | 14 / 16.3 min | 11 |
| Fall needed to alert raised to 0.5–1.2 mg/dL a minute | no earlier | same |
| Confirmed on 3–5 ticks | 2–9 min | 2–5 |
| Shorter (10–15 min) or longer (25 min) trend window | 4–7 min | 0–4 |
| Not after a rise in the 10–20 minutes before | 5–13 min | 5–11 |

Every way of calling a low earlier also called falls that levelled off. The false alarms were
mostly steep drops straight after a rise or a spike, which level off; the real lows were longer
falls that sped up near the end, which a fading trend can't see coming much
earlier.

**What changed.** Predicted lows now look along the trend's full 30 minutes, whatever is drawn:
the drawn forecast, the part live checks cut off (`unshown`), and the trend carried on past the
calibrated horizon (`GlucoseForecast.lowLookahead`, `Forecast.lowLookahead` on the relay, central
line only, never drawn, shared or scored). The default "warn me ahead by" is now 30 minutes, so
the setting is what it says. Predicted highs still read only what's drawn and look no further than
30 minutes (`PredictiveAlertRules.highLeadMaximum`), as they did at the old 20-minute default.
Relay 2.11.0.

| Replay, 110 h, lows under 70 | Lows | Warned | Median ahead | Mean ahead | Alerts | False alarms |
| --- | --- | --- | --- | --- | --- | --- |
| Before (drawn only, 20 min) | 6 | 6 | 6 min | 8.2 min | 18 | 1 |
| After, 20-minute setting | 6 | 6 | 6 min | 9.2 min | 18 | 1 |
| After, 30-minute default | 6 | 6 | 6 min | 10.8 min | 18 | 1 |

Each low by when it was first warned (before → after): 11 Nov 06:51 20 → 27 min, 12 Nov 10:45
6 → 6, 12 Nov 15:39 4 → 4, 13 Nov 11:05 8 → 10, 15 Nov 09:16 8 → 14, 15 Nov 13:40 3 → 4. Urgent-low
heads-ups move up too (15 Nov 13:40: at 69 rather than 66). None came later, and no alert was
added or lost. The median doesn't move because three lows were sharp drops that nothing in the
trend saw more than 4–6 minutes out. Six lows is a small sample; rerun the replay as more build up:

    GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-replay.ts
    # LOOK=drawn for the old rule, LEAD=min for another setting, LIST=1 for each low and alert

The Mac and iPhone use the same rules (`PredictiveAlertRules`) on their own forecasts, so the
lookahead applies there too whenever their forecast is the trend. Their insulin-and-carb forecasts
still alert only on what's drawn: the insulin-only ones ran 25 mg/dL low (§12), and reading their
cut-off part would call lows that don't come.

## 14. Accuracy per app version (15 Nov 2026)

The 7-day scorecard mixed forecasts from several releases (rounds 4 to 7 all shipped on 15 Nov),
so a release that changed the forecast only showed up in it days later. Each forecast now carries
the version that showed it (`ForecastRecord.appVersion`, `forecast_checks.app_version`; the relay
records its own version, 2.12.0 on). Records from before have none.

- On the device, the Insights card (and the Outlook page) keep the 7-day figure and add the
  installed version's own figure under each horizon once it has 30 clean checks there
  (`ForecastSinceUpdate`). Until then the card says how many checks the version has so far. When
  the whole week is on one version there is nothing to split and the card just says so.
- On the server, `glucos.forecast_scorecard_by_version` gives the same figures per device and
  version over 30 days, with each version's first and last forecast:

```sql
select shown_on, app_version, minutes, checks, mae_mmol, no_change_mae_mmol, inside_range_pct, first_issued
from glucos.forecast_scorecard_by_version order by shown_on, first_issued desc, minutes;
```


## 15. Do slow meals need a longer, flatter curve? (15 Nov 2026)

Every meal is absorbed on one curve (`CarbAbsorptionCurve.standard`: starts 10 minutes after
eating, done 3 hours later). Burgers, fried food and big mixed meals are often absorbed later and
for longer, so the question was whether giving those meals a longer, flatter curve would make the
30- and 60-minute forecasts after them better. The bar for shipping it: better than the standard
curve at both 30 and 60 minutes on meals the curve wasn't chosen from. **It didn't clear that bar,
so nothing changed.**

**What the data allows.** The logbook stores only carbs for a meal, and the bundled food data
(AUSNUT, Open Food Facts carbs) has no fat or protein, so "slow" can't be worked out from the
food; the meals were sorted by hand from their names. Of the 14 meals logged, 7 have live
insulin-and-carb forecasts after them (the forecast log starts on 12 Nov). Three are slow: the
burrito bowl (12 Nov, 37.5 g), eggs and hash browns (13 Nov, 35.8 g) and the Big Mac (14 Nov,
38.5 g, whose forecasts only start 80 minutes after eating). The sushi had no forecasts of its own
(the green juice was logged 74 minutes later), and the rest are drinks. None of the slow meals
was over 50 g, so "large" couldn't be tested apart. That's 56 checks at 30 minutes and 46 at 60
from three meals: enough to rule out a large, consistent gain, not enough to find a small one.

**How it was tested.** For each clean insulin-and-carb point in `glucos.forecast_points` within 4
hours after a meal, the standard curve's carb term was swapped for the candidate curve's, with the
same blend into the trend over the first 30 minutes and the learnt carb effect (2.8 mg/dL per g;
2.0 and 3.5 give the same verdict). Candidates: a start 10–60 minutes after eating and absorption
over 3–6 hours, 30 timings. Each slow meal was held out in turn, the timing chosen on the other
two and scored on the held-out one. Typical error, mg/dL:

| Held-out meal | Timing chosen on the other two | 30 min, standard → slow | 60 min, standard → slow |
| --- | --- | --- | --- |
| Burrito bowl | starts at 60 min, 4 h | 27.5 → 30.2 | 47.6 → 58.6 |
| Eggs and hash browns | standard | 10.6 → 10.6 | 24.3 → 24.3 |
| Big Mac | starts at 60 min, 4 h | 14.4 → 15.9 | 21.8 → 18.8 (4 checks) |
| All three | | 17.1 → 18.3 | 32.2 → 35.7 |
| No change | | 22.9 | 38.4 |

Held out, the slow curve was worse at both horizons. The three meals each wanted something
different: on its own the burrito bowl fits the standard curve best, eggs and hash browns a start
at 60 minutes over 4 hours, and the Big Mac a start at 60 minutes over 3 hours.

Fixed slow timings chosen up front rather than fitted gave the same picture (all three meals,
30 / 60 min):

| Slow-meal curve | Burrito bowl | Eggs and hash browns | Big Mac | All three |
| --- | --- | --- | --- | --- |
| Standard (10 min, 3 h) | 27.5 / 47.6 | 10.6 / 24.3 | 14.4 / 21.8 | 17.1 / 32.2 |
| 20 min, 4 h | 29.3 / 54.2 | 9.2 / 17.3 | 14.9 / 19.4 | 17.1 / 30.3 |
| 20 min, 4.5 h | 29.8 / 55.7 | 8.8 / 15.2 | 15.7 / 22.1 | 17.3 / 29.9 |
| 30 min, 5 h | 30.1 / 56.8 | 8.7 / 14.1 | 16.6 / 24.6 | 17.5 / 29.9 |
| 30 min, 6 h | 30.2 / 56.5 | 9.0 / 15.2 | 17.5 / 28.6 | 17.9 / 30.7 |

A 4–5 hour curve helps the eggs and hash browns at 60 minutes (24.3 → about 15) and costs the
burrito bowl about as much (47.6 → 55), with 30 minutes no better overall. The pooled 60-minute
gain (32.2 → 29.9) is that one meal, and it fails the 30-minute half of the bar. Giving every meal
the slower curve is worse for the drinks (60 min 39.9 → 43.1), as expected.

The burrito bowl's misses aren't timing: its forecasts ran 31 mg/dL high at 60 minutes because
glucose fell from 264 to about 150 two to three hours after eating, which is the insulin (or less
carbohydrate than logged), not carbs arriving late.

**What would settle it.** Ten or more slow meals logged with forecasts from the start, and the
food data carrying fat and protein so "slow" comes from the food rather than its name (AUSNUT
has both; the build script keeps carbs only). The test then reruns as is: per-meal hold-out, ship
only if 30 and 60 minutes both improve. The prototype was a scratch script; it's simple to redo
from the description above.

## 16. Does "Your usual day" help overnight? (16 Nov 2026)

"Your usual day" in Insights (`DayPattern`) draws the median glucose for each half hour of the day.
Overnight there's usually nothing logged, so the forecast is the trend alone, and the question
was whether the usual shape of the night (the dawn rise in particular) would make the 30- and
60-minute forecasts better. The bar for shipping it: better than the current forecast at both 30
and 60 minutes on nights the pattern wasn't built from. **It didn't clear that bar, so nothing
changed.**

**What the data allows.** The server has readings from 10 Nov 22:45 to 16 Nov 02:36 (Perth), so
five full nights and part of a sixth. Every night was scored with a usual day built from the
other days only (the card's own method: 5-minute buckets, half-hour medians, 1-2-1 smoothing),
so each pattern came from four or five days, below the card's own 5-day minimum. Overnight here
means forecasts issued 22:00–09:00 Perth. The forecast log has only 102 overnight checks at 30 and
60 minutes from four nights, because the Mac sleeps and the iPhone is in the background: 28 clean
checks at 30 minutes and 15 at 60, and just 3 between 03:00 and 09:00, none of them at 60. So the
test also used a replay of the trend forecast every 15 minutes on the one-minute readings (183
checks at 30 minutes, 181 at 60, from five nights), with the trend gain fitted on the other nights.

**The usual night does have a dawn rise.** The median falls to about 110 mg/dL at 04:00–05:00 and
climbs to about 160 by 07:00 and 190 by 08:00, and glucose rose between 05:00 and 07:00 on every
one of the five nights (+17 to +54). But the level is very different from night to night (05:00
was 94–108 on three nights and 246–269 on the other two) and the rise starts at different times,
and a pattern built from four days can't tell those apart.

**Two ways of using it were tested.** *Shape*: add the usual day's change over the next 30 or 60
minutes to the forecast, at weights of 0.25, 0.5 and 1. *Level*: pull the forecast a share (0.1,
0.2, 0.3) of the way to the usual day's level at the forecast time. The weight was picked on the
other nights and scored on the held-out one. Typical error, mg/dL:

| Overnight checks | Horizon | Checks | Current | Usual day, held out | No change |
| --- | --- | --- | --- | --- | --- |
| Live, clean | 30 min | 28 | 24.6 | 23.5 | 34.0 |
| Live, clean | 60 min | 15 | 51.4 | 53.7 | 51.9 |
| Live, all | 30 min | 60 | 30.7 | 29.1 | 32.2 |
| Live, all | 60 min | 42 | 52.3 | 44.0 | 46.9 |
| Replay, clean | 30 min | 147 | 20.3 | 20.7 | 21.1 |
| Replay, clean | 60 min | 147 | 35.9 | 36.2 | 36.1 |
| Replay, 04:00–08:00 | 30 min | 57 | 16.5 | 16.5 | 17.0 |
| Replay, 04:00–08:00 | 60 min | 57 | 28.6 | 32.1 | 28.7 |

On clean live checks the shape helps at 30 minutes and loses at 60. On the replay, which has five
times the checks, it's no better at 30 minutes and worse at 60, and in the dawn hours it costs 3.5
mg/dL at 60 minutes: the trend already follows the rise once it starts, and the usual day's timing
is wrong on most nights.

The one large gain, live "all" at 60 minutes (52.3 → 44.0), isn't the usual day. It comes from the
night of 12–13 Nov, when the sports drink and the insulin-and-carb forecasts around it were far off
(before calibration), and pulling any forecast towards a typical level shrinks those misses.
Pulling towards a flat 150–170 mg/dL (the median of the other days) instead of the time-of-day
curve does about as well (44.6), and on clean checks the flat level does better than the usual
day (47.0 against 49.4 at 60 minutes). That's damping, not time of day, and the after-log and
uncalibrated cases already have their own ranges and caps (§12, §8).

**What would settle it.** Two to three weeks of nights, so the pattern has 14+ days behind it as
the card does, and forecasts logged through the night (the relay keeps forecasting while the
devices sleep, so its ledger is the place to look once it has enough nights). The dawn rise is
better tied to waking than to the clock: `MorningPatternLearner` (docs/Mornings.md) already learns
the rise after a logged wake-up, and that's the lever to strengthen. Rerun as is: per-night hold-out,
shape and level weights, ship only if 30 and 60 minutes both improve, including 04:00–08:00. The
prototype was a scratch script; it's simple to redo from the description above.

## 17. Compression lows overnight: is a guard worth it? (16 Nov 2026)

A compression low is a sensor reading low because it's been lain on: a sudden drop, often into
the 50s or 60s, that bounces back within about 20 minutes once you roll over, with nothing eaten.
The question was whether these send false low alerts or throw out the 15–30 minute forecast at
night, and whether a guard (for example, holding the alert until a second reading agrees) would
cut those false alerts **without delaying any real low**. That last part was the bar, after a real
low to 51 mg/dL (2.8 mmol/L) at 00:52–01:42 Perth tonight. **No guard cleared it, so nothing
changed.**

**What was looked at.** All of `glucos.readings` (10 Nov 22:45 to 16 Nov 03:08 Perth: five and a
half nights, about 112 hours of one-minute readings), the logbook, and the overnight
`forecast_checks`. `scripts/compression-lows.ts` lists every dip of 20+ mg/dL at 2+ mg/dL a
minute that bounced back two thirds of the way within 20 minutes, and every low (readings under
70). Overnight here is 22:00–07:00 Perth.

**No compression low reached the low line.** There were 22 such dips, 9 of them overnight and 7
of those with nothing logged. All 7 bottomed out between 95 and 238 mg/dL, far above 70, so none
could set off a low alert from a reading. Only one dip went under 70 at all (12 Nov 23:39, 105 →
66): it was treated, with carbs logged at 23:42. Of the 8 lows in the data, the two overnight
ones were both real and treated (12 Nov 23:39 and tonight).

**Tonight's real low started out looking like a compression low.** Readings fell 96 → 67 in six
minutes (00:47–00:53), the steepest fall of the night at 4–5 mg/dL a minute, and came back up to
78 by 00:57. That's the textbook shape. Then they fell again from 01:01 and stayed under 70 for 40
minutes, down to 51, until the carbs at 01:05 brought it back. A guard that held the 00:52 alert
because the drop was sudden, overnight and bouncing back would have put off the first warning of a
genuine 2.8 by around ten minutes.

**Predicted lows.** The forecast-based alerts are where night-time falls do cause false alarms.
Replaying the alert rules on the full 30-minute trend at every one-minute reading (the most
predicted-low alerts the relay could send, before its calibration cuts the forecast short) gives
40 alerts, every one of the 7 lows in the window warned (median 18 minutes ahead), and 10 false
alarms. Four were overnight: 13 Nov 00:40 and 03:42, 14 Nov 00:52 and 01:32, falls from about
110 that levelled off at 90–100. The live overnight checks show the same thing: of 14 forecasts
issued in a fall of 1.5+ mg/dL a minute, three ran 17–45 mg/dL low at 15–30 minutes because the
fall bounced back, but none of those three called a low. The one that did (Mac, 12 Nov 23:36,
forecasting 52) was right until the carbs.

**Every guard tried would have delayed tonight's warning.** Measured at the moment of each first
warning, the false alarms and the real lows look alike:

| At the first alert | Real lows (7) | False alarms (8) |
| --- | --- | --- |
| Reading | 86–129 | 91–113 |
| Change over the last 15 min | −18 to −67 | −21 to −52 |
| Rose in the 15 minutes before that | 2 of 6 | 5 of 7 |

Tonight's low is the hardest case: the first warning came at 00:34 at 126 mg/dL, after a rise
(+34 over 00:04–00:19) and then a fall of 61 in 15 minutes, which is exactly the shape of the
false alarms. So:

- *A second reading to confirm a low reading* saves nothing here (no compression low crossed 70)
  and delays every real low by at least a minute, or 15 minutes on LinkUp's 15-minute history.
- *Holding predicted lows for sudden, overnight or after-a-rise falls* would have held tonight's
  00:34 and 00:40 warnings. §13 already rejected confirmation ticks and a no-recent-rise gate for
  the same reason.
- *A steeper fall needed to alert* misses lows that start slowly (12 Nov 23:34 and 15 Nov 21:34
  fell 18–22 in 15 minutes), and §13 found it gave no earlier warnings either.

So the alerts stay as #90 left them. A missed real low costs far more than a false alarm at
night, and nothing in five nights tells the two apart in time.

**Something to look at next.** The readings table holds a second reading a second or so from a
live one at most 15-minute marks: LinkUp's graph points, merged by exact time
(`mergeReadings`). In 100 of 255 such pairs the two differ by 5 mg/dL or more, which puts small
false blips and dips into the one-minute series. It also makes the low-alert replay depend on
which of each pair is kept. On today's export, §13's replay draws no forecast on about 80% of
ticks and warns of 1–3 of the 7 lows, where the live relay forecast through tonight's low
(00:40, 110 falling 3.7 a minute, forecast 89 at 15 minutes against 71). Keeping one reading per
minute in the store and in exports would remove those blips. It's a data fix, not a guard, and
it should be checked against the replay before it ships. §18 did that, and it didn't.

    GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/compression-lows.ts
    # DROP=mg/dL and RATE=mg/dL a minute change what counts as a dip; TZ_HOURS for another time zone

Rerun this once there are a few weeks of nights. A guard is worth trying again only if
compression lows that cross 70 start to show up, and only if it holds no warning of a low that
the readings then confirm.

## 18. One reading per minute: should LinkUp's graph points go? (16 Nov 2026)

The relay stores each live reading and, every 15 minutes, LinkUp's graph point for about the same
moment, 1–9 seconds apart (`glucos.readings` keys by exact time). The question from §17 was
whether keeping one reading per minute, the live one, would take the small blips out of the
history without making forecasts or low alerts worse. **It made both worse, so nothing changed.**

**The pairs.** 263 of 6,847 readings (10 Nov 22:45 to 16 Nov 03:40 Perth) sit within 30 seconds of
another. Every pair is one live reading (trend known) and one graph point (trend 0), so they are
easy to tell apart; 122 differ by 5 mg/dL or more. Live readings never come closer than 55 seconds
to each other, so a 30-second window loses no real reading.

**The apps don't keep them.** The Mac and iPhone archive (`HistoryArchive`) keeps one reading per
5-minute slot, so the app charts never hold both of a pair. Only the relay's one-minute series (its forecast, alerts and the scorecard's
`reading_at`) and exports hold both.

**The replay.** Exported with exact times and the trend (so the replay ticks the way the relay
does), then run as is and with `ONE_PER_MINUTE=1`. Forecast errors are scored against the same
one-per-minute readings both ways, so only the forecast's input differs.

| | Both kept (now) | One per minute |
|---|---|---|
| 15 min error, every origin (`UNGATED=1`) | 15.1 (no change 15.8) | 15.6 (no change 15.9) |
| 30 min error, every origin | 23.9 (no change 24.6) | 24.5 (no change 25.0) |
| 15 min forecasts the relay draws | 168 | 30 |
| Lows warned (of 7) | 7, median 6 min ahead | 6, median 4 min ahead |
| False low alarms | 1 | 0 |

Taking the graph points out makes the trend about half a mg/dL worse, and the relay's own replay
then judges the 15-minute forecast no better than no change and hides most of it. The low on
15 Nov 17:16 Perth (nadir 54) got no warning at all, where it now gets 14 minutes, and two others
were warned a minute later. Ticking only on live readings while keeping both pairs in the data
gives the same 7 of 7 as now, so it's the graph points themselves that help, not extra ticks.
LinkUp's graph values are its own smoothed history, and the forecast's trend fit seems to gain
from that second, steadier sample every 15 minutes. Keeping the graph point instead of the live
reading was no better (6 of 7 lows warned, 15 min error 15.5).

So the relay keeps both, as it does now, and low-alert timing is unchanged. §17's export note
stands corrected: with exact times the replay draws a forecast on 92% of ticks and warns of all
7 lows; the 80%-blank result came from rounded times in that export.

To export with the trend, and to rerun:

    -- one row per reading: [unix seconds, mg/dL, trend]
    select json_agg(json_build_array(extract(epoch from at)::bigint, mgdl, trend) order by at) from glucos.readings;

    GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-replay.ts
    ONE_PER_MINUTE=1 GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-replay.ts
    # and the same for scripts/relay-replay.ts, with UNGATED=1 to judge the forecast itself

Worth trying again with a few weeks of readings, and only if it keeps every low warning.

## 19. Should the range change with time of day? (16 Nov 2026)

The range is meant to hold the actual reading 80% of the time. The question was whether some
parts of the day miss more often than others, and if so whether each part of the day should get
its own widening on top of `ForecastRangeScale` (§9, §11). **It shouldn't yet. A separate figure
for each part of the day did worse on days it hadn't seen than one figure for the whole day, so
nothing changed.**

**The data.** These are the clean points (nothing logged after the forecast) in
`glucos.forecast_checks`, from 12 Nov 15:23 to 16 Nov 04:45 Perth, on the Mac, iPhone and relay.
That is 459 points at 15 and 30 minutes and 109 at 60 minutes, from four days and nights. The
times of day use Perth time: night 00–06, morning 06–12, afternoon 12–18 and evening 18–24.

**Shown ranges as they are.** Every part of the day is under 80% at every horizon, except the
morning:

| Inside range | Night | Morning | Afternoon | Evening |
|---|---|---|---|---|
| 15 min | 71% (45) | 76% (29) | 71% (89) | 69% (106) |
| 30 min | 56% (25) | 84% (25) | 67% (70) | 73% (70) |
| 60 min | 63% (16) | 83% (12) | 61% (51) | 63% (30) |

The morning figures come from three mornings, and the 60-minute one from just one. The days
differ from each other more than the parts of the day do. At 30 minutes, coverage by day was 55%,
81%, 73% and 67% (12–15 Nov). Ranges also got wider through the week as §9 and §11 landed, so
the older points are measured against narrower ranges than the apps draw now.

**The test.** For each point, the miss is the distance from the forecast to the actual reading,
divided by the range's half-width on that side. A side clipped at the sensor floor uses the upper
half-width instead. For each day held out in turn, the widening needed to hold 80% was learnt
from the other days. It was learnt once as a single figure for the whole day, and again as one
figure for each part of the day. Both were then scored on the held-out day.

| Held-out days, 15 + 30 min (459 points) | Inside | Mean width |
|---|---|---|
| As shown | 70% | 51 mg/dL |
| One figure for the whole day | 79% | 70 mg/dL |
| One figure per part of the day | 77% | 74 mg/dL |
| Per part of the day, shrunk halfway to the whole-day figure, 20+ points each | 77–79% | 55 / 91 mg/dL (15 / 30 min) |

Splitting by time of day made the ranges wider and coverage lower. The night is the clearest
case. To reach 80% on a held-out night, the 30-minute range would have had to be 156 mg/dL wide
(about 8.7 mmol/L), because one night (15 Nov, around 01:00–02:30) swung far more than the
others. The morning looked like it could be narrowed. Held out, though, it needed as much
widening as the rest. Shrinking each part's figure halfway towards the whole-day figure only
matched the whole-day figure, and didn't beat it.

The whole-day row isn't a new change. It is what the existing widening already does from each
device's own shown points (§9), and those figures were learnt from ranges that are now out of
date. Live coverage since §11 should be read from the scorecard, not from this table.

To rerun, using the miss ratio described above:

    with p as (select c.issued_at at time zone 'Australia/Perth' lt, (e->>'minutes')::int m,
      (e->>'actual')::float a, (e->>'lower')::float lo, (e->>'upper')::float up, (e->>'mgdl')::float f,
      coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e)
    select m, extract(hour from lt)::int / 6 part, count(*),
      avg((abs(a - f) <= case when a >= f or lo <= 39 then up - f else f - lo end)::int) inside
    from p where a is not null and not al group by 1, 2 order by 1, 2;

Try this again with at least three weeks of points, so each part of the day has about 20 days.
Look first at night, which misses the most and has the fewest points.

## 20. Does the insulin-on-board curve fit? (16 Nov 2026)

Saved insulins (docs/Insulins.md) only set a name and a kind. The timing comes from the kind:
NovoRapid is `.rapid`, which uses `InsulinActionCurve.rapid` (10-minute delay, peak 75 minutes
after that, finished 6 hours after that). The forecast's insulin effect and the bolus
calculator's insulin on board (`InsulinActivity.compute`) both use that one curve. The question
was whether a different peak or duration fits the drops seen after corrections. **None fitted
better on corrections it hadn't seen, so the curve is unchanged.**

**The data.** The server's readings start on 10 Nov 14:45 UTC. Since then 13 fast-acting doses
were logged, and 9 went with a meal. That leaves four correction windows, and none is fully
clean:

| Window (Perth) | Insulin | What muddies it |
| --- | --- | --- |
| A, 11 Nov 12:56 | 6 U, plus 8 U from 10:46 | Pancake breakfast 3½ h before; ends at a 61 low and an unlogged rise |
| B, 14 Nov 20:04 | 1.5 U, then 4 U at 22:00 | Big Mac 3 h before; ends at 23:10, before an unexplained rise |
| C, 15 Nov 11:30 | 4.5 U, then 10 U at 12:51 | Flat for 80 minutes after the 4.5 U, then 225 mg/dL in 50 minutes; ends at a 92 that bounced straight up |
| D, 15 Nov 18:38 | 6 U | Taken while glucose was still rising from an unlogged low treatment; ends at a 57 |

Every window ends early, at a low or a rise with nothing logged. So these show the first 1½–3
hours of the curve, and say little about its tail.

**The test.** Each window was modelled as glucose = a starting level − sensitivity × insulin
acted since the start, counting every fast-acting dose still on board. The grid had 175 curves:
delays of 0, 10 and 20 minutes, peaks of 35–100 minutes and durations of 3–6 hours. Each curve
was scored two ways. First, with its own sensitivity per window, which tests shape only. Second,
leaving one window out: the curve and one shared sensitivity were chosen on the other three, then
scored on the held-out window. Typical error is in mg/dL, on 5-minute averages.

| | Shape only, same windows | Held out, from the dose | Held out, from the high |
| --- | --- | --- | --- |
| Current curve (10 / 75 min / 6 h) | 15.4 | 17.5 | 16.1 |
| Best grid curve (0 / 100 min / 5 h) | 15.0 | | |
| Curve chosen on the other three | | 20.4 | 19.6 |

("From the high" starts each window at its highest reading in the first 40 minutes, to take out
the rise that was still under way in D.)

On the windows it was picked from, the best curve was only 0.4 mg/dL better, and the top eight
curves were within 0.1 of each other. Held out, the chosen curve lost in three of the four
windows. It also moved between folds: peaks of 80–100 minutes and durations of 3½–6 hours. Four
muddied windows can't pin the curve down. A later peak looked slightly better only because the
windows start on rises that hadn't finished yet.

**What a change would do to doses.** The calculator takes insulin on board off a correction. The
current curve leaves 0.83, 0.50, 0.24 and 0.09 of a unit on board after 1, 2, 3 and 4 hours. The
best grid curve leaves 0.83, 0.51, 0.23 and 0.06. On 14 Nov at 20:04, the 5 U from 17:04 counted
as 1.20 U on board, and the best curve would have counted 1.15 U. That rounds to the same 1.5 U
dose. So even the best-looking alternative would barely move suggested doses, and it isn't
better.

The fitted sensitivities (24–38 mg/dL per unit) are not an estimate of the correction factor.
Unlogged treatments push glucose up inside every window, which pulls the fit down. Settings
review (docs/FoodAndBolus.md) is the place for that, and it needs clean examples too.

Try this again once there are about ten corrections that each have 4 hours with no food before or
after. Logging low treatments is what makes a correction window usable. Without them, every
window ends at the first low. To find candidate windows:

    select d.user_id, d.payload->>'units' u,
      to_timestamp((d.payload->>'timestamp')::float) at time zone 'Australia/Perth' t
    from glucos.logbook d where d.kind = 'dose' and not d.deleted and d.payload->>'kind' in ('rapid', 'ultraRapid')
      and not exists (select 1 from glucos.logbook m where m.user_id = d.user_id and m.kind = 'meal' and not m.deleted
        and abs((m.payload->>'timestamp')::float - (d.payload->>'timestamp')::float) < 4 * 3600)
    order by d.user_id, t;

## 21. Should the range depend on how fast glucose is moving? (16 Nov 2026)

§9 already splits the range in two by speed: forecasts that start with glucose moving at
1.5 mg/dL a minute or more (`ForecastRangeScale.fastTrendPerMinute`) get their own widening,
and everything else shares the steady figure. The question was whether finer speed bands
(flat, slow and fast, or rising apart from falling) would hold 80% better. **They don't. On days
they hadn't seen, none of the finer splits beat the existing two-way split, so nothing changed.**

**The data.** The same kind of points as §19: clean points (nothing logged after the forecast) in
`glucos.forecast_checks` at 15 and 30 minutes, from 12 Nov 15:23 to 16 Nov 06:17 Perth, on the
Mac, iPhone and relay. That is 467 points (277 at 15 minutes and 190 at 30). Speed is the trend
the forecast started from, in mg/dL a minute: flat is under 0.5, slow is 0.5 to 1.5, fast is
1.5 or more.

**Shown ranges as they are.** Fast forecasts miss most, as §9 found. The surprise is that flat
forecasts miss more often than slow ones:

| Inside range | Flat | Slow | Fast |
|---|---|---|---|
| 15 min | 72% (71) | 77% (122) | 60% (84) |
| 30 min | 68% (53) | 78% (86) | 59% (51) |

Flat missed more than slow on four of the five days. One guess, not checked: a trend near zero
is often a peak or a dip that is about to turn, so "flat" doesn't mean calm.

**The test.** Same method as §19. The miss is the distance from the forecast to the actual
reading, divided by the range's half-width on that side (a side clipped at the sensor floor uses
the upper half-width). For each day held out in turn, the widening needed to hold 80% was learnt
from the other days, per horizon and per speed band, and never below 1. A band with fewer than
25 points in the other days fell back to one figure for that horizon, as the apps do. The
interval score adds the width to ten times any miss beyond the edge, so lower is better and it
can't be won by width alone.

| Held-out days, 15 + 30 min (467 points) | Inside | Mean width | Interval score |
|---|---|---|---|
| As shown | 70.2% | 51.3 mg/dL | 117.2 |
| One figure | 78.8% | 70.4 mg/dL | 116.3 |
| Steady / fast at 1.5 (what §9 does) | 79.2% | 69.8 mg/dL | 116.3 |
| Flat / slow / fast (0.5, 1.5) | 79.4% | 70.2 mg/dL | 117.1 |
| Four bands (0.5, 1, 2) | 78.8% | 67.3 mg/dL | 117.4 |
| Flat, slow and fast, rising apart from falling (five bands) | 77.3% | 67.8 mg/dL | 118.3 |

Splitting flat from slow gave the same coverage at the same width. Flat needed more widening
and slow needed less, but slow's figure was already close to 1, and the range is never narrowed,
so nothing was saved. Four bands gave slightly narrower ranges, but coverage dropped with them
and the score got worse at 30 minutes (151.2 against 146.9). Splitting rising from falling gave
each band too few points (a day held out left 20–60 per band), and it lost on every measure.

The days differ more than the bands do. Fast forecasts needed 4.1× on 13 Nov and 0.9× on
16 Nov, and slow ones 0.8× on 14 Nov and 1.65× on 15 Nov. The `recent` correction (§9) is what
follows that.

To rerun, using the miss ratio above:

    with p as (select (c.issued_at at time zone 'Australia/Perth')::date d, c.trend_per_minute tr,
      (e->>'minutes')::int m, (e->>'actual')::float a, (e->>'lower')::float lo, (e->>'upper')::float up,
      (e->>'mgdl')::float f, coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al
      from glucos.forecast_checks c, jsonb_array_elements(c.points) e)
    select m, case when abs(tr) < 0.5 then 'flat' when abs(tr) < 1.5 then 'slow' else 'fast' end band,
      count(*), avg((abs(a - f) <= case when a >= f or lo <= 39.5 then up - f else f - lo end)::int) inside
    from p where a is not null and not al and m in (15, 30) group by 1, 2 order by 1, 2;

Try again with about three weeks of points, so each band has a few hundred. Look first at flat
forecasts at turning points: if a trend near zero just after a rise or fall misses as often as a
fast one, that is a better split than speed alone.

## 22. Should the trend count for less when readings are noisy? (16 Nov 2026)

The forecast follows the trend, the slope of the last 20 minutes of readings, and
`ForecastTuning.trendGain` already counts it at about 55–70% strength (§3). The idea tested here:
when readings jitter around their line, the slope is less trustworthy, so count it for less still.
**It doesn't help. On days they hadn't seen, no noise-based damping beat the forecast as it is at
15 or 30 minutes, and most did slightly worse, so nothing changed.**

**The data.** Clean points (nothing logged after the forecast) in `glucos.forecast_checks` at 15
and 30 minutes, from 12 Nov 15:08 Perth to the morning of 16 Nov, on the Mac, iPhone and relay: 469 points
(279 at 15 minutes and 190 at 30). Jitter was measured from `glucos.readings` over the 15 minutes
before each forecast, two ways:

- the spread of readings around their straight line (residual standard deviation), and
- the mean size of the second difference (reading − 2 × previous + the one before), which ignores
  a steady bend in the line, so a peak or dip isn't counted as noise.

**The test.** A damped forecast keeps everything but the trend's share of it, which is scaled by a
factor k (1 is the forecast as shown, 0 drops the trend). The trend's share is the whole move for
trend-only forecasts, and the trend times its effective minutes (6.2 at 15 minutes, 15 at 30, the
median from trend-only forecasts) for those with insulin and carbs. For each day held out in turn,
k was learnt from the other days by least absolute error.

| Held-out days, mean error (mg/dL) | 15 min | 30 min |
|---|---|---|
| As shown | **17.6** | **27.2** |
| Trend dropped (k = 0) | 18.4 | 31.2 |
| One extra damping for all forecasts | 18.1 | 27.3 |
| Damping per jitter third (spread) | 18.1 | 27.4 |
| Damping per jitter third (second difference) | 18.4 | 28.4 |
| Fixed jitter bands (second difference 3 / 5) | 17.9 | 27.4 |
| k = 1 / (1 + a × spread), a learnt | 18.2 | 27.2 |
| k = 1 / (1 + a × second difference), a learnt | 18.2 | 27.5 |

The fitted `a` was zero or 0.1–0.2 on 9 of the 10 folds: the best damping by noise was next to none. 15 Nov (the low at 17:16
and the meals around it) was worse by 1–2 mg/dL under every variant, and no day was better by more
than 0.7.

**Why.** Noise does mark the forecasts that miss. Split into thirds by second difference, the
15-minute error is 11.2, 13.8 and 27.1 mg/dL, and the 30-minute error 17.5, 23.8 and 39.9. But the
best k in the noisiest third was 1.05 at 15 minutes and 1.25 at 30, not less than 1. Jittery
stretches are mostly fast rises and falls (after meals, during lows), where glucose kept going the
way the trend said. The trend wasn't overshooting there; the size of the miss was just bigger in
both directions. That is a reason to widen the range when readings are noisy, not to flatten the
line.

To get the jitter for each forecast:

    with c as (select id, issued_at from glucos.forecast_checks),
    r as (select c.id, r.mgdl, lag(r.mgdl) over w l1, lag(r.mgdl, 2) over w l2
      from c join glucos.readings r on r.at > c.issued_at - interval '15 minutes' and r.at <= c.issued_at
      window w as (partition by c.id order by r.at))
    select id, avg(abs(mgdl - 2 * l1 + l2)) jitter from r where l2 is not null group by id;

Next: try range widening by jitter, the same way as §19 and §21 (miss ratio, held-out days,
interval score), with the noisiest third as its own band. Retest damping with about three weeks of
points if the noisy third ever shows a best k under 1.

## 23. Re-check of §15–§22 on the latest data (16 Nov 2026)

Each of §15–§22 changed nothing and said what data would settle it. This re-runs each one on
what the server held at 16 Nov 07:50 Perth, and runs the one new test §22 asked for: widening
the range when readings are noisy. **Nothing cleared its bar, so nothing changed.** The data has
barely grown since those sections were written a few hours ago, and none of the stated
thresholds (three weeks of points, 14 nights, 10 slow meals) is close.

**What the data allows now.** 471 clean points at 15 and 30 minutes in
`glucos.forecast_checks` (12 Nov 15:23 to 16 Nov 07:19 Perth; §19 had 459, §21 467, §22 469),
109 at 60 minutes, and one-minute readings from 10 Nov 22:45 to 16 Nov 07:50 (7,108 readings, five
full nights and most of a sixth). No meal has been logged since the Big Mac on 14 Nov apart from
a Coke for tonight's low.

| Section | Bar it set | Re-run on 16 Nov | Verdict |
|---|---|---|---|
| §15 slow-meal curve | 10+ slow meals with forecasts, fat and protein in the food data | Not re-run: still 3 slow meals, no new meal | Unchanged |
| §16 "Your usual day" overnight | 14+ nights; 30 and 60 min forecasts through the night | Not re-run: 6 nights. The relay now forecasts all night (36 clean checks 22:00–07:30), but it only scores 15 minutes | Unchanged |
| §17 compression-low guard | A compression low that crosses 70 | `scripts/compression-lows.ts` on 16 Nov 00:00–07:50: no compression-shaped dip. One new low, 04:50 (83 → 53 over 20 minutes, 16 minutes under 70, nothing logged), falls slowly, which is a real low's shape | Unchanged |
| §19 range by time of day | Three weeks of points | Held out, 471 points: one figure 79.0% inside at 70.2 mg/dL (interval score 116.0); four parts of the day 77.7% at 70.7 (122.2) | Unchanged |
| §21 range by speed | Three weeks of points | Steady / fast at 1.5 (what §9 does) 79.2% at 69.7 (116.0); flat / slow / fast 79.4% at 69.8 (116.7) | Unchanged |
| §22 trend damping by noise | The noisy third showing a best k under 1 | Not re-run: 2 more points than §22 had | Unchanged |
| §22 next: range widening by noise | Better interval score than §9 on held-out days | Looked better at first, then didn't once LinkUp's graph points were taken out (below) | Not shipped |

**Range widening by noise.** Jitter is §22's second difference: the mean size of reading − 2 ×
previous + the one before, over the 15 minutes before each forecast. It was tested two ways,
holding each day out in turn. The first is §19's and §21's method: one 80th-percentile miss ratio
per band, learnt on the other days. The second copies how `ForecastLedger.rangeScale` actually
works: a steady figure for each horizon, then a correction for the noisy band learnt on what's
left over, used in place of the fast-trend correction, or on top of it. The noisy band is either
the noisiest third of the training days or a fixed jitter of 2.3 or 3 mg/dL.

On the readings as stored, it looked like a clear win:

| Held-out days, 15 + 30 min, as `rangeScale` works | Inside | Mean width | Interval score |
|---|---|---|---|
| Steady / fast at 1.5 (now) | 80.3% | 74.6 mg/dL | 116.7 |
| Steady / noisy third, in place of fast | 79.8% | 75.3 mg/dL | 108.2 |
| Steady / jitter 3 or more, in place of fast | 80.5% | 72.2 mg/dL | 106.1 |
| Fast and noisy third, both | 83.2% | 87.6 mg/dL | 115.2 |

That's 7–8% better at both 15 and 30 minutes, though only on 3 of the 5 days (14 and 16 Nov
were worse). It didn't hold up. `glucos.readings` keeps LinkUp's 15-minute graph point beside the
live reading, a second or so apart (§17, §18), and the two often differ by 5 mg/dL or more. Those
pairs were most of the "jitter". With the graph point dropped where it sits within 30 seconds of a
live reading, so jitter is measured on the live readings alone, the gain goes away:

| Same test, jitter from live readings only | Inside | Mean width | Interval score |
|---|---|---|---|
| Steady / fast at 1.5 (now) | 80.3% | 74.6 mg/dL | 116.7 |
| Steady / noisy third, in place of fast | 80.7% | 75.2 mg/dL | 118.4 |
| Steady / jitter 3 or more, in place of fast | 78.1% | 69.9 mg/dL | 116.5 |
| Fast and noisy third, both | 79.8% | 76.7 mg/dL | 118.2 |

So the signal was mostly the gap between LinkUp's smoothed graph value and the live reading,
which grows when glucose is moving fast. That is closer to speed, which §9 already uses, than to
sensor noise. It also isn't something the Mac or iPhone could measure the same way, because their
stored history keeps one reading per 5-minute slot. A range rule built on it would be tuned to a quirk
of the server's store. Nothing shipped.

To get jitter from live readings only (join on the forecast's id, as in §22):

    with rd as (select r.at, r.mgdl from glucos.readings r
      where not (r.trend = 0 and exists (select 1 from glucos.readings o
        where o.at <> r.at and abs(extract(epoch from o.at - r.at)) < 30)))
    -- then §22's query with rd in place of glucos.readings

**When to look again.** Around 3 December, with three weeks of points, for §19, §21 and noise
widening on live readings only. §16 needs the relay to score 30 and 60 minutes as well as 15
before its overnight checks can settle it. §15 needs slow meals logged. Logging low treatments
would help everywhere: tonight's 04:50 low and the rise to 140 straight after it have nothing in
the logbook, so the points after it count as "clean" when they weren't.

## 24. "Back in range in about X min" (16 Nov 2026)

When glucose is above range, the iPhone's Today screen can now say when the forecast comes back
into range: "Back in range ≈ 20 min", under the forecast note. The question was whether that time
is close enough to show. **On held-out days it typically missed by 6 minutes, well inside the
15-minute bar, so it's shown, but only while each device's own checks keep the typical miss
within 15 minutes.**

**How the time is worked out** (`Engine/BackInRange.swift`). Where the forecast's central line
first comes down to the high threshold, linear between its points. Nothing past the last drawn
point is guessed, so the estimate only appears when the drawn forecast itself comes back into
range, which is mostly in the last half hour of a high. Lows are given no time back at all: the
forecast can't see a low being treated (most treatments aren't logged), and on the 19 low
forecasts that didn't come back up within their drawn points, 13 were back in range by then
anyway. A "back soon" beside a low must never read as a reason to wait.

**The data.** Every forecast in `glucos.forecast_checks` that started above 180 mg/dL (Declan's
high threshold), 12 Nov 15:08 to 16 Nov 08:21 Perth: 102 forecasts on the Mac, iPhone and relay.
The estimate uses each forecast's stored points (15, 30, 45, 60 minutes and on, the drawn ones
only) with the starting reading at 0. The actual return is the first live reading (LinkUp's graph
points left out, §23) at or under 180 whose next reading, within 20 minutes, is too, looked for up
to 6 hours later.

**Most highs get no estimate.** 89 of the 102 forecasts stayed above range to the end of what was
drawn. 24 of those were back in range before the forecast's end anyway, mostly the trend-only
forecasts that run level at about 55–70% of the trend (§3). Saying nothing there costs nothing.

**The 13 that did come back:**

| | Checks | Typical miss (median) | Mean miss | Within 15 min |
|---|---|---|---|---|
| All | 13 | **5.8 min** | 17.6 min | 9 of 13 |
| Nothing logged after the forecast | 10 | 5.8 min | 8.8 min | 8 of 10 |
| Something logged after it | 3 | 65 min | 47 min | 1 of 3 |
| Estimate 15 min or less | 9 | 5.8 min | 20.7 min | 6 of 9 |
| Estimate over 15 min | 4 | 6.4 min | 10.5 min | 3 of 4 |
| Mac / iPhone / Lock Screen | 7 / 5 / 1 | 5.7 / 7.4 / 4.8 min | | 5 / 3 / 1 |

The two big misses (14 Nov 21:33 and 21:36, both "≈ 15 min", back after 80 minutes) had food
logged after the forecast, which no estimate made at the time could know. The worst clean miss
was 25 minutes early (15 Nov 00:39, "≈ 35 min", back in 8). The signed median is +4 minutes: the
estimate runs a little late more often than early, which is the safer side for a high.

**Held out by day.** For each of the four days in turn, the gate (typical miss within 15 minutes,
at least 5 checks) was decided on the other three days and applied to the held-out one. It opened
every time (typical miss on the other days 5.7–7.4 minutes), so every held-out estimate would have
been shown: 13 shown, typical miss 5.8 minutes, 9 of 13 within 15.

**The rule in the apps.** Each device scores its own settled forecasts from the last 30 days the
same way (`BackInRange.check`, from `forecast-log.json` and its stored readings) and shows the
estimate only with at least 5 checks and a median miss of 15 minutes or less. Replaying that
walk-forward per device on these forecasts, the Mac would have opened after its fifth check and
the iPhone now has five (typical miss 7.4 minutes), so it should show from the first launch
of this version. A forecast still above range 6 hours later counts as a miss of 6 hours less the
estimate, so a run of wrong "≈ 10 min" calls closes the gate quickly. The live estimate uses the
forecast's 5-minute points rather than the log's 15-minute ones, so it's at least as fine as what
was checked. The Lock Screen doesn't show it: the relay's forecast has had 1 check.

**On the Mac (round 20).** The Mac shows the same estimate under the same rule, from its own checks
(its device in the log is "Mac"): a line under the forecast in the menu bar popover, and a second
line in the menu bar item's tooltip, "Back in range ≈ 25 min (around 10:40 am) if nothing else
changes". The tooltip gives the clock time too, since it isn't redrawn between readings. VoiceOver
hears it at the end of the item's label. All three places (iPhone Today, Mac popover, tooltip) go
through one check, `GlucoseSnapshot.backInRange(at:)`: live reading above range, an outlook that
belongs to it, no low expected, and the device's gate open. With the forecast turned off in
Settings it isn't shown.

To rerun (estimate from stored points, actual from live readings):

    with rd0 as (select r.at, r.mgdl from glucos.readings r where not (r.trend = 0 and exists (
        select 1 from glucos.readings o where o.at <> r.at and abs(extract(epoch from o.at - r.at)) < 30))),
    rd as (select at, mgdl, lead(at) over (order by at) nat, lead(mgdl) over (order by at) nmg from rd0),
    f as (select * from glucos.forecast_checks where start_mgdl > 180),
    pts as (select f.id, 0 m, f.start_mgdl v, true sh from f union all
      select f.id, (e->>'minutes')::int, (e->>'mgdl')::float, coalesce((e->>'shown')::bool, true)
      from f, jsonb_array_elements(f.points) e),
    seg as (select id, m, v, lag(m) over w m0, lag(v) over w v0, sh from pts window w as (partition by id order by m)),
    est as (select distinct on (id) id, m0 + (v0 - 180) / (v0 - v) * (m - m0) est from seg
      where m0 is not null and sh and v0 > 180 and v <= 180 order by id, m)
    select f.device, f.issued_at, est.est, (select extract(epoch from min(rd.at) - f.issued_at) / 60 from rd
      where rd.at > f.issued_at and rd.at <= f.issued_at + interval '6 hours' and rd.mgdl between 70 and 180
        and rd.nmg between 70 and 180 and rd.nat <= rd.at + interval '20 minutes') actual
    from f join est using (id) order by f.issued_at;

**Lock Screen and widgets (round 21).** The Live Activity (Lock Screen card and expanded
Dynamic Island), the Lock Screen rectangular widget and the Home Screen widget footer (medium and
up) show it too, in place of the "≈ 6.8 in 30 min" headline, with "In range ≈ 20 min" where space
is short. A low expected always wins. The iPhone's own card and widgets use its gate
(`GlucoseSnapshot.backInRange(at:)`, the card's `backInRangeAt`), and widgets reload when the
estimate appears, moves or goes (`WidgetReload.OutlookKey.backAt`). The relay draws its own
forecast, so it never borrows the iPhone's gate: relay 2.14.0 scores its own ledger the same way
(core.ts `backInRangeCheck`: ≥5 checks, median miss ≤15 min, last 30 days, redone when a new
forecast could be checked or hourly) and sends `backInRangeAt` only while that is open. On 16 Nov
the relay had 10 forecasts from above range and 1 that came back within its drawn 30 minutes, so
its cards won't show it yet; the card shown while the app is open will, from the iPhone's gate.
The card checks again whatever it's sent: never on a low, with a low expected, stale, or after the
time has passed.

**When to look again.** 13 checks is few, and the tail is wide (4 of 13 off by more than 15
minutes). Re-run around 3 December. If the share within 15 minutes stays under 7 in 10, try
requiring that as well as the median. If the relay reaches 5 checks under the same bar, the Lock
Screen could show it too.

## 25. "Peak ≈ 11.2 around 1:40 pm" after a meal (16 Nov 2026)

The idea: after a logged meal, say how high glucose is expected to go and when, from the forecast,
and show it only while that has been close on past meals (the same kind of gate as §24). **It
isn't close. On the logged meals so far the forecast's peak was typically 2.7 mmol/L (49 mg/dL)
too low and 21 minutes early, and most of the time the drawn forecast is still rising at its last
point, so it has no peak to give. Nothing is shown; no app code changed.**

**The data.** Every meal in the logbook with forecasts after it, 12 Nov to 16 Nov (Perth): 8 meals
after merging the eggs logged on both devices, 62 forecasts from the Mac, iPhone and relay issued
in the 2 hours after a meal (each forecast belongs to the latest meal before it). The estimate is
the highest point of the drawn forecast (stored points, starting reading at 0) and its time. The
actual peak is the highest live reading (LinkUp's graph points left out, §23) from the forecast
to 3 hours after the meal, or to the next meal if that comes first.

**What the forecasts said:**

| Forecast's highest point | Forecasts | Meals | Typical height miss | Typical time miss |
|---|---|---|---|---|
| Still rising at its last drawn point | 30 | 7 | 31 mg/dL (1.7 mmol/L) | 32 min |
| Turns over inside what's drawn | 7 | 3 | **49 mg/dL (2.7 mmol/L)** | **21 min** |
| Already falling or flat (peak is now) | 22 | 6 | 4 mg/dL | 2 min |
| Nothing drawn | 3 | 1 | | |

Only the middle row is a real peak estimate: the first has no peak (the line hasn't turned yet,
and the actual peak was a median 26 mg/dL above its end), and the third just says the peak has
passed, which the reading already shows. All seven real estimates were low, none high:

- Green juice (Mac, 16:26–16:56 on 12 Nov): 5.8, 6.9, 8.3 against an actual 8.8, 21 min early each time.
- Burrito bowl (iPhone, 19:17 on 12 Nov): 8.7 at 30 min against 14.8 two hours on. The rise went
  on for over two hours (§15).
- Hamburger (Mac, 18:25–18:55 on 14 Nov): 10.2, 9.1, 10.6 against 12.9, 9–24 min early.

**Held out by meal.** With the bar set at a typical miss of 1 mmol/L (18 mg/dL) in height and
15 minutes in time, at least 5 checks, the gate was decided on the other meals and applied to the
held-out one. It never opened: two folds have only 4 checks, and the third's typical height miss
is 45 mg/dL. So the estimate would have been hidden on every meal.

**Why, and what would change it.** The forecast's carb effect is learnt as one figure per gram on a
standard 3-hour curve (§1, §15), and it's drawn only as far as it beats "no change" (60 minutes
after most meals). Peaks after these meals came about 2 to 3 hours after eating, so the
forecast's line is usually cut off before it turns, and when it does turn early it's the curve
timing showing, not the meal. A slower curve for slow meals lost on held-out meals (§15), and the
food data has carbs only, so there's nothing yet to tell a juice from a burrito bowl. The carb
effect itself is dosing-adjacent maths and was left alone.

Re-run when there are 10 or more meals whose forecast turns over inside what's drawn. If the
typical miss comes under 1 mmol/L and 15 minutes on held-out meals, build it the way §24's
estimate was built: highest point of the drawn central line, only when it turns over inside
the drawn points, each device gated on its own settled checks.

To rerun (one row per forecast; `kind` gives the table's rows, "turns over" are the real
estimates, and `meal_at` groups them for the held-out folds):

    with rd as (select r.at, r.mgdl from glucos.readings r where not (r.trend = 0 and exists (
        select 1 from glucos.readings o where o.at <> r.at and abs(extract(epoch from o.at - r.at)) < 30))),
    m0 as (select to_timestamp((payload->>'timestamp')::float) t, (payload->>'carbs')::float carbs,
      payload->>'food' food from glucos.logbook where not deleted and kind = 'meal'),
    -- the same meal logged on both devices: same food and carbs within 20 minutes
    m as (select * from m0 where not exists (select 1 from m0 p where p.t < m0.t
      and p.t > m0.t - interval '20 minutes' and p.carbs = m0.carbs and p.food = m0.food)),
    f as (select f.*, m.t mt, m.food, (select min(n.t) from m n where n.t > m.t) nt from glucos.forecast_checks f
      join m on f.issued_at between m.t and m.t + interval '2 hours'
      where not exists (select 1 from m n where n.t > m.t and n.t <= f.issued_at)),
    w as (select f.*, least(f.mt + interval '3 hours', coalesce(f.nt, 'infinity')) wend from f),
    pts as (select w.id, 0 mm, w.start_mgdl v from w union all
      select w.id, (e->>'minutes')::int, (e->>'mgdl')::float from w, jsonb_array_elements(w.points) e
      where coalesce((e->>'shown')::bool, true)),
    est as (select distinct on (id) id, mm est_min, v est_peak,
      (select max(mm) from pts p2 where p2.id = pts.id) horizon from pts order by id, v desc, mm),
    act as (select w.id, a.at pat, a.mgdl peak from w cross join lateral (select at, mgdl from rd
      where rd.at between w.issued_at and w.wend order by mgdl desc, at limit 1) a
      where w.wend < now())  -- only windows that have closed
    select w.mt meal_at, w.food, w.device, w.issued_at, est.*, act.peak,
      extract(epoch from act.pat - w.issued_at) / 60 act_min,
      case when est.horizon = 0 then 'nothing drawn' when est.est_min = 0 then 'falling or flat'
        when est.est_min = est.horizon then 'still rising' else 'turns over' end kind
    from w join est using (id) join act using (id) order by w.issued_at;

## 26. Should the forecast expect a bigger, later rise after meals? (16 Nov 2026)

§25 found the forecast's post-meal peak 2.7 mmol/L too low and 21 minutes early. The idea here: a
forecast-only correction learnt from past meals, a scale on the carb rise and a delay before it,
applied to the forecast's carb term and nothing else. **It doesn't help. Inside what the forecast
draws (up to 60 minutes after most meals) post-meal forecasts aren't running low, so there's
nothing for a bigger rise to fix, and a later rise only moves the turn past the drawn points.
Nothing shipped; no app code changed.**

**Nothing that doses reads the forecast.** Checked before testing, so a forecast-only change
could ship on its own: `BolusCalculator.suggest` takes the carbs, readings, doses, contexts and the
user's own settings (`BolusRequest`, built in `BolusViews`), its trend adjustment is the measured
rate (`BolusCalculator.ratePerMinute`), and insulin on board is `InsulinActivity.compute(doses:)`
on the fixed action curves. None of them touch `GlucoseForecaster`, `OutlookEngine` or the
forecast log. The learnt carb effect (`EffectProfile.reliableCarbs`) is read by the forecaster,
the morning pattern and the Outlook card only. A correction would have lived in the forecaster's
`modelRate`, leaving `CarbAbsorptionCurve.standard` (shared with carbs on board and the effect
learner) alone.

**The test.** Every insulin-and-carb forecast (`trendInsulinCarbs`) in the 2 hours after a meal in
`glucos.forecast_checks`, 12–15 Nov: 44 forecasts after 5 meals (green juice, burrito bowl, the
late-night sports drink, eggs and potato, hamburger), scored at 15–60 minutes on points not marked
`after_log` (150 points with a reading). The correction replaces the carb term with `scale × K × carb rate(t −
delay)` under the same 30-minute trend fade, every logged meal counted (K = 2.8 mg/dL per gram, the
learnt value, §1). Scale 0.5–3, delay 0–120 minutes were fitted on four meals and scored on the
fifth.

| Ahead | Points | As drawn | With the fitted correction | Bias as drawn |
|---|---|---|---|---|
| 15 min | 40 | 18.2 mg/dL | 18.3 | +0.7 |
| 30 min | 38 | 23.9 | 23.8 | −3.0 |
| 45 min | 37 | 27.8 | 26.4 | +0.5 |
| 60 min | 35 | 28.6 | **29.7** | +3.6 |
| All | 150 | 24.4 | 24.4 | |

(Typical miss, held out by meal. Without the sports drink, which was a low being treated: 18.8
against 19.1 overall, and 26.4 against 28.1 at 60 minutes.)

The fitted scale came out at 0.75–1.25, so no bigger rise, and the delay sat at 45–60 minutes, the
fit pushing the rise past the drawn points rather than describing it. Three of the five held-out
meals came out a little better (juice 19.2 → 15.3, hamburger 13.0 → 12.6, sports drink 51.4 →
50.8), two worse (eggs 16.1 → 18.6, burrito bowl 25.3 → 26.4), and 60 minutes got worse. That
fails the tuner's own rule for a change (§2: at least 3% better, and better in both halves).

The peak got worse too. On the same forecasts, the ones whose drawn line turns over went from 5 to
3, and their typical height miss went from 41 to 119 mg/dL too low: with the rise pushed later the
line turns at the wrong time, early on the burrito bowl, so the estimate is further off, not closer.

**So what is §25's 2.7 mmol/L?** It's the horizon, not the shape. Real peaks came 2 to 3 hours after
eating; the forecast is drawn only as far as it beats "no change" (about 60 minutes after meals),
and inside that it's unbiased. A correction can't show a peak the forecast doesn't draw, and
drawing further would show lines that have lost to "no change". K was taken as one figure for the
whole period, which is only approximate for 12 Nov forecasts made while it was still being learnt;
the scale fit would absorb a K that was off by a constant, and it found none.

Re-run when there are 10 or more meals with insulin-and-carb forecasts, or once forecasts after
meals are drawn past 90 minutes (the live checks would have to allow it first). The prototype
reads the export below and the meal list, and needs nothing else:

    with m0 as (select to_timestamp((payload->>'timestamp')::float) t, (payload->>'carbs')::float carbs,
      payload->>'food' food from glucos.logbook where not deleted and kind = 'meal'),
    m as (select * from m0 where not exists (select 1 from m0 p where p.t < m0.t
      and p.t > m0.t - interval '20 minutes' and p.carbs = m0.carbs and p.food = m0.food))
    select m.t meal_at, f.issued_at, f.device, f.start_mgdl, p.*
    from glucos.forecast_checks f join m on f.issued_at between m.t and m.t + interval '2 hours'
      cross join lateral jsonb_to_recordset(f.points) p(minutes int, mgdl float, actual float, after_log bool)
    where f.basis = 'trendInsulinCarbs' and p.minutes <= 60 and not p.after_log and p.actual is not null
      and not exists (select 1 from m n where n.t > m.t and n.t <= f.issued_at)
    order by f.issued_at, p.minutes;

## 27. Should the forecast be drawn 90 or 120 minutes ahead after meals? (16 Nov 2026)

§26 put §25's low post-meal peak down to the horizon: real peaks come 2 to 3 hours after eating
and the forecast is drawn about 60 minutes ahead. The idea here: after a meal, draw the same
forecast to 90 or 120 minutes with a range that widens with it, and show the peak if it gets
close. **It doesn't. Drawn to 120 minutes far more forecasts turn over (5 → 21), but the peak is
still typically 41 mg/dL (2.3 mmol/L) too low and 24 minutes early, and the held-out gate never
opens. 90 minutes beats "no change" overall but not on 12 Nov's meals, 120 minutes loses to it,
and the range that would honestly go with them is 7 to 8.5 mmol/L wide. Nothing shipped; no app
code changed.**

**Nothing that doses reads the forecast** (checked in §26): the bolus calculator and insulin on
board don't touch `GlucoseForecaster`, so this was a forecast-only question. The carb and insulin
effects themselves were left exactly as each device had learnt them.

**The test.** Every insulin-and-carb forecast (`trendInsulinCarbs`, no morning adjustment) in
`glucos.forecast_checks` issued in the 2 hours after a meal, 12–14 Nov: 43 forecasts from the Mac
and iPhone after 5 meals (green juice, burrito bowl, the late-night sports drink, eggs and potato,
hamburger). The Coke on 15 Nov has only 15-minute forecasts and the eggs forecast issued 30
seconds after logging is left out (another log came 11 minutes later). Each forecast was carried
on from its stored 60-minute point exactly as `GlucoseForecaster` would have drawn it with a
longer horizon: past the trend fade the line is only the model, `K × carb rate − S × insulin
activity` on the standard curves, with the logs known at the time. K and S aren't stored, so they
were recovered per device and meal from the stored points after 45 minutes (fit error 0.0–0.8
mg/dL per step). The Mac's hamburger forecasts, which the app did draw to 150 minutes, came out
within 0.1 mg/dL at 90 and 120, so the extension is the app's own line, not a new model. Actual
values are the live readings within 2½ minutes of each point (LinkUp graph points left out, §23),
and points after the next log are dropped.

| Ahead | Checks | Meals | Typical miss | No change | Ratio | Bias (actual − forecast) |
|---|---|---|---|---|---|---|
| 60 min (as drawn now) | 43 | 5 | 33.2 mg/dL | 38.6 | 0.86 | −8 |
| 75 min | 42 | 5 | 37.1 | 44.3 | 0.84 | −11 |
| 90 min | 41 | 5 | 43.7 | 49.5 | 0.88 | −17 |
| 105 min | 39 | 4 | 46.7 | 51.0 | 0.92 | −24 |
| 120 min | 38 | 4 | 52.6 | 51.7 | **1.02** | −28 |

Pooled, 90 and 105 minutes clear the app's own bar (§1: 30 checks and at most 0.95 of "no
change"). Split by day they don't hold: on 12 Nov's three meals 90 minutes is 0.96 of no change
and 120 is 1.07; on 13–14 Nov it's 0.73 and 0.90. The sports drink (a low being treated) loses at
every horizon and runs 48–66 mg/dL high at 90–120 minutes; without it the line is 0.72 of no
change at 90 and 0.82 at 120, but still runs high late (−6 at 90, −12 at 120), because forecasts
made after the peak expect the rise to keep going.

**The peak.** Same estimate and gate as §25 (highest point of the drawn line when it turns over
inside what's drawn, against the highest live reading to 3 hours after the meal; held out by
meal, open at a typical miss of 18 mg/dL and 15 minutes with at least 5 checks):

| Drawn to | Turns over | Still rising | Falling or flat | Typical height miss | Typical time miss | Gate opened |
|---|---|---|---|---|---|---|
| 60 min | 5 | 25 | 13 | 41 mg/dL low | 21 min early | never |
| 90 min | 15 | 15 | 13 | 41 mg/dL low | 24 min early | never |
| 120 min | 21 | 9 | 13 | 41 mg/dL low | 24 min early | never |

Drawing further gives the line room to turn, but it turns at the wrong height: on the juice,
burrito bowl and hamburger the turn is 26–68 mg/dL below the real peak, and on the sports drink 75
mg/dL above it. The line's shape after meals (one figure per gram on a standard 3-hour curve)
is what's off, not only where it's cut.

**The range.** Set from the other meals' 10th–90th percentile misses (never narrower than the
app's floor) and tried on the held-out meal, it held 76% of readings at 90 minutes and 79% at 120,
close to the 8 in 10 it aims for, but only by being 133 mg/dL (7.4 mmol/L) wide at 90 and 153
(8.5 mmol/L) at 120. A band from 6 to 13 mmol/L says little a person can act on.

**Why it stays at 60.** The app already decides the horizon from its own checks: the replay's
`allowedHorizon` (to 180 minutes) and each device's live checks (§8) can only shorten it, and
the first hour after a log uses the fresh-forecast figures (§3). That's why the hamburger was
drawn to 150 on the Mac and most meals stop at 60. Forcing 90 or 120 after meals would bypass
those checks for a line that, on these meals, doesn't hold up on both days and doesn't find the
peak. Left as it is.

Re-run with 10 or more meals with insulin-and-carb forecasts (ideally with fat and protein in the
food data, §15), or if the post-meal curve changes. The longer points are worth having either
way: forecasts that the checks do allow past 60 are already logged to 180 minutes. The export
(join each forecast to its meal and the readings as in §25's query; K and S are fitted from the
`points` steps after 45 minutes):

    select f.id, f.device, f.issued_at, f.start_mgdl, f.points
    from glucos.forecast_checks f
    where f.basis = 'trendInsulinCarbs' and not f.morning
      and exists (select 1 from glucos.logbook l where not l.deleted and l.kind = 'meal'
        and f.issued_at between to_timestamp((l.payload->>'timestamp')::float)
                            and to_timestamp((l.payload->>'timestamp')::float) + interval '2 hours')
    order by f.issued_at;

## 28. Do the Mac, iPhone and relay forecast differently at the same moments? (16 Nov 2026)

Each sender's live figures look different: the iPhone loses to "no change" at 15 minutes and
badly at 60, while the Mac and relay beat it. The question was whether one sender is worse
because of what it's fed (history length, LinkUp graph points, §10, §17–§18) and should be
aligned. **It isn't. At the same moments the three forecasts are nearly the same line, and the
iPhone is no worse than the Mac at 15 and 30 minutes. The gaps in the per-sender figures come
from when each one forecasts: the iPhone is opened during lows and fast drops, the relay covers
the nights, the Mac sleeps overnight. The one input difference found (the iPhone's trend on
sparse history) is the one #82 fixed, and only 5 iPhone checks since then have been scored.
Nothing shipped; no app or relay code changed.**

Nothing here touches dosing: the bolus calculator, insulin on board, sensitivity and carb
ratios were not read or changed.

**Per sender, all clean checks** (`glucos.forecast_checks`, nothing logged in between, 12–16 Nov;
bias is actual − forecast, positive = ran low):

| Sender | 15 min | no change | bias | 30 min | no change | 60 min | no change | bias |
|---|---|---|---|---|---|---|---|---|
| Mac (136 / 118 / 81) | 17.5 | 18.9 | −1 | 27.9 | 31.1 | 48.4 | 49.8 | 0 |
| iPhone (90 / 76 / 29) | **15.8** | **15.4** | +5 | 26.5 | 28.8 | **47.0** | **38.9** | +14 |
| relay (72 / – / –) | 18.8 | 20.4 | 0 | – | – | – | – | – |

The relay only logs 15-minute points: its own replay (`allowedHorizon`) stops its drawn line at
15, and the 30-minute look-ahead used for low warnings (§13) isn't logged.

**At the same moments.** Pairs of checks from two senders issued within 5 minutes of each other,
all re-scored against the same truth (`glucos.reading_at` at issue + horizon):

| Pair | Ahead | Pairs | First sender | Second sender | No change (first / second) |
|---|---|---|---|---|---|
| iPhone vs Mac | 15 min | 38 | **14.6** | 17.5 | 16.0 / 17.8 |
| iPhone vs Mac | 30 min | 28 | **23.0** | 24.3 | 23.9 / 24.8 |
| iPhone vs Mac | 60 min | 20 | 52.4 | 50.2 | 46.6 / 47.0 |
| Mac vs relay | 15 min | 27 | 26.1 | 25.1 | 26.7 / 26.4 |
| iPhone vs relay | 15 min | 7 | 27.5 | 27.3 | 33.1 / 31.4 |

Mac and relay 15-minute forecasts are typically within 5 mg/dL of each other (same trend to
±0.3 mg/dL/min), because 15 minutes ahead both are mostly the trend. The iPhone runs on average
3 mg/dL lower than the Mac at 15 and 30 and 8 lower at 60, and does slightly better at 15 and 30.
At 60 minutes all three lose to no change at these moments; the live cut (§8) is what handles
that.

**Why the per-sender figures differ.** Where each sender's checks fall:

| Sender | Checks | Starting below 100 mg/dL | Mean \|trend\| |
|---|---|---|---|
| Mac | 146 | 14% | 1.20 mg/dL/min |
| iPhone | 106 | 17% | 1.20 |
| relay | 76 | 41% | 1.31 |

Below 100 mg/dL every sender runs low (bias +10 to +114): untreated-in-the-log lows, where
rescue carbs come after the forecast ("Did you treat this low?" re-marks these as after a log once
answered, §2). The iPhone's 60-minute figure is 29 checks, and its worst misses are lows at
14:10, 15:06, 17:18 and 21:55 on 15 Nov (start 59–96 mg/dL, forecast 39–64, actual 93–217 an
hour later): moments the phone was opened because of the low. Its only clearly different
forecasts at the same moment as the Mac or relay (15 Nov 17:18, trend −2.4 vs −1.5; 21:55,
−0.7 vs −1.9) are from before #82, when its history was LinkUp's 15-minute graph plus a few
live readings (§10). The iPhone was untuned (`tuned = false`) on 74 of its 90 15-minute checks.

**Tried: cut the iPhone's horizons sooner.** The iPhone's 60-minute line lost to no change
(1.2×) but was never cut, because §8 needs 30 clean checks per kind in 7 days and the iPhone
doesn't reach that. Replaying §8's rule walk-forward on each device's own checks (only points
already scored at each check's time), for the iPhone (gain = error saved by hiding a point,
against no change):

| Minimum checks | Hidden 15 / 30 / 45 / 60 | Error saved | Shown 60 min vs no change |
|---|---|---|---|
| 30 (now) | 12 / 10 / 9 / 8 | 539 mg/dL·points | 28.2 / 25.4 |
| 20 | 22 / 18 / 16 / 14 | 731 | 23.5 / 25.9 |
| 15 | 27 / 23 / 21 / 19 | 760 | 30.6 / 36.3 |
| Mac + iPhone pooled, 30 | 0 | 0 | 47.0 / 38.9 |

On the Mac no threshold changes anything (it is never cut). Lower minimums look better, but
split in time the whole gain is in the second half (14–16 Nov; nothing in the first half), from
untuned pre-#82 iPhone builds whose cause is already fixed, and 30 is also the count the
Insights scorecard needs before it calls a horizon "further off than no change". Pooling the Mac's
checks into the iPhone's gate is worse: the Mac's good figures keep the iPhone's bad horizons
drawn. Not shipped.

**Re-run** once the iPhone has 30 or more clean checks from a build with #82 (relay history fill)
or later, by version via `glucos.forecast_scorecard_by_version` (§14). If its 60-minute line still loses
to no change then while the Mac's doesn't, the lower minimum is worth retrying. Logging the
relay's 30-minute look-ahead as unshown points would let the relay be compared at 30 too. The
matched-moment query:

    with pts as (
      select c.device, c.issued_at, (p->>'minutes')::int m, (p->>'mgdl')::float f
      from glucos.forecast_checks c, jsonb_array_elements(c.points) p
      where p->>'actual' is not null and not coalesce((p->>'after_log')::bool, false)),
    s as (select *, glucos.reading_at(issued_at + make_interval(mins => m)) a,
                    glucos.reading_at(issued_at) a0 from pts)
    select x.device, y.device, x.m, count(*), avg(abs(x.f - x.a)), avg(abs(y.f - y.a)),
           avg(abs(x.a0 - x.a)), avg(abs(y.a0 - y.a))
    from s x join s y on x.m = y.m and x.device < y.device
      and abs(extract(epoch from x.issued_at - y.issued_at)) <= 300
    group by 1, 2, 3;

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

## 30. Predicted-low alerts re-checked on everything since §13 (16 Nov 2026)

The question: with 30-minute lookahead and the 30-minute default lead in place since §13 (relay
2.11.0), how early do predicted-low alerts warn, how many lows do they miss, how many are false
alarms, and would another lead, trend gate or margin do better on days it wasn't chosen on?
**No: the shipped settings won held out. Nothing shipped; no app or relay code changed.** The
Mac, iPhone and relay still share the same rules (`PredictiveAlertRules`, `evaluatePrediction`:
lead 30, trend falling at least 0.3 mg/dL a minute, crossing 70 or 54).

Nothing here touches dosing: the bolus calculator, insulin on board, sensitivity and carb ratios
were not read or changed.

**What there is.** 7,272 readings from 10 Nov 22:45 to 16 Nov 11:15 Perth, 121 hours ticked
(7,208 ticks, 6 Perth days), 8 lows under 70 (6 in §13, plus 16 Nov 00:52, nadir 51, and 16 Nov
04:50, nadir 53). Only about 10 hours (one low) come after §13 merged, too little to judge it on
its own, so every day is used and each is held out in turn.

**Scoring, tightened.** §13 counted a low as warned by any alert in the hour before it, while an
alert was a false alarm with no low in the 45 minutes after it, so one alert could be both: the
16 Nov 03:52 alert was a false alarm and also "warned" the 04:50 low 58 minutes early. Both now use
45 minutes. `scripts/low-alert-heldout.ts` replays the relay once, then runs the alert rules per
candidate and scores each Perth day as minutes of warning (capped at 30 per low) minus 10 per
false alarm. For each day, the best candidate on the other five days is scored on the day left
out, against the shipped setting. Candidates: lead 15/20/25/30, trend gate −0.2/−0.3/−0.4/−0.5,
and warning when the forecast crosses 0, 4 or 8 mg/dL above the line.

**Shipped, all days:** all 8 lows warned, median 6 / mean 9.8 minutes ahead (the 45-minute
window; `low-alert-replay.ts` says 16.0 because of the hour window), 27 alerts, 4 false alarms.
None missed.

| Held out | Chosen on the other days | Score (warned, false) | Shipped score (warned, false) |
|---|---|---|---|
| 11 Nov | lead 15, gate −0.5, margin 4 | 22 (1/1, 0) | 27 (1/1, 0) |
| 12 Nov | shipped | 10 (2/2, 0) | 10 (2/2, 0) |
| 13 Nov | shipped | 10 (1/1, 0) | 10 (1/1, 0) |
| 14 Nov | shipped | 0 (no lows) | 0 |
| 15 Nov | lead 20 | 3 (2/2, 1) | 8 (2/2, 1) |
| 16 Nov | lead 30, gate −0.2, margin 4 | −34 (2/2, 5) | −17 (2/2, 3) |
| **Total** | | **11 (8/8, 6)** | **38 (8/8, 4)** |

Shipped also wins at 5 (58 against 50) and 20 (−2 against −12) minutes per false alarm; only with
no cost for false alarms does anything beat it (114 against 78, with 16 false alarms against 4).

- **Lead.** 20 minutes drops one false alarm but warns 1.4 minutes later on average; 15 warns
  later still. 25 is worse than both. Nothing past 30 can matter: the lookahead stops at 30 (§13).
- **Trend gate.** −0.2 changes nothing (a trend that slow never reaches 70 inside 30 minutes from
  above it); −0.4 and −0.5 drop at most one alert and no false alarms.
- **Margin.** 4 mg/dL moves the median from 6 to 11 minutes but adds 3–4 false alarms; 8 adds
  9–12. This is the §13 "toward the lower edge" result again.

**What the false alarms are.** All four are dips that bottomed out in the high 70s or low 80s:
15 Nov 14:11 (a fall from 237 levelling at 86), and three on the night of 16 Nov (Perth): 03:52 (to
78, an hour before the 04:50 low), 05:39 (a 140 → 84 drop straight after an unlogged spike) and
07:45 (bouncing between 77 and 88). The last one is in the iPhone's own alert log at 07:45:01,
the same minute as the replay, so the replay and the live relay agree; the iPhone also logged the
04:57 urgent-low heads-up that the replay fires at 04:56. The other replay alerts aren't in the
log because it only records pushes the app sees before they're cleared (docs/AlertLog.md).

**Late warnings.** The four lows warned 4–6 minutes ahead were first alerted at 76–90 mg/dL,
most of them falling 2–7 mg/dL a minute. No setting here sees them earlier without the false
alarms above.

**When to re-check.** After two or three more weeks of lows (early December), with the same
script. Changes that would be worth testing then, once lows have more company: a margin used only
overnight, and false alarms split by whether the reading had just spiked (§18 found the LinkUp
graph points make spikes look sharper than they are).

    GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-heldout.ts
    # PENALTY=min per false alarm (default 10), LIST=1 for every candidate, FROM=unix seconds to
    # score only lows and alerts from then on

`dir` holds readings.json, with the trend column, and log.json, as for `low-alert-replay.ts`:

    select json_agg(json_build_array(extract(epoch from at)::bigint, mgdl, trend) order by at) from glucos.readings;
    select json_agg((payload->>'timestamp')::float::bigint order by (payload->>'timestamp')::float)
      from glucos.logbook where not deleted and kind in ('dose', 'meal', 'context')
        and payload->>'timestamp' is not null and not coalesce(payload->'tags' ? 'wokeUp', false);

## 31. Forecasts made just after a gap in readings (16 Nov 2026)

The question: do forecasts made just after a gap in readings (a LibreLinkUp or Bluetooth dropout,
the Mac asleep, the iPhone app closed) miss more than ones made on unbroken readings, and if so,
would a shorter horizon or a wider range for the first few minutes after a gap do better on days
it wasn't learnt on? **Partly, but neither fix held up held out, so nothing shipped.** No app or
relay code changed, so the Mac, iPhone and relay still forecast and widen the same way they did.

Nothing here touches dosing: the bolus calculator, insulin on board, sensitivity and carb ratios
were not read or changed.

**What there is.** 605 clean points at 15, 30 and 60 minutes in `glucos.forecast_checks`
(12 Nov 15:23 to 16 Nov 11:49 Perth) and 7,294 readings to 16 Nov 12:06. Two kinds of gap:

- **A gap in the data.** Live readings only (LinkUp graph points within 30 seconds of another
  reading dropped, as in §23), any step over 5 minutes. Since forecasts started being logged there
  have been only 13 of these, 5–15 minutes long. The other 52 of the 65 are 10–11 Nov, before
  the relay ran, when only LinkUp's 15-minute graph was stored.
- **The app waking up.** The first forecast an app logs after more than 25 minutes without one:
  the Mac waking from sleep or the iPhone app opened again. The ledger keeps one forecast per 15
  minutes, so 25 minutes means at least one was skipped. Of the 56 such forecasts with a clean
  15-minute point, 49 are the iPhone and 7 the Mac, and only 3 (all iPhone) come after the iPhone
  started filling its history from the relay (PR #82, 15 Nov). The relay never sleeps, so it only has the first kind.

**Do they miss more?** Clean points, error in mg/dL:

| Horizon | Unbroken: forecast / no change / inside | First after a wake | Data gap in the last 30 min |
|---|---|---|---|
| 15 min | 17.4 / 19.2 / 72% (227) | 16.6 / 14.9 / 64% (50) | 16.4 / 13.6 / 83% (24) |
| 30 min | 27.1 / 31.2 / 71% (142) | 26.7 / 28.5 / 67% (43) | 34.0 / 21.8 / 78% (9) |
| 60 min | 47.0 / 47.6 / 67% (91) | 44.2 / 35.3 / 58% (12) | 68.1 / 58.8 / 43% (7) |

The forecast's own error after a gap is no bigger than usual. What changes is that it loses its
edge over "no change": the moments after a wake or a dropout are calmer on average, so no change
does better there, and the forecast doesn't. The first forecast after a wake also falls inside its
range less often (64% against 72% at 15 minutes).

It isn't the trend being read from stale data. At the iPhone's first forecast after opening, its
starting reading matched the server's live reading to the mg/dL, and its trend was 0.74 mg/dL a
minute off a 10-minute line through the server's live readings, against 0.62 for its other
forecasts. Forecasting those moments with the server's trend instead would still have lost to no
change (16.4 against 15.2).

**Held out.** Each Perth day left out in turn, learnt on the other days (at least 10 points),
for the first forecast after a wake and for every forecast up to 15, 30 or 45 minutes after it:

- **Shorter horizon:** stop drawing a horizon after a gap when, on the other days, it lost to no
  change there (scored as no change on the day left out).
- **Wider range:** widen the range after a gap by the 80th-percentile miss ratio on the other
  days (never narrower), as §19 and §21 did. Scored on the 80% interval score (width plus ten times
  any miss outside it; lower is better).

| After a wake | 15 min: error now → cut, score now → wider | 30 min | 60 min |
|---|---|---|---|
| First forecast only | 17.9 → 15.0, 101.1 → 98.9 (56) | 28.4 → 31.0, 154.2 → 152.4 (47) | 33.5 → 31.2, 160.0 → 135.3 (9) |
| Up to 15 min after | 17.4 → 15.3, 95.9 → 94.4 (61) | 27.6 → 30.1, 145.2 → 145.8 (52) | 45.6 → 35.9, 249.6 → 219.8 (17) |
| Up to 30 min after | 16.7 → 15.4, 94.6 → 94.7 (81) | 28.5 → 29.8, 156.1 → 153.2 (66) | 42.4 → 34.6, 243.5 → 224.2 (25) |
| Up to 45 min after | 16.4 → 16.7, 90.0 → 88.0 (95) | 26.0 → 26.0, 144.5 → 148.2 (77) | 40.9 → 42.2, 219.6 → 217.7 (32) |

Why none of it shipped:

- **Cutting 15 minutes is the wrong shape.** It wins at 15 minutes, but a horizon is cut from the
  far end. Hiding the first 15 minutes while drawing 30 makes no sense, and at 30 minutes cutting
  loses (28.4 → 31.0). Cutting the whole forecast after a wake would cost more at 30 minutes than
  it saves at 15.
- **The 60-minute win is one afternoon.** 17 points over 4 days, and 15 Nov carries it: model
  forecasts heading for 39 mg/dL at 14:10, 15:06 and 17:18 that ended at 93–217, because the lows
  were treated and the treatment wasn't logged, so the points count as clean. On 13 Nov cutting
  loses (25.3 against 24.6 for no change); on 12 Nov the forecast beat no change.
- **The wider range wins on two days and loses on two.** At the first forecast after a wake:
  13–15 Nov better at 15 minutes, 12 and 16 Nov worse (16 Nov, the only day with the relay
  history fill in place, goes 101 → 178, on 3 points). The pooled gain is 2% at 15 and 30 minutes and is mostly
  15 Nov again. §9 already widens each device's range from its own shown forecasts, which covers
  part of this.
- **Data gaps are too rare to learn from.** 8–30 points over three days; on most held-out days
  there weren't 10 training points, and where there were, nothing changed. The relay's points after
  a dropout were better than usual (10.1 against 19.6 mg/dL), and those are the only after-gap
  points that all three senders would share, so a rule there couldn't be made to agree.
- **Most of the wake points predate the fix for them.** PR #82 fills the iPhone's history from the
  relay before it forecasts. Only 3 first-after-opening iPhone points at 15 minutes come after it.

**Side notes.** The Mac's last logged forecast is 16 Nov 00:01 Perth; nothing from it since. Live readings had two 15-minute gaps at 11:31 and 11:46 Perth today, with only
LinkUp's graph points in between.

**When to look again.** Around 3 December, with the iPhone's opens after PR #82 counted on their
own (`since_wake` in the script): if the first forecast after opening still loses to no change at
15 and 30 minutes on most days, the thing to test is drawing nothing until the second reading
after opening, rather than a horizon or a range. Logging low treatments would also take 15 Nov's
afternoon out of "clean".

    python3 scripts/gap-forecasts.py dir

`dir` holds readings.json, with the trend column (as for §30), and checks.json:

    select json_agg(json_build_array(extract(epoch from issued_at)::bigint, device, basis, start_mgdl,
      trend_per_minute, (select json_agg(json_build_array((p->>'minutes')::int, (p->>'mgdl')::numeric,
        (p->>'lower')::numeric, (p->>'upper')::numeric, (p->>'actual')::numeric,
        coalesce((p->>'after_log')::boolean, false), coalesce((p->>'shown')::boolean, true),
        (p->>'scale')::numeric))
      from jsonb_array_elements(points) p
      where (p->>'minutes')::int in (15, 30, 60) and jsonb_typeof(p->'actual') = 'number'),
      app_version) order by issued_at)
    from glucos.forecast_checks;

## 32. Does the trend arrow match what happened next? (16 Nov 2026)

The question: the arrow beside the reading (falling quickly, falling, steady, rising, rising
quickly) is the first thing anyone reads. Does it describe the next 15–30 minutes, and if its
thresholds mislead, would different ones do better on days they weren't learnt on? **It overstates
moves, but no threshold set beat it held out without hiding falls before lows, so nothing shipped.**
No app or relay code changed: the Mac, iPhone, widgets, Live Activity and relay all still show the
same arrow.

Nothing here touches dosing: the bolus calculator's trend adjustment, insulin on board,
sensitivity and carb ratios were not read or changed.

**Where the arrow comes from.** Every screen shows LibreLinkUp's `TrendArrow`, passed through
unchanged (`LibreLinkUpClient`, relay `libre.ts`, then `GlucoseActivityState.trend` to the Live
Activity and widgets). Abbott documents it as the rate now: beyond ±2 mg/dL a minute is "quickly",
beyond ±1 is rising or falling. GlucOS only works out its own arrow for readings decoded straight
from a sensor (`LibreReadings.trend`, the same ±1/±2 over the last 15 minutes), which Declan's
Gen2 sensor doesn't allow. So the realistic change is replacing LinkUp's arrow with one GlucOS
works out from the readings.

**What there is.** 6,770 live readings (one per minute, LinkUp graph points dropped as in §23),
11 to 16 Nov Perth; 6,654 have a live reading within 2 minutes of both 15 and 30 minutes later.
"What happened" uses the same bands as the arrow: the change over the next 15 minutes divided by
15 (±15 and ±30 mg/dL; ±30 and ±60 over 30 minutes).

| LinkUp arrow | Readings | Median change, 15 / 30 min | Right band, 15 / 30 | Right way, 15 / 30 | Wrong way by 15+ |
|---|---|---|---|---|---|
| Falling quickly | 195 | −12 / −29 | 23% / 11% | 74% / 76% | 12% |
| Falling | 522 | −12 / −16 | 26% / 33% | 72% / 62% | 15% |
| Steady | 5,235 | −1 / −2 | 66% / 75% | 66% / 75% (within ±15 / ±30) | 12% (moved 30+) |
| Rising | 456 | +9 / +5 | 25% / 22% | 63% / 53% | 18% |
| Rising quickly | 246 | +11 / +9 | 23% / 15% | 67% / 61% | 19% |

So the direction is right about two times in three, but the size is overstated: after "rising
quickly" glucose rose a median 11 mg/dL over the next 15 minutes, which is the steady band. That's
expected from an arrow that reports the rate now, since rises and falls turn; the forecast, which
carries only part of the trend forward (§3, `ForecastTuning.trendGain`), already allows for it. Rising arrows are
the weakest: after "rising", glucose was higher 30 minutes later only 53% of the time. When glucose
really did move 15 mg/dL in 15 minutes, LinkUp's arrow pointed that way beforehand only 23% of the
time.

**Candidates.** An arrow GlucOS works out from the rate over the last 5, 10 or 15 minutes of live
readings, with the steady/rising threshold from 0.5 to 2 mg/dL a minute and the quickly threshold
from 1.5 to 4. Each Perth day left out in turn (6 days), thresholds fitted on the other five.

- **Band distance** (how many bands the arrow was off; lower is better) picks ±2/±4 on every
  fold and "wins" 0.548 against 0.604 at 15 minutes. But showing no arrow at all, always steady,
  scores 0.534: this score rewards a quiet arrow, because most of the time nothing much happens.
  ±2/±4 shows a falling arrow before only 32% of pre-low readings, against 59% for LinkUp.
- **Balanced score** (share of real moves the arrow pointed at, plus share of steady stretches
  it left steady; always steady scores 1.0): the fitted rule beat LinkUp on 2 of 6 days at 15
  minutes (mean 1.050 against 1.063) and 3 of 6 at 30 minutes (1.062 against 1.086). A loss.
- **Trade-off, all days pooled, 15 minutes:**

| Arrow | Moves pointed at | Arrow shown, then steady | Falling arrow before a low |
|---|---|---|---|
| LinkUp (shown now) | 23% | 42% | 59% |
| Own, 15 min, ±1/±2 | 36% | 47% | 64% |
| Own, 15 min, ±0.75/±1.5 | 43% | 51% | 72% |
| Own, 15 min, ±2/±4 | 16% | 39% | 32% |
| LinkUp with "quickly" shown as plain rising/falling | 23% | 42% | 59% |

"Before a low" is the 141 readings at 80 mg/dL or more that were under 70 thirty minutes later
(8 separate lows). Every own arrow that catches more moves also cries wolf more often, and every
one that cries wolf less hides falls before lows. None is better on both, and §30's low alerts
already warn on all 8 of these lows with the forecast, not the arrow.

Why nothing shipped:

- **No candidate won held out.** On the balanced score LinkUp's arrow won 4 of 6 days at 15
  minutes and 3 of 6 at 30. The only score a new threshold wins outright is one a blank arrow
  wins too.
- **Quieter arrows cost safety.** The wider thresholds that look better on band distance halve
  the share of falls flagged before a low. A low-going reading shown as steady is the worst
  mistake an arrow can make.
- **Demoting "quickly" changes nothing that matters.** Showing falling quickly as falling (and
  rising quickly as rising) improves band distance a little (0.604 → 0.569) only because the
  quickly bands are rarely reached; it points the same way and flags the same lows. And it would
  drop "falling quickly" from Abbott's own arrow, which people learn from the Libre app.
- **A GlucOS arrow would disagree with LibreLinkUp.** LinkUp's arrow matches a 15-minute rate
  through the live readings 71% of the time (96% within one band), so an own arrow would
  differ from the Libre app on Declan's phone about one reading in three, for no measured gain.

**When to look again.** With 3+ weeks of readings (early December), if rising arrows are still
right only about half the time at 30 minutes: test showing "rising" only once the rise has lasted
10 minutes, scored on the balanced score and the falls-before-lows check together.
`python3 scripts/trend-arrow.py DIR` with readings.json ([[unix, mgdl, trend], ...] from
`glucos.readings`) prints every table here.

## 33. Can Today so far say where today will end up? (16 Nov 2026)

The question: the Today so far card says how today's time in range compares with your usual day
by now. Could it also say "Today is on track for about X% in range", from today's hours so far
plus your usual day for the rest, and be right to within about 5 points? **Not yet. The
projection beats both simpler guesses, but it missed by a median 7 points (10 counting only
earlier days), and by 9 to 43 points before midday, when it would be worth reading. Nothing
shipped.** No app or relay code changed; the card still shows today against the same hours on
your usual day.

Nothing here touches dosing: insulin, carbs and the bolus calculator were not read.

**What there is.** Five whole Perth days, 11 to 15 Nov (16 Nov was still going), readings
averaged into 5-minute buckets as the card does, target 70–180 mg/dL. Each day's time in range:

| Day | In range |
|---|---|
| 11 Nov | 28% |
| 12 Nov | 86% |
| 13 Nov | 75% |
| 14 Nov | 52% |
| 15 Nov | 37% |

**The projection.** At each whole hour from 01:00 to 23:00 (115 cuts), the share of the day gone
times today's time in range so far, plus the share still to come times the median of the other
days' time in range over those same remaining hours. Checked against the day's real end figure.
Two "usual" versions: every other day (more days, but it uses later days too), and only days
before it (honest, but 1 to 4 days). The app's own usual day needs 5 earlier days
(`DayPattern.minimumDays`), so on this data it would not have shown at all.

| From | Cuts | Projection, other days | Projection, earlier days only | Today so far only | Usual whole day |
|---|---|---|---|---|---|
| 01:00–06:00 | 30 | 26.6 | 21.7 | 23.2 | 30.2 |
| 07:00–12:00 | 30 | 9.2 | 11.2 | 14.2 | 30.2 |
| 13:00–18:00 | 30 | 2.9 | 6.5 | 13.2 | 30.2 |
| 19:00–23:00 | 25 | 2.8 | 3.1 | 6.3 | 30.2 |
| **All** | 115 | **7.0** | **10.3** | 14.2 | 30.2 |

Median miss in percentage points. Within 5 points: 44% of projections, 16% for today so far.
The 90th percentile miss was 36 points overall and 26 from 13:00 to 18:00.

Why nothing shipped:

- **It fails the bar.** A median miss of 7 to 10 points is over the ~5 points set for this
  round, and one projection in ten was off by more than a third of the day.
- **It only passes when it says little.** From 13:00 the median miss falls under 5, but by then
  most of the day is known, and on 11 Nov it was still off by 24 to 30 points all afternoon (the
  evening went far higher than any other day's). Before midday, when "on track for" would change
  how someone reads their day, it missed by 9 to 43 points.
- **Days differ more than hours do.** Days ranged from 28% to 86% in range. A usual rest of the
  day is a median of very different days, so it pulls every projection toward the middle; good
  days were projected too low and bad ones too high all morning (average miss per day from −36 to +43 points before midday).
- **A gate couldn't open honestly.** A self-check like back in range (§24) needs earlier days to
  score itself on, and with fewer than 5 earlier days the card has no usual day to project from.

Retest around 2026-12-03, once there are 3 weeks of whole days: run the same cuts with a 14-day
usual from earlier days only, and ship (gated per device by its own past misses, from midday)
only if the median miss is 5 points or less before 18:00.

SQL (Supabase, `glucos.readings`; change the window and cut list to rerun):

```sql
with r as (select (at at time zone 'Australia/Perth') l, mgdl from glucos.readings
           where mgdl > 0 and at >= '2026-11-10 16:00Z' and at < '2026-11-15 16:00Z'),
b as (select l::date d, (extract(hour from l)*12 + floor(extract(minute from l)/5))::int k,
             avg(mgdl) m from r group by 1, 2),
bi as (select d, k, (m >= 70 and m <= 180)::int i from b),
cuts as (select generate_series(12, 276, 12) c),
days as (select distinct d from bi),
sofar as (select D.d, c, avg(i) t from days D cross join cuts join bi on bi.d = D.d and bi.k < c group by 1, 2),
rest as (select D.d, c, avg(i) t from days D cross join cuts join bi on bi.d = D.d and bi.k >= c group by 1, 2),
actual as (select d, avg(i) t from bi group by d)
select s.d, s.c / 12 as hour, a.t as actual,
       s.c / 288.0 * s.t + (1 - s.c / 288.0) *
         (select percentile_cont(0.5) within group (order by r2.t)
            from rest r2 where r2.c = s.c and r2.d < s.d) as projected
from sofar s join actual a on a.d = s.d;
```


## 34. Did any release since 1.0 make forecasts worse? (16 Nov 2026)

The question: rounds 1 to 28 of the improvement loop shipped 1.0.0 to 1.23.0 in under a day. Did
any of them make the 15, 30 or 60 minute forecast worse against no change, on the Mac, the
iPhone or the relay (Lock Screen)? **No. No release since 1.0.0 changed a forecast that is drawn
or scored, and the relay, the only sender with enough checks since then, is exactly as far ahead
of no change as before (ratio 0.92 before, 0.93 since). The Mac and iPhone have too few checks
per version to judge either way, and nothing in their code gives a reason to expect a change.
Nothing shipped.**

Nothing here touches dosing: insulin, carbs and the bolus calculator were not read or changed.

**What changed in the forecast code.** Every commit from `v1.0.0` to `0ce7e75` (1.23.0) that
touched `Sources/Engine`, `Sources/Core` or `supabase/functions/relay` was read. Only three reach
the forecast at all:

| Change | Shipped in | Effect on forecasts |
|---|---|---|
| Predicted lows look along the trend's full 30 min (#90, §13) | 1.1.0, relay 2.11.0 | Adds `lowLookahead`, read by low alerts only. The drawn and scored samples are built by the same loop with the same sums (`morningAdded` stops at the old horizon), so they are unchanged. |
| Forecast accuracy per version (#95, §14) | 1.3.0, relay 2.12.0 | Records `app_version`. No forecast change. |
| "Did you treat this low?" (#125) | 1.10.0 | Re-marks `afterLog` on settled forecasts when a log arrives late, so a few checks move out of the clean set. Changes what is scored, not what is forecast. |

Back in range (#141, #145, #149) reads the forecast but doesn't change it; the relay's 2.13.0
(snooze) and 2.14.0 (back in range) don't touch `core.ts`'s forecast path. #82, #85 and #86 shipped
inside 1.0.0 itself and are the baseline here.

**What the forecast log shows.** Clean checks (`afterLog` false) from `glucos.forecast_checks`,
16 Nov 05:40 UTC. Ratio is the forecast's mean miss over no change's (under 1 = better than no
change). Checks without a version are split at the 1.0.0 tag (15 Nov 16:45 UTC).

| Sender | Versions | 15 min (n, ratio) | 30 min | 60 min |
|---|---|---|---|---|
| Mac | before 1.0 | 136, 0.93 | 118, 0.90 | 81, 0.97 |
| Mac | 1.15–1.19 | 5, 1.00 | 4, 1.19 | 2, 1.43 |
| iPhone | before 1.0 | 85, 1.04 | 75, 0.91 | 29, 1.21 |
| iPhone | 1.0–1.18 | 8, 0.86 | 1 | 0 |
| Relay | before 2.12 | 37, 0.92 | — | — |
| Relay | 2.12–2.14 (untagged, 2.12, 2.13, 2.14) | 42 (4, 7, 23, 8), 0.93 (0.91, 0.79, 0.98, 1.06) | — | — |

The relay scores 15 minutes only. Its per-version ratios drift from 0.79 to 1.06, but that is
the hour, not the version: since 1.0 more than half its checks were overnight and flat, where no
change is hard to beat. Split by how fast glucose was moving at the time, the relay is unchanged:

| Relay, 15 min | Flat (< 0.5 mg/dL/min) | Slow (0.5–1) | Fast (≥ 1) |
|---|---|---|---|
| Before 1.0 | 5, 0.99 | 6, 0.89 | 26, 0.91 |
| Since 1.0 | 23, 1.02 | 7, 0.96 | 13, 0.85 |

Its tuned trend share hasn't moved either: the forecast's 15-minute step over trend × 15 is 0.37
before and 0.36 since, so the tuner refits haven't drifted.

**Why the Mac and iPhone can't be judged per version.** A version lived about 30 minutes during
the loop, and each device logs one forecast per 15 minutes while it's awake, so most versions
have 1 to 4 checks (the Mac was asleep from 00:00 to 10:50 Perth; the iPhone logs only when the
app wakes). With 5 or fewer checks a ratio swings ±0.3 on one reading. Pooling every version
since 1.0, the Mac's 15-minute ratio is 1.00 on 5 checks and the iPhone's is 0.86 on 8: neither is
worse than before, and neither is evidence of anything. The Insights card's per-version line
(`ForecastSinceUpdate`, 30 checks) correctly shows nothing yet for the same reason.

**What would count as a regression next time.** Group by forecast code, not by version: the
versions above share one forecast engine. Re-run when the Mac and iPhone each have 100 clean
15-minute checks since 1.0 (about two waking days), or straight away if a release touches
`GlucoseForecaster`, `ForecastTuner`, `ForecastCalibration`, `ForecastLedger.rangeScale` or the
relay's `forecast`/`tuneTrend`. Flag it if any speed band's ratio rises by 0.10 or more on 30+
checks in that band.

SQL (Supabase; change the split date to the release being checked):

```sql
select fp.device,
       case when fp.issued_at < '2026-11-15 16:45:36+00' then 'before' else 'since' end era,
       case when abs(fc.trend_per_minute) < 0.5 then 'flat'
            when abs(fc.trend_per_minute) < 1 then 'slow' else 'fast' end speed,
       fp.minutes, count(*) checks,
       round((avg(abs(actual - predicted)) / nullif(avg(abs(actual - fp.start_mgdl)), 0))::numeric, 2) ratio
from glucos.forecast_points fp join glucos.forecast_checks fc on fc.id = fp.id
where fp.minutes in (15, 30, 60) and not fp.after_log
group by 1, 2, 3, 4 order by 1, 4, 3, 2;
```

## 35. More forecast checks from the Mac and iPhone (16 Nov 2026)

The question: §34 couldn't judge a release on the Mac or iPhone because each had 1 to 4 checks
per version. Why so few, and can they record more without changing any forecast? **They kept one
forecast per 15 minutes, only while awake, and sent each one only after it settled 3 h 20 min
later. Both now keep one every 5 minutes while fresh readings come in and send each one once its
first hour is scored. What's drawn is decided exactly as before.**

Nothing here touches dosing, the forecast's sums, or the relay's ledger (still one per 15 minutes).

**Why there were so few.** Gaps between the Mac's and iPhone's consecutive forecast checks, last
3 days (`glucos.forecast_checks`, 16 Nov 06:15 UTC):

| Gap | Mac (n, hours) | iPhone (n, hours) |
|---|---|---|
| Under 16 min | 62, 15.8 | 23, 5.9 |
| 16–20 min | 21, 5.7 | 14, 4.0 |
| 20–30 min | 3, 1.2 | 16, 7.1 |
| 30 min – 2 h | 3, 3.1 | 25, 26.3 |
| Over 2 h | 4, 44.9 | 8, 26.8 |

1. **Cadence.** The ledger's `spacing` of 15 minutes was a hard ceiling: at most 4 an hour however
   long the Mac was awake with readings every minute. That was most of the Mac's shortfall.
2. **Asleep.** 45 of the Mac's 70 hours were 4 stretches over 2 hours (overnight, lid closed). The
   iPhone records only while the app is open or woken for a background refresh, so most of its
   gaps are 30 minutes to hours. Neither can be fixed without polling while asleep, which the power
   rule from #94 rules out, and a forecast can't be recorded after the fact: that would be a
   replay, not what was shown.
3. **Upload lag.** A forecast was sent only once settled, 20 minutes after its last point (up to
   3 hours), so a version that lived 30 minutes had almost nothing on the server when §34 looked.
   Since 1.0 the server had 8 Mac forecasts and 10 iPhone ones in total.

Not a cause: dedupe. Each device's ledger keeps only its own forecasts, one per issue time, and
the server's `forecast_push` replaces on the forecast's id.

**What changed** (`ForecastLedger`, `ForecastLedgerStore`, `ForecastUpload`, migration
`20261116070000_glucos_forecast_extra_checks.sql`):

- `note` keeps a forecast when it's 5 minutes (`checkSpacing`) after the last one kept. The
  first one 15 minutes after the last quarter-hour check is always kept as a quarter-hour check,
  even if an extra was kept a minute before, so the quarter-hour checks land exactly where the
  old log put them. The others carry `extra = true` (nil on quarter-hour ones and every older
  record). No new timer: `note` runs on the readings the apps already fetch.
- **What's drawn doesn't change.** The range widening (`rangeScale`), the live horizon cut
  (`liveHorizon`) and the back-in-range gate read `ForecastLedger.quarterHourly`, the
  quarter-hour checks only: the same records, with the same values, as before. Using the extras
  there too would change the drawn forecast, and 5-minute checks overlap (their 15-minute points
  share 10 minutes of readings), so their thresholds would mean less. That's a separate question.
- **The Insights card and since-update line count every check**, as do the server's
  `glucos.forecast_scorecard` and `glucos.forecast_scorecard_by_version`, which mirror them. The
  views are unchanged and still match the apps: they count every row, and extras are rows. A
  horizon reaches the card's 30 checks about 3 times sooner on the Mac. Bear in mind the overlap:
  30 checks 5 minutes apart are worth roughly 10 to 15 independent ones, so a ratio on just
  over 30 is still loose. The mean miss itself isn't biased by the spacing.
- `forecast_checks.extra` (default false; older app versions send nothing) lets an analysis
  keep the old spacing: add `and not fc.extra` to compare with weeks before 16 Nov or with the
  relay.
- Sending: a forecast goes up as soon as its points up to 60 minutes have their readings
  (`earlyUploadMinutes`) and again when it settles (settling clears `uploaded`). The server
  already replaced points on a resend. Same once-a-minute sync, at most one more small push per
  forecast.
- Extras are kept 8 days on the device (`extraRetention`), enough for the card's week and the
  since-update figures; quarter-hour checks keep 90. The 3 weeks the trend line compares with are
  quarter-hour checks only, which doesn't bias a mean miss. The file grows by about a fifth,
  not threefold.

**What to expect.** The Mac was awake with readings about 26 hours in those 3 days: about 310
checks instead of about 100, roughly 100 a waking day. The iPhone gains less, since most of its
opens are shorter than 5 minutes; its checks also arrive sooner now. §34's "100 clean 15-minute
checks since 1.0" should take about a waking day on the Mac rather than two or three.

SQL (Supabase), checks per device and version with and without extras:

```sql
select device, app_version, count(*) checks, count(*) filter (where not extra) quarter_hour
from glucos.forecast_checks
where issued_at > now() - interval '2 days' and device <> 'relay'
group by 1, 2 order by 1, 2;
```

## 36. Are forecasts worse when glucose is low or high? (16 Nov 2026)

The question: do the 15 and 30 minute forecasts miss more, or hold their range less often, when
they start below 4.5 mmol/L (81 mg/dL), between 4.5 and 10, or above 10 (180 mg/dL)? And would a
trend damping or a range widening of its own for each band do better on days it hadn't seen?
**Yes, the bands differ, and in a consistent direction: forecasts that start low run low and ones
that start high run high. But neither fix beat what ships on held-out days, so nothing changed.**

Nothing here touches dosing, the insulin or carb effects, the low alerts or the relay.

**The data.** Clean points (nothing logged after the forecast) at 15 and 30 minutes in
`glucos.forecast_checks`, Mac, iPhone and relay, from 12 Nov 15:23 to 16 Nov 14:21 Perth: 531
points (325 at 15 minutes, 206 at 30). None are §35's 5-minute extras yet: 1.25, which sends
them, was released at 14:43 Perth, after the last settled point. The band is the reading the
forecast started from.

**As shown.** Bias is actual minus forecast, so positive means the forecast ran low.

| Start | Horizon | Points | Miss (mean) | No change | Bias | Inside range | Width |
|---|---|---|---|---|---|---|---|
| Under 4.5 | 15 min | 30 | 25.6 | 24.6 | +24.0 | 63% | 43.8 |
| 4.5–10 | 15 min | 198 | 15.4 | 17.0 | +2.6 | 73% | 43.6 |
| Over 10 | 15 min | 97 | 16.9 | 16.6 | −9.9 | 78% | 49.0 |
| Under 4.5 | 30 min | 8 | 74.7 | 67.4 | +74.7 | 38% | 59.7 |
| 4.5–10 | 30 min | 135 | 25.1 | 27.3 | +6.8 | 70% | 64.3 |
| Over 10 | 30 min | 63 | 23.2 | 28.1 | −16.0 | 83% | 71.4 |

(mg/dL, except inside range.) The pattern holds in finer steps too: the 15-minute bias goes from
+24 under 4.5 through about 0 between 6.7 and 10 to −9 to −12 above 10, and every sender shows it.

- **Low.** The forecast never missed *below* its range when it started low: all 11 misses at
  15 minutes and all 5 at 30 were glucose coming back up faster than the range allowed, 9 of the
  30 by more than 2 mmol/L in 15 minutes. That is lows being treated (or compression lows ending,
  §17) without the treatment logged, which is what "Did you treat this low?" (#125) is there to
  catch: answering it moves those points out of the clean set. "No change" does no better here. The 30-minute low band is 8 points
  on two days, too few to read anything into.
- **High.** Forecasts above 10 run about 10 mg/dL high at 15 minutes and 16 at 30, on both
  trend-only and model forecasts, so highs come down faster than forecast. The range still holds
  (78% and 83%): it's already wide enough there.
- **In range** is where the 4.5–10 band's coverage gap is (73% and 70% as shown), as §21 found
  for slow and flat trends.

**The tests.** Leave one day out, as in §21 and §22. Damping is f − (1 − k)·trend share, with k
learnt per band by least absolute error and bands with under 25 training points falling back to
one k. The widening is learnt per horizon and per group to hold 80%, never below 1, with the same
25-point fallback and interval score as §21.

| Held out, mean miss (mg/dL) | 15 min | 30 min |
|---|---|---|
| As shown | 16.80 | 26.46 |
| No change | 17.56 | 29.11 |
| One extra damping for all | 16.87 | 26.37 |
| Damping per band | 16.83 | 26.44 |
| Damping per band, above 4.5 only | 16.87 | 26.46 |
| Damping above 10 only | 16.58 | 26.52 |
| Shift forecasts above 10 by their median bias (not damping) | 16.41 | 25.63 |

| Held out, ranges, 15 + 30 min | Inside | Mean width | Interval score |
|---|---|---|---|
| As shown | 73.1% | 53.4 | 113.4 |
| One figure | 78.7% | 66.9 | 115.1 |
| Steady / fast at 1.5 (what §9 does) | 79.1% | 69.6 | 112.4 |
| Per band (under 4.5, 4.5–10, over 10) | 78.0% | 65.3 | 114.7 |
| Under 4.5 apart from the rest | 77.2% | 63.4 | 114.0 |
| Band × steady / fast | 77.0% | 63.5 | 112.4 |
| Steady / fast, under 4.5 apart | 79.1% | 67.1 | 112.1 |

- **Damping per band** changes nothing that matters. The fitted k is about 1 (no extra damping)
  at 30 minutes in every band with enough points. The low band would want much more damping
  (k ≈ 0.26 at 15 minutes), but that pulls falling forecasts up and so makes predicted lows
  later, which is ruled out; and with 30 points it falls back to one k anyway.
- **Ranges per band** lose to the speed split on both coverage and score. Bands and speed
  overlap (fast falls end low, fast rises end high), so splitting by band mostly re-cuts the same
  points into smaller groups. The last row is within noise of what ships: only the low band
  changes, it nearly always falls back to one figure, and its coverage stays at 66.7%.
- **Shifting highs down** by the median bias is the one thing that won overall (2.3% at
  15 minutes, 3.1% at 30). It was not part of the question and it doesn't pass the tuner's own
  bar (at least 3% better, and better in both halves): at 15 minutes it lost on 12 Nov and tied on 13 Nov, and most
  of the gain is 15 Nov's 42 points. It is also the learnt drift PR #53 rejected, now for one
  band. It would make "Back in range ≈ X min" (§24, highs only) sooner too, and that line has its
  own gate. Worth rerunning once §35's extras have filled a week.

**Low warnings.** Nothing tested here shipped, so low warnings (§13, §30) are exactly as before
on the apps and the relay. For the record, the shown forecast never ran high when it started
low, so it doesn't make low warnings late from that side.

To rerun the first table:

```sql
with p as (select c.start_mgdl s, (e->>'minutes')::int m, (e->>'actual')::float a,
  (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float up,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e)
select m, case when s < 81 then 'under 4.5' when s <= 180 then '4.5-10' else 'over 10' end band,
  count(*), avg(abs(a - f)) miss, avg(abs(a - s)) no_change, avg(a - f) bias,
  avg((abs(a - f) <= case when a >= f or lo <= 39.5 then up - f else f - lo end)::int) inside
from p where a is not null and not al and m in (15, 30) group by 1, 2 order by 1, 2;
```

## 37. Counting logged low treatments in the forecast (16 Nov 2026)

The question: §36 found forecasts that start under 4.5 mmol/L run low, because glucose comes back
up after a treatment. When the treatment *is* logged, does modelling it as fast carbs beat what
ships on lows the test hadn't seen? **Yes, by a wide margin and on every treated low, so it ships.
The shown forecast changes; low warnings don't.**

**What ships today after a logged low treatment.** Carbs tagged as a hypo treatment ("Treat a
low", "Log treatment") made the forecast trend only (`uncountedFood`), even with their carbs
logged. Carbs logged without the tag went on the meal curve (absorbed over three hours, from ten
minutes in), and for the first hour usually trend only (`freshLog`).

**The data.** Every meal logged at or under 45 g while the reading was under 70 mg/dL and with
one-minute readings around it: four, none tagged.

| Low | Treatment | Reading at log | Peak within 45 min |
|---|---|---|---|
| 12 Nov 19:08 | Burrito bowl, 37.5 g (+4 u, logged later) | 65 | 212 |
| 12 Nov 23:42 | Sports drink, 36.8 g | 66 | 156 |
| 13 Nov 19:27 | Sports drink, 21.4 g | 53 | 145 |
| 16 Nov 01:19 | Coke, 35 g | 54 | 151 |

Glucose was back up 90–145 mg/dL within about 45 minutes each time: more, and much sooner, than
the learnt carb effect (2.8 mg/dL per gram) gives the same grams on the meal curve.

**The test.** Forecasts every 5 minutes from the log to an hour after it, scored at 15 and 30
minutes against the readings (104 points), with the engine's trend handling (20-minute trend,
30-minute fade, 60% gain) and the logged insulin. Candidates: the treatment's carbs on a curve of
their own, delay 0–20 minutes, absorbed over 30–120, at 1–1.5× the learnt carb effect, picked on
three lows and scored on the fourth (leave one low out).

| Held out, mean miss (mg/dL) | 15 min | 30 min | Bias |
|---|---|---|---|
| No change | 26.7 | 41.6 | |
| Trend only | 24.5 | 42.3 | |
| Meal curve (what ships when it's modelled) | 24.4 | 40.5 | +10.9 |
| **Fast curve, held out** | **18.9** | **25.6** | **+1.3** |

| Each low held out (15 / 30 min) | Fast curve | Meal curve | No change |
|---|---|---|---|
| 12 Nov 19:08 | 21.8 / 25.8 | 25.4 / 39.4 | 30.2 / 40.1 |
| 12 Nov 23:42 | 24.0 / 33.6 | 32.6 / 56.5 | 28.5 / 41.8 |
| 13 Nov 19:27 | 9.8 / 12.5 | 13.3 / 20.5 | 23.9 / 39.6 |
| 16 Nov 01:19 | 20.0 / 30.6 | 26.1 / 45.5 | 24.3 / 44.8 |

The fit picked the same curve on three of the four folds (10-minute delay, absorbed over 30
minutes, 1.5× the carb effect; the other moved the delay to 15), and it beat the meal curve at
both horizons on every low, well past the tuner's bar (3% better and better in both halves). A
wider grid (up to 2.5×, 15-minute absorption) fitted less steadily and did no better held out.
The extra half on top of the carb effect is the rebound from the low itself (§17).

**What ships** (`Engine/LowTreatment.swift`):

- A low treatment is carbs, 45 g or less, logged with a hypo treatment tag or while the reading
  was under 70 mg/dL. Bigger meals keep the meal curve whatever the reading.
- In the forecast only, its carbs are absorbed over 30 minutes after a 10-minute delay, at 1.5×
  the learnt carb effect. It needs the carb effect learnt, as any carbs do.
- A tagged treatment with its carbs logged is no longer `uncountedFood` (a tag on its own still
  is), and a treatment doesn't start the `freshLog` hour (a dose logged with it still does).
- The forecast says so (`lowTreatment`: "Includes the fast carbs logged for a low"), so the
  forecast log can check these apart. After 40 minutes nothing of the treatment is left.

**Low warnings.** Counting a treatment raises the forecast, which would make a predicted low
later. So predicted alerts read the forecast worked out without the fast curve
(`Outlook.alertForecast`, exactly what shipped before): every warning, low or high, fires as it
did. The relay has no logbook and never sees treatments, so its forecast and warnings are
unchanged, and it and the apps still run the same alert rules on the same kind of forecast.
Lows on actual readings are untouched.

**Dosing.** Carbs on board, the carb-effect learner and the bolus calculator keep the meal curve
for the same entry (they never read the forecast, §26); only the forecaster's own rate uses the
fast curve.

**Caveats.** Four lows, so the 1.5× is rough. The one way it can mislead is the 16 Nov low, where
glucose sat at 53 for 18 minutes after the Coke: the fast curve drew it coming up about 10 mg/dL
early once. Treatments that go unlogged (most §36 rebounds) still aren't seen; "Did you treat this
low?" (#125) logs them, and they then count. Rerun once ten treated lows are logged, checking the
`lowTreatment` forecasts in `glucos.forecast_checks`:

```sql
select (e->>'minutes')::int m, count(*), avg(abs((e->>'actual')::float - (e->>'mgdl')::float)) miss,
  avg(abs((e->>'actual')::float - c.start_mgdl)) no_change
from glucos.forecast_checks c, jsonb_array_elements(c.points) e
where 'lowTreatment' = any(c.limitations) and e->>'actual' is not null
group by 1 order by 1;
```

## 38. Moving a late-logged meal back to when the rise started (16 Nov 2026)

The question: meals are sometimes logged after glucose has started climbing. If the forecast
moved such a meal's carbs back to where the rise began, would forecasts after it be closer at 30
and 60 minutes, on meals the test hadn't seen? **No. Every amount of back-dating made the 60-minute
forecast worse on both late-logged meals, and the held-out fit always chose the smallest shift on
offer. Nothing shipped; no app code changed.**

**What ships today.** A meal's carbs go on the meal curve from the time it's logged at (ten-minute
delay, absorbed over three hours). If the user sets an earlier time in the log sheet, that time is
used. The rise already under way when it's logged is in the 20-minute trend.

**The data.** Every meal logged since one-minute readings began (11–16 Nov), not counting the four
low treatments (§37) and the 13 Nov eggs logged twice: nine meals. A meal counts as logged late
when, walking back from the log in 5-minute steps (only readings up to the log, so it works live),
glucose kept getting lower and the log came at least 15 mg/dL and 10 minutes above that low point.
Two meals passed, and the result didn't move across rise thresholds of 15–40 mg/dL, noise
allowances of 3–6 and look-backs of 45–60 minutes:

| Meal | Reading at the rise start | At the log | Rise started |
|---|---|---|---|
| 11 Nov 09:29 pancakes, 40 g | 54 | 116 | 25 min before |
| 14 Nov 17:04 hamburger, 38.5 g | 106 | 182 | 30 min before |

The other seven were logged at or before the rise. The pancakes rise began at a 54 low, so it may
be an untreated-low rebound (§36) as much as a late log: really one clearly late meal in nine.

**The test.** Forecasts every 5 minutes from each meal's log to 2 hours after, replayed with the
engine's maths (20-minute trend, 30-minute fade, 60% gain, the logged rapid doses at 19.2 mg/dL
per unit, carbs at 2.8 mg/dL per gram on the meal curve, treatments on the §37 curve) and scored at
15–60 minutes against the readings, skipping points with another log in between (174 points at
15 minutes, 159 at 60). The candidate moved a late meal's carbs to the rise start, then a further
0–30 minutes earlier; detection settings and shift were picked on four days and scored on the
fifth (leave one day out).

| All nine meals, mean miss (mg/dL) | 15 min | 30 min | 45 min | 60 min |
|---|---|---|---|---|
| No change | 16.6 | 26.8 | 31.9 | 35.7 |
| What ships | 15.6 | 25.9 | 31.2 | **34.7** |
| Back-dated, held out | 15.6 | 26.0 | 32.0 | 36.5 |

| Late meals (30 / 60 min), miss and bias | What ships | Moved back 10 min | 20 min | 30 min |
|---|---|---|---|---|
| 11 Nov pancakes | 33.3 / 35.1 (−35 at 60) | 32.8 / 37.9 | 32.6 / 41.2 | 32.7 / 44.7 (−45) |
| 14 Nov hamburger | 21.0 / 33.0 (+0.4 at 60) | 21.5 / 35.4 | 21.9 / 38.0 | 22.4 / 40.5 (−7) |

Every fold picked the smallest shift, and held out it lost to what ships at 45 and 60 minutes, so
it fails the tuner's rule (§2: 3% better, and better in both halves).

**Why it doesn't help.** By the time a late meal is logged the trend already carries the rise. Moving
the carbs earlier counts some of them as already absorbed, so less is left to come and the line
drawn after the log is lower. After the pancakes the forecast was already 35 mg/dL low at an hour
(the rise went on to 288); after the hamburger it was unbiased. Lowering it hurt both. The
forecast's after-meal problem is the size and length of real rises (§25–§27), not their timing.

**Low warnings.** Back-dating only lowers the forecast after a late meal, so it could only make a
predicted low sooner, never later. In the replay, across 298 forecasts in the 4 hours after these
meals, no low warning (under 70 within 30 minutes) appeared or went away at any shift. Had it
shipped, predicted alerts would have read the forecast without it, as in §37.

**Dosing.** Not touched: nothing here changes dose timing, carbs on board, the effect learner or the
bolus calculator, none of which read the forecast (§26).

Rerun once five or more meals are logged 15+ minutes into their rise. The quickest way to find
them is the reading 30 minutes before each meal against the one at the log:

```sql
with m as (select to_timestamp((payload->>'timestamp')::float) t, payload->>'food' food, (payload->>'carbs')::float carbs
           from glucos.logbook where kind = 'meal' and not deleted and (payload->>'carbs')::float > 0)
select m.t at time zone 'Australia/Perth', m.food, m.carbs,
  (select mgdl from glucos.readings r where r.at between m.t - interval '35 min' and m.t - interval '25 min' order by r.at limit 1) before30,
  (select mgdl from glucos.readings r where r.at <= m.t order by r.at desc limit 1) at_log
from m order by 1;
```

Low treatments (§37) show up in that list too; leave out any logged under 70.

## 39. Adding the trend's acceleration (16 Nov 2026)

The question: the trend is a straight line through the last 20 minutes, so it can't see glucose
speeding up or easing off. If the forecast also carried on the curve of the last 15–20 minutes
(the second derivative, damped), would it be closer at 15 and 30 minutes on days the test hadn't
seen, especially around turning points, without making any low warning later? **Barely: under 1%
closer held out, against the tuner's 3%, and it made one low warning a minute later and added a
false alarm. Nothing shipped; no app code changed.**

**What ships today.** The trend is the least-squares slope of the last 20 minutes of readings,
counted at the tuned gain (about 60%) and faded to nothing over 30 minutes. Trend-only low warnings
read that line carried to 30 minutes (§13, §30).

**The test.** `scripts/acceleration-trend.py`, on every live reading from 11–16 Nov (6,967, one a
minute, LinkUp graph points left out). A trend forecast every 5 minutes, scored at 15 and 30 minutes
against the readings: 1,320 points over six Perth days, 298 of them at turning points (trend at
least 0.5 mg/dL per minute and the trend 15 minutes later the other way). The candidate fits a
quadratic to the last W minutes and adds k × acceleration × time to the slope as it fades, with the
added part capped at `cap` minutes (counted from the middle of the trend window, which is where a
least-squares slope sits). k (0–1), cap (5–30 minutes) and W (15 or 20) were picked on five days and
scored on the sixth.

| Held-out mean miss (mg/dL) | Points | No change, 15 / 30 | What ships | With acceleration |
|---|---|---|---|---|
| All | 1,320 | 16.0 / 25.4 | 15.5 / 25.0 | **15.4 / 24.8** |
| Quiet (no meal in 3 h) | 990 | 15.9 / 25.3 | 15.5 / 24.7 | 15.5 / 24.6 |
| Within 3 h of a meal | 330 | 16.1 / 25.8 | 15.6 / 25.9 | 15.3 / 25.5 |
| Turning points | 298 | **17.7 / 26.3** | 26.1 / 34.6 | 25.2 / 33.5 |
| Falling faster than 1 a minute | 263 | 17.9 / 29.9 | 17.2 / 27.9 | 17.0 / 27.6 |
| Rising faster than 1 a minute | 249 | 21.5 / 32.1 | 21.3 / 33.5 | 20.8 / 32.6 |

Every fold chose a light touch, W = 15 and k = 0.1 (four folds) or 0.3 with a 5-minute cap (two).
It was never worse than what ships on any held-out day, and tied on 15 Nov, but the overall gain is
0.6% at 15 minutes and 0.8% at 30, short of the tuner's rule (§2: 3% better, and better in both
halves). Larger amounts lose quickly: k = 0.5 is 16.4 / 26.2 and k = 1 is 18.6 / 29.6, because the
curve of 15 minutes of one-minute readings is mostly sensor noise (§22) and carrying it on doubles
the miss when it's wrong.

**Turning points.** This is where it helps most (3–4%), but it doesn't fix them. At a turning point
the straight trend misses by 26 mg/dL at 15 minutes where "no change" misses by 18, and the
acceleration term only takes one off that. The curve is too noisy to see the turn coming much
before it shows in the slope itself. This matches §21's finding that "flat" forecasts are turning
points and miss more: the honest fix is a wider range there, not a smarter line.

**Low warnings.** Replayed minute by minute over the 90 minutes before each of the eight lows under
70, a warning being the trend carried 30 minutes going under 70 (the predicted-alert gates aren't
modelled, so read this as the forecast's side only):

| Low (Perth) | What ships | k 0.1, cap 15 | k 0.3, cap 5 | k 0.5, cap 15, W 20 |
|---|---|---|---|---|
| 11 Nov 14:51 | 19 min | 19 | 19 | 17 |
| 12 Nov 18:45 | 6 | 6 | 6 | 6 |
| 12 Nov 23:39 | 4 | 5 | 5 | 5 |
| 13 Nov 19:05 | 10 | 11 | 11 | 13 |
| 15 Nov 17:16 | 14 | 14 | 14 | 14 |
| 15 Nov 21:40 | 4 | 4 | 4 | 7 |
| 16 Nov 00:52 | 5 | 5 | 5 | 5 |
| 16 Nov 04:50 | 60 | **59** | **59** | 71 |
| Warnings / false alarms | 18 / 7 | 20 / 8 | 19 / 7 | 31 / 19 |

The held-out settings warn a minute sooner on two lows and a minute later on one (the 16 Nov
overnight fall, as the fall eased before it carried on), and add a false alarm. The stronger
setting warns sooner on three lows but later on another and nearly triples the false alarms. So it
fails the rule that nothing may make a low warning later, as well as the accuracy rule.

**Dosing.** Not touched: the trend feeds only the drawn forecast and predicted alerts, never insulin
on board, the effect learner or the bolus calculator.

Retest once there are three or more weeks of one-minute readings, and only with a less noisy curve
(for example fitted over 5-minute means). Don't retry it on raw one-minute readings.

## 40. Are the ranges still right, and after lows? (16 Nov 2026)

The question: §37 started counting logged low treatments as fast carbs. Has it done what it should
on the readings since, are the likely ranges at 15, 30 and 60 minutes still holding 4 readings in
5, and do they hold up right after a low? **§37 hasn't had a low to act on yet. The ranges hold
74 / 70 / 65% overall, and only 58 / 27 / 20% on forecasts that start under 80 mg/dL (4.4 mmol/L),
where every miss is glucose coming back up past the top of the range. Widening the upper side
alone for those forecasts held 79 / 87 / 80% on lows the fit hadn't seen, so it ships. The central
line and the lower side don't move, so no warning changes.**

**§37 since it shipped.** Nothing to score: since #193 merged (07:26 UTC 16 Nov) glucose stayed
between 114 and 247 mg/dL, nothing was logged under 70, and no forecast in `glucos.forecast_checks`
carries `lowTreatment`. The treated lows are still the four in §37. Rerun with the §37 query once
ten are logged.

**Coverage, every moment.** All shown points with a reading at that distance (apps and relay,
12–16 Nov Perth; `scripts/low-start-range.py`, export query at its top):

| Inside the range (aim 80%) | 15 min | 30 min | 60 min |
|---|---|---|---|
| All | 74% (382) | 70% (256) | 65% (159) |
| 12 Nov | 60% | 50% | 49% |
| 13 Nov | 75% | 75% | 82% |
| 14 Nov | 73% | 74% | 73% |
| 15 Nov | 67% | 70% | 52% |
| 16 Nov | 86% | 74% | 77% |
| Starting under 80 mg/dL | **58% (33)** | **27% (15)** | **20% (10)** |
| 0–60 min after a treated low | 50% (14) | 12% (8) | 62% (8) |

By day it swings both ways: too narrow on 12 and 15 Nov, then on 16 Nov the 15-minute range holds
86% because the recent correction (§9) widened it after 15 Nov's misses. That's the correction
lagging a day, as designed, not a drift to fix. §19 and §21 already showed a single re-fitted
figure doesn't beat it (here one held-out factor per horizon reaches 80% but at 26–49% wider,
for an interval score no better: 93.5 → 94.5 at 15 minutes). The one place it's clearly wrong is
the start of a low: 21 of the 33 points under 80 missed at 15 minutes, all of them above the range.
That's the rebound of §17 and §36, treated or not, which neither the trend nor the meal curve draws.

**The test.** For forecasts starting under 80, the upper half of the shown range times a factor
per horizon, the factor being what would have held 4 in 5 of the other lows (leave one low out,
seven lows, points over 2 hours apart counting as different lows). The lower side stays as shown.
Interval score = width + 10 × how far outside (the standard score for an 80% range; lower is better).

| Held out, starting under 80 | Shipped | Upper side widened | Better on |
|---|---|---|---|
| 15 min (33 points) | 58% inside, 40 wide, score 167 | **79%, 83 wide, 94** | 6 of 7 lows |
| 30 min (15) | 27%, 47 wide, 422 | **87%, 133 wide, 167** | 5 of 6 |
| 60 min (10) | 20%, 75 wide, 721 | **80%, 226 wide, 324** | 3 of 4 |

The factor came out at 2.6–2.9 (15 min), 3.1–3.8 (30) and 2.5–3.7 (60) whichever low was left
out, and better in both halves of the week. Widening both sides instead is no better (score 96 at
15 minutes): nothing missed below. Over every moment the change takes the interval score from 93.5
to about 87 (15 min), 158 to 143 (30) and 256 to 231 (60), and coverage to about 76 / 74 / 69%.

**What ships** (`ForecastRangeScale.lowStartUpper`, relay 2.17.0 `lowStartUpper`):

- A forecast that starts under 80 mg/dL draws the upper side of its range 2.8× at 15 minutes,
  3.3× at 30 and 3.6× from 60 on (fitted on all seven lows; interpolated, from none at the start),
  on top of the usual widening, up to the sensor's top.
- Not when the forecast already counts carbs logged for the low (`lowTreatment`, §37): that draws
  the rebound itself, and wasn't part of this test. The relay never sees treatments, so always.
- Each point keeps the factor (`upperScale`), and the range widening (§9, §11) takes it out before
  learning from that point, so the steady widening doesn't shrink to make up for it.

**Low warnings.** Predicted lows read the central line (and the trend's 30-minute lookahead), and
the lower side is unchanged, so `firstRangeBelow` and every warning are exactly as before
(`LowStartRangeTests.testPredictedLowsAreUnchanged`). The relay and the apps still agree (parity
fixture regenerated).

**Dosing.** Not touched: ranges feed no dose, insulin on board, learner or bolus figure.

**Caveats.** Seven lows over five days, so the factors are rough; at 60 minutes only ten points.
A drawn range from 65 can now reach 140 at 30 minutes, which is honest (four rebounds in five went
higher than the old top) but looks wide. Retest at three weeks or 15 lows, and once §37 has scored
ten treated lows, check whether `lowTreatment` forecasts need this too.

## 41. Do forecasts that start high come down faster than the range allows? (16 Nov 2026)

The question: §40 found forecasts that start low come back up faster than their range allows.
Is the mirror true for highs: at 15, 30 and 60 minutes, do forecasts that start high come down
faster than the line (corrections), and is the bottom of the range right? **Up to 30 minutes the
range bottom is fine (79% and 78% inside). An hour out it isn't: forecasts starting over 180 mg/dL
(10 mmol/L) held only 57%, and all 19 misses were glucose coming down below the range. Widening
the lower side alone around the hour held 77–84% on highs and days the fit hadn't seen, so it
ships. Possible lows and low warnings read the range bottom from before the widening, so none of
them move.**

**The data.** Every shown point with a reading at that distance (Mac, iPhone and relay, 12–16 Nov
Perth; same export as §40, `scripts/high-start-range.py`). The relay only draws 30 minutes, and
every 60-minute point starting high is a Mac or iPhone model forecast. Bias is actual minus
forecast, so negative means the forecast ran high.

| Starting over 180 mg/dL | 15 min | 30 min | 45 min | 60 min | 90 min |
|---|---|---|---|---|---|
| Points | 126 | 89 | 53 | 44 | 9 |
| Inside the range (aim 80%) | 79% | 78% | 64% | **57%** | 89% |
| Missed below / above | 22 / 4 | 18 / 2 | 18 / 1 | **19 / 0** | 1 / 0 |
| Bias (mg/dL) | −9 | −18 | −33 | **−54** | −34 |
| Lower side needed for 4 in 5 | 0.91× | 1.04× | 1.42× | **1.72×** | 0.77× |

Yes, highs come down faster than the line, and more so the further out: −9 mg/dL at 15 minutes
(§36's figure), −54 at an hour. At 15 and 30 minutes the range is wide enough to take it, as §36
found. At 45 and 60 it isn't. It's there over 160 and over 200 too, on trend and model forecasts,
rising and falling starts, and on 4 of 5 days (14 Nov's six points all landed inside). Mostly
clean points (36 of 44 at 60 minutes had nothing logged after), so it's not only logged
corrections: insulin already on board doing more than the model credits, or meals peaking early.
Fixing that is the insulin curve, which is dosing maths and not touched here (§20 already found
no held-out win in its timing).

**The test.** For forecasts starting over 180, the lower half of the shown range times a factor
per horizon, the factor being what would have held 4 in 5 of the other highs (leave one high out,
points over 2 hours apart counting as different highs), and again leaving one day out. The upper
side stays as shown. Interval score as in §40 (width + 10 × how far outside; lower is better).

| Held out, starting over 180 | Shipped | Lower side widened | Better on |
|---|---|---|---|
| 15 min, one high out (126) | 79% inside, 51 wide, score 87 | 79%, 52 wide, 87 | 0 of 15 (factor ~1) |
| 30 min, one high out (89) | 78%, 75 wide, 141 | 79%, 80 wide, 145 | 3 of 14 |
| 60 min, one high out (44) | 57%, 121 wide, 292 | **77%, 162 wide, 222** | 5 of 8 highs |
| 60 min, one day out | 57%, 121 wide, 292 | **84%, 163 wide, 216** | 4 of 5 days |

The 60-minute factor came out at 1.60–1.83 whichever high or day was left out. Fitting on 12–14
Nov and testing on 15–16 Nov took the score from 348 to 254; the other way round, 253 to 196.
At 15 and 30 minutes there's nothing to win, so they stay as they are. The 45-minute points
(interpolated 1.35×, not fitted there) were better on 4 of 5 days (64% → 74% inside, score
218 → 196), and at 90 minutes
widening made it worse (8 of 9 already inside), so the widening tapers back to none by then.

**What ships** (`ForecastRangeScale.highStartLower`, Mac and iPhone):

- A forecast that starts over 180 mg/dL draws the lower side of its range 1.7× at 60 minutes,
  rising from none at 30 and back to none at 90 (interpolated, so 1.35× at 45 and 75), on top of
  the usual widening, down to the sensor's floor.
- Each point keeps the factor (`lowerScale`), and the range widening (§9, §11) takes it out before
  learning from that point, as §40 does for `upperScale`.
- The relay is unchanged: its trend forecast stops at 30 minutes, where the factor is 1.

**Low warnings.** The central line doesn't move, so predicted lows (`PredictiveAlertRules`, the
trend's 30-minute lookahead) are exactly as before. "A low is possible from …"
(`firstRangeBelow`) is the one thing that reads the range bottom, so the forecast keeps the bottom
each widened sample had before (`warningLowers`) and that reads it; it fires at exactly the same
moments (`HighStartRangeTests.testPossibleAndPredictedLowsAreUnchanged`). The chart's hover caption
on the Mac describes the drawn range, so it can now say the range reaches below your low an hour
out from a fast-falling high, which is what the wider range honestly shows.

**Dosing.** Not touched: ranges feed no dose, insulin on board, learner or bolus figure. The
central-line fix (shifting highs down, §36) stays rejected for now: it would move "Back in range
≈ X min" sooner and changes the line, not the range.

**Caveats.** Eight highs and 44 points at 60 minutes over five days; the factor is rough and
falls back on four days of data. Retest at three weeks with `scripts/high-start-range.py`. If the
insulin curve is ever re-fitted (with Declan's OK), drop this first and measure again.

## 42. Should the range follow the last few hours' accuracy, narrower as well as wider? (16 Nov 2026)

The question: the range widening (§9) learns from two weeks, with a 12-hour correction that can
only widen. Would scaling every range by how the last few hours of forecasts actually landed do
better: narrower after a run of good forecasts, wider after misses, within caps? **No. Every
version either widened the range more than it won back in coverage, or narrowed it and lost
coverage. None improved both, so nothing ships.**

**The data.** 974 clean shown points (nothing logged after, drawn) with a reading at 15, 30 or
60 minutes, Mac, iPhone and relay, 12–16 Nov Perth (`scripts/adaptive-range.py`, export query at
its top). Points drawn by a version from before §40 or §41 (by app version) get those widenings
first, so "shipped" below is what's drawn today and nothing is widened twice. 28 of the points
landed under 70 mg/dL.

**The test.** Walk forward through the points. At each forecast, take the points whose reading
came in during the last W hours, apps and relay apart, and work out the factor that would have
held 4 in 5 of them (80th percentile of the miss ratio, as §9 does). Once there are N of them,
draw both sides of the range times that factor, clamped between a floor and a cap. Interval score
as in §40 (width + 10 × how far outside; lower is better).

| Inside / width (mg/dL) / score | 15 min | 30 min | 60 min | Days better (of 5) |
|---|---|---|---|---|
| Shipped | 76% / 50 / 87.3 | 73% / 79 / 145.9 | 77% / 155 / 229.7 | |
| 6 h, 20 points, 0.7–2× (as suggested) | 79% / 59 / 92.0 | 77% / 95 / 152.3 | 78% / 165 / 234.5 | 2, 2, 2 |
| 6 h, widen only to 2× | 80% / 62 / 92.3 | 78% / 99 / 151.8 | 80% / 173 / 232.4 | 2, 2, 2 |
| 12 h, widen only to 2× | 83% / 66 / 91.7 | 79% / 108 / 153.5 | 85% / 186 / 235.2 | 2, 1, 1 |
| 3 h, 10 points, 0.85–1.5× (best overall) | 77% / 56 / 88.2 | 77% / 91 / 145.7 | 81% / 169 / 221.0 | 3, 4, 3 |
| 3 h, narrow only, to 0.7× | 71% / 46 / 87.3 | 70% / 73 / 145.0 | 76% / 145 / 229.6 | 2, 2, 2 |
| 6 h, narrow only, to 0.7× | 74% / 48 / 87.0 | 72% / 75 / 146.4 | 75% / 147 / 231.9 | 2, 2, 1 |

These seven are what the script prints. `--grid` runs the 179 combinations behind them (windows
of 3, 6, 12 and 24 hours, 10, 20 or 30 points, floors 0.5–1, caps 1–2.5); "best overall" is the
lowest summed score among those, and its near neighbours (3 hours, 1.5× cap) score within a point.

- **The suggested 6-hour version is worse on every horizon.** It lifts coverage by 3–4 points at
  15 and 30 minutes (still short of 80%) by drawing ranges 17–20% wider, and its score goes up,
  not down. Errors from the last six hours say little about the next half hour here; by then the
  meal, the correction or the low is over.
- **Narrowing trades coverage for width almost one for one.** The last few hours' factor came out
  under 1 about 30% of the time, but the ranges are still short of 80% overall (76 / 73 / 77%),
  so a narrower range after a good spell mostly turned near-misses into misses. The narrow-only
  versions lose 1–5 points of coverage for 2–10 mg/dL less width, with scores within 2.2 of
  shipped either way (87.0 vs 87.3 at 15 minutes for 6 hours, 145.0 vs 145.9 at 30 for 3 hours),
  and they're better on only 1–2 days of 5.
- **The best of the grid (3 hours, 0.85–1.5×)** reaches 77 / 77 / 81%, but it's 9–15% wider at
  every horizon, worse at 15 minutes (88.2 vs 87.3), level at 30, and was picked on the same five
  days. The one clear gain is at 60 minutes (230 → 221), mostly long highs that §41 now covers on
  the lower side.

**Low warnings.** A range that only narrowed could have left the bottom above 70 on readings that
went under it; none of the versions here lost one (26 of the 28 had the bottom under 70, as
shipped). Widening both sides does the other thing: the bottom reached under 70 on 267–274 of the
946 readings that stayed above 70, against 237 shipped, so "a low is possible" would show more
often for nothing. Any version that ships would need §41's `warningLowers` to keep warnings where
they are.

**Dosing.** Not touched: ranges feed no dose, insulin on board, learner or bolus figure.

**Caveats.** Five days. The shown points already carry the 12-hour correction, and app points in
`glucos.forecast_checks` don't record their widening (only the relay's carry `scale`), so this
measures an extra correction on top of what was drawn, not a replacement for it. Retest at three
weeks with `scripts/adaptive-range.py --grid`, and only take a 3-hour window if it wins on held-out
days with width no worse; if coverage reaches 80% on its own, try the narrow-only version again
first.

## 43. Forecasts after back-to-back meals (16 Nov 2026)

The question: when a second meal is logged while the first is still being absorbed (within 90
minutes of it), do forecasts after the second meal run high or low, and would combining the two
meals' absorption (slowing or queueing the second, or treating them as one meal) do better? **There
is only one such pair in the history, so nothing can be tested on meals the fit hasn't seen. On that
pair the forecast ran low, delaying or slowing the second meal made it worse at 60 and 90 minutes
(a 30-minute wait was level to slightly better at 15–45), and the versions that helped change the
first meal's curve too, which §15 already turned down. Nothing
shipped; no app or relay code changed.**

**What ships today.** Every meal's carbs go on their own copy of the standard curve (ten-minute
delay, three hours) from the time they're logged, and the forecast adds the copies together. A
second meal neither waits for the first nor changes how fast it's absorbed.

**The data.** All 17 meals with carbs logged 7–16 Nov. Pairs under 90 minutes apart:

| Pair | Gap | Counted |
|---|---|---|
| 12 Nov 14:09 sushi (53.9 g, 7 U), then 15:23 green juice (16.6 g); 4 U at 14:43 | 74 min | Yes |
| 13 Nov 09:58 and 10:10 eggs and hash brown | 12 min | No: the same meal logged twice (§38) |

The next closest gaps are 197 minutes (11 Nov breakfast then pancakes, 16 Nov pie then sausage
roll), after the first meal's three hours ten minutes on the curve, so the model already sees them
as separate meals. Stored forecasts after those two pull opposite ways: after the sausage roll the
60-minute point ran 39 mg/dL high (11 forecasts, 55% inside the range), after the juice 17 mg/dL low
(7 forecasts, 86% inside).

**The test.** Forecasts every 5 minutes for the 2 hours after the juice (25 forecasts), replayed
with the engine's maths (20-minute trend, 30-minute fade, 60% gain, carbs at 2.8 mg/dL per gram,
rapid insulin at 19.2 mg/dL per unit) and scored against the readings up to the 19:08 burrito bowl
(`scripts/stacked-meals.py`, export query at its top). Mean miss, with the bias in brackets
(negative is the forecast below what happened). In the first hour after a log the engine draws
the trend alone unless its fresh-model check allows the model (`freshModel`); after the juice the
apps drew the model (7 of the 8 stored forecasts), so every origin is replayed with it, and the
script also prints the first hour (12 origins) and the rest (13) apart. "Both over 4 h" and
"merged" come out best in both parts; a 30-minute wait is a little better than what ships after the
first hour (33.8 against 34.0 at 60 minutes) and worse within it (38.3 against 35.4).

Mean miss (mg/dL), all 25 origins:

| Model of the two meals | 30 min | 60 min | 90 min |
|---|---|---|---|
| No change | 19.8 (−12.5) | 33.5 (−20.3) | 49.0 (−13.6) |
| What ships: two curves added | 18.2 (−12.8) | 34.7 (−26.6) | 53.0 (−28.8) |
| Second meal absorbed over 4 h / 5 h | 18.7 / 19.3 | 36.8 / 38.7 | 57.8 / 60.4 |
| Second meal waits 30 / 60 / 90 min | 17.9 / 19.2 / 20.6 | 36.0 / 40.5 / 44.5 | 56.5 / 63.1 / 69.4 |
| Second queued until the first is 80% absorbed (+49 min) | 18.7 | 39.0 | 60.6 |
| Merged into one 70.5 g meal from the first log, stretched by the gap | 16.2 (−11.9) | 32.2 (−21.2) | 50.8 (−18.2) |
| Both meals absorbed over 4 h | 15.7 (−11.4) | 31.6 (−18.9) | 50.6 (−13.6) |
| Both meals absorbed over 5 h | 16.1 | 36.4 | 57.9 |

- **Making the second meal wait or last longer is worse at 60 and 90 minutes.** Only the 30-minute
  wait is level or a little better earlier on (17.9 against 18.2 at 30 minutes), and longer waits
  are worse everywhere. The forecast was
  already low: glucose went from 104 at the juice down to 82, then up to 158 two and a half hours
  later, a rise of 76 mg/dL against the 46 that 16.6 g is worth. Pushing the juice's carbs later
  moves more of them past the drawn points and lowers the line further.
- **What helped is a longer curve for the first meal.** "Both over 4 h" and "merged" are 7–9%
  better at 60 minutes, because they keep more of the sushi's carbs for the second rise. That's
  the slow-meal question §15 tested on all meals, where a longer curve didn't win; here it's one
  meal, one afternoon, so a stacking rule fitted to it would be fitting the sushi, not stacking.
- Even the best version misses by more than no change at 90 minutes, and none passes the tuner's
  rule (§2: 3% better, and better in both halves), which needs at least two events to split.

**Low warnings.** Glucose stayed above 82 for the 2 hours after the juice, and no replayed
forecast in any version went under 70 within 30 minutes, so there's nothing to compare. Every
delaying version would only lower the forecast after a stacked meal and so could make a predicted
low sooner, not later; had any shipped, predicted alerts would have read the forecast without it,
as in §37.

**Dosing.** Not touched: the carb curve is shared with carbs on board and the effect learner, so a
forecast-only change would have gone in `GlucoseForecaster`'s `modelRate`; nothing here changes the
bolus calculator, insulin on board or the curves themselves.

Rerun once five or more meals are logged within 90 minutes of an earlier one (not counting the
same meal logged twice or low treatments, §37). To find them:

```sql
-- Leaves out low treatments (logged under 70 mg/dL) and repeat logs of the same food within
-- 20 minutes before pairing, so neither hides a real pair.
with m0 as (select to_timestamp((payload->>'timestamp')::float) t, payload->>'food' food, (payload->>'carbs')::float carbs
            from glucos.logbook where kind = 'meal' and not deleted and coalesce((payload->>'carbs')::float, 0) > 0),
m1 as (select m0.*, (select mgdl from glucos.readings r where r.at <= m0.t order by r.at desc limit 1) at_log,
         lag(t) over (partition by food order by t) same_food_before from m0),
m as (select * from m1 where coalesce(at_log, 100) >= 70
        and (same_food_before is null or t - same_food_before > interval '20 min'))
select * from (select t at time zone 'Australia/Perth' perth, food, carbs,
  round(extract(epoch from t - lag(t) over (order by t)) / 60) gap_min from m) x
where gap_min < 90 order by perth;
```

Then score forecasts across all of them with each meal held out in turn, starting with "both over
4 h" and "merged", and keep the delaying versions out unless the forecast after stacked meals turns
out to run high.

## 44. Should forecasts drift back toward your usual level further out? (16 Nov 2026)

The question: of everything the forecast log holds, where is the biggest error that hasn't been
tried, and does one targeted fix beat what ships on error and on the range at once, without making
a low warning later? **The biggest untried pattern is level at 45–60 minutes: forecasts that start
in range run low and ones that start high run high, so glucose drifts back toward its usual level
faster than the line does. Pulling the line toward the last 7 days' mean fixes most of it, but
almost all of the gain comes from lifting forecasts that are heading low, which would hide lows
from the drawn line. The version that leaves those alone is under 2% better at 15, 30 and 60
minutes and worse on some days, so nothing ships.**

Nothing here touches dosing, the insulin or carb effects, the low alerts or the relay.

**Finding the bucket.** Clean shown points (nothing logged after, drawn) in
`glucos.forecast_checks`, Mac, iPhone and relay, 12–16 Nov Perth, split by horizon and then by
start level, trend, time of day and basis. Ranked by total miss, the model forecasts
(`trendInsulinCarbs`) at 45 and 60 minutes are the largest (8,429 and 7,916 mg/dL summed), and
at 60 minutes they no longer beat "no change" (55.0 against 54.5). Inside that, the split that
shows a steady, growing bias is the start level:

| Start | 15 min | 30 min | 45 min | 60 min |
|---|---|---|---|---|
| Under 81 (bias, points) | +23.6 (28) | +74.7 (8) | +79.2 (6) | +93.7 (5) |
| 81–180 | +4.0 (227) | +11.0 (148) | +19.1 (106) | **+31.6 (89)** |
| Over 180 | −8.8 (157) | −15.2 (107) | −31.7 (68) | **−31.0 (50)** |

(Bias is actual minus forecast, mg/dL, so positive means the forecast ran low.) §36 looked at
this by band at 15 and 30 minutes only, and §40 and §41 widened one side of the range at each end;
none of them moved the line, and none looked at the in-range band past 30 minutes, which has the
most points. The other splits were weaker or already tried: rising trends of 1–2 mg/dL a minute
with no meal in 3 hours run high (the trend replay fits them a gain of 0.13 against about 0.45
for falls), but a separate rise gain was within 1–2% of what ships by day, with days 11 and 14 Nov
wanting the full trend; and the afternoon 60-minute in-range bucket is a handful of unlogged
rises of 115–155 mg/dL that nothing can see coming.

**The test.** Each point's line (and its range with it) moved toward μ, the mean of every reading
in the 7 days before it was issued: f + α(h)·(μ − f). μ averaged 171 mg/dL. Leaving one day out
and picking α per horizon on the rest chose 0.1 (15 min), 0.2 (30), 0.4 (45) and 0.5 (60) on
every fold but one, so the versions below use α = 0.5·(h − 10)/50, capped at 0.5 from 60 minutes.
Scored on clean model-forecast points; interval score as in §40 (width + 10 × how far outside).

| Model forecasts, clean | 15 min (241) | 30 min (215) | 45 min (180) | 60 min (144) |
|---|---|---|---|---|
| What ships: miss / inside / score | 18.2 / 73.4% / 92.0 | 32.5 / 69.8% / 163.0 | 46.8 / 67.2% / 217.1 | 55.0 / 68.1% / 252.7 |
| Pull both ways | 17.6 / 75.5% / 87.0 | 30.5 / 73.0% / 136.9 | **41.5 / 71.7% / 173.2** | **48.4 / 73.6% / 192.3** |
| Pull down only (line above μ) | 17.9 / 74.3% / 90.5 | 32.1 / 72.1% / 152.9 | 44.6 / 68.9% / 203.5 | 55.2 / 70.1% / 233.2 |
| No lift under 90 | 17.8 / 74.3% / 88.9 | 32.0 / 72.6% / 147.7 | 44.1 / 71.1% / 192.2 | 53.6 / 70.1% / 222.9 |
| Lift tapered in from 90 to 140 | 17.9 / 74.3% / 89.7 | 32.1 / 72.1% / 150.8 | 44.6 / 70.0% / 199.6 | 54.6 / 69.4% / 229.8 |

On all clean points (apps and relay, every basis) the two-way pull is 17.8 → 17.2, 31.0 → 29.4,
46.8 → 41.5 and 55.0 → 48.4 mg/dL, with coverage up at every horizon and the miss lower in both halves
of the week (coverage in the first half dips at 30 minutes, 71.2% → 70.5%). The relay's trend-only points barely move (18.1 → 17.9 at 15 minutes) and trend-only
forecasts at 30 minutes get slightly worse (24.2 → 24.4, coverage 70.8% → 68.8%).

**Why it doesn't ship.** The two-way pull earns its gain by lifting forecasts that are heading
low: forecasts under 81 run low by 75–94 mg/dL from 30 minutes on (lows come back up, §17, §36,
§40), and pulling toward 171 corrects that. But of the four 45-minute points where glucose really
went under 70, all four had the range bottom under 70 and two had the line under 90 as shipped;
after the pull, neither line was under 90 and only one range bottom still reached under 70. The alerts could be
kept on the old line (they already read `Outlook.alertForecast`, and §41's `warningLowers` keeps
"a low is possible" where it was), but the chart would stop showing a fall that ends in a low, and
that's the forecast's most important job.

Every version that leaves falling forecasts alone gives most of it back. The safest one (no lift
under 90, tapering in to full at 140) keeps both of those lines under 90 and all four range bottoms
under 70, and does improve error and coverage overall, but by 1.6%, 1.2%, 4.7% and 0.7%, short of
the tuner's bar (§2: 3%, and better in both halves), and by day it's mixed: on 16 Nov the
60-minute miss goes from 77.4 to 87.4, and 12 Nov's 15 and 30-minute coverage drops (67% → 64%,
56% → 50%). What's left of it is mostly pulling highs down, which is §36's rejected shift by
another route, and it would move "Back in range ≈ X min" (§24) sooner too. §41's wider range
bottom on highs already covers the hour where they come down fastest.

**Low warnings.** Nothing shipped, so low warnings (§13, §30) and "a low is possible" are exactly
as before on the apps and the relay.

**Dosing.** Not touched: the pull would have been forecast-only, after the insulin and carb
effects, and no version here changed insulin on board, the effect learner or the bolus figure.

**Caveats.** Five days, 7-day means from at most six days of readings, and only four model points
that ended under 70 at 45 minutes, so the low check is thin in both directions. Rerun at three
weeks. If it's tried again, try it with the lift for falling forecasts kept off and see whether the
gain on highs and in-range forecasts alone reaches 3% on held-out days; don't ship the two-way
pull without a way to keep a forecast low drawn as low. To rerun the table:

```sql
with c0 as (select c.*, (select avg(mgdl) from glucos.readings r
    where r.at between c.issued_at - interval '7 days' and c.issued_at) mu,
  (select count(*) from glucos.readings r
    where r.at between c.issued_at - interval '7 days' and c.issued_at) nmu
  from glucos.forecast_checks c where c.basis = 'trendInsulinCarbs'),
p as (select c0.mu, (e->>'minutes')::int m, (e->>'actual')::float a, (e->>'mgdl')::float f,
    (e->>'lower')::float lo, (e->>'upper')::float up,
    coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from c0, jsonb_array_elements(c0.points) e where nmu > 1000),
q as (select *, least(0.5, greatest(0, 0.5 * (m - 10) / 50.0)) * (mu - f) dl from p
  where a is not null and shown <> 'false' and not al and m in (15, 30, 45, 60))
select m, count(*), avg(abs(a - f)) miss, avg(abs(a - f - dl)) pulled,
  avg((a between lo and up)::int) inside, avg((a between lo + dl and up + dl)::int) pulled_inside
from q group by 1 order by 1;
```

For the "no lift under 90, tapered to 140" version, multiply `dl` by
`case when mu > f then least(1, greatest(0, (f - 90) / 50)) else 1 end`.

## 45. Easing the trend when the last few minutes already disagree (16 Nov 2026)

The question: near a peak or a trough, the 15–30 minute forecast keeps going the old way, because
the trend is a straight line through the last 20 minutes and the turn hasn't reached it yet. If the
trend were eased whenever the last 5–10 minutes are weaker than it, or already going the other way,
would forecasts be closer and the range hold more of what happened, on days the test hadn't seen,
without making any low warning later? **Yes, but not by enough, and it costs high warnings. Easing
rises only (peaks) is better on every held-out day and leaves low warnings exactly as they are,
but it's 1.4–3.1% closer overall depending on the device's gain, short of the tuner's 3% at 30
minutes on every device, and it makes some predicted highs a few minutes later. Easing falls as
well helps troughs but makes one low warning later. Nothing shipped; no app or relay code
changed, so the relay stays 2.17.0.**

Not a repeat of §39: that carried on the curve of the last 15 minutes (the second derivative) and
was mostly noise. This compares two slopes, which is far steadier, and only ever weakens the trend.

**The test.** `scripts/turning-point-damping.py`, on every live reading from 11–16 Nov (7,374, one a
minute), the same replay as §39: the engine's trend (20-minute least-squares slope, 30-minute fade)
issued every 5 minutes and scored at 15 and 30 minutes, 1,457 points over six Perth days, 330 of
them at turning points (trend at least 0.5 mg/dL a minute and the other way 15 minutes later; 175
peaks, 155 troughs). It's run at the gains the tuner has fitted: about 0.45 (Mac and relay), 0.6
and 0.7 (iPhone). The candidate takes s, the slope of only the last S minutes (5, 8 or 10), and
ρ = s / trend. When ρ < 1 (weaker the same way, or already the other way) the trend is scaled by
1 − k·(1 − max(ρ, floor)); a trend that's speeding up is left alone. k (0.25–1), floor (0, or −0.5
to let it tip slightly the other way) and side (both, rises only, falls only, or falls only while
the un-eased line stays above 85 at 30 minutes) were picked on five days and scored on the sixth.
Coverage uses one band for every version: the 10th–90th percentile of what ships' misses on the
training days, laid around each line.

Every fold picked the shortest window, S = 5, at full strength (k = 0.75–1): when the last five
minutes are weaker than the trend, the forecast does best following the last five minutes.

| Held out, gain 0.6 (mg/dL; inside the band) | Points | No change, 15 / 30 | What ships | Eased, any side | Eased, rises only |
|---|---|---|---|---|---|
| All | 1,457 | 16.1 / 25.8 | 15.7 / 25.1; 79.3% / 79.5% | 15.2 / 24.8; 79.8% / 80.3% | **15.2 / 24.6; 79.8% / 80.3%** |
| Turning points | 330 | **17.4 / 25.8** | 25.6 / 33.9; 57.3% / 67.0% | 21.5 / 29.8; 66.1% / 72.4% | 22.3 / 30.2; 64.5% / 72.1% |
| Peaks | 175 | 18.5 / 26.5 | 26.9 / 35.4; 55.4% / 64.6% | 21.7 / 29.5 | 20.7 / 28.5; 69.1% / 74.3% |
| Troughs | 155 | 16.1 / 25.0 | 24.2 / 32.2; 59.4% / 69.7% | 21.4 / 30.2 | 24.2 / 32.2 (untouched) |
| Rising faster than 1 a minute | 281 | 21.6 / 32.7 | 20.8 / 33.1 | 19.1 / 31.0 | 18.9 / 30.7 |
| Within 3 h of a meal | 360 | 17.0 / 27.7 | 16.2 / 27.4 | 15.6 / 26.6 | 15.7 / 26.5 |

This is the biggest change at turning points any section has found: at a peak the 15-minute miss
drops by almost a quarter and the band holds 69% instead of 55%. It still doesn't get to "no
change" there (17.4), because the five minutes before a turn usually still go the old way.

**By device.** Rises only, floor 0 (the version that can't move a low warning, below), against
what ships, on all six days:

| Gain | 15 min | 30 min | Held-out days better (15 / 30) |
|---|---|---|---|
| 0.45 (Mac, relay) | 15.57 → 15.32 (−1.6%) | 25.05 → 24.69 (−1.4%) | 6 / 5 (13 Nov +0.1%) |
| 0.6 | 15.65 → 15.27 (−2.5%) | 25.14 → 24.62 (−2.1%) | 6 / 6 |
| 0.7 (iPhone) | 15.81 → 15.33 (−3.1%) | 25.31 → 24.64 (−2.7%) | 6 / 6 |

Letting a reversing rise tip slightly downward (floor −0.5, which every fold chose) adds 0.2–0.3
points, and easing falls too adds more at 15 minutes (−3.5% at gain 0.6) but almost nothing at 30
(−1.9%), and at gain 0.45 it's worse than what ships on three of the six days there. It's better in both halves of the week either way. None
of them reach the tuner's rule (§2: 3% better, at each horizon, in both halves) at 30 minutes on any
device, and the relay and Mac, at the lower gain, get the least.

**Low warnings.** As in §39, every reading in the 90 minutes before each of the eight lows under
70, a warning being the trend carried 30 minutes going under 70. Rises only with floor 0 can't
change a low warning: an eased rise still never goes below where it started. It's identical on all
eight lows, with the same warnings and false alarms at every gain. Floor −0.5 adds a false alarm at
gains 0.6 and 0.7 (7 → 8, 9 → 10). Easing falls too cuts false alarms (9 → 5 at gain 0.7) but warns
2 minutes later for the 16 Nov 00:52 low (7 → 5 minutes) at gain 0.7, which rules it out. The
guarded version (falls eased only while the line stays above 85) leaves lows alone but almost
never fires at a trough, because troughs are mostly low.

**High warnings.** Easing a rise lowers the line, so predicted highs can only come later or drop.
Of 20 highs over 180, rises only (floor 0) warns later for 2 at gains 0.45 and 0.6 (the worst
11 → 3 minutes, 15 Nov 15:50, at 0.45) and for 6 at gain 0.7 (the worst 14 → 7, 15 Nov 02:28), while
cutting false alarms by 2 at each gain (9 → 7, 9 → 7, 14 → 12). The alerts could stay on the
un-eased line, as §41 did with `warningLowers`, so this alone needn't stop it, but it's another
part to carry for a change under the bar.

**Why it doesn't ship.** Error and coverage both improve, every day, and low warnings don't move,
which is the first version of a turning-point fix that holds up on all three. But overall it's
1.4–2.7% at 30 minutes, under the 3% every forecast change has had to clear (§39, §42, §44), with
the least gain on the Mac and relay, and it would need its own path to keep predicted highs on
time. Six days and 175 peaks is enough to see the effect at peaks but not to trust that the
overall margin sits above 3%.

**Dosing.** Not touched: the trend feeds only the drawn forecast and predicted alerts, never insulin
on board, the effect learner or the bolus figure.

**Next time.** This is the nearest miss so far and the one to retest first at three weeks, rises
only, S = 5, k = 1, floor 0, with predicted highs kept on the un-eased line, ideally on the stored
model forecasts (`trendInsulinCarbs`) too, where the trend is only part of the line. Ship it if
it clears 3% at 15 and 30 minutes at the Mac's and relay's gain. Don't ease falls without the
low-warning check passing on every low. To rerun: `python3 scripts/turning-point-damping.py DIR`,
with readings.json and logs.json as for `scripts/acceleration-trend.py` (§39), exported from
`glucos.readings where trend > 0` and the meals in `glucos.logbook` (`payload->>'timestamp'`).

## 46. Correcting each horizon's average miss (16 Nov 2026)

The question: if forecasts at 15, 30 or 60 minutes run on average a little high or low, split by
the trend they started from, would subtracting that average (learnt as it goes, from forecasts
already scored) bring the line closer and the range around more readings, on days it wasn't
learnt from, without making a low warning later? **No. The average miss in each bucket is small
next to the typical miss and changes sign from one day to the next, so every version tried, rolling
or fixed, by horizon alone or by horizon and trend, is level or worse at every horizon. Nothing
shipped; no app or relay code changed, so the relay stays 2.17.0.**

Not a repeat of §36 or §44: those shifted forecasts by start level (highs down, or toward the
7-day mean). This splits by horizon and starting trend instead, and learns the shift walking
forward, as the app would have to. It's the learnt drift PR #53 rejected, retried on the stored
shown forecasts rather than a replay.

**The data.** 854 clean shown points (nothing logged after, drawn) in `glucos.forecast_checks`
with a reading at 15 (445), 30 (265) or 60 minutes (144), Mac, iPhone and relay, 12–17 Nov Perth.
Bias is actual minus forecast, so positive means the forecast ran low.

| Start trend (mg/dL a minute) | 15 min: bias / miss | 30 min | 60 min |
|---|---|---|---|
| Falling faster than 1 | +2.8 / 19.2 (124) | −1.3 / 33.3 (67) | +24.8 / 64.8 (32) |
| Falling 0.3–1 | +3.0 / 11.8 (71) | +4.4 / 22.6 (46) | +10.3 / 47.0 (24) |
| Steady | +0.8 / 17.5 (86) | +8.0 / 27.1 (51) | +17.0 / 36.6 (29) |
| Rising 0.3–1 | +3.4 / 18.6 (62) | +10.0 / 32.3 (39) | +9.4 / 64.3 (16) |
| Rising faster than 1 | −6.1 / 22.6 (102) | −4.6 / 36.9 (62) | +1.0 / 61.0 (43) |

The only sizeable averages are at 60 minutes, where there are fewest points and the miss is
three to six times the bias. By Perth day, falls, steady and rises at each horizon swing both
ways: at 30 minutes falling starts ran −10, +4, +8, +15 and −22 on 12–16 Nov, and at 60 minutes
rising starts −17, −30, −2, −22 and then +49. The day-to-day spread of a bucket's bias (13–36
mg/dL) is larger than its average (0–19), so last night's bias says little about this morning's.

**The test.** Each point's line and both sides of its range moved by d, the mean of actual −
forecast over points at the same horizon (and, where split, the same trend bucket) whose reading
had already come in before this one was issued, from the last 6, 24 or 72 hours or all history,
once there were 5 of them. Shrunk toward 0 as sum / (n + k) with k = 0, 10 or 30. Also leave one
Perth day out with a fixed mean or median per horizon, per horizon and trend, and per horizon,
trend and apps or relay.

Mean miss change against what ships (negative is better); coverage as shipped is 74.2% / 69.8% /
68.1%:

| Version | 15 min | 30 min | 60 min | Days better (15 / 30 / 60) |
|---|---|---|---|---|
| Rolling, by horizon, 6 h, k 30 | +2.1% | +3.0% | +4.0% | |
| Rolling, by horizon, all history, k 30 | +0.6% | +1.1% | +2.5% | |
| Rolling, by horizon and 3 trends, 24 h, k 30 | +0.7% | +1.5% | **−0.7%** | |
| Rolling, by horizon and 3 trends, all history, k 10 | +1.0% | +2.3% | +3.0% | |
| Rolling, by horizon and 5 trends, all history, k 30 | +0.8% | +1.9% | +2.7% | |
| Unshrunk (k 0), any window | +0.8 to +4.8% | +1.7 to +8.1% | +4.6 to +22% | |
| Held-out day, median by horizon | +0.1% | 0.0% | +1.0% | 4/6, 4/6, 3/5 |
| Held-out day, mean by horizon and 3 trends | +2.5% | +2.1% | +8.2% | 3/6, 2/6, 1/5 |
| Held-out day, median by horizon, 3 trends, apps/relay | +16.8% | +0.2% | +12.9% | 2/6, 2/6, 1/5 |

(36 rolling versions were run; the table gives the best of each kind and the range of the
unshrunk ones. Every one is worse at 15 and 30 minutes.)

- **The more it learns from, the less it does.** Shrinking harder and using longer windows only
  brings the correction closer to zero, and the result closer to what ships, never past it.
  Short windows chase the last few hours' meal or low, which is over by the next forecast.
- **Coverage at 15 and 30 minutes moves by under 2 points either way** (best 74.2 → 75.7% at 15 minutes, by horizon
  and 3 trends from all history, while the miss there is 0.6% worse). At 60 minutes every rolling
  version loses coverage (68.1 → 58–68%).
- **The one better cell** (60 minutes, 3 trends, 24 h, k 30: 55.0 → 54.6) is 0.7%, alone among 36,
  and the same settings are worse at 15 and 30. That's noise, not a bias.

**Low warnings.** Of the 25 points that ended under 70 (16 / 6 / 3), the range bottom reached
under 70 on 22 as shipped. At 15 and 30 minutes every version keeps all of those (one, by horizon
and 3 trends over 24 hours unshrunk, gains a 30-minute one); at 60 minutes the 6-hour and 24-hour
versions with little or no shrinking lose the one there. The line was under 80 on 20 as
shipped against 19 for the trend-split versions at 15 minutes. So the one extra low caught comes
from a version 7.4% worse at 30 minutes, and the trend-split ones put one line back over 80. Nothing shipped, so low warnings (§13, §30) and
"a low is possible" are exactly as before.

**Dosing.** Not touched: a shift would have been forecast-only, after the insulin and carb
effects, and nothing here changes insulin on board, the effect learner or the bolus figure.

**Caveats.** Six days, 144 points at 60 minutes. The shown points already carry the trend gain
the tuner fits, which scales the trend to what has carried on and so already takes some steady
lean out of the line (the range widening, §9, moves only the range, not the line). What's left
is the meal-by-meal and low-by-low part no average can follow.

`glucos.forecast_checks` has no time for when each actual reading reached the device, so the
rolling versions treat a point's reading as known from its target time. A live correction would
learn a little later than that, which can only make it staler; the query below takes a `lag` for
that check (5–10 minutes is about the sync delay). It also reads every user's rows; add a
`c.user_id` filter once there's more than one. Rerun at three
weeks with the query below; only take a correction if a shrunk, all-history version by horizon
is 3% better at 15 and 30 minutes and on most held-out days, with the low check unchanged.

```sql
with p0 as (select c.issued_at t, c.trend_per_minute tr, (e->>'minutes')::int m, (e->>'actual')::float a,
  (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float up,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e),
p as (select *, case when tr < -0.3 then 1 when tr <= 0.3 then 2 else 3 end tb, row_number() over () id
  from p0 where a is not null and not al and shown <> 'false' and m in (15, 30, 60)),
r as (select p.*, case when q.n >= 5 then q.s / (q.n + 30) else 0 end d from p cross join lateral (
  select count(*) n, sum(x.a - x.f) s from p x where x.m = p.m and x.tb = p.tb   -- drop "and x.tb = p.tb" for horizon only
    and x.t + make_interval(mins => x.m) + interval '0 min' <= p.t) q)           -- lag; add "and x.t > p.t - interval '24 h'" for a window
select m, count(*), avg(abs(a - f)) miss, avg(abs(a - f - d)) corrected,
  avg((a between lo and up)::int) inside, avg((a between lo + d and up + d)::int) corrected_inside,
  sum((a < 70 and lo < 70)::int) low_bottom, sum((a < 70 and lo + d < 70)::int) low_bottom_corrected
from r group by 1 order by 1;
```

## 47. Allowing for how late each reading arrives (16 Nov 2026)

The question: LibreLinkUp readings reach the apps and the relay a little after the time they carry.
Would starting the forecast from the reading's time plus that lag, rather than from when it was
fetched, bring the line closer and the range around more readings at 15, 30 and 60 minutes, on days
it wasn't tuned on, without making a low warning later? **No. Readings arrive about 30 seconds after
their time at the relay and under a minute and a half on the apps, and the forecast already starts
from the reading's own time. The one place that reads it from fetch time, the "In 30 min ≈ …"
headline, is level or slightly worse when moved on by the lag. Nothing shipped; no app or relay code
changed, so the relay stays 2.17.0.**

Not a repeat of §31: that was forecasts after a gap of minutes to hours (or the app waking). This is
the ordinary under-a-minute delay on every reading.

**How late readings arrive.** `glucos.readings` has no arrival time, so the relay's own state was
read once a minute (`work->'current'->'t'` against `work->'lastFetchAt'`, six fetches 20:35–20:41
UTC): every reading was first fetched 30–31 seconds after its time. The relay ticks at about :01 each
minute and the sensor's readings carry about :31, so LinkUp had each one within 30 seconds. A
reading LinkUp was later with would show as 90 seconds and would leave a missing minute in the stored
readings: of 7,678 steps between live readings, 94.7% are a minute, 348 are two minutes (one minute
missed, by LinkUp or by a skipped tick), 43 are three to six, and 13 are longer gaps (§31's ground).
The Mac and iPhone poll every 60 seconds (`pollIntervalSeconds`) from whenever they started, so their
reading is on average about 30 seconds plus LinkUp's delay old when fetched, at worst about 90.

**What already allows for it.** `GlucoseForecaster` sets `t0 = latest.timestamp`, and the relay's
`forecast` uses `latest.t`, so every point is drawn at the reading's time plus its minutes, and the
ledger scores it there (`issuedAt` + minutes). The chart, the range, the predicted-low lookahead and
every scored figure in this document are already "reading time plus the lag", whatever the lag was.
The headline (`OutlookFormat.headlineSample`) and the Outlook rows take
`OutlookSnapshot.sample(minutesAhead:)`, the point 15, 30 or 60 minutes after the reading, and the
person reads it at fetch time or later. That label is effectively a forecast started at fetch time,
really 30 − a minutes away for a reading a minutes old. The candidate picks the point at m + a
instead, so "in 30 min" means 30 minutes from when it's read.

**The test.** Scored against the reading m + a minutes after each start (interpolated to the
second), for a = 0.5 (relay), 1.0 (apps on average), 1.5 (apps, worst ordinary case), 3 and 5
(a late upload or a widget still showing an older reading).

- Replay: the engine's trend forecast every 5 minutes, away from logs (nothing logged from 3 h before
  to the target), 730 points, 11–17 Nov Perth, at the gains the tuner fits (0.45 / 0.6 / 0.7).
  Coverage from the 10th–90th percentile of the label's misses on the other six days.
- Stored: the shown, clean points in `glucos.forecast_checks` (Mac, iPhone and relay, trend and
  insulin-and-carbs forecasts), the candidate interpolated between the stored 15/30/45/60-minute
  points, range included.

Mean miss as shipped → reading-time-plus-lag (gain 0.6 for the replay):

| Age | 15 min replay | 30 min replay | 60 min replay | 15 min stored | 30 min stored | 60 min stored |
|---|---|---|---|---|---|---|
| 0.5 min | 14.88 → 14.91 (+0.2%) | 20.99 → 20.99 | 33.39 → 33.39 | 19.08 → 19.10 (+0.1%) | 31.27 → 31.27 | 55.64 → 55.64 |
| 1.0 min | 15.10 → 15.16 (+0.4%) | 21.21 → 21.21 | 33.57 → 33.57 | 19.13 → 19.16 (+0.1%) | 31.11 → 31.11 | 54.97 → 54.97 |
| 1.5 min | 15.21 → 15.30 (+0.6%) | 21.38 → 21.38 | 33.75 → 33.75 | 19.91 → 19.94 (+0.2%) | 31.61 → 31.62 | 55.72 → 55.72 |
| 3 min | 15.64 → 15.80 (+1.0%) | 22.01 → 22.01 | 34.40 → 34.40 | 21.71 → 21.75 (+0.2%) | 32.78 → 32.82 (+0.1%) | 54.96 → 54.96 |
| 5 min | 16.52 → 16.81 (+1.8%) | 23.09 → 23.09 | 35.15 → 35.15 | | | |

- **At 15 minutes it's worse at every age and gain** (gain 0.45: +0.1 to +0.9%; 0.7: +0.3 to
  +2.5%), better on at most 2 of 7 held-out days. Carrying the trend further adds the part of it
  that doesn't carry on; the fitted gain already sets how much does.
- **At 30 and 60 minutes it's the same line.** The trend fades out by 30 minutes (§1), so a minute
  or three more changes nothing; insulin and carbs move under a mg/dL a minute, so the stored
  insulin-and-carb forecasts move by under 0.1%. The stored forecasts stop at 60 minutes, so the
  60-minute label can't be moved on at all.
- **Coverage** moves by under a point in the replay. In the stored points it rises at 15 minutes
  (72.3 → 73.9% at 1 minute, 66.4 → 70.1% at 3) only because the range at 15 + a is interpolated
  toward the wider 30-minute one; the line is no closer.
- **What the lag itself costs** is small and nothing here wins it back: a reading read a minute late
  is 15.10 instead of 14.72 at 15 minutes (2.6%), 21.21 instead of 20.81 at 30 (1.9%).

**Low warnings.** Of the points that ended under 70, the line under 70 and the range bottom under
70 are the same as shipped for every age, horizon and gain in the replay (15 minutes: 6 of 8 lines,
8 of 8 bottoms at gain 0.6), and in the stored points (16 / 6 / 3 lows at 0.5 minutes, every bottom
and line unchanged). The predicted-low lookahead already counts from the reading's time (§13, §30),
so nothing about when a low warning fires depends on this.

**Dosing.** Not touched: this would only have changed which forecast point a label reads.

**Caveats.** Six relay fetches is a small sample of arrival, but the stored minute steps (94.7% a
minute apart) say the same over seven days; delays under 30 seconds can't be seen at the relay's
phase. The 5-minute row is a widget or Lock Screen card still showing an older reading, where the
label isn't redrawn at all; the reading's age is on screen there, and the forecast goes at 6 minutes
(`GlucoseSnapshot.staleAfter`). Sensor lag behind blood glucose (interstitial fluid, minutes) is a
different thing and can't be measured from sensor readings alone.

Rerun with `python3 scripts/reading-latency.py dir`: readings.json (live readings, as §45), logs.json
(the query in §31) and samples.json ([[reading_t, fetched_at], ...] from the relay row, read a few
times a minute apart). Only take a lag-aware label if it's 3% better at 30 minutes on most held-out
days with the low check unchanged, which needs a forecast that still bends after 30 minutes. For the
stored version:

```sql
with p0 as (select c.id, c.issued_at t, (e->>'minutes')::int m, (e->>'mgdl')::float f,
  (e->>'lower')::float lo, (e->>'upper')::float up,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e),
p as (select a.*, b.f fn, b.lo lon, b.up upn from p0 a left join p0 b on b.id = a.id and b.m = a.m + 15
  where not a.al and a.shown <> 'false' and a.m in (15, 30, 60)),
x as (select p.*, ag, case when fn is null then f else f + (fn - f) * ag / 15 end fc,
  case when fn is null then lo else lo + (lon - lo) * ag / 15 end loc,
  case when fn is null then up else up + (upn - up) * ag / 15 end upc,
  (select r.mgdl from glucos.readings r where r.trend > 0
     and r.at between p.t + make_interval(secs => (p.m + ag) * 60) - interval '40 s'
                  and p.t + make_interval(secs => (p.m + ag) * 60) + interval '40 s'
     order by abs(extract(epoch from r.at - (p.t + make_interval(secs => (p.m + ag) * 60)))) limit 1) a
  from p cross join unnest(array[0.5, 1.0, 1.5, 3.0]) ag)
select ag, m, count(*), avg(abs(a - f)) shipped, avg(abs(a - fc)) lag_aware,
  avg((a between lo and up)::int) inside, avg((a between loc and upc)::int) lag_aware_inside,
  sum((a < 70 and lo < 70)::int) low_bottom, sum((a < 70 and loc < 70)::int) low_bottom_lag_aware
from x where a is not null group by 1, 2 order by 1, 2;
```

## 48. Does "Your usual day" help during the day? (17 Nov 2026)

§16 tried the usual day (`DayPattern`, the Insights card) as a prior overnight. This is the daytime
version: forecasts issued 09:00–22:00 Perth, scored at 30, 45 and 60 minutes, with the usual day
built from the other days only. The bar: at least 3% better at 30 minutes on held-out days, coverage
not worse, and no low drawn later. **It didn't clear it. The usual day's shape never helped at any
weight, and pulling toward its level is §44's drift-to-average again, which a flat average does
better. Nothing ships.**

Nothing here touches dosing, the insulin or carb effects, the low alerts, the relay or `web/`.

**Data.** Readings 10 Nov 22:45 to 17 Nov 05:51 Perth (six full days). For each held-out day the
pattern was rebuilt from the other days with the card's own method: 5-minute bucket means,
half-hour medians, 1-2-1 smoothing round midnight, a slot needing 8 buckets; the value at any
minute is interpolated between slot centres. Live: clean shown points in `glucos.forecast_checks`
(not after a log, drawn), 12–16 Nov, 206 at 30 minutes, 144 at 45 and 114 at 60. Replay: the
trend forecast (gain 0.45, 30-minute fade, as §44) every 15 minutes on the readings, 11–16 Nov,
split into clean (no meal or dose from 3 hours before to the target) and after-log.

**Three ways in.** *Shape*: add w × the usual day's change from now to the target time (w 0.1,
0.2, 0.3, 0.5). *Level*: pull the line w of the way to the usual day's value at the target time
(w 0.05–0.3). *Flat*: the same pull toward one figure, the other days' mean, as a control for
plain damping. The range moves with the line. w was picked per horizon on the other days and
scored on the held-out one. Typical error, mg/dL:

| Held out | 30 min | 45 min | 60 min |
|---|---|---|---|
| Live clean: what ships | 31.5 | 47.4 | 55.5 |
| Live clean: shape | 31.5 (w = 0 every day) | 47.4 (w = 0) | 55.8 |
| Live clean: level | 32.0 | 45.9 | 55.0 |
| Replay clean: what ships / shape / level / flat | 22.6 / 22.6 / 23.0 / 22.7 | 30.9 / 30.9 / 31.5 / 31.2 | 35.9 / 35.9 / 36.4 / 35.8 |
| Replay after a log: what ships / level / flat | 31.6 / 30.6 / 29.2 | 42.1 / 39.8 / 38.4 | 52.0 / 48.2 / 45.8 |

**Shape.** The other days never wanted it: the held-out pick was 0 at 30 and 45 minutes on every
day, live and replay, and 0.1 at 60 minutes on three live days made those days worse. At a fixed
w = 0.2 the live 30-minute miss goes 31.5 → 31.9 and coverage 71.4% → 69.9%. Daytime glucose here
is meals and activity at different times each day; five other days give a median curve whose rises
land at the wrong time, and the trend already follows a rise once it starts.

**Level.** Worse at 30 minutes (31.5 → 32.0, coverage 71.4% → 70.4%), mixed by day at 45 (13 Nov
15.5 → 18.9) and within 1% at 60. On the clean replay it's worse at every horizon. Where it does
help (after a log, live 45 minutes) the flat mean helps more (live fixed w = 0.2: flat 43.7 against
level 45.8 at 45 minutes, 51.7 against 53.6 at 60), so the gain is damping toward a typical level,
not the time of day. That's §44's pull, which was rejected because it lifts forecasts heading for a
low: here too, of the six live 30-minute points that ended under 70, four had the line under 90 as
shipped and only two after a level pull at w = 0.2. The replay's after-log rows are the trend alone,
which the apps don't ship after a log (§12), so they're no case for it either.

**Low warnings.** Unchanged, since nothing shipped.

**What would settle it.** Three weeks of days, so the pattern has 14+ days behind it as the card
wants, and a pattern keyed to logged meals rather than the clock (that's the carb effect's job). If
it's rerun, try shape only (level is §44), hold out by day, and ship only at ≥3% at 30 minutes on
most held-out days with the six-low check unchanged. To rerun the live table:

```sql
with b as (select (at at time zone 'Australia/Perth')::date d,
    floor(extract(epoch from (at at time zone 'Australia/Perth')::time) / 300)::int b5, avg(mgdl) v
  from glucos.readings group by 1, 2),
days as (select distinct d from b),
raw as (select h.d hd, b.b5 / 6 s, percentile_cont(0.5) within group (order by b.v) med, count(*) n
  from days h join b on b.d <> h.d group by 1, 2),
pat as (select r.hd, r.s, 0.25 * p.med + 0.5 * r.med + 0.25 * x.med u from raw r
  join raw p on p.hd = r.hd and p.s = (r.s + 47) % 48 join raw x on x.hd = r.hd and x.s = (r.s + 1) % 48
  where r.n >= 8 and p.n >= 8 and x.n >= 8),
q0 as (select (c.issued_at at time zone 'Australia/Perth') li, (e->>'minutes')::int m,
    (e->>'actual')::float a, (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float up
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e
  where e->>'actual' is not null and coalesce(e->>'shown', 'true') <> 'false'
    and not coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false)
    and (e->>'minutes')::int in (30, 45, 60)
    and (c.issued_at at time zone 'Australia/Perth')::time between '09:00' and '21:59'),
q as (select q0.*, (select (1 - fr) * p0.u + fr * p1.u from
      (select (x - 15) / 30 - floor((x - 15) / 30) fr, (floor((x - 15) / 30)::int + 48) % 48 s0
       from (select extract(epoch from li::time) / 60.0 + k x) t) z
      join pat p0 on p0.hd = li::date and p0.s = z.s0 join pat p1 on p1.hd = li::date and p1.s = (z.s0 + 1) % 48) uk,
    k from q0 cross join lateral (values (0), (q0.m)) kk(k)),
w as (select li, m, a, f, lo, up, max(uk) filter (where k = 0) u0, max(uk) filter (where k = m) u1
  from q group by 1, 2, 3, 4, 5, 6)
select m, count(*), avg(abs(a - f)) shipped, avg(abs(a - f - 0.2 * (u1 - u0))) shape_02,
  avg(abs(a - f - 0.2 * (u1 - f))) level_02, avg((a between lo and up)::int) inside,
  sum((a < 70 and f < 90)::int) low_line_90, sum((a < 70 and f + 0.2 * (u1 - f) < 90)::int) low_line_90_level
from w group by 1 order by 1;
```

## 49. Do forecasts made 4–8 am miss the dawn rise? (17 Nov 2026)

§16 found a real dawn rise (glucose climbed between 05:00 and 07:00 on every night) and tried the
usual day's shape for it, which lost at 60 minutes. This asks a narrower question: do forecasts
issued 04:00–07:59 Perth run low, and if so, does a small fixed rise allowance for that window
(not the usual day's curve) fix it on held-out days? The bar: at least 3% better at 30 minutes,
range coverage not worse, and no low drawn later. **They do run a little low, but no more than
forecasts either side of the window, and the allowance doesn't hold up on days it wasn't fitted
on: 30 minutes gets slightly worse, 60 minutes is 1.9% better with one day much worse. Nothing
ships.**

Nothing here touches dosing, the insulin or carb effects, the low alerts, the relay or `web/`.

**Data.** The forecast log has almost nothing at dawn (the Mac sleeps and the iPhone is in the
background): 28 clean shown points at 15 minutes and 2 at 30, from three mornings. So this is a
replay on the server's readings (10 Nov 22:45 to 17 Nov 07:07 Perth): the engine's trend (20-minute
least-squares slope, clamped to ±4 mg/dL a minute, 30-minute fade) issued every 5 minutes, at gain
0.45 (Mac and relay) and 0.6 (iPhone), scored against the reading within 2 minutes of each target.
Clean only: no meal or rapid dose from 3 hours before the forecast to its target, which drops
11 Nov (breakfast at 06:12) and the end of 12 Nov (breakfast at 07:26). Six mornings, 12–17 Nov,
255 / 248 / 234 points at 15 / 30 / 60 minutes.

**The miss.** Bias is actual minus forecast, so positive means the forecast ran low. Gain 0.45:

| Issued (Perth) | 15 min | 30 min | 45 min | 60 min |
|---|---|---|---|---|
| 03:00–03:59 (63 points, 5 mornings) | +1.1 | −0.5 | +5.5 | +12.9 |
| **04:00–07:59** (234–255, 6) | +1.7 | +4.0 | +6.1 | +9.0 |
| 08:00–09:59 (76–83, 4) | +1.4 | +4.9 | +8.7 | +10.8 |

At 30 minutes the dawn window runs low on four of six mornings (+7 to +11 on 13–15 Nov, about 0
on 12 and 16 Nov, −4 on 17 Nov) and at 60 minutes on five. But the median miss is small (+2.7 at
30 minutes, +6.5 at 60); the mean is pulled up by a few large rises on 14 and 15 Nov, which
started at 190–330 mg/dL. And the hour before and the two hours after run just as low at 60
minutes, so this is §44's in-range drift showing up at dawn, not something tied to the clock.

**The test.** Add r mg/dL a minute for each minute of the forecast that falls before 08:00, weighted
like the model's part of the line (1 − the trend's fade weight, so it builds in as the trend fades,
the same way `MorningPatternLearner`'s wake-up rise is added). That's +15r at 30 minutes and +45r at
60 for a forecast issued well inside the window. r from 0 to 0.8 in steps of 0.05, picked on five
mornings and scored on the sixth, separately for 30 and 60 minutes. A guarded version (no allowance
when the line is under 100 or the trend is falling) was also tried. Typical error, mg/dL:

| Held out, gain 0.45 | 12 Nov | 13 | 14 | 15 | 16 | 17 | All |
|---|---|---|---|---|---|---|---|
| 30 min: what ships | 13.0 | 11.8 | 27.4 | 19.9 | 22.1 | 13.7 | 18.6 |
| 30 min: allowance (r picked) | 13.4 (0.3) | 11.0 (0.1) | 26.9 (0.15) | 19.5 (0.15) | 22.9 (0.3) | 15.0 (0.3) | 18.7 |
| 60 min: what ships | 19.2 | 20.3 | 47.1 | 25.2 | 20.4 | 15.2 | 26.0 |
| 60 min: allowance (r picked) | 17.0 | 17.0 | 45.2 | 24.8 | 20.6 | 22.1 | 25.5 |

At gain 0.6 it's the same story (30 minutes 19.4 → 19.5, 60 minutes 26.6 → 26.3). The guarded
version's held-out pick was r = 0 on five of six days (30 minutes 18.56 → 18.60). The picked r swings
from 0.1 to 0.3 depending on which morning is left out, and the mornings that want the most (12, 16
and 17 Nov) are the ones where it does harm, because the rise comes at a different time and size
each morning: on 17 Nov glucose fell from about 195 into the 130s through the window, and the allowance
makes the 60-minute miss 15.2 → 22.1.

Even fitted on all six mornings at once (r = 0.15), it's 18.57 → 18.42 at 30 minutes (0.8%) and
25.96 → 24.93 at 60 (4.0%), with coverage flat (79.8% → 79.4% at 30 minutes, the band being the
10th–90th percentile of what ships' misses).

**Low warnings.** Four points at 15 and 30 minutes ended under 70, all on 16 Nov (under 70 from about
04:50, down to 53). At r = 0.3, one of the two 30-minute lines that were under 90 is lifted above it, so the
chart would draw that low later. Nothing shipped, so low warnings (§13, §30) and "a low is
possible" are unchanged on the apps and the relay.

**Why the wake-up rise doesn't cover it either.** `MorningPatternLearner` (docs/Mornings.md) adds
a learnt rise after a logged wake-up. Five wake-ups are logged (05:30, 08:14, 07:15, 10:59 and
08:50), four of them after 07:00, while the rise usually starts around 05:00. So most of the dawn
rise happens before the wake-up it would be tied to; that's the behaviour to expect, not a bug,
since the rise is hormonal and starts in sleep.

**What would settle it.** Three weeks of mornings, and forecasts actually logged through the window
(the relay's ledger, once it has enough nights). If it's rerun, hold out by morning, require ≥3% at
30 minutes with most mornings better, and keep the allowance off lines under 100 so a low is never
drawn later. If the in-range drift is ever fixed generally (§44's pull with lows left alone), check
the dawn window again after it, since most of what's here is that drift. To rerun the held-out
table:

```sql
with r as (select at, mgdl, (at at time zone 'Australia/Perth') l from glucos.readings),
lg as (select to_timestamp((payload->>'timestamp')::float) t from glucos.logbook
  where not deleted and (kind = 'meal' or (kind = 'dose' and payload->>'kind' = 'rapid'))),
iss as (select r.at t, r.l, r.mgdl v0 from r
  where extract(minute from r.l)::int % 5 = 0 and r.l::time between '04:00' and '07:59'),
tr as (select i.*, s.sl, s.n, s.span from iss i cross join lateral (select regr_slope(mgdl, extract(epoch from at) / 60) sl,
    count(*) n, extract(epoch from max(at) - min(at)) / 60 span from r where r.at > i.t - interval '20 min' and r.at <= i.t) s),
pts as (select tr.*, h, (select mgdl from r where r.at between tr.t + (h - 2) * interval '1 min' and tr.t + (h + 2) * interval '1 min'
      order by abs(extract(epoch from r.at - tr.t) - h * 60) limit 1) a,
    exists(select 1 from lg where lg.t between tr.t - interval '3 hours' and tr.t + h * interval '1 min') logged,
    (select sum(1 - greatest(0, 1 - (m + 0.5) / 30)) from generate_series(0, h - 1) m
      where (tr.l + (m + 0.5) * interval '1 min')::time < '08:00') k
  from tr cross join (values (30), (60)) hh(h) where n >= 3 and span >= 9),
f as (select l::date d, h, a, coalesce(k, 0) k, v0 + 0.45 * greatest(-4, least(4, sl)) * 15 f
  from pts where a is not null and not logged),
grid as (select x / 20.0 rr from generate_series(0, 16) x),
sc as (select f.d hd, o.h, rr, avg(abs(o.a - o.f - rr * o.k)) e
  from (select distinct d from f) f cross join grid join f o on o.d <> f.d group by 1, 2, 3),
pick as (select distinct on (hd, h) hd, h, rr from sc order by hd, h, e, rr)
select f.h, f.d, count(*), p.rr, avg(abs(f.a - f.f)) shipped, avg(abs(f.a - f.f - p.rr * f.k)) allowance
from f join pick p on p.hd = f.d and p.h = f.h group by grouping sets ((1, 2, 4), (1)) order by 1, 2;
```

## 50. Should the trend be capped tighter than ±4 mg/dL a minute? (17 Nov 2026)

The trend forecast already clamps the 20-minute slope to ±4 mg/dL a minute
(`GlucoseForecaster.maxTrendPerMinute`, `slope` in the relay's core.ts). The question: would a
tighter cap, at 3 mg/dL a minute or below, lower the 30- and 60-minute error, on the idea that
very fast rates rarely carry on? The bar: at least 3% better at both 30 and 60 minutes on days
the cap wasn't picked on, and no low drawn later. **It doesn't come close. The best fixed cap
is 0.1% better on clean forecasts and slightly worse on all of them, a cap picked on other days
is 0.0–0.4% worse, and at the iPhone's gain a cap of 3 lifts three of seven low-ending forecast
points above the 90 line. Nothing ships.**

Nothing here touches dosing, the insulin or carb effects, the low alerts, the relay or `web/`.

**Data.** A replay on the server's readings (from 10 Nov 22:45 Perth, exported 17 Nov 08:12; the
first scoreable forecast is 11 Nov 10:40 and the last 07:40 on 17 Nov), the same way as §49: the engine's trend (20-minute least-squares slope, 30-minute fade) issued every 5 minutes,
held to one past the sensor range (39–401) like the engine, scored against the reading within 2
minutes of each target, at gain 0.45 (Mac and relay), 0.6 and
0.7 (iPhone). Clean = no meal or rapid dose from 3 hours before the forecast to its target. 1,038 /
969 clean points at 30 / 60 minutes (1,703 / 1,699 in all). Fast trends are rare: the slope is past
3 mg/dL a minute on 36 clean points at 30 minutes (21 rises, 15 falls), 81 in all, and past 4 on 9
clean.

**Typical error, mg/dL** (all points / just the points faster than 3 mg/dL a minute):

| Gain 0.45 | cap 1.5 | 2 | 2.5 | 3 | 3.5 | **4 (ships)** |
|---|---|---|---|---|---|---|
| 30 min, clean | 21.18 / 29.9 | 21.15 / 30.0 | 21.12 / 30.4 | 21.13 / 31.0 | 21.14 / 31.3 | 21.15 / 31.5 |
| 30 min, all | 24.53 / 37.5 | 24.49 / 36.7 | 24.46 / 36.3 | 24.45 / 36.1 | 24.44 / 35.8 | 24.43 / 35.6 |
| 60 min, clean | 32.73 / 35.5 | 32.75 / 35.5 | 32.76 / 36.0 | 32.79 / 36.8 | 32.82 / 37.7 | 32.83 / 38.0 |
| 60 min, all | 39.49 / 49.4 | 39.53 / 48.8 | 39.54 / 48.4 | 39.54 / 48.2 | 39.53 / 48.1 | 39.51 / 47.8 |

At gain 0.6 and 0.7 a cap helps the fast clean points more (0.7, 30 minutes: 36.5 → 30.2 at a
cap of 1.5), but across all points it's still 0.3–1% at best, because those points are 3% of the
total. On clean fast points even the best cap only matches "no change" (30.8 at 30 minutes), so
what helps is not trusting a fast trend at all, which the fade and the gain already do. After
meals and doses (the "all" rows) the fast rises are real and carry on, so capping makes 30
minutes worse.

**Held out by Perth day** (cap picked from 1.5–4 on the other six days, clean points):

| | 30 min | 60 min |
|---|---|---|
| Gain 0.45 | 21.15 → 21.23 (+0.4%) | 32.83 → 32.89 (+0.2%) |
| Gain 0.6 | 21.44 → 21.53 (+0.4%) | 33.10 → 33.11 (+0.0%) |

The picked cap swings between 1.5 and 3 depending on which day is left out, and it helps only
17 Nov (30 minutes 22.2 → 22.0 at 0.45).

**Low warnings.** 58 forecast points (30 and 60 minutes pooled, so one forecast can count twice)
started on a fall faster than 3 mg/dL a minute; 11 ended under 70. At gain 0.45 a cap of 3 leaves
the four points drawn under 90 as they are; at gain 0.6 it lifts three of the seven under 90 above
it. This is a threshold count, not a measured warning delay (that needs the per-low timing check of
§13 and §30), but a fall capped tighter can only draw a line higher, never lower, so it points the
wrong way for lows. That alone rules out capping falls.

**What would settle it.** The fast points are too few to fit a cap on (36 clean in six days). If it's
rerun at 3+ weeks, try rises only (falls stay at ±4 so lows are never drawn later), on the clean
points, and require ≥3% at both horizons held out. §45's rise easing (turning points) is the closer
lever for the same overshoot. To rerun, export the points and run
`python3 scripts/extreme-trend-cap.py pts.json`:

```sql
with r as (select at, mgdl, (at at time zone 'Australia/Perth') l from glucos.readings),
lg as (select to_timestamp((payload->>'timestamp')::float) t from glucos.logbook
  where not deleted and (kind = 'meal' or (kind = 'dose' and payload->>'kind' = 'rapid'))),
iss as (select r.at t, r.l, r.mgdl v0 from r where extract(minute from r.l)::int % 5 = 0
  and r.l < '2026-11-17 08:00'),  -- the §50 cohort; drop or move both bounds to rerun on newer data
tr as (select i.*, s.sl, s.n, s.span from iss i cross join lateral (select regr_slope(mgdl, extract(epoch from at) / 60) sl,
    count(*) n, extract(epoch from max(at) - min(at)) / 60 span from r where r.at > i.t - interval '20 min' and r.at <= i.t) s),
pts as (select tr.*, h, (select mgdl from r where r.at between tr.t + (h - 2) * interval '1 min' and tr.t + (h + 2) * interval '1 min'
        and r.l <= '2026-11-17 08:12'  -- targets as of the §50 export
      order by abs(extract(epoch from r.at - tr.t) - h * 60) limit 1) a,
    exists(select 1 from lg where lg.t between tr.t - interval '3 hours' and tr.t + h * interval '1 min') logged
  from tr cross join (values (30), (60)) hh(h) where n >= 3 and span >= 9)
select json_agg(json_build_object('day', to_char(l, 'MMDD'), 'h', h, 'lg', logged, 'v0', v0, 'sl', sl, 'a', a) order by t, h)
from pts where a is not null;
```

## 51. Do forecasts miss differently on weekends? (17 Nov 2026)

The question: weekends often mean different meals, sleep and activity. Do forecasts run high or
low differently on Saturdays and Sundays than on weekdays, and would a separate average-miss
correction for each, at 30 and 60 minutes, bring the line closer on days it wasn't learnt from?
**The weekend did run lower than weekdays, but a correction learnt from it is worse at 15 and 30
minutes, better on only 1 of 6 held-out days at 30 minutes, and loses coverage at 60. Nothing
shipped; no app or relay code changed, so the relay stays 2.17.0.**

Not a repeat of §46: that learnt one shift per horizon (and per trend) from all days together.
This splits the learning by weekday against weekend (Saturday and Sunday in Perth), the split
the Insights "Weekdays and weekends" card (PR #223) uses for time in range.

**The data.** 881 clean shown points (nothing logged after, drawn) in `glucos.forecast_checks` with
a reading at 15 (472), 30 (265) or 60 minutes (144), Mac, iPhone and relay, 12–17 Nov Perth. That is
four weekdays (12, 13, 16 and the start of 17 Nov) and **one weekend, two days** (14 and 15 Nov).
Bias is actual minus forecast, so positive means the forecast ran low.

| | 15 min: bias / miss | 30 min | 60 min | Inside the range (all) |
|---|---|---|---|---|
| Weekdays (555 points) | −0.6 / 17.1 | −1.5 / 29.8 | +7.6 / 47.8 | 75.9% |
| Weekend (326 points) | +2.3 / 20.5 | +7.7 / 32.5 | +21.3 / 70.3 | 66.6% |

| Perth day | 30 min bias / miss | 60 min bias / miss |
|---|---|---|
| Thu 12 | −5.6 / 25.6 | −21.2 / 42.4 |
| Fri 13 | −1.1 / 16.2 | −0.2 / 24.5 |
| Sat 14 | +5.4 / 20.7 | +25.5 / 34.4 (8 points) |
| Sun 15 | +9.6 / 42.3 | +20.4 / 77.8 |
| Mon 16 | +0.1 / 41.3 | +39.0 / 77.4 |

Both weekend days ran low at every horizon, which looks like a pattern. But it is one weekend,
the weekday biases swing from −21 to +39 at 60 minutes, and Monday ran lower at 60 minutes than
either weekend day. The weekend's bigger miss is almost all Sunday (39 mg/dL across horizons
against Saturday's 18); Saturday was a better day than Thursday or Monday. So the gap between
the two sides is smaller than the gap between days on either side.

**The test.** Each point's line and both sides of its range moved by d, the mean actual − forecast
at the same horizon over points on the same side (weekday or weekend), shrunk toward 0 as
sum / (n + k) with k = 0, 10 or 30, once there were 5. Two ways: leave the point's Perth day out
(so a weekend day learns from the other weekend day only), and walking forward from points whose
reading had already come in. Each against the same two without the split (one pool), and a
median instead of a mean for the held-out version.

Mean miss change against what ships (negative is better); coverage as shipped is 75.2% / 69.8% /
68.1%:

| Version | 15 min | 30 min | 60 min | Held-out days better (15 / 30 / 60) |
|---|---|---|---|---|
| Held-out day, split, mean, k 0 | +0.8% | +1.2% | +0.7% | 4/6, 1/6, 2/5 |
| Held-out day, split, mean, k 30 | +0.5% | +0.6% | +0.6% | 4/6, 1/6, 3/5 |
| Held-out day, split, median | +1.5% | +0.3% | **−2.5%** | |
| Held-out day, one pool, mean, k 0–30 | +0.2% | +0.2% | +0.3 to +1.2% | |
| Walking forward, split, k 0 / 10 / 30 | +1.3 / +1.0 / +0.8% | +3.4 / +2.5 / +1.8% | +6.0 / +3.8 / +2.5% | 0–1/6, 0–1/6, 0–2/5 |
| Walking forward, one pool, k 0 / 10 / 30 | +0.8 / +0.7 / +0.6% | +1.7 / +1.4 / +1.1% | +4.9 / +3.6 / +2.5% | |

- **Splitting makes it worse than not splitting**, at 15 and 30 minutes in every version, because
  each side learns from half the points and a weekend learns from one other day.
- **The weekend points themselves got worse at 15 and 30 minutes** (held out, mean, k 0: +2.1% and
  +1.8%) even though both weekend days ran low. A mean shift of +5 to +10 helps the rises it's
  pulled up by and hurts the many small misses either side; the miss is mostly spread, not lean.
- **The one better cell, 60 minutes** (median −2.5%, weekend-only mean −8.1%), is the same 60-minute
  lean §46 found, carried by Sunday's and Monday's big misses (46 weekend points), and weekdays got
  worse there (+3.6 to +6.8%). It fails the 30-minute half of the bar.
- **Coverage**: held-out split moves 30 minutes 69.8 → 70.9–72.1% and leaves 15 minutes within half
  a point, but at 60 minutes drops 68.1 → 61.1–63.9%. Walking forward it's within a point at 15
  and 30 and 4.9–8.4 points worse at 60.

**Low warnings.** Of the 25 points that ended under 70 (16 / 6 / 3), the range bottom reached under
70 on 22 as shipped. The held-out split versions keep all 22. Walking forward unshrunk loses the
one at 60 minutes. Nothing shipped, so low warnings (§13, §30) and "a low is possible" are exactly
as before.

**Dosing.** Not touched: a shift would have been forecast-only, after the insulin and carb
effects, and nothing here changes insulin on board, the effect learner or the bolus figure.

**Caveats.** One weekend. Weekend here is Perth Saturday and Sunday; a public holiday counts as
a weekday. As in §46, walking forward treats a reading as known from its target time, which can
only flatter it. Rerun after at least three weekends (about 7 Dec); take a weekend correction only
if a shrunk held-out version is 3% better at both 30 and 60 minutes, better on most weekend days
held out, and the low check unchanged.

```sql
with p0 as (select c.issued_at t, (e->>'minutes')::int m, (e->>'actual')::float a,
  (e->>'mgdl')::float f, (e->>'lower')::float lo, (e->>'upper')::float up,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e),
p as (select *, (t at time zone 'Australia/Perth')::date dy,
  extract(isodow from t at time zone 'Australia/Perth') in (6, 7) we
  from p0 where a is not null and not al and shown <> 'false' and m in (15, 30, 60)),
k(k) as (values (0), (10), (30)),
r as (select p.*, k.k,
  coalesce((select sum(x.a - x.f) / (count(*) + k.k) from p x where x.m = p.m and x.we = p.we
    and x.dy <> p.dy having count(*) >= 5), 0) d_held_out,                 -- drop "x.we = p.we" for one pool
  coalesce((select sum(x.a - x.f) / (count(*) + k.k) from p x where x.m = p.m and x.we = p.we
    and x.t + make_interval(mins => x.m) <= p.t having count(*) >= 5), 0) d_forward
  from p cross join k)
select k, m, we, count(*) n, avg(abs(a - f)) miss,
  100 * avg(abs(a - f - d_held_out)) / avg(abs(a - f)) - 100 held_out_pct,
  100 * avg(abs(a - f - d_forward)) / avg(abs(a - f)) - 100 forward_pct,
  avg((a between lo and up)::int) inside, avg((a between lo + d_held_out and up + d_held_out)::int) held_out_inside,
  sum((a < 70 and lo < 70)::int) low_bottom, sum((a < 70 and lo + d_held_out < 70)::int) low_bottom_held_out
from r group by rollup ((k, m), (we)) order by 1, 2, 3;
```

## 52. Does every drawn horizon beat "no change"? (17 Nov 2026)

The question: score every drawn forecast against simply assuming the reading stays where it is
("no change", persistence), horizon by horizon, and where a horizon doesn't beat it, would drawing
the line only as far as the last horizon that does bring the picture closer? **Overall the drawn
forecasts beat no change by 4–9% at 15 to 45 minutes, tie at 60, and lose at 90 minutes and beyond
(only 31 checks, all Mac). Cutting the line sooner than §8 already does helps by under 1% overall,
is worse at 30 minutes, and is better on only some days. Nothing shipped; no app or relay code
changed, so the relay stays 2.17.0.**

Not a repeat of §8: that section built the live cut (cut a horizon once it is 5% worse than no
change over 30 checks, bring it back once it is 5% better). This section measures how the drawn
line now stands against no change and tests stricter versions of that cut.

**The data.** 1,098 clean drawn points (nothing logged after) with a reading, in
`glucos.forecast_checks`, Mac, iPhone and relay, 12–17 Nov Perth. No change is the reading the
forecast started from (`start_mgdl`). Miss is the mean absolute error in mg/dL; a negative
difference means the forecast was closer.

| Horizon | Checks | Forecast | No change | Difference | Forecast closer on |
|---|---|---|---|---|---|
| 15 min | 477 | 18.3 | 19.1 | −4.2% | 52% |
| 30 min | 266 | 31.0 | 34.2 | −9.4% | 59% |
| 45 min | 180 | 46.8 | 48.9 | −4.3% | 57% |
| 60 min | 144 | 55.0 | 54.5 | +0.9% | 49% |
| 90 min | 15 | 75.4 | 66.3 | +13.8% | 40% |
| 120 / 150 min | 8 / 8 | 77.2 / 69.3 | 67.6 / 59.7 | +14.2 / +16.1% | 25% |

By device and kind, since the §8 cut reached the devices (15 Nov, 8 pm Perth):

| | 15 min | 30 min | 45 min | 60 min |
|---|---|---|---|---|
| Mac, insulin and carbs | −12.7% (70) | −9.0% (67) | −5.4% (61) | +0.3% (39) |
| iPhone, insulin and carbs | −7.1% (16) | −6.7% (15) | not drawn | not drawn |
| iPhone, trend only | +25.5% (27) | | | |
| Relay, trend only | +0.2% (137) | | | |

- **The §8 cut is working.** Before it, the iPhone's insulin-and-carb forecasts were 9% and 20%
  worse than no change at 45 and 60 minutes; since it, they stop at 30 minutes and beat no change
  at 15 and 30.
- **What still doesn't beat no change**: the Mac at 60 minutes (a tie), the relay's 15-minute Lock
  Screen forecast (a tie over 137 checks), the iPhone's trend-only forecast at 15 minutes (27 checks
  since 15 Nov, most of them on the morning of 17 Nov), and 90 minutes and beyond (31 checks
  from the first two days, before the cut).

**The test.** I walked forward through every drawn forecast and recomputed the cut from what that
device had already scored, for that kind of forecast, over the 7 days before. A horizon (and every
one after it) was cut when it had at least N checks and its miss was at least T times no change's.
A cut point counts as no change's miss, because with no line the reading itself is the only guide.
The baseline is the §8 rule (T 1.05, N 30) run the same way, since the stored points from before
15 Nov were never cut.

| Rule | Points cut | 15 min | 30 min | 45 min | 60 min | All | Days better at 15 / 30 / 60 |
|---|---|---|---|---|---|---|---|
| §8: 5% worse, 30 checks (baseline) | 50 | 18.21 | 30.69 | 45.93 | 53.76 | 31.96 | |
| Not better, 30 checks | 84 | +0.1% | +1.2% | 0.0% | 0.0% | +0.3% | |
| Not better, 15 checks | 139 | +0.1% | +0.8% | −0.9% | −1.5% | −0.4% | 2/6, 2/6, 3/5 |
| Not 5% better, 30 checks | 191 | −1.2% | +1.3% | +0.4% | +0.1% | 0.0% | |
| Not 5% better, 15 checks | 248 | −1.1% | +1.4% | −0.4% | −1.4% | −0.6% | 2/6, 2/6, 3/5 |

- **Cutting harder is worse at 30 minutes in every version** (+0.8 to +1.4%). That is the horizon
  where the forecast beats no change most clearly, and a cut that follows a bad stretch at 15
  minutes takes it away too.
- **The 15-minute gain is one morning.** The strictest rule is 15.6% better on 17 Nov (the iPhone
  trend-only run above) and 3.0% worse on 15 Nov; the other days are within a point.
- **The 60-minute gain is about a point and a half**, carried by 8 points on 14 Nov; 16 Nov gets
  worse.
- **Points the stricter rules cut** at 15 and 30 minutes were on average between 0.6 mg/dL closer
  and 2.0 mg/dL further off than no change, so hiding them hardly changes what you'd see.

**Low warnings.** Of the drawn points that ended under 70 with a range bottom under 70, every rule
here, the baseline included, cuts the same one. Nothing shipped, so low warnings (§13, §30) and
"a low is possible" are exactly as before.

**Dosing.** Not touched: the cut only decides how far the line is drawn. Nothing here changes
insulin on board, the effect learner or the bolus figure.

**Caveats.** Five and a bit days, 31 checks past 60 minutes, and a walk-forward that treats a
reading as known from its target time, which can only flatter the stricter rules. The ties that
remain (relay 15 minutes, Mac 60 minutes) are already the cut's "about the same" band, which §8
leaves drawn on purpose so a near-tie doesn't make the line flicker. Rerun after two more weeks; take
a stricter cut only if it is at least 3% better at 15 and 30 minutes, better on most days, and keeps
the low check unchanged.

```sql
with p as (select c.id, c.device d, c.basis b, c.issued_at t, c.start_mgdl s, (e->>'minutes')::int m,
  (e->>'actual')::float a, (e->>'mgdl')::float f, (e->>'lower')::float lo,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e),
cl as (select * from p where a is not null and not al),
hs as (select distinct m h from cl),
st as (select c.id, h.h,
  (select count(*) from cl x where x.d = c.d and x.b = c.b and x.m = h.h
    and x.t + make_interval(mins => h.h) <= c.t and x.t >= c.t - interval '7 days') n,
  (select avg(abs(x.a - x.f)) / nullif(avg(abs(x.a - x.s)), 0) from cl x where x.d = c.d and x.b = c.b and x.m = h.h
    and x.t + make_interval(mins => h.h) <= c.t and x.t >= c.t - interval '7 days') r
  from (select distinct id, d, b, t from cl) c cross join hs h),
th(th, nmin) as (values (1.05, 30), (1.00, 30), (0.95, 30), (1.00, 15), (0.95, 15)),
ev as (select th.th, th.nmin, x.*, exists (select 1 from st where st.id = x.id and st.h <= x.m
  and st.n >= th.nmin and st.r >= th.th) cut from cl x cross join th where x.shown <> 'false')
select th, nmin, m, count(*) n, sum(cut::int) cut_n, avg(abs(a - f)) drawn,
  avg(case when cut then abs(a - s) else abs(a - f) end) rule, avg(abs(a - s)) no_change,
  sum((a < 70 and lo < 70 and cut)::int) lows_lost
from ev group by rollup ((th, nmin), m) order by 1 desc, 2 desc, 3;
```

## 53. Does the drawn range hold its 8 in 10 at each horizon? (17 Nov 2026)

The question: the range is labelled "about 8 in 10 past forecasts landed inside". Does it, horizon
by horizon, and if not, would one fixed factor per horizon (not the recent-error scaling that lost
in §42) bring it closer without making the forecast worse at 30 and 60 minutes? **The range is
short at every horizon: 76 / 71 / 72 / 77% inside at 15 / 30 / 45 / 60 minutes. One fixed factor
per horizon (1.09 / 1.23 / 1.31 / 1.18) brings it to 80–82% held out, but only by drawing it
13–24% wider, and the interval score is no better at any horizon and worse on most held-out days.
Nothing shipped; no app or relay code changed, so the relay stays 2.17.0.**

**The data.** 1,100 clean drawn points (nothing logged after) with a reading, in
`glucos.forecast_checks`, Mac, iPhone and relay, 12–17 Nov Perth, with §40/§41 applied to points
drawn before those versions so the baseline is what is drawn today (the same export and cleaning
as `scripts/adaptive-range.py`). A factor only scales the drawn half-widths; it can't move the
central line, so the 30- and 60-minute miss (31.0 and 55.0 mg/dL) is unchanged by construction.
The test is therefore the interval score at 80%: width + 10 × how far outside the reading
landed, lower is better, which rewards a range for holding 8 in 10 only if the extra width is
worth the misses it saves.

| Horizon | Points | Inside | Above | Below | Fitted factor (apps / relay) |
|---|---|---|---|---|---|
| 15 min | 479 | 76% | 14% | 9% | 1.09 (1.16 / 1.00) |
| 30 min | 266 | 71% | 14% | 14% | 1.23 (apps only) |
| 45 min | 180 | 72% | 18% | 10% | 1.31 |
| 60 min | 144 | 77% | 15% | 8% | 1.18 |

The relay (15-minute Lock Screen range) already holds 80%; the shortfall is the apps'.

**Held out.** The factor is the 80th percentile of the points' miss ratios (miss ÷ drawn
half-width on that side), apps and relay apart, fitted on every other day (leave one day out) or
on the days before only (walk forward, 30 points minimum).

| Horizon | Drawn: inside / width / score | Leave one day out | Walk forward | Days better (LODO) |
|---|---|---|---|---|
| 15 min | 76% / 52.6 / 88.0 | 80% / 59.4 / 90.3 | 82% / 64.6 / 92.8 | 3 of 6 |
| 30 min | 71% / 82.0 / 149.0 | 80% / 100.0 / 148.6 | 79% / 103.4 / 150.8 | 2 of 5 |
| 45 min | 72% / 127.7 / 210.2 | 80% / 158.8 / 211.1 | 76% / 151.9 / 211.0 | 2 of 5 |
| 60 min | 77% / 154.9 / 229.7 | 82% / 170.3 / 231.1 | 78% / 158.7 / 229.3 | 3 of 4 |

Lows that landed under 70 with the range bottom already under 70: unchanged (15 / 5 / 4 / 2).

**Why a fixed factor doesn't pay.** The shortfall isn't a steady one. Daily coverage at 30
minutes runs 58–81% (15 minutes 68–86%), so one factor widens the good days for nothing while
still missing on the bad ones. The miss ratios are heavy-tailed: the median is 0.58–0.65 of the
drawn half-width (about where a well-sized 80% range puts it), but the 90th and 95th percentiles
are 1.6–1.9 and 1.9–2.4. The misses are mostly large, not near ones, so widening everything turns
few of them into hits. That points at which forecasts get a wide range (meals, fast changes,
sensor trouble) rather than at the overall size, which is what §40/§41 did for low and high
starts.

**Decision.** Keep the drawn range as it is. The "8 in 10" wording stays: the relay holds it,
and the apps sit 3–9 points short, inside the day-to-day spread. Retest at three weeks: ship a
fixed per-horizon factor only if it wins the interval score held out on most days at 30 and
60 minutes. To rerun: export with the SQL in `scripts/adaptive-range.py`, then
`python3 -I scripts/range-calibration.py points.txt`.

## 54. Should forecasts lean toward "no change" when nothing has been logged for hours? (17 Nov 2026)

The question: split forecast error by how long it has been since the last logged meal or rapid
dose, and in the idle stretches (4 hours or more with nothing active), would pulling the drawn line
part of the way back toward "no change" lower the 30- and 60-minute miss? §52 found the forecast
beats no change by 4–9% at 15–45 minutes overall. **Idle forecasts still beat no change by 7% at
30 minutes, and no pull toward no change helps there held out (0.0 to +0.2% at a 2 or 4 hour
cut, +12.6% at 6 hours). At 60 minutes there are only 16 idle points from 2 days, too few to act
on. Nothing shipped; no app or relay code changed, so the relay stays 2.17.0.**

**The data.** 1,072 clean drawn points (nothing logged after, a reading at the target) at 15, 30,
45 and 60 minutes in `glucos.forecast_checks`, Mac, iPhone and relay, 12–17 Nov Perth, with extras
included as in §52. "Time since" is from the issue time back to the latest non-deleted meal or
rapid dose in `glucos.logbook` (long-acting doses don't count). Points with no earlier entry count
as idle. A negative difference means the forecast was closer than no change.

| Horizon | Under 4 h: checks / forecast / no change / diff | 4 h or more: checks / forecast / no change / diff |
|---|---|---|
| 15 min | 279 / 17.8 / 19.8 / −9.8% | 203 / 18.8 / 18.2 / +3.5% |
| 30 min | 191 / 30.8 / 34.3 / −10.2% | 75 / 31.6 / 34.1 / −7.3% |
| 45 min | 150 / 44.9 / 47.4 / −5.3% | 30 / 56.6 / 56.7 / −0.2% |
| 60 min | 128 / 56.5 / 56.6 / −0.1% | 16 / 42.4 / 37.6 / +13.0% |

- **The idle edge is smaller but real at 30 minutes.** Idle forecasts are 7% closer than no change
  there; the trend still carries information when nothing is active.
- **At 15 minutes idle forecasts lose to no change** (+3.5%), mostly the iPhone's trend-only
  forecast (+11.7%, 59 checks, around late morning) and the relay (+3.4%, 97 checks). The Mac's
  insulin-and-carb forecast still wins idle (−8.6%). This matches the §52 near-ties (relay 15,
  iPhone trend-only 15 on the morning of 17 Nov).
- **60 minutes barely exists idle**: the §8 cut stops trend-only lines at 30 minutes, so the 16
  idle 60-minute points are insulin-and-carb forecasts from 2 days (13 and 15 Nov).

**The test.** For idle points (cut at 2, 4 or 6 hours), the line becomes
`start + w × (forecast − start)`, w from 1 (as drawn) to 0 (no change). w was chosen per horizon
on every other Perth day and applied to the held-out day (leave one day out), so the result isn't
fitted to the day it's scored on.

| Idle cut | Horizon | Points | Drawn | Held out | Diff | No change | Best w in sample |
|---|---|---|---|---|---|---|---|
| 2 h | 15 min | 340 | 18.7 | 18.9 | +1.6% | 19.6 | 0.75–0.9 |
| 2 h | 30 min | 172 | 34.3 | 34.3 | 0.0% | 37.6 | 1.0 |
| 2 h | 60 min | 87 | 66.4 | 67.3 | +1.4% | 64.3 | 0 |
| 4 h | 15 min | 203 | 18.8 | 19.0 | +1.1% | 18.2 | 0.25 |
| 4 h | 30 min | 75 | 31.6 | 31.7 | +0.2% | 34.1 | 0.9–1.0 |
| 4 h | 60 min | 16 | 42.4 | 37.6 | −11.5% | 37.6 | 0 (2 days) |
| 6 h | 15 min | 128 | 16.7 | 15.7 | −6.1% | 14.8 | 0 |
| 6 h | 30 min | 34 | 23.4 | 26.4 | +12.6% | 25.9 | 0.75 |

- **30 minutes picks w = 1 (no pull) on every held-out day at 2 hours, and 0.9–1.0 at 4.** The
  forecast is already as far from no change as it should be there.
- **The 60-minute win at 4 hours is 16 points on 2 days** and doesn't hold at 2 hours (+1.4%,
  87 points). With 2 days, each is fitted on the other alone, so it isn't a held-out result worth
  trusting.
- **The only steady signal is 15 minutes after 6 idle hours** (−6.1% held out, w = 0 on 4 of 5
  days), but the brief was 30 and 60, and 30 minutes gets worse by 12.6% under the same cut. It's
  the same short-horizon trend-only weakness §52 and §31 saw, not an idle effect on its own.

**Low warnings.** A pull toward no change would move the central line and so the predicted-low
check (§13, §30). Nothing shipped, so low warnings and "a low is possible" are exactly as before.

**Dosing.** Not touched: nothing here changes insulin on board, the effect learner or the bolus
figure.

**Caveats.** Five and a bit days, only 17 meals and 29 doses logged since 7 Nov, so "idle" is most
of every night and late morning, and is partly a time-of-day split. Rerun after three weeks with
more logged entries; ship an idle pull only if it is at least 3% better held out at 30 AND 60
minutes on most days, with the low check unchanged. If the 15-minute idle loss persists, the
candidate is a trend-only 15-minute fix (for example a §8-style cut that can reach 15 minutes for
the relay and the iPhone's trend-only forecast), not an idle rule.

```sql
with lg as (select to_timestamp((payload->>'timestamp')::float) ts, kind, payload->>'kind' k
  from glucos.logbook where not deleted and kind in ('meal','dose') and payload->>'timestamp' is not null),
p as (select c.id, c.device d, c.basis b, c.issued_at t, c.start_mgdl s, (e->>'minutes')::int m,
  (e->>'actual')::float a, (e->>'mgdl')::float f,
  coalesce((e->>'afterLog')::bool, (e->>'after_log')::bool, false) al, coalesce(e->>'shown', 'true') shown
  from glucos.forecast_checks c, jsonb_array_elements(c.points) e),
cl as (select p.*, date(t at time zone 'Australia/Perth') dy,
  (select extract(epoch from p.t - max(ts)) / 3600 from lg
    where ts <= p.t and (kind = 'meal' or coalesce(k, 'rapid') = 'rapid')) since
  from p where a is not null and not al and shown <> 'false' and m in (15, 30, 45, 60)),
th(h) as (values (2), (4), (6)),
w(w) as (values (1.0), (0.9), (0.75), (0.5), (0.25), (0.0)),
idle as (select th.h thr, cl.* from cl cross join th where cl.since is null or cl.since >= th.h),
dayw as (select thr, m, dy, w.w, sum(abs(a - (s + w.w * (f - s)))) se, count(*) n
  from idle cross join w group by 1, 2, 3, 4),
oth as (select d1.thr, d1.m, d1.dy, d2.w, sum(d2.se) / sum(d2.n) e
  from (select distinct thr, m, dy from dayw) d1
  join dayw d2 on d2.thr = d1.thr and d2.m = d1.m and d2.dy <> d1.dy group by 1, 2, 3, 4),
pick as (select distinct on (thr, m, dy) thr, m, dy, w from oth order by thr, m, dy, e, w desc)
select i.thr, i.m, count(*) n, avg(abs(i.a - i.f)) drawn,
  avg(abs(i.a - (i.s + pk.w * (i.f - i.s)))) held_out, avg(abs(i.a - i.s)) no_change
from idle i join pick pk using (thr, m, dy) group by 1, 2 order by 1, 2;
```
