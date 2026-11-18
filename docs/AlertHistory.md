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

## Opening the Logbook

Tapping (iPhone) or clicking (Mac) a row opens the Logbook around that alert: everything from 15
minutes before the start of the Logbook row it folds into to 2 hours after it, under a period chip
"Around Yesterday 2:14 pm" with no kind chip (`LogbookFilter.aroundAlert`, unlisted).

- iPhone: Settings closes and the Logbook is pushed from the top of the home stack
  (`AlertHistoryRoute`), a plain push since nothing on the stack is there to zoom from.
- Mac: the sheet closes and the dashboard opens on the Logbook (`DashboardRequest.logbookLink`).

## Accessibility and motion

- Each row is one VoiceOver element and a button: "Low alert, 2:14 pm, reading 3.4 mmol/L,
  Snoozed 30 min at 2:16 pm", hint "Opens the Logbook around this alert." Day headers are headers
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
- **Reduce Motion**: rows appear, chips and counts change instantly. Announcements are the same.

## Where it lives

- Rules and words: `Sources/Engine/AlertHistory.swift` (`AlertHistory`, `AlertHistoryText`).
  Tests: `AlertHistoryTests`.
- Dismissals: `AlertLog.dismissed`, `LogbookStore.alertDismissed`, `AlertLogRecorder.dismissed`,
  `AlertNotifications.isDismissal`, `AlertBannerCenter.close`.
- Views: `Sources/App/Views/AlertHistoryViews.swift` (`AlertHistoryContent`, `AlertHistoryRow`,
  `AlertOutcomeChip`, `alertHistoryAnnouncements`, `AlertHistoryRoute`). iPhone `PhoneAlertHistoryScreen` in PhoneSettingsView; Mac
  `MacAlertHistorySheet` in SettingsView.
