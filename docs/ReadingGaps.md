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
  - *No signal from LibreLinkUp*: GlucOS was checking for at least half the gap.
  - *Mac was asleep* / *iPhone was asleep*: it wasn't.
  - *No readings*: the gap is older than the record of checks, so there's no telling.
- **Record of checks.** `PollLog` (UserDefaults `readingGapPollLog`) notes every fetch, failed or
  not, joining fetches less than 5 minutes (or 3 poll intervals) apart into stretches, kept for 48 h.
- **VoiceOver.** The chart stays one element; its summary gains one line for the gaps ending on
  screen: "Gap in readings from 2:10 pm to 2:42 pm: Mac was asleep." or, with several, "3 gaps in
  readings; the latest from …". The bridges and card are hidden from VoiceOver.

Code: `Sources/Shared/ReadingGaps.swift` (rules, words, `PollLog`, `ReadingGapDrawIn`),
`GlucoseChart.gapContext` and `ReadingGapLayer` (drawing), `GlucoseStore.polls`/`gapContext`.
Tests: `Tests/EngineTests/ReadingGapsTests.swift`.
