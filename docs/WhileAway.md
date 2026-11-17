# While you were away

Open the iPhone app or the Mac popover after two hours or more without looking, and one quiet line
sits under the reading for ten seconds:

> Away 5 h 20 m · 3.9–11.2 · 84% in range · 1 low alert

It gives the lowest and highest readings, the time in range and the low and high alerts that went
off since the screen was last looked at. Tap or click it to open the Logbook on that span, every
kind of entry and the alerts, under a "While you were away" period chip.

## Rules

- **Last looked** (`LastLookedClock`, `Sources/Engine/WhileAway.swift`) is kept per device in
  UserDefaults (`whileAway.lastLooked`). Opening the screen and closing it both count as a look,
  so an app left open for hours and then put away doesn't greet the next opening.
  - iPhone: the scene becoming active is an opening; inactive (Control Center, the app switcher) and
    background are looks. A launch in the background is not a look.
  - Mac: the popover appearing and disappearing.
- The first launch shows nothing: there's nothing to compare with yet. A stored time after now (the
  clock was set back) shows nothing and starts again from now.
- Away for more than a day, the line covers the last 24 hours and starts "Last 24 h".
- The figures need readings in at least six 5-minute buckets of the span (half an hour). Time in
  range counts buckets inside the target. Alerts are folded the way the Logbook folds them
  (`AlertLog.rows`), so a low that repeated every 15 minutes is one low alert.
- Never for followers: the line only shows on the sensor wearer's own Today screen and popover,
  and a follower's screen keeps no last look.
- It reports readings and alerts only. No insulin on board, no suggestions.

## Motion

The line slides down from under the reading as it fades in, then fades out after 10 seconds. Under
Reduce Motion it cross-fades in and out. With VoiceOver on it stays until the screen closes, so it
can be reached, and reads as one sentence: "While you were away, 5 hours 20 minutes: lowest 3.9
mmol/L at 2:10 am, …". On iPhone the Logbook opens with a plain push, since the line will have
faded by the time Back returns.

Tests: `WhileAwayTests`.
