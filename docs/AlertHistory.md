# Alert history

**Settings › Alerts › Alert History** lists every low and high alert from the last 7 days on the
iPhone and the Mac, grouped by day (Today, Yesterday, Mon 16 Nov…), newest first.

| Row | Detail |
| --- | --- |
| Low alert · 2:14 pm · 3.4 mmol/L | Snoozed 30 min at 2:16 pm |
| Urgent low alert · 2:24 pm · 2.9 mmol/L | Tapped Log treatment at 2:25 pm |
| Predicted high alert · 9:02 am · 11.8 mmol/L | Dismissed at 9:03 am |
| High alert · 7:40 am · No reading | No response |

## What's listed

- The alerts with buttons: urgent low, low, very high and high, and their forecast versions, the
  same ones the Logbook keeps (docs/AlertLog.md). Today and the 6 days before it, by the device's
  calendar.
- Each alert is its own row. The Logbook folds a spell's repeats into one row; the history lists
  each time it went off. The Mac's and the iPhone's copies of one alert (same kind, within 3 min)
  are one row.
- **The reading**: the last stored reading at or up to 10 minutes before the alert, or failing
  that the first one up to 5 minutes after it. "No reading" when none was stored that close.
- **What happened**: Tapped Log treatment, else Snoozed N min, else Dismissed, else No response.
  A button tapped on either device beats a dismissal. "Log treatment" only opens the log sheet, so
  the history says it was tapped, not that the low was treated.
- **Test alerts** (docs/TestAlert.md) are never recorded, so they never show.
- Nothing to list: "No alerts in the last 7 days", saying why (alerts off, or none went off).
- **Notes**: each row's pencil adds a short Logbook note at the alert's time, shown under the
  outcome (docs/AlertNotes.md).

## Dismissed

New in this round. Swiping a low or high alert away in Notification Center or on the lock screen,
or closing the in-app banner (swipe, ✕ or a tap on it), now notes it as dismissed in the alert's
record (`AlertRecord.Response.dismissed`, `AlertLog.dismissed`). The alert categories now carry
`.customDismissAction` so iOS and macOS tell the app. A dismissal:

- never snoozes, logs or opens anything;
- never replaces a snooze or "Log treatment" already tapped on that alert (the banner goes away
  after its button too), while a button tapped afterwards still counts;
- syncs like any alert record. An older build reads it as no response.

The Logbook's alert rows say "Dismissed at 9:03" the same way.

## Chart in a row

Tapping (iPhone) or clicking (Mac) a row opens it in place into a small chart of the two hours
around the alert, an hour either side (`AlertHistoryChart`, Sources/Engine/AlertHistoryChart.swift):

- the reading line on the target band, as the Logbook's day chart draws it (5-minute means, broken
  at gaps over 20 minutes), stopping at now for an alert less than an hour old;
- a dashed rule and bell at the alert's moment in its range's colour, with a dot on the reading it
  went off on;
- whatever was logged in that time (insulin, food, wake-ups, sensor starts) marked along the
  bottom, as on the day chart. The alert's own note is already under the row, so notes aren't
  marked again;
- a caption with the lowest and highest, and an **Open in Logbook** button (below).

One row is open at a time: tapping another moves the chart there, tapping it again closes it, and a
chip switch that hides the open row closes it. The row's height springs open on the `.emphasized`
spring and the chart grows in from the top; under Reduce Motion it cross-fades in place. The chevron
on the row turns to show which way it goes. The chart is a picture only and hidden from VoiceOver:
the row adds one line instead, "Chart from 1:14 pm to 3:14 pm: lowest 3.1 mmol/L at 2:20 pm,
highest 5.6 mmol/L at 3:05 pm, 2 entries logged." ("so far" and "to now" while the hour after is
still running), and that line is announced as the chart opens.

## Opening the Logbook

**Open in Logbook** under an open row's chart (or the row's VoiceOver action of the same name)
opens the Logbook around that alert: everything from 15
minutes before the start of the Logbook row it folds into to 2 hours after it, under a period chip
"Around Yesterday 2:14 pm" with no kind chip (`LogbookFilter.aroundAlert`, unlisted).

- iPhone: Settings closes and the Logbook is pushed from the top of the home stack
  (`AlertHistoryRoute`), a plain push since nothing on the stack is there to zoom from.
- Mac: the sheet closes and the dashboard opens on the Logbook (`DashboardRequest.logbookLink`).

## Accessibility and motion

- Each row is one VoiceOver element and a button: "Low alert, 2:14 pm, reading 3.4 mmol/L,
  Snoozed 30 min at 2:16 pm", hint "Shows a chart of the two hours around this alert." Activating
  it opens or closes the chart; actions Open in Logbook and Add note (or Edit note). Day headers are headers
  and read their count.
- At the largest text sizes the time and reading move under the title.
- Live while open: see below. Under Reduce Motion every change is instant.
- Settings search finds it ("history", "past", "dismissed", "went off").

## Live while open

The list keeps up while it's open on either device, from the alert records as they arrive or
sync in from the other device.

- **A new alert** slides in at the top of today (`DS.Transition.banner`, the `.standard` curve);
  the day's count rolls.
- **An outcome moving on** (snoozed, "Log treatment" tapped, dismissed, on this device or the
  other) morphs the row's status chip in place: the symbol replaces itself, the words blend and
  the tint glides on the `.emphasized` spring (`AlertOutcomeChip`). Tints: Tapped Log treatment
  green, Snoozed blue, Dismissed and No response plain.
- **VoiceOver** hears each change once, at low priority, after a 0.6 s pause that gathers a burst
  (`alertHistoryAnnouncements` on the screen's list): "New low alert, 2:14 pm, reading 3.4
  mmol/L", "Low alert at 2:14 pm: Snoozed 30 min", or for several at once "Alert history: 1 new
  alert, 2 updated". The row's own label already reads the new outcome.
- Nothing is announced for what was listed when it opened, for an alert more than 15 minutes old
  that syncs in late (it's listed quietly), or for the other device's copy of an alert already
  listed unless it brings a new outcome (`AlertHistory.changes` matches it as the same alert).
- **Reduce Motion**: rows cross-fade in and out (see below), chips and counts change instantly.
  Announcements are the same.

## Rows coming and going

`AlertHistoryRowMotion` (Sources/Engine/AlertHistoryRowMotion.swift) and `AlertHistoryContent`.

- **A new alert** slides down into the top of its day and fades in; the rows below glide down on
  the `.standard` curve.
- **An alert ageing out** of the 7 days (the oldest day, at midnight) fades as it shrinks toward its
  top edge (to 94%) and the rows close up; its day header goes with it. The list wakes once at that
  midnight (`nextAgeOut`), only while it's open and only if the oldest day has alerts. No repeating
  timer.
- **The same alert from the other device** syncing in with an earlier time moves the merged item's
  id, but its row keeps its key (`AlertHistoryRowMotion.keys`), so it doesn't leave and slide in
  again; its chip just morphs if the outcome moved on.
- **Chip switches** don't slide rows; they fade the list over as before.
- **Reduce Motion**: rows cross-fade in and out in place over 0.25 s, nothing moves.
- **VoiceOver**: unchanged. New alerts and outcomes are announced as above; ageing out is quiet.

## Filters

Two rows of chips sit above the list once there is anything in it.

- **Kind:** All, Lows, Highs, Predicted. One at a time. Lows and Highs are the alerts about a
  reading (urgent low and low; high and very high), Predicted the ones about the forecast, low or
  high. Every alert falls under exactly one of the three.
- **Outcome:** Treated ("Log treatment" tapped), Snoozed (any length), Dismissed, No response.
  Tap one to show only those, tap it again for every outcome. It ANDs with the kind chip, so Lows
  and Snoozed shows the snoozed lows. A row's outcome is its merged one: a low snoozed on the iPhone
  counts as snoozed even if the Mac's copy went unanswered.

The picked chip's highlight slides to the new chip on the `.emphasized` spring (the Logbook's
`ChipButtonStyle` matched geometry, one namespace per row). The rows fade out, switch without
sliding, and fade in, on the Logbook's timings (`AlertHistory.FilterPick.fadeOut/fadeIn`).
VoiceOver hears the count once the list has switched ("3 alerts", "No matching alerts"); a quick
run of taps only speaks for the last. The chips are selected buttons inside an "Alert type" and an
"Outcome" group; Treated is read as "Tapped Log treatment". Under Reduce Motion the highlight and
list switch at once. iPhone taps play the light `choice` haptic.

When the chips leave nothing, the list says what they asked for ("No snoozed low alerts in the
last 7 days.") with a Show All Alerts button that clears both rows. The pick lasts while the
screen is open and starts at All next time. Live changes are still announced for alerts the chips
hide, so a new low is never silent because Highs was picked.

Rules and words: `AlertHistory.KindFilter`, `OutcomeFilter`, `FilterPick`,
`AlertHistoryText.filterAnnouncement` / `filteredEmptyMessage`. View: `AlertHistoryFilterBar` in
Sources/App/Views/AlertHistoryViews.swift.

## Export

For a clinic visit. Under the chips, a line says how many alerts are shown ("12 alerts shown",
"3 of 12 alerts shown") beside an **Export** menu:

- **iPhone:** Share PDF / Share CSV. The file is made off the main thread in the app's temporary
  export folder (cleared before each export, complete file protection, as the Logbook export's
  `ExportFile`), then the share sheet opens (Mail, Messages, AirDrop, Save to Files, Print).
- **Mac:** Save PDF… / Save CSV… asks where to save, then says "Saved “name”" under the count.

What's in it is exactly what the list shows under the chips as picked at that moment: the same
rows (the Mac's and the iPhone's copies merged, the same 7 days), the same reading and outcome,
and each alert's note (docs/AlertNotes.md). Oldest first, since a clinic reads a log forwards.
The menu is disabled when the chips leave nothing.

| CSV column | Example |
| --- | --- |
| Date, Time | 2026-11-18, 14:14 (24 h) |
| Alert | Low alert |
| Type | Low, High or Predicted (the kind chip it falls under) |
| Glucose (mmol/L or mg/dL) | 3.4, blank for no reading |
| Outcome | Snoozed 30 min, Tapped Log treatment, Dismissed, No response |
| Responded | 14:16, or 2026-11-18 00:02 when it was the next day |
| Note | the alert's note |

CSV is RFC 4180 with CRLF line ends and the Logbook export's formula guard (a note starting with
= + - @ gets an apostrophe).

The PDF (A4, the Logbook export's print colours, layout and footer) opens with "GlucOS Alert
History", the period ("12 Nov – 18 Nov 2026 (7 days)"), the filter ("Showing: Snoozed low alerts ·
3 of 12 alerts", or "Showing: All alerts · 12 alerts"), the unit and when it was made, then a
"What happened" line counting each outcome, then every alert by day: time, a dot in the range's
colour with the alert's name, the reading, what happened with its time, and the note in italics.
The file name carries the days and any filter: "GlucOS Alert History 2026-11-12 to 2026-11-18
(Snoozed low alerts).pdf". The footer says it was made on this iPhone or Mac from its own alerts,
readings and notes, that "Tapped Log treatment" means the button was tapped rather than that a low
was treated, and that it's observations, not advice.

**Never anyone else's data.** It reads only the owner's alert records (a follower's copies of a
shared person's alerts are never recorded, docs/AlertLog.md), the owner's stored readings and the
owner's Logbook notes. Test alerts are never recorded, so they never appear. Nothing leaves the
device until the person shares or saves the file.

Rules and words: `Sources/Engine/AlertHistoryExport.swift` (`AlertHistoryExport`,
`AlertHistoryExportText`), tests `AlertHistoryExportTests`. PDF: `Sources/App/Export/AlertHistoryPDF.swift`,
drawn with `LogbookPDF.render` (shared with the Logbook export). View: `AlertHistoryExportRow` in
Sources/App/Views/AlertHistoryViews.swift.

## Where it lives

- Rules and words: `Sources/Engine/AlertHistory.swift` (`AlertHistory`, `AlertHistoryText`).
  Tests: `AlertHistoryTests`.
- Dismissals: `AlertLog.dismissed`, `LogbookStore.alertDismissed`, `AlertLogRecorder.dismissed`,
  `AlertNotifications.isDismissal`, `AlertBannerCenter.close`.
- Views: `Sources/App/Views/AlertHistoryViews.swift` (`AlertHistoryContent`, `AlertHistoryRow`,
  `AlertOutcomeChip`, `alertHistoryAnnouncements`, `AlertHistoryRoute`). iPhone `PhoneAlertHistoryScreen` in PhoneSettingsView; Mac
  `MacAlertHistorySheet` in SettingsView.
