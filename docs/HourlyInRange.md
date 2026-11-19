# Time in range by hour

An Insights card on iPhone and Mac, after **Your usual day**: a strip of 24 cells, one per hour of
the clock, each coloured by its time in range over the last 7, 14 or 30 days. Tapping a cell opens
the Logbook on that hour across the same days.

Code: `Sources/Engine/HourlyInRange.swift` (maths, words, cache) and
`Sources/App/Views/HourlyInRangeCardView.swift` (the card). Tests: `HourlyInRangeTests`.

## Rules

1. Readings are averaged into 5-minute buckets over the `days` × 24 hours up to the newest reading,
   as for Lows, Highs and Overnight.
2. Each bucket goes to the local clock hour it starts in. On the day the clocks go forward the
   skipped hour has nothing that day; on the day they go back the repeated hour gets both passes.
   Zones on a half hour (Adelaide, India) still line up, because 5-minute buckets sit on local
   5 minutes there too.
3. An hour counts on a day when half its twelve buckets have readings. A cell needs 3 such days,
   otherwise it's drawn empty (dashed outline, "not enough readings"). The card needs 3 days.
4. Colour: 70% or more in range uses the in-range hue. Under that a cell takes the high or low hue,
   whichever side it spent more time on: strong under 50%, faint from 50% to 70%.
5. The headline names the hour most in range and the hour least in range (earliest on a tie),
   with the overall figure and how many hours reached 70%.

Observational only: it never suggests a change to insulin, food or any setting.

## Layout

- One row of 24 when each cell can be at least 22 pt wide (the Mac); two rows of 12, midnight to
  noon over noon to midnight, where it can't (the iPhone), so every cell stays tappable.
- Ticks at 12a, 6a, 12p, 6p (one row) or every 3 hours (two rows).
- The Mac shows each hour's figure as a tooltip.

## Accessibility

VoiceOver reads the summary as one stop, then each hour as its own button: "7 am to 8 am, 54 percent
in range, 30 percent above, 16 percent below, over 12 days", with the hint that it opens the
Logbook. The legend and ticks are hidden from VoiceOver. Colour changes cross-fade; with Reduce
Motion on they cross-fade all at once instead of in a step from left to right.

## Motion

- First reveal (iPhone and Mac Insights, where `figuresCountUp` is on): the cells fill in a
  left-to-right wave as the card rises in (`onEntrance`), each rising from its baseline and fading
  in on the arrival spring. 0.12 s lead, 0.45 s from first cell to last; in two rows both rows fill
  together, column by column, so both layouts take the same time (`HourlyCellMotion`).
- Period change: each cell cross-fades to its new colour over 0.3 s, a step after the one to its
  left, 0.18 s from first to last. Cells whose colour doesn't change stay still.
- Reduce Motion: nothing moves or steps. On the first reveal every cell fades in together over
  0.25 s after the same 0.12 s lead, and on a period change every changed cell cross-fades to its
  new colour together over 0.25 s (`HourlyCellMotion.reducedFade`).
- Plays once per appearance and never loops. Never in a shared picture. Only the drawing moves: every hour's button, its order, label and
  value are there for VoiceOver from the start.

## Works with

- **Card order and hiding** (docs/InsightsLayout.md): `InsightsCard.hourlyInRange`, after Your
  usual day on both screens, synced per screen like the other cards.
- **Share Card…** (docs/InsightsShare.md): the period comes from `insights.hourlyDays`.
- **Compare to previous period** (docs/InsightsCompare.md): the overall figure gets a badge; each
  hour's change is spoken, and a line names the hour that moved most.
- **Logbook** (docs/LogbookSearch.md, "An hour of the day").
