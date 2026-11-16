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
point plus 20 minutes). The Mac's quiet stretch, 2026-11-14 18:42 to 2026-11-15 03:31 UTC
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

To rerun:

    with rd as (select r.at, r.mgdl from glucos.readings r where not (r.trend = 0 and exists (
        select 1 from glucos.readings o where o.at <> r.at and abs(extract(epoch from o.at - r.at)) < 30))),
    m0 as (select to_timestamp((payload->>'timestamp')::float) t, payload->>'food' food
      from glucos.logbook where not deleted and kind = 'meal'),
    m as (select * from m0 where not exists (select 1 from m0 p where p.t < m0.t and p.t > m0.t - interval '20 minutes')),
    f as (select f.*, m.t mt, (select min(n.t) from m n where n.t > m.t) nt from glucos.forecast_checks f
      join m on f.issued_at between m.t and m.t + interval '2 hours'
      where not exists (select 1 from m n where n.t > m.t and n.t <= f.issued_at)),
    pts as (select f.id, 0 mm, f.start_mgdl v from f union all
      select f.id, (e->>'minutes')::int, (e->>'mgdl')::float from f, jsonb_array_elements(f.points) e
      where coalesce((e->>'shown')::bool, true)),
    est as (select distinct on (id) id, mm est_min, v est_peak,
      (select max(mm) from pts p2 where p2.id = pts.id) horizon from pts order by id, v desc, mm),
    act as (select f.id, a.at pat, a.mgdl peak from f cross join lateral (select at, mgdl from rd
      where rd.at between f.issued_at and least(f.mt + interval '3 hours', coalesce(f.nt, 'infinity'))
      order by mgdl desc, at limit 1) a)
    select f.device, f.issued_at, est.*, act.peak, extract(epoch from act.pat - f.issued_at) / 60 act_min
    from f join est using (id) join act using (id)
    where est.est_min > 0 and est.est_min < est.horizon order by f.issued_at;
