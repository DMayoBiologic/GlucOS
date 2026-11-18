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
- **Motion.** See "Motion" below.
- **Share.** Its period picker key is `insights.coverageDays` (`InsightsShare.Key.coverage`).

Observational only: no advice about insulin, food or settings.

## Motion

The rules are plain numbers in `SensorCoverageCardMotion` (tested in
`SensorCoverageCardMotionTests`); the view is `SensorCoverageCardView`, on both the iPhone and the Mac.

- **Entrance.** The card rises in with the others (`dsReveal`). As it does (`onEntrance`), the
  Covered and Gaps figures count up (`RollingFigure`, the same roll as every Insights figure), the
  coverage meter under them fills from the leading edge (0.1 s in), and each of the longest gaps
  slides up with its bar growing from the leading edge, 0.18 s in and 0.06 s behind the one above.
  Once per appearance.
- **Gap bars.** Each bar is its gap's length against the longest one shown, never thinner than 4 pt
  so a 10-minute gap beside a day-long one still shows.
- **New period.** The figures roll, and the meter and bars glide to their new lengths.
- **Compare.** With "Compare to previous period" on, a thin mark fades in on the meter at the period
  before's coverage, and on each bar at the period before's gap in the same place (its longest,
  second longest, third). The bars share one scale with those marks, so turning Compare on can glide
  them shorter to make room. The badges fade in beside the figures.
- **Opening the Logbook.** The iPhone zooms the card into the Logbook around the gap and shrinks it
  back home on Back (`matchedTransitionSource`, keyed on the `aroundGap` link); the Mac cross-fades
  the dashboard to the Logbook, with a way back to the card.
- **Reduce Motion.** The rows are there at once, the meter, bars and marks fade in over 0.2 s, and
  new values cross-fade instead of gliding. Nothing slides or zooms.
- **VoiceOver.** The bars and meter are drawing only, inside the card's one stop, which reads the
  coverage, the gaps and any comparison as one line.
