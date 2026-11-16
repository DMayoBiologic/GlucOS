# Alerts in the Logbook

Low and high alerts show in the Logbook on the iPhone and the Mac as quiet rows between the
entries: a small bell in the range's colour, when the alert went off, and what was done about it.

| Row | Detail |
| --- | --- |
| Low alert | Snoozed 30 min at 10:06 |
| Urgent low alert | Tapped Log treatment at 02:14 · Went off 3 times, last at 02:24 |
| Predicted high alert | No response |

## What gets a row

- Urgent low, low, very high and high alerts, and their forecast versions (the alerts with
  "Log treatment" and "Snooze 30 min", docs/AlertActions.md). Rapid change, no data, sensor and
  connection alerts don't.
- One spell is one row. Alerts about the same side (low or high) less than 45 minutes apart fold
  together: the 15-minute repeats, a forecast low that then arrives, and the Mac and the iPhone
  both showing it (counted once). The row is named after the most serious alert in it, a real
  reading over a forecast and urgent over plain.
- What was tapped: Log treatment if it was tapped on any alert in the spell, otherwise a snooze,
  otherwise "No response".

## Where the records come from

- **Mac**: every local low or high alert it shows, and the button tapped on it.
- **iPhone**: its own local alerts, the relay's pushes it shows while open, the button tapped on
  any of them, and the pushes still in Notification Center whenever the app opens or refreshes in
  the background. A push cleared from Notification Center before GlucOS ran again isn't seen.
- A follower's copy of someone else's alert (it names the share it came from) is never recorded.
- Records sync through the logbook sync (docs/LogbookSync.md, kind `alert`) and are kept for 90 days.

## Hiding them

- iPhone: the filter menu on the Logbook has **Show Alerts**, and an **Alerts** chip shows only
  them. Mac: the **Alerts** checkbox next to the search field, and an **Alerts** filter.
  Each device remembers its own choice (`logbookShowsAlerts`).

## What they never do

Alert rows are a record of what the phone or Mac said, not something the user did. They are kept
apart from doses, food, site changes and moments (`LogbookStore.alerts`, not `entries`), so:

- they never count as a treatment. "Log treatment" opens the log sheet, and only what is then
  logged is a treatment. "Did you treat this low?" still asks when nothing was logged.
- the forecast, insulin on board, the double-dose warning, the bolus calculator, the insights and
  the day totals never see them.
- followers never see them: the follower page only shows doses, food, site changes and moments
  (`sharedLogKinds` in supabase/functions/share/detail.ts).
- they can't be edited, logged again or deleted.

## Where it lives

- Rules: `Sources/Engine/AlertLog.swift` (tests `AlertLogTests`).
- Recording: `AlertLogRecorder` in `Sources/App/AlertManager.swift`, called from `AlertManager`,
  both apps' notification delegates and `PhoneServices`.
- Rows: `Sources/App/Logbook/AlertLogStyle.swift`, `PhoneLogbookView` (iPhone) and
  `LogbookSection` (Mac).
