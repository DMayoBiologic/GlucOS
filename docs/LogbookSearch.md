# Logbook search (iPhone and Mac)

Round 17 of the improvement loop. The iPhone Logbook's search field and chips are there to find
"that pizza last week" in a couple of taps. Everything runs on what's already on the phone (the
synced logbook and the alert records), so search works offline. Rules live in
`Sources/Engine/LogbookSearch.swift` and are covered by `LogbookSearchTests`.

## What the search reads

- **Words.** Every word has to be found somewhere in the entry. Case, accents and a plain plural
  don't matter ("PIZZAS" finds "Pizza"). Words like "that", "the" and "I had" are skipped.
- **Where it looks.** The row's title and note, a meal's foods, an insulin's name, type, site and
  purpose, a moment's tags, the kind of entry ("insulin", "meal", "site"), and "low"/"hypo" on
  anything logged with a Hypo treatment tag. Alert rows are found by their title and what was tapped.
- **Days.** One stretch of time per search: `today`, `yesterday`, `tonight`, `this morning`,
  `last night` (5 pm to 7 am), `this week`, `this month`, `last week` and `last month` (both run up
  to now, since "last week" often means four days ago), weekdays (`monday`, `fri`, `last thursday`:
  the latest one, today included unless "last"), `last 3 days`, `past 2 weeks` and `2 days ago`.
  "sat" and "sun" aren't read as days.

What the search understood shows as a chip above the list ("Since last week ✕") with how many
rows it found. Tapping the chip drops the time part and keeps the words.

## Quick filter chips

All, then whichever of these would show something: **Meals**, **Insulin**, **Lows** (Hypo treatment
tags, the food or insulin logged with one, and low alert rows), **Highs** (high and very high
alert rows, and insulin marked as a correction), **Notes** (anything with a note),
**Sites**, **Moments**, **Alerts**. One chip at a time, on top of the search.

## Highlights and the empty list

The words found are bold, on a faint wash of the row's own colour, in the row's title and its
second line. When nothing matches, the list says what was searched ("Nothing in Meals matches
“pizza” since last week.") with **Clear Filters**, and **Search All Dates** when a day was part of it.

## On the Mac

Round 22 brought the same search to the dashboard's Logbook, with the same rules (nothing here is
Mac-only maths; the two only differ in how they show it).

- **⌘F** from anywhere in the dashboard opens the Logbook with the cursor in the search field. Esc in
  the field clears the search and the chip. Both are in the ⌘? list.
- **Chips** sit in the sliding picker: All, then whichever of Meals, Insulin, Lows, Notes, Sites,
  Moments and Alerts would show something.
- **Which dates.** With nothing typed, the list keeps to the toolbar's period, as before, and so does
  a chip on its own. Any search looks across every stored entry: the words decide, and the day when
  one is named ("pizza last week", "fri"). What it understood shows beside the field
  ("Since last week ✕", or "All dates ✕") with how many rows it found. ✕ on a day drops the day
  and keeps the words. The Glucose column only fills in for rows inside the toolbar's period.
- **Highlights.** The words found are bold on a faint wash of the row's colour in the Entry, Details
  and Site columns, and in an alert row's title and detail.
- **Nothing found.** The empty list says what was searched ("Nothing in Meals matches “pizza” since
  last week.") with **Clear Filters**, and **Search All Dates** when the day or the toolbar's period
  was what narrowed it (`LogbookSearch.offersAllDates`).

## Day bars

Round 32 added each day's time in range to the Logbook, on iPhone and Mac (`DayInRange`, Engine,
tested in DayInRangeTests).

- **Where.** Under the day's name and totals in each iPhone day header, as a thin bar with
  "78% in range" beside it. On the Mac, a Day column carries the day's name, a short bar and the
  figure on that day's first (newest) row; the Time column under it shows just the time.
- **What it counts.** The same rules as "Today so far": readings averaged into 5-minute buckets,
  below the low threshold, in range (thresholds included), or above the high one. A past day runs
  midnight to midnight; today runs to now and needs an hour gone. A day needs readings in half of
  its 15-minute slots, or it gets no bar (a sensor gap shows nothing rather than a few hours
  passed off as the day). The bar is the whole day, whatever the search or chip leaves showing.
- **Colours.** Below, in and above use the range hues (coral, mint, amber), all 3:1 or more on
  every Logbook background (docs/DesignSystem.md). The figure beside it is always in words, so
  the colours never carry it alone.
- **Motion.** A bar grows from the left once, the first time its day comes on screen, then simply
  sits there when it scrolls back into view (`DrawnOnce`). Today's bar glides to its new shares as
  readings arrive. Nothing loops (§4.6 Power). Instant under Reduce Motion.
- **VoiceOver.** The iPhone header is one heading: "Tuesday 12 November, 78% in range, 4% below,
  18% above", then the day's totals. The Mac Day cell says the same; each Time cell reads its day
  and time.
- **Cost.** The figures are worked out once per data change (`DayInRangeCache`, keyed by the
  readings, thresholds, days shown and the 5-minute clock), never per frame or keystroke.

Mac: the bar only fills for days inside the readings the dashboard has loaded for the toolbar's
period, like the Glucose column.

## Day charts

Round 37 lets a day's bar open into that day's chart (`DayChart`, Engine, tested in
DayChartTests; drawn by `DayMiniChart`).

- **Where.** On iPhone, tap a day header that has a bar: the bar grows in place into a small chart
  of the day, midnight to midnight, on its target band, with doses, meals and wake-ups marked
  along the bottom. "Lowest 3.9 at 4:10 am · Highest 12.1 at 1:30 pm" takes the bar's place under
  it, beside "78% in range". Tap again and the chart shrinks back into the bar. One day is open at
  a time: opening another closes the first, so the pinned headers never stack two charts. On the
  Mac, clicking a day in the Day column shows the same chart in a popover.
- **What it draws.** Readings averaged into 5-minute buckets, as for the bar, so a day plots 288
  points at most. The line breaks where readings stop for more than 20 minutes. Today's trace
  stops at now, on a full day's axis. Markers come from the whole day's entries, whatever the
  search or chip leaves showing. On the Mac, the trace covers the toolbar's period, like the bars.
- **Motion.** The bar and the chart share one frame (`matchedGeometryEffect`), so the chart grows
  out of the bar with the emphasized spring and shrinks back into it. Under Reduce Motion the two
  cross-fade in place. The chart itself never moves once it is there. Nothing loops.
- **VoiceOver.** The header is still one heading, now also a button ("Shows the day's chart").
  Opened, it reads "Tuesday 12 November, chart. 78% in range, 4% below. Lowest 3.9 mmol/L at
  4:10 am, highest 12.1 mmol/L at 1:30 pm. Target 3.9 to 10.0. 3 entries logged."
  (`DayChartText.spoken`); the chart itself is hidden.
- **Cost.** Only the open day is worked out, once per day or readings change (`DayChartCache`).

## From the Insights cards

Round 34 joined the Insights Lows card to the Logbook, on iPhone and Mac (`LogbookLink`, Engine,
tested in LogbookLinkTests).

- **What opens.** Tapping the card's figures, or the "See the last 14 days in the Logbook" row at
  its foot, opens the Logbook on the **Lows** chip over the card's period. Only when the period
  had a low; the period picker stays its own control.
- **Which days.** The same ones the card counted: 7, 14 or 30 × 24 hours up to the newest reading,
  not from a midnight (typing "last 14 days" would start at midnight 13 days ago and miss the first
  morning). It runs on to now, so a treatment logged after the last reading still shows. Nothing is
  typed into the search field: the period shows as the usual chip ("Last 14 days ✕"). ✕ or Search
  All Dates drops it and keeps the chip; Clear Filters drops both. A day typed into the field wins
  over the card's period.
- **iPhone motion.** The card zooms into the Logbook (`navigationTransition(.zoom)`, iOS 18) and
  shrinks back into it on Back, keyed on the card rather than its period, so the way back still
  finds it after a new reading. A plain push under Reduce Motion, for every zoom on the home stack.
- **Mac.** The dashboard cross-fades from Insights to its Logbook section (instant under Reduce
  Motion). The Logbook then has "‹ Insights" at the top, which cross-fades back and scrolls to the
  Lows card. Picking another section in the sidebar ends the trip. A period on the Mac looks past
  the toolbar's period, as any search does.
- **Highs (round 37).** The Insights Highs card does the same on the **Highs** chip, over its own
  7, 14 or 30 days counted the same way (`LogbookLink.highs`). It zooms from its own card on
  iPhone, and "‹ Insights" on the Mac scrolls back to the Highs card rather than Lows. A chip a
  card opened with stays in the chip bar even when it has nothing to show, so the empty list
  still says what it's filtered by.
- **Overnight (round 39).** The Insights Overnight card opens the Logbook on an **Overnight** chip
  over its own 7, 14 or 30 days (`LogbookLink.overnight`): every entry and alert between midnight
  and 6 am local time on those days, so the nights the card counted can be read through. It opens
  whenever the card has nights to show, not only when there was a low. Overnight is a time of day
  rather than a kind of entry, so the chip bar lists it only while the card has opened on it
  (`LogbookFilter.isListed`); new entries arriving don't drop it. iPhone zoom and Mac "‹ Insights"
  work as for Lows and Highs.
- **Weekdays and Weekends (round 40).** Each side of the Insights Weekdays and weekends card is
  its own button: it opens the Logbook on a **Weekdays** or **Weekends** chip over the card's 7, 14
  or 30 days (`LogbookLink.weekPart`), with every entry and alert on those days of the week. Weekend
  days follow the device's region (`Calendar.isDateInWeekend`), as the card does. Like Overnight,
  both chips are listed only while the card has opened on them. On iPhone both sides zoom from the
  card; on the Mac "‹ Insights" scrolls back to the one card from either (`LogbookFilter.insightsCard`).
- **This week and Last week (round 41).** The Insights Week in review card now shows the two
  weeks side by side, each its own button. This week opens the Logbook on a **This week** chip over
  the last 7 days up to the newest reading (running on to now); Last week opens a **Last week** chip
  over the 7 days before that (`LogbookLink.week`), the same days the card counted
  (`WeekInReview.interval`). Both chips keep every entry and alert, so the period does the
  narrowing. Like Overnight they're listed only while the card has opened on them. On iPhone both
  weeks zoom from the card; on the Mac "‹ Insights" scrolls back to Week in review from either.
- **Longest streak (round 42).** The Insights In-range streaks card is one button: it opens the
  Logbook on a **Longest streak** chip over the longest run's days, local midnight of its first day
  to midnight after its last (`LogbookLink.bestStreak`), labelled with those days ("23 Aug – 9 Sep").
  The chip keeps every entry and alert, so the period does the narrowing. A run that takes in today
  runs to tonight's midnight, so something logged after the last reading still shows. Listed only
  while the card has opened on it; iPhone zoom and Mac "‹ Insights" work as for the other cards.
  With no day at 70% yet the card has nothing to open, so it isn't a button.
