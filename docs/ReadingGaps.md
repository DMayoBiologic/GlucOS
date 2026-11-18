# Gaps in readings

iPhone Today and the Mac popover explain where readings are missing.

- **What's a gap.** Two readings 10 minutes or more apart. A step of about 15 minutes (±90 s) is
  LibreLinkUp's history filling time the app wasn't checking, so it isn't marked.
- **How it looks.** The trace breaks at the gap (each unbroken stretch is its own line, glow and
  out-of-range fill), and a thin dashed grey bridge joins the last reading before it to the first
  after. Each bridge draws in from left to right the first time it's shown in a launch, then holds.
  Under Reduce Motion it's simply there.
- **Why.** A tap on iPhone (tap again to close; a scrub closes it too), or the pointer resting on
  it on the Mac, shows a small card with the reason, the times and the length:
  - *Sensor warming up*: the gap reaches into the current sensor's first hour (plus 20 minutes'
    grace), which covers the old sensor ending before it.
  - *Sensor ended*: the gap starts at (or up to 5 minutes before) the sensor's end.
  - *Can't connect to LibreLinkUp*: GlucOS was checking for at least half the gap, and its
    checks were failing for at least half of that time.
  - *No signal from LibreLinkUp*: GlucOS was checking for at least half the gap (and mostly
    getting through).
  - *Mac was asleep* / *iPhone was asleep*: it wasn't.
  - *No readings*: the gap is older than the record of checks, so there's no telling.
- **Record of checks.** `PollLog` (UserDefaults `readingGapPollLog`) notes every fetch, failed or
  not, joining fetches less than 5 minutes (or 3 poll intervals) apart into stretches, kept for 48 h.
  Failed fetches are also joined into their own stretches (`failed`, missing from logs saved
  before round 82, which read as none).
- **Check now** (round 82, `ReadingGapCheck`). When the newest gap on the chart says *No signal*
  or *Can't connect*, its card ends with a Check Now button (the card then takes the pointer and
  touches; on the Mac it stays up while the pointer moves from the bridge onto it). A tap runs one
  fetch through `GlucoseStore.refresh()` (or waits for one already under way), and the spinner
  becomes a check mark (an alert mark if it failed; a plain swap under Reduce Motion). The card
  then says "Connected, new reading 6.1", "Connected, no new reading yet", or the connection
  problem's title in plain words. One tap per 30 seconds: until then the button reads "Check
  again in 12 s", ticking once a second only for those 30 seconds. It never schedules anything or
  changes polling. Followers (no LibreLinkUp login) never get it. VoiceOver gets a "Check now"
  action on the chart, and hears the result once.
- **VoiceOver.** The chart stays one element; its summary gains one line for the gaps ending on
  screen: "Gap in readings from 2:10 pm to 2:42 pm: Mac was asleep." or, with several, "3 gaps in
  readings; the latest from …". The bridges and card are hidden from VoiceOver.

## On widgets

The Home Screen widgets (iPhone and Mac), StandBy, the Lock Screen accessories, the Glucose
control and the Live Activity say the same thing, calmly, while a gap is still going on.

- **When.** From 10 minutes after the last reading, the same edge as a gap in the chart. Between 6
  and 10 minutes a late reading is only stale, as before ("Stale · 8m").
- **Words.** "No readings for 12 min" ("No readings for 12m" on the Lock Screen), in grey with a
  clock, never the amber warning. The status pill names the reason in a word or two; StandBy puts
  it after the length ("No readings for 12 min · No signal"); the rectangular accessory's middle
  line carries it. Once the number is withdrawn (30 minutes), the widgets add the last value
  where it fits ("No readings for 45 min · last 6.1").
- **Why** (`WidgetGap.reason`), worked out from the snapshot alone at each timeline entry:
  - *Sensor warming up* / *Sensor ended*: the chart's own sensor rules, checked first.
  - *Can't connect to LibreLinkUp*: the app's last check failed.
  - *No signal from LibreLinkUp*: the app's last good check came at least half way through the
    stretch. A good check returns any readings in between, so up to then there were none.
  - *Not checked since 2:40 pm*: it didn't (in the background iOS lets the app check about every
    15 minutes at best, §80). Readings may be waiting; VoiceOver adds "Open GlucOS to check."
  - Nothing, when the app has never checked: just "No readings for 12 min".
- **Live Activity.** "No readings since 2:10 pm" in place of the range word, in grey. A card only
  redraws when an update arrives (the relay sends none while nothing changes) or at its stale
  date, so it names the time, not a count that would stop. The card carries neither the sensor
  nor the app's checks, so it gives no reason; a warm-up keeps its own countdown card.
- **Budget.** No new data, timeline entries, reloads or wakes: the widgets already had an entry a
  minute for the reading's first hour, and the reason only reads `fetchedAt`, `lastError` and
  `sensor`.
- **Motion** (`WidgetGapMotion`, `gapSwap`). As the state begins, the reading's line (StandBy's
  caption, the detail line, the inline and rectangular accessories) cross-fades into "No readings
  for 12 min", and the status pill fades rather than pushing. The minutes roll to the next one
  with each per-minute entry (`numericText`), the withdrawn number fades to dashes at 30 minutes,
  and everything fades back when readings resume. On the Live Activity, "No readings since
  2:10 pm" fades in over the range word and the card's colour fades to grey on `.sweep`, and back
  with the next reading. All of it plays between entries or card states the system already has:
  no reloads, entries or wakes. Instant under Reduce Motion.
- **VoiceOver.** "No readings for 12 minutes: No signal from LibreLinkUp. The last reading was 6.1
  millimoles per litre at 2:10 pm." Never the range or trend.

Code: `WidgetGap` and its callers in `Sources/Shared/WidgetGlance.swift`, `StatusPill` /
`DetailLine` (Sources/Widget/WidgetComponents.swift), the rectangular accessory,
`GlucoseActivityState.noReadingsLine`, `WidgetGapMotion` and the `gapSwap` modifiers
(Sources/Shared/DesignSystem/Motion.swift). Tests: `Tests/EngineTests/WidgetGapTests.swift`.

Code: `Sources/Shared/ReadingGaps.swift` (rules, words, `PollLog`, `ReadingGapDrawIn`),
`GlucoseChart.gapContext` and `ReadingGapLayer` (drawing), `GlucoseStore.polls`/`gapContext`.
Tests: `Tests/EngineTests/ReadingGapsTests.swift`.
