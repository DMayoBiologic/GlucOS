# Last 7 days

A long-press on the time-in-range row on iPhone Today, or a click on the time-in-range bar in the
Mac popover, opens a small card with each of the last seven days' time in range as a mini bar,
today last. Tap or click a bar to close the card and open the Logbook on that day, every kind of
entry and the alerts, under a period chip that names it ("Yesterday", "Mon 16 Nov").

## Rules

- **Days** (`RecentDays.compute`, `Sources/Engine/RecentDays.swift`): the seven local days ending
  today, oldest first. Each share is the Logbook's own day bar (`DayInRange`): 5-minute buckets,
  midnight to midnight, today from midnight to now. A day with readings in under half its
  15-minute slots keeps its place with no bar and "–" over it, so the bars don't shift.
- The bar's height is the share of the day in range. The figure above it is the same share
  ("78%"), the label under it is the weekday, or "Today".
- **Link** (`LogbookLink.recentDay`): the day from local midnight to the next one, on the unlisted
  One day chip, which shows no kind chip. Today's day runs on to tonight's midnight, so something
  logged after the last reading still shows. iPhone pushes the Logbook (no zoom, since the card has
  closed); the Mac opens the Dashboard on the Logbook (`DashboardRequest.logbookLink`).
- Never for followers: the long-press does nothing on a follower's Today screen. The Mac popover
  is always the sensor wearer's own.
- The card is a popover, kept a popover on iPhone too. Its days are worked out when it opens.
- Observational only: shares of time, nothing about what to do.

## Motion

- The bars grow up from the baseline as the card opens, one after another, oldest first, so
  today's lands last (`RecentDays.growDelay`: 0.12 s, then 0.04 s apart, on the `.emphasized`
  spring). Their figures fade in with them. Once per opening, nothing loops.
- Reduce Motion: the bars are at full height and fade in together over 0.2 s.
- iPhone: a light `choice` haptic when the long-press opens the card. The tap that ends the
  long-press doesn't also open Insights.

## Accessibility

- VoiceOver reads one line per day, each bar its own button: "Today so far, 78% in range, 4%
  below", "Monday 16 November, 70% in range", "Saturday 14 November, not enough readings".
  The hint is "Opens the Logbook on this day".
- The time-in-range row on iPhone and the bar in the Mac popover have a "Show last 7 days" action,
  so the card is reachable without a long-press.

Tests: `RecentDaysTests`.
