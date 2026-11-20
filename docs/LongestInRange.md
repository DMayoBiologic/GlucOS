# Longest in range

An Insights card on iPhone and Mac: the longest unbroken stretch spent in range over the last 7, 14
or 30 days, how long it lasted, and when it happened.

Engine: `Sources/Engine/LongestInRange.swift` (`LongestInRange`, `LongestInRangeText`,
`LongestInRangeCache`). View: `Sources/App/Views/LongestInRangeCardView.swift`. Tests:
`Tests/EngineTests/LongestInRangeTests.swift`.

## How it's worked out

- Readings are averaged into 5-minute buckets, as for time in range, Lows and Highs.
- A stretch is a run of buckets at or above the low line and at or below the high line. The first
  bucket out of range ends it. More than 30 minutes with no readings ends it too, five minutes after
  its last bucket, so LibreLinkUp's 15-minute history never breaks a stretch.
- A stretch shorter than 15 minutes doesn't count. A stretch that began before the period counts
  from the period's start. One still going at the newest reading says "and counting".
- Ties go to the later stretch. The "4 h or more" tile counts stretches of 4 hours or longer.

## When it shows

Only with readings in at least half of the period's 15-minute slots
(`LongestInRange.minimumCoverage`). Below that the Insights screen leaves the card out
(`LongestInRangeCache.shows`), like Sensor coverage. Under 90% coverage the footnote says how much
the readings cover, since a longer stretch may have gone unseen.

## Card

- Period picker (7, 14, 30 days, stored under `insights.longestInRangeDays`), and the period step
  caption: the card moves with Insights' Earlier and Later.
- Headline ("9 h 40 min in range in one go."), Longest and 4 h or more tiles, a thin timeline of the
  period with the stretch drawn where it fell, and "From yesterday at 10:15 pm to today at 7:55 am."
- Motion: figures count up and roll; the stretch grows from its start once the card is in view and
  glides when the period changes. Under Reduce Motion it fades in. Nothing loops.
- VoiceOver: one element with the whole card in a few sentences, a button trait, and its default
  action opens the Logbook.
- Order: right after Time in range by hour on both screens (`InsightsCard.longestInRange`).

## Logbook

Tapping the card, or "See this stretch in the Logbook", opens the Logbook on the unlisted
"Longest in range" chip (`LogbookFilter.inRangeStretch`) over the stretch itself, its period chip
reading "Yesterday 10:15 pm – 7:55 am". No kind chip. A stretch still going runs on to now. The
iPhone zooms the card into the Logbook; the Mac cross-fades, and Back scrolls to the card.

Observations only: it never suggests a dose, a correction or a change to settings.
