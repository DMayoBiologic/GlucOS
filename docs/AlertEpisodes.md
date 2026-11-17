# Alerts grouped by low or high

Alerts from one time below range (or one time above it) replace each other in Notification Centre
instead of stacking up. Once the reading is back in range, that alert changes one last time to a
quiet summary:

> **Back in range after 25 min**
> Lowest 58 mg/dL, now 82 mg/dL.

Highs say "Highest". Figures are in the unit chosen in Settings. Durations of an hour or more read
"1 h 35 min".

## Rules

- **What counts as one episode.** It starts at the first reading below the low limit (or above the
  high limit), or at a heads-up alert ("Low predicted…") that comes before one. It ends at the first
  in-range reading. Lows: urgent low, low, predicted urgent low, predicted low. Highs: very high,
  high, and both predicted highs. Rapid change, no data, sensor and connection alerts keep their own
  identifiers, as before.
- **Replacing never quietens an alert.** Each replacement is a new alert with its own sound,
  interruption level (urgent lows stay critical / time-sensitive), buttons and chart (docs/AlertActions.md,
  "Chart on alerts"). Only where it shows changes. Repeat timers, snoozes and what fires are untouched:
  this changes the identifier and nothing else.
- **The summary is quiet.** It replaces the alert with no sound and a passive interruption level, so
  it never wakes anyone or lights the screen. It has no buttons. It only goes out when an alert was
  shown for the episode, and only replaces alerts the same device (or the relay) showed.
- **No summary when it isn't known.** If readings stop for more than 30 minutes, if the reading goes
  straight to the other side of the range, or if a heads-up never became a real low or high (it lapses
  45 minutes after its last alert), the episode ends without one. Stale readings change nothing.
- **A new episode stacks.** The next low gets a new identifier, so it sits beside the earlier summary.
- **Logbook.** Each replacement, and the summary, lists the alerts it replaced (`earlier`, as
  `[[kind, seconds since 1970]]`). The iPhone records them as it would have recorded the alerts
  themselves (docs/AlertLog.md), so a replaced push that arrived while the app was closed still
  appears.
- **Followers** get the same grouping on their copies (`<id>.<share id>`) and the same quiet summary,
  titled with the person's name. Their copies carry no `earlier` list.

## Identifiers

`glucos.low.<seconds>` or `glucos.high.<seconds>`, where the number is when the episode began (the
first out-of-range reading's timestamp, or the heads-up's time). The same id is the local
notification identifier on the Mac and iPhone and the APNs collapse id on relay pushes. Because the
start comes from the reading itself, the relay and the phone key a reading-led episode alike.

## Accessibility

Notifications are drawn by the system, so nothing animates and Reduce Motion has nothing to change.
VoiceOver reads the summary as written; it uses words, not arrows or symbols.

## Code

- Swift: `AlertEpisodes` (`Sources/Core/AlertEpisodes.swift`), used by `AlertManager` (delivery and
  `deliverBackInRange`) and `AlertLogRecorder.arrived` (the `earlier` list). Tests:
  `AlertEpisodesTests`.
- Relay (2.19.0): `observeEpisodes`, `recordEpisodeAlert`, `backInRangeText` in core.ts;
  `payloads.backInRange` in apns.ts; state in `work.ownerEpisodes` (owner pushes) and `work.episodes`
  (followers). Back-in-range pushes go at priority 5. Tests: `episodes_test.ts` (same numbers as
  the Swift tests), plus engine and follower cases in `engine_test.ts` and `checkins_test.ts`.
