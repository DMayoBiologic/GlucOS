# Alert count preview (round 66)

Under the low and high limits in Settings (iPhone Settings › Display, Mac Settings › Glucose) two
lines say how often each limit would have alerted over the last 7 days of stored readings:

> Last 7 days: this would have alerted 3 times (was 5)

"Was" is the count for the limits as they were when the editor opened; it only shows while the two
differ. The figure rolls to its new value as a limit steps (numeric text), and changes instantly
under Reduce Motion. VoiceOver reads each line as one element: "Low alerts, last 7 days: this limit
would have alerted 3 times, down from 5".

## How it counts

`AlertCountPreview` (Sources/Engine/AlertCountPreview.swift) replays the readings, one at a time at
each reading's own time, through the real rules: `AlertPlanner.evaluate`, then `unsnoozed`. So it
follows the same repeat timer (Settings › Alerts › repeat), the reset when glucose comes back into
range, the fixed urgent-low (under 54 mg/dL, every 5 minutes) and very-high (over 250) lines, the
High alerts switch, and the snoozes: every "Snooze 30 min" or "Log treatment" tap in the alert log
quiets its level from when it was tapped, for as long as it did then.

- Low line: low and urgent-low alerts. High line: high and very-high alerts.
- Forecast heads-ups (predicted low/high) are not counted: they depend on the forecast as it was
  at the time, which isn't stored.
- Rapid change, no data and sensor alerts don't depend on the range and are not counted.
- Hidden until the last 7 days hold 6 hours of readings, and while alerts are off. With less than
  a week of readings it says "Last 3 days" (whole days covered, rounded up).
- The window is gathered off the main thread once per new reading or snooze tap; only the replay
  runs again as a limit changes.

Tests: Tests/EngineTests/AlertCountPreviewTests.swift (fixtures of 5-minute readings).
