# "Did you treat this low?"

A low that comes back up with nothing logged reads, to everything that learns from the logbook, as
glucose rising on its own. The forecasts shown during it are scored as if nothing changed, so the
rebound counts as a miss and widens the range; Insights can't tell a treated low from one that
recovered by itself; and the "Treat a low" usual ([UsualEntries.md](UsualEntries.md)) never learns
what was eaten. Treatments are the entry most often skipped, because the user is busy fixing the low.

So once a low is over, GlucOS asks once whether it was treated. It follows the pattern of
[DoseQuestion.md](DoseQuestion.md).

## When it asks

Rules: `Sources/Engine/LowTreatmentCheck.swift` (tests: `LowTreatmentCheckTests`).

- A low: readings below the low line for at least 15 minutes. A dip back below within 15 minutes of
  coming up is the same low.
- Over: glucose has been back at or above the line for 15 minutes, every reading since has stayed
  there, and it isn't low or heading low now (just above the line and falling 1 mg/dL a minute or
  faster). It never asks during a low.
- Nothing logged for it: no food, and no hypo treatment tag, from 20 minutes before the low to
  10 minutes after it ended. "I'm treating it" on a low alert logs one, so those lows aren't asked about.
- Not answered yet, on any device.
- Until 2 hours after the low ended. Only the latest low is asked about.

## Where it asks

- **iPhone:** a strip above the log bar's buttons (`PhoneLowStrip`): "You went low at 9:12 pm and
  were back up by 9:40 pm. Did you treat it?"
- **Mac:** the same question in the menu bar popover (`PopoverLowPrompt`).
- No notification. After a low, another buzz is the last thing wanted.

## The answers

- **The usual treatment** ("Jelly beans · 15 g"), when the user has one (logged for a low at least
  twice in 90 days): one tap logs it as the log sheet would, as food plus a hypo treatment tag, never
  a dose. It's logged 10 minutes before the lowest reading (fast carbs take about that long to turn
  glucose around), but not before the low began. The confirmation names the time; the entry can be
  edited in the logbook like any other.
- **Other** (or **Log what I had**, with no usual yet): opens the log sheet on a hypo treatment at that
  time (`PhoneLogTarget.lowTreatment(at:)`, `LogSheetTarget.lowTreatment(at:)`), with no bolus step.
- **No:** it came up by itself. Stored as a `LowAnswer` (`notTreated`).
- **Close:** stored as a `LowAnswer` (`dismissed`).

Every answer is confirmed for 10 minutes with **Undo**. `LowAnswer` is a logbook record of its own
kind (`lowAnswer`) and syncs, so a low answered on one device is never asked about on another. Two
devices' views of a low match when they overlap, give or take 10 minutes. Answers older than 90 days
are dropped. Older app versions skip the new kind, and the follower page and the relay never read it.

## The forecast checks

The treatment is logged up to 2 hours after the low, at the time it was eaten, by which point some of
the forecasts shown before and during the low have been settled and sent to
`glucos.forecast_checks`. So `ForecastLedger.score` now re-marks `afterLog` on settled forecasts
from the last 12 hours whenever logs change (`ForecastLedger.relogWindow`). A forecast whose points
change is sent again, and `forecast_push` replaces the row. The same goes for any entry logged late
or moved by an edit, and for Undo.

The relay's own Lock Screen forecasts are re-scored by the database from the synced logbook for 4
hours (`glucos.score_relay_forecasts`), which covers a treatment logged within the 2-hour window.

Nothing here changes dosing: the treatment is a food entry like any other, and the bolus calculator
reads it the way it reads any logged hypo treatment.
