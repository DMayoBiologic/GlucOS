# Send a test alert

Settings › Alerts on iPhone and Mac has **Send a Test Alert** (also on the setup screens). It sends
a sample low alert, so you can check that banners, sound, buttons and the chart reach you.

## What it looks like

- Title **Test alert**. Body: "Sample low, 3.4 mmol/L, falling. This is how a low alert looks and
  sounds. Nothing is logged or snoozed." The sample is 8 mg/dL under your low limit, never an
  urgent low.
- It goes through the same local notification path as a real low (`AlertManager.sendTest`): the
  default sound, active interruption level, the `glucos.alert` category (Log treatment, Snooze
  30 min), and a sample chart (`AlertChart`, docs/AlertActions.md "Chart on alerts"). The iPhone's
  notification content extension draws it; the Mac attaches it as a picture.
- It is sent even where the push relay delivers alerts, since it checks this device.
- With GlucOS in front it keeps the system banner, not the in-app banner, because the system banner
  is what it tests.
- Sending another one clears the previous test from Notification Centre. Real alerts are left alone.

## What it never does

Rules in `Sources/Core/TestAlert.swift`, tests in `TestAlertTests`.

- Its userInfo is `test: true` plus `chart`, with no `kind`. `TestAlert.ownKind` is the one rule the
  Logbook recorder (`AlertLogRecorder`), the buttons (`AlertNotifications.button`) and the in-app
  banner go by, and it turns a test away even if it ever carried a `kind`.
- So it adds no alert record. The Logbook, alert stats and the alert-count preview
  (docs/AlertCountPreview.md) never see it.
- Its buttons do nothing: no snooze, no log sheet. Tapping the alert opens the app (Mac: popover).
- Its identifier is `glucos.test.<seconds>`, never an episode's (`glucos.low.…`, `glucos.high.…`)
  or a kind's (`glucos.<kind>`), so it can't join or replace a real low's notification
  (docs/AlertEpisodes.md), and a real one can't replace it. It never goes through `AlertPlanner` or
  `AlertEpisodes`, so it changes no repeat timer and opens no episode.

## Accessibility

- VoiceOver: label "Send a test alert", hint "Sends a sample low alert with its sound, buttons and
  chart. Nothing is logged or snoozed." After a tap it announces that the test was sent and that
  nothing was logged or snoozed.
- The button reads "Test Alert Sent" for 3 seconds with a short cross-fade, instant under Reduce
  Motion.
