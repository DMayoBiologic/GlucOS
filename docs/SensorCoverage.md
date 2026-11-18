# Sensor coverage

An Insights card on iPhone and Mac (round 81): how much of the last 7, 14 or 30 days GlucOS has
readings for, and the longest stretches it doesn't, each with the reason the chart gives it
([ReadingGaps.md](ReadingGaps.md)). Engine: `Sources/Engine/SensorCoverage.swift`
(`SensorCoverage`, `SensorCoverageText`, `SensorCoverageCache`), tested in SensorCoverageTests.
View: `Sources/App/Views/SensorCoverageCardView.swift`.

## What it counts

- **A gap** is what the chart marks: readings 10 minutes or more apart, except LibreLinkUp's
  15-minute history fill. A stretch filled at one reading every 15 minutes while the app slept
  counts as covered, as the chart draws it.
- **The period** is the 7, 14 or 30 days up to the newest reading, like Lows, Highs and Overnight.
  When the stored readings start inside it (a new install), it starts at the first reading and the
  headline says "of the 5 days stored so far". A gap crossing the start counts from the start.
- **Coverage** is the share of the period outside a gap. It needs a day of period.
- **Reasons** are the chart's: warm-up and sensor ended from the current sensor, no signal or
  asleep from the 48-hour record of checks, otherwise "No readings". So gaps older than two days
  mostly read "No readings"; the footnote says so.

## What it shows

Headline ("Readings for 96% of the last 14 days."), Covered and Gaps tiles (Gaps captions the
missing time), the three longest gaps (when, how long, why), and "Most of the missing time: Mac was
asleep (6 hr)." when the biggest share has a known reason.

- **Hidden at 99% or more.** The screen leaves the card out (`SensorCoverageCache.shows`, its
  `onScreen` check on iPhone and Mac) for the picked period and step. Its slot in the order is kept.
- **Order.** Last on both screens, after Forecast accuracy (`InsightsCard.sensorCoverage`).
- **Compare to previous period.** Covered (in points, more is better) and Gaps (fewer is better)
  get badges. Only when the period before had stored readings over 4 of every 7 of its days, and
  never for a partial period.
- **Logbook.** Tapping the card, or "See the longest gap in the Logbook", opens the Logbook around
  the longest gap, an hour either side, on the unlisted "Around a gap" chip
  (`LogbookFilter.aroundGap`, `SensorCoverage.link`). Each gap row opens around its own gap. The
  iPhone zooms the card into the Logbook; the Mac cross-fades and Back scrolls to the card.
- **Motion.** The card rises in with the others (`dsReveal`); its figures count up and the gap
  rows slide up one after another as it rises (`onEntrance`); period changes roll the figures and
  cross-fade the rows. All instant under Reduce Motion. VoiceOver reads the card as one element.
- **Share.** Its period picker key is `insights.coverageDays` (`InsightsShare.Key.coverage`).

Observational only: no advice about insulin, food or settings.
