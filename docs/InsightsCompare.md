# Compare to previous period

An optional switch on both Insights screens. When it's on, each card with a period puts a small up
or down figure beside its headline numbers: how much they moved from the period of the same length
just before. Off by default; the choice is kept per device (`insights.comparePrevious`).

## Where

- **iPhone**: a "Compare to previous period" switch at the top of Insights.
- **Mac**: a checkbox beside **Customise Cards…** on the Dashboard's Insights page.

| Card | Compared |
| --- | --- |
| At a glance (iPhone) | Time in range (under the range bar), average |
| Lows | Number of lows |
| Highs | Time above, number of highs |
| Overnight | Time in range, lows |
| Weekdays and weekends | Each side's time in range |

Week in review is left as it is: it already sets this week against last week. In-range streaks,
Best and toughest days, Tags, Your usual day, Mornings and Forecast accuracy have no like-for-like
earlier figure, so they show nothing extra.

## Rules (`Sources/Engine/InsightsDelta.swift`)

- The previous period is the card worked out again on readings from two periods back to one period
  back from the card's newest reading. Its own newest reading must be within a day of where the
  current period starts.
- It needs readings on 4 of every 7 of its days (as Week in review asks of last week). At a glance
  needs readings across 4 of every 7 hours of the window before. Short of that, nothing shows.
- Shares change in points and read "Same" when they round to the same percent. Counts are the same
  when equal. The average is the same within 0.1 mmol/L or 1 mg/dL.
- Green is better, amber worse, grey neither: more time in range, less time above, fewer lows and
  fewer highs are better. The average is better when it moved closer to the middle of the target
  range, worse when it moved away.
- Observational only. It never suggests a change to insulin, food or settings.

## Accessibility and motion

VoiceOver reads each change in words: "Lows down 2 on the previous 14 days, better." Cards that read
as one stop add these sentences to their value. Badges fade in and out with the switch
(`DSMotion.standard`), cross-fade under Reduce Motion, and the figures roll like the rest of
Insights. The previous period is worked out off the main thread only while the switch is on.
