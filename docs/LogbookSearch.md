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

## Switching chips

Round 51. Picking a chip, on iPhone or Mac, moves one highlight: it slides on a spring from the old
chip to the new one (matched geometry), its colour turning to the new chip's on the way. The kind
chips and the tag chips each have their own highlight. The list doesn't slide its rows about: the
old rows fade out (0.09 s), the list switches to the new rows, and those fade in (0.2 s), so the
rows have settled before the highlight has. VoiceOver then says how many rows are showing, once
("12 entries", "1 entry", "No matches"); a quick run of taps only speaks for the last one.

Under Reduce Motion the highlight and the list switch at once, with the same one announcement.
Opening the Logbook from a card or the "last logged" line, and a calendar jump that clears the
chips, switch the list straight away and say nothing extra. The list follows the chips through
`LogbookFilterPick` (Engine, tested in LogbookSearchTests).

## Highlights and the empty list

The words found are bold, on a faint wash of the row's own colour, in the row's title and its
second line. When nothing matches, the list says what was searched ("Nothing in Meals matches
“pizza” since last week.") with **Clear Filters**, and **Search All Dates** when a day was part of it.

## While you type

Round 70. The list follows the typing instead of jumping on each letter, on iPhone and Mac. Display
only: what the search finds is unchanged. Timings and wording live in `LogbookSearchMotion` (Engine,
tested in LogbookSearchMotionTests).

- **Highlights fade.** Letters a new keystroke finds fade into their wash (0.25 s), and letters no
  longer found fade out of it, while the highlight that was already there holds still, so typing
  "piz" → "pizz" only lights the new "z". Bold switches at once, so a line never reflows mid-fade
  (`SearchHighlightText`, which Logbook rows use in place of a plain highlighted `Text`).
- **The count rolls.** "3 found" rolls digit by digit to its new value, down as the search narrows
  and up as it widens.
- **Rows that stop matching shrink out.** They scale down a little and fade (0.14 s) before the list
  closes up behind them on its usual row animation; a day whose rows all go fades its header with
  them. The list follows a moment behind the field (`listedQuery` on iPhone, `listedSearch` on Mac)
  only while something is leaving: rows a wider search finds slide in at once, and a row that
  matches again before it has gone grows back. Opening from a card, the "last logged" line or a
  calendar jump still shows the rows straight away. On the Mac the table's cells shrink and fade;
  the table itself closes the gap.
- **Reduce Motion.** Highlights, the count and the rows switch at once.
- **VoiceOver.** Once typing pauses (0.8 s), VoiceOver says the count once: "3 found", "1 found" or
  "No matches". The same search after a pause (typed on, then deleted back) says nothing new, and an
  empty field says nothing.

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
  readings arrive. Nothing loops (§4.6 Power). Round 104 (`DayBarEntrance`, DayInRangeTests): on
  iPhone the grow waits until half the header is inside the list, so a header prepared just off
  screen doesn't spend it unseen (if the list never reports it, it draws after 1.2 s); the Mac
  grows each bar as the Logbook opens. A refresh, a rebuilt header or a period change never
  replays it. Under Reduce Motion the bar fades in over 0.25 s instead, and a changed split
  cross-fades rather than jumping.
- **VoiceOver.** The iPhone header is one heading: "Tuesday 12 November, 78% in range, 4% below,
  18% above", then the day's totals. The Mac Day cell says the same; each Time cell reads its day
  and time.
- **Cost.** The figures are worked out once per data change (`DayInRangeCache`, keyed by the
  readings, thresholds, days shown and the 5-minute clock), never per frame or keystroke.

Mac: the bar only fills for days inside the readings the dashboard has loaded for the toolbar's
period, like the Glucose column.

### When an entry changes (round 68)

Adding, editing, deleting or undoing an entry (or one arriving by sync) moves the day's header
instead of swapping it, on iPhone and Mac.

- **Totals roll.** The iPhone header's "14 u · 120 g carbs" (and "4 entries · …" on a folded day)
  and the Mac Day cell's new "14 u · 120 g" after the bar roll digit by digit to their new values
  on the `.arrival` spring: upward when the day grows, downward when it shrinks (`DayTotalsRoll`,
  Engine, tested in LogbookDayTotalsTests). The Mac's folded line rolls its count the same way.
  Totals are the whole day, whatever the chips or search leave showing, so a filter never rolls
  them. Display only: the same sums the header always showed.
- **Rebuilt headers keep their place.** The Mac's Day cell moves to the day's new first row when a
  newer entry joins it, and the iPhone's pinned headers are rebuilt as the list changes, so each
  screen remembers what every day last showed (`DayTotalsMemory`, and `DrawnOnce.lastFigures` for
  the bar). A rebuilt header starts from the old figures and rolls or glides to the new ones.
  Opening the Logbook rolls nothing.
- **The bar glides.** A day's time in range comes from its readings, so an entry alone doesn't
  change it, but whenever the split does change (new readings, a rebuilt header catching up) it
  glides to its new widths on the emphasized spring instead of jumping.
- **Grouped rows and folded days.** Totals count each entry once, grouped (#282) or not, and a
  folded day (round 63) rolls its count and totals in its header like an open one.
- **Reduce Motion.** The new figures and split replace the old at once.
- **VoiceOver.** One low-priority announcement per change, after the undo toast or "Saved":
  "Today now 14 units, 120 grams of carbs, 4 entries" (`DayTotalsText`, tested). A sync or undo
  touching several days at once says only the first (1.5 s apart). The Mac Day cell's value
  reads the same totals.

## Day charts

Round 37 lets a day's bar open into that day's chart (`DayChart`, Engine, tested in
DayChartTests; drawn by `DayMiniChart`).

- **Where.** On iPhone, tap the bar on a day header (round 44 moved taps on the day's name to the
  calendar, below): the bar grows in place into a small chart
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

## Day breakdown

Round 94 puts the bar's split into numbers (`DayInRange.parts`, `DayInRangeBreakdownText`, Engine,
tested in DayInRangeTests; drawn by `DayRangeBreakdown`).

- **Where.** On iPhone, under an opened day's chart: three small columns, Below, In range and
  Above, each with its colour dot, share and how long it lasted ("4% · 1 h", "78% · 18 h 40 min").
  On the Mac the same row sits under the chart in the Day popover, and hovering the Day cell shows
  it as the tooltip: "In range 78% · 18 h 40 min, below 4% · 1 h, above 18% · 4 h 20 min. Click
  to show the day's chart." The row stacks at the largest text sizes.
- **What it counts.** Each share of the day's span: 24 hours for a past day (23 or 25 across a
  clock change), midnight to now for today. Below and above are rounded to the nearest 5 minutes
  (never to nothing if it happened) and in range takes the rest, so the three add up to the day.
  Shares, not reading counts, so 15-minute LinkUp history reads the same as 1-minute readings.
- **Days with gaps (round 95).** The hours spread the shares over the whole span, so a day with
  readings in only part of its 15-minute slots would read as if the missing hours went the same
  way. `DayInRange.coverage` is the share of slots with a reading and `DayInRange.times` decides
  the hours: 90% or more, as measured; 50% to 90%, estimates ("78% · ≈18 h 40 min", VoiceOver
  "about 18 hours 40 minutes") with one line under the row, also ending the tooltip and VoiceOver
  label: "Hours estimated from readings over 72% of the day."; under 50%, percents only. Days
  under 50% get no bar today anyway, so that case is a guard. Today counts its slots up to now.
- **VoiceOver.** Still one element: the opened header (and the Mac popover) now reads "78% in
  range, 18 hours 40 minutes. 4% below, 1 hour" in place of the bare shares
  (`DayChartText.spoken(breakdown: true)`). The row itself is hidden.
- **Motion.** None. It arrives with the chart (cross-fade) and its figures change at once.

## Compared with your usual

Round 103 says when a day stood out against the person's own recent days (`DayVsUsual`,
`DayVsUsualText`, Engine, tested in DayVsUsualTests; drawn by `DayVsUsualNote`).

- **Where.** On iPhone, one quiet line under the day's name (and its note, if any): an arrow and
  "+12 vs your usual" or "−15 vs your usual". On the Mac the same note follows the Day cell's
  totals, with the sentence as its tooltip. Secondary text, never the low or high colours: a day
  below its usual is information, not an alarm.
- **What it compares.** The day's time in range, the bar's own figure, against the median of the
  14 days before it that have a figure. Days with readings over less than half their 15-minute
  slots have none, so they are neither compared nor counted, and at least 7 of the 14 must have
  one. The note shows when the rounded percents differ by 10 or more points, so it agrees with
  the figures on screen. Today isn't compared until it's over. Both platforms read the whole
  archive (up to 90 days), so the Mac's toolbar period never cuts the usual short.
- **Tap or click.** Opens a small popover: what the usual is ("the middle time in range of the 14
  days before this one, counting the 12 that had enough readings: 68%"), the day against it, and
  when a note shows.
- **VoiceOver.** Said once, in the day header's value on iPhone and the Day cell's value on the
  Mac ("12 points above your usual time in range of 68%"). The note itself is hidden; the day
  offers "How Your Usual Is Worked Out", which opens the same popover.
- **Motion.** The note fades in and out with the day's figures (`dsAnimation`), at once under
  Reduce Motion. Nothing loops.
- **Work.** One `DayInRangeCache` per Logbook holds the listed days and the 14 before each, worked
  out once per data change or 5-minute clock tick.

## Jump to a date

Round 44 adds a compact month calendar to the Logbook, on iPhone and Mac (`LogbookCalendar` and
`LogbookJump`, Engine, tested in LogbookCalendarTests; drawn by `LogbookCalendarView`, shared).

- **Where.** On iPhone, tap a day header's name or totals (a small calendar glyph sits beside the
  name): the calendar pops over the header, open on that day's month with the day filled. The bar
  under it still opens the day's chart. On the Mac, ⌘J in the Logbook (or the Jump to Date button
  beside the search) opens the same calendar. Elsewhere in the dashboard ⌘J is still Back to Now.
- **Which days.** Days with nothing logged are dimmed and can't be picked; alerts alone don't
  count. Today is ringed, later days are dimmed. The chevrons step a month at a time, from the
  first month with an entry up to this one. **Latest** goes to the newest day with entries.
  VoiceOver reads each day as "Tuesday 12 November, 3 entries" or "nothing logged".
- **Landing.** Picking a day closes the calendar and the list springs (the emphasized spring) so
  that day's header sits at the top, then the header lights once and VoiceOver says "Showing
  Tuesday 12 November". Under Reduce Motion the list dips out, moves, and fades back instead. If
  the search or a chip is hiding that day's entries, they're cleared first so there's a day to
  land on (`LogbookJump.plan`). On the Mac, a day outside the toolbar's period moves the period
  so it ends with that day (24 hours at least), and that day's rows light once as they arrive.
- **Motion and colour (round 86).** Besides the chevrons, a sideways swipe or drag steps the month
  (left for later, right for earlier, 44 pt and mostly sideways); the grid follows the finger and
  rubber-bands towards a month it can't show. Each pickable day's circle washes in tinted by that
  day's time in range, in the day bars' colours: in range when 70% or more of it was, otherwise
  low or high by whichever it spent longer in, stronger the bigger that share. A day without enough
  readings keeps the plain circle. The wash runs from the 1st, 12 ms apart, all in within 0.4 s.
  The selected day's mark springs in with a ring around it. VoiceOver adds the share ("3 entries,
  78% in range"), so the colour never carries it alone. Under Reduce Motion the grid cross-fades,
  the tints fade in together and the mark fades; nothing slides, follows or springs. Rules in
  `LogbookCalendarMotion` (LogbookCalendarTests).

## Back to today

Round 91 adds a quick way back to the top of the Logbook (`LogbookToday`, Engine, tested in
LogbookTodayTests).

- **iPhone.** Once the list has scrolled more than 0.8 of a screen from the top (360 pt at least),
  a small **Today** pill drops in under the navigation bar. It goes again once the list is back
  within 0.4 of a screen (180 pt at least), so it never blinks at one spot. A tap springs the list
  (the emphasized spring) back to the very top, chips included, lights the newest day's header once,
  plays the light choice tap and VoiceOver says "Showing Today". When nothing was logged today (or
  the search leaves today out) the pill says **Latest** and goes to the newest listed day. It hides
  in Select mode and while an entry is open.
- **Mac.** In the Logbook the toolbar has a **Today** button, also ⌘T. If the toolbar's period is
  in the past it moves back to now first; the table then springs to its newest row and that day's
  rows light once.
- **Reduce Motion.** The pill just appears and goes, and the list or table moves at once, with no
  spring and no dip.
- **VoiceOver.** One button, "Back to today" (or "Back to the latest entries").

## Folding a day

Round 63 lets a day fold down to its header, on iPhone and Mac (`LogbookCollapse`,
`LogbookFolds` and `LogbookFolding`, Engine, tested in LogbookCollapseTests).

- **Where.** On iPhone, tap the chevron before a day header's name. The name still opens the
  calendar and the bar still opens the day's chart. On the Mac, click the chevron in the Day
  column, or right-click any line of the day for Collapse Day. A folded day is one line there;
  double-click or Return on it (or Expand Day) opens it.
- **What stays.** The header keeps its time-in-range bar and adds how many rows it holds:
  "4 entries · 1 alert · 14 u · 120 g carbs" on iPhone, "4 entries · 1 alert" in the Mac's Entry
  column. The count is what the chips and search leave listed for that day.
- **Motion.** The rows below slide up on the emphasized spring and come back down on reopen; the
  chevron turns with them. Under Reduce Motion the list dips out, switches and fades back, so
  nothing slides. VoiceOver reads the header's value as "Collapsed, 4 entries" or "Expanded",
  offers Collapse Day / Expand Day as an action, and says "Yesterday collapsed, 4 entries" once.
- **Kept.** Folded days are kept per device in UserDefaults (`logbook.collapsedDays`), not
  synced, for 120 days. Today never starts folded: each time the Logbook opens, today is taken
  out. A search has its own folds that start with every day open, so every match shows; clearing
  it brings the kept folds back. Jumping to a date, or opening an entry from elsewhere (the "last
  logged" line, the Mac popover), reopens that day.
- **Safety.** Folding hides rows, nothing else: export, sync and the day totals still see every
  entry, and a folded day's lines leave the Mac selection, so Delete never reaches them.

## Day notes

Round 70. A few words about a whole day, such as "sick day", "travel" or "new sensor", kept with
the day rather than with any one entry. Rules and words in `Sources/Engine/DayNotes.swift`
(`DayNotes`, `DayNoteText`), tested in `DayNotesTests`.

- **Writing one.** iPhone: hold a day header for **Add Note** (or **Edit Note** and **Remove
  Note**), next to Collapse Day and Jump to a Date. A tap on the header already opens the calendar
  and a tap on its bar opens the day's chart, so the note lives in the header's menu; once a note
  is there, tapping it edits it. Mac: right-click the Day cell (any line of the day works, folded
  or open) for **Add Note…**; clicking the note edits it. Both ask in a small prompt with one text
  field. Notes are one line, at most 60 characters; an empty note removes it.
- **Where it shows.** One quiet line under the iPhone day header, with a note icon, and after the
  totals in the Mac Day cell, its whole text in the tooltip. In the Insights **Best and toughest
  days** card a noted day shows the note as a small caption under its chart. A shared card picture
  leaves notes out.
- **Search.** A day's note is searched with every row of that day: "sick" lists everything logged
  on a sick day, "sick pizza" the pizza eaten on one, and a typed day still narrows it. The note's
  matching words are lit like a row's.
- **Sync.** Notes sync like Logbook records, one record per date (docs/LogbookSync.md "Day notes").
  The key is the local calendar date, so a note stays on its day after a time zone change.
- **Motion and VoiceOver.** On iPhone the note slides in under the name on the emphasized spring
  and slides out when removed; under Reduce Motion it fades. On the Mac it fades in, at once under
  Reduce Motion. VoiceOver reads it with the header ("Note: sick day", before the totals), offers
  Add Note or Edit Note as an action, says "Note added to Today" (changed, removed) once after a
  save, and reads it after the day on the Best and toughest days tiles.

## Comparing two days

Round 74. Two days' readings over one chart, with each day's figures side by side. Rules and
words in `Sources/Engine/DayCompare.swift` (`DayCompare`, `DayCompareText`, `DayComparePair`),
tested in `DayCompareTests`; the view is `Sources/App/Logbook/DayCompareView.swift`.

- **Opening it.** From the jump-to-a-date calendar, **Compare** in its footer switches the grid to
  picking a second day: days with at least 12 readings are lit (`DayCompare.readingDays`; an hour of 5-minute readings),
  the day it was opened from is filled and can't be picked, and **Back** returns to jumping. A
  day's own menu offers **Compare with Another Day…**, which opens the calendar already comparing:
  hold a day header on iPhone (next to Add Note and Jump to a Date), or right-click any line of a
  day on the Mac. On the Mac the toolbar calendar compares the newest listed day.
- **The chart.** Midnight to midnight by the wall clock, on the target band. The first day is a
  solid blue line, the second a dashed magenta one, so they tell apart without colour. Points are
  the day bars' 5-minute means; a gap of over 20 minutes breaks a line.
- **Clock changes.** Readings sit at their wall-clock time, so 6 pm is over 6 pm on a 23- or
  25-hour day. The skipped hour is a gap; the repeated hour draws over itself as its own run, so
  no line doubles back. Today stops at now.
- **Figures.** Time in range (the day bar's figure and coverage rule, "–" when a day has too few
  readings), the average of the 5-minute means, and the number of lows and highs (runs of 15
  minutes or more outside the lines, the Insights rule). Nothing says which day was better.
- **Stepping and swapping.** The chevrons beside the second day move it a day at a time, skipping
  the first day and days without readings, never past today. The swap button beside the first
  day's name trades the two days' places (solid and dashed lines swap too).
- **Motion and VoiceOver.** Round 75 (`DayCompareMotion`, Engine, tested in
  `DayCompareMotionTests`): the second line draws in from midnight on the left when the comparison
  opens. Stepping or swapping cross-slides each changed line: the old one slides 150 minutes away
  and fades while the new one slides in from the other side (a later day from the right), and the
  side-by-side figures roll with `rollingDigits`. The chart is redrawn per frame from cut and
  shifted runs, so Swift Charts never animates on its own. Under Reduce Motion the lines and
  figures switch at once. VoiceOver reads the chart as one element naming both days and the
  target, then one summary per day ("Today: 78% in range, average 7.2 mmol/L, 1 low, 2 highs."),
  hears "Comparing Today with Monday 11 November." once when it opens and once per step or swap,
  and has Compare with Another Day as a header action on iPhone and a Day cell action on the Mac.
  The calendar's Compare says
  what to pick.
- **Shared cursor.** Round 87 (`DayCompareScrub`, Engine, tested in `DayCompareScrubTests`):
  drag along the chart on iPhone, or point at it on the Mac, and one line sits across both days
  at a clock time, snapped to the nearest reading of either day (nothing shows over a stretch of
  more than 20 minutes with no reading on either day). The row above the chart reads that time,
  each day's value there by its swatch ("–" where a day has no reading within 5 minutes), and how
  far apart they are ("1.1 higher" beside the higher line's swatch, or "Same"). The solid line
  gets a circle and the dashed one a diamond. iPhone ticks `scrubSnapped` when the cursor lands
  and `scrubRangeEdge` when either line crosses the low or high line; readings themselves don't
  tick. VoiceOver hears each stop once per touch ("6:15 pm. Today 7.2 mmol/L, Monday 11 November
  6.1 mmol/L. Today 1.1 mmol/L higher."), and can swipe up or down on the chart to move the cursor
  an hour at a time. It shows what was there only, never which day was better.
- iPhone: a sheet with Done (medium and large detents). Mac: a sheet with Done (Return or Esc).

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
- **Best day and Toughest day (round 43).** Each day on the Insights Best and toughest days card is
  its own button: it opens the Logbook on a **Best day** or **Toughest day** chip over that day,
  local midnight to midnight (`LogbookLink.bestDay`), labelled with the day ("Yesterday",
  "Sat 12 Sep"). The chips keep every entry and alert, so the period does the narrowing. Listed only
  while the card has opened on them; on iPhone either day zooms from the card, and on the Mac
  "‹ Insights" scrolls back to the card from either.
- **A tag (round 48).** Each tag on the Insights Tags card is its own button: it opens the Logbook
  on that tag's chip over the card's 7, 14 or 30 days (`LogbookLink.tag`), with no kind chip, so
  every kind of entry carrying the tag shows (alerts carry no tags, so they drop out). The link's
  `filter` is an unlisted **Tagged** chip (`LogbookFilter.tagged`) that only says where it came
  from: the iPhone zooms from the card on it and the Mac's "‹ Insights" scrolls back to the card.
- **An hour of the day (round 55).** Each cell on the Insights Time in range by hour card is its own
  button: it opens the Logbook on everything logged in that local clock hour on every day of the
  card's 7, 14 or 30 days (`LogbookLink.hour`). There's no kind chip: the hour rides on the period
  chip ("7–8 am · Last 14 days", `LogbookQuery.Period.hour`), so its ✕ drops hour and days together.
  The link's `filter` is an unlisted **Hour of day** chip (`LogbookFilter.hourOfDay`) that only says
  where it came from, for the iPhone zoom and the Mac's "‹ Insights". The hour is read off the clock,
  so on the night the clocks go back both passes of the repeated hour match.

- **While you were away (round 64).** Not a card: the line under the reading after 2 hours or more
  unseen (docs/WhileAway.md) opens the Logbook over the span it covers, under a "While you were
  away" period chip with no kind chip (`LogbookLink.whileAway`, unlisted `LogbookFilter.whileAway`),
  so every entry and alert in the gap shows. A plain push on iPhone; on the Mac the dashboard opens
  on its Logbook with no "‹ Insights".

## Tags

Each tag in use gets its own chip after the kind chips, on iPhone and Mac. See docs/LogbookTags.md.

## Grouped rows

A meal and the insulin for it, logged within 15 minutes of each other, show as one row in the
Logbook on iPhone and Mac: "Meal and insulin", what each part was ("45 g · Toast + 4 u NovoRapid")
and the time. The rules are `LogbookGrouping` in Sources/Engine/LogbookGrouping.swift, tested in
LogbookGroupingTests.

- **What groups.** Only meals and doses, and a group needs at least one of each. Two doses close
  together never fold into one row, so a second dose is always its own row; two meals alone don't
  group either. Site changes, moments and alerts always stand alone.
- **When.** Neighbouring rows only: anything listed between two entries (an alert, a moment) keeps
  them apart, so nothing moves out of time order. A group starts at its first entry and takes in
  what follows while the whole group fits in 15 minutes, on the same day.
- **Filters stay per entry.** Grouping runs on what the chips, tags and search leave showing. The
  Insulin chip shows the doses alone; a search that finds only the meal shows the meal alone.
- **Opening a group.** iPhone: tap the row, and the entries open out under it, indented, each
  with its own swipes (Log Again Now, Delete), menu and card. The combined row's long-press menu
  has Edit, Log Again Now and Delete for each entry. Mac: click the chevron, double-click the line
  or press Return; the right-click menu has each entry's actions, and Delete on a selected group
  line deletes its entries (with Undo). Opening and closing uses the list's usual motion, instant
  under Reduce Motion.
- **Going to one entry.** The "last logged" line on iPhone and the popover's reveal on the Mac open
  the entry's group first, so the entry itself opens or is selected.
- **VoiceOver** reads a group as one item ("Meal and insulin, 2 entries: 45 g · Toast, 4 u
  NovoRapid", then the time and Collapsed or Expanded), with Expand or Collapse as its action, and
  says "Showing 2 entries" or "Entries grouped" once after.
- **Export and sync** are untouched: the PDF, the CSV and the sync records stay one per entry.
  Grouping never changes an entry; the totals are the logged amounts added up, as the day headers do.

## Swiping a row (round 95)

On iPhone, a Logbook row's swipes are drawn by GlucOS (`PhoneLogbookSwipe`, rules in
Sources/Engine/LogbookSwipe.swift, tests in LogbookSwipeTests). What they do is unchanged from #249:

- **Swipe left to delete.** A full swipe (past 55% of the row, at least 140 pt) deletes on letting
  go, and the Undo toast offers it back. A shorter swipe (past 38 pt) leaves the trash button open
  to tap.
- **Swipe right for Log Again Now.** It never logs on letting go, however far or fast: past 38 pt
  the button stays open (76 pt wide), and only a tap on it logs. Past 76 pt the row resists.
- **Motion.** The icon grows from 40% to full size and fades in as the row opens, and the trash
  grows a touch more once letting go would delete. A soft tick (`HapticEvent.swipeThreshold`,
  light impact 0.4) plays once each time the drag passes the point where letting go acts (38 pt on the right, the
  delete point on the left), never
  again while the finger rests there (10 pt hysteresis). Under Reduce Motion the icon is there at
  full size as soon as the row moves, and the row snaps instead of springing.
- **One open at a time.** Swiping another row, scrolling, or tapping the open row shuts it.
- **VoiceOver** keeps Log Again Now and Delete as the row's actions; the icons are hidden from it.
- **Mac** is unchanged: right-click a line for Log Again Now and Delete.

## Selecting several entries (round 71)

Delete or tag several entries at once (`LogbookSelection`, `LogbookBulkTag` in
Sources/Engine/LogbookSelection.swift).

- **iPhone.** Use Select Entries in the Logbook's options menu, or Select in a row's long-press
  menu, which also picks that row. Each row gets a checkmark circle, and a tap picks it or lets it
  go. The title shows "3 Selected", Select All / Deselect All sits top left, and Done leaves. The
  bottom bar holds Tag, the count and Delete. Swipes, opening a row and alert rows are off while
  selecting (alerts dim, because they're records). Delete ends Select mode, as in Mail. Tag keeps
  the selection so another tag can follow.
- **Mac.** The table's own Shift-click, ⌘-click and Shift-arrows pick several rows. The bar above
  the table shows "3 entries selected", a Tag menu and Delete 3. The right-click menu has the same
  Tag menu and Delete N Entries, and ⌫ still deletes.
- **Groups.** A meal and its insulin shown as one row are picked as a unit. On iPhone groups stay
  closed while selecting, so there's one checkmark for both. Counts are always entries, not rows.
- **Hidden rows never count.** A search, a chip, a folded day or a delete synced from the other
  device takes rows out of the selection, so Delete only reaches what's on screen.
- **Tag menu.** It offers the usual tags, with a checkmark when every picked entry has it, plus
  New Tag… and Remove Tag (the tags the picked entries hold). Only the tags change. Entries that
  already show under the tag (including a moment's matching "What else is going on?" choice) or
  already hold 8 tags are skipped. If nothing changes, VoiceOver says "Already tagged Exercise".
- **Undo.** One toast: "3 entries deleted" or "Added Exercise to 3 entries". Undo brings every
  entry back exactly as it was, under the same id, synced like any edit (docs/LogbookSync.md).
- **VoiceOver.** Each row reads as one item, Selected when picked, with "Adds it to the selection"
  as the hint. Every pick announces "3 entries selected". On the Mac the count is announced once
  the selection settles (0.45 s), from 2 entries up.
- **Reduce Motion.** Checkmarks slide in from the leading edge and fill with a symbol swap, and the
  count rolls. Under Reduce Motion they fade and swap instantly.

### Deleting several entries (round 73)

When Delete takes two or more rows, they go one after another instead of all at once
(`LogbookCascade` in Sources/Engine/LogbookCascade.swift).

- **Out.** Rows shrink out from the top, 45 ms apart, each in 0.2 s. A long selection tightens
  the step so the last row starts by 0.3 s, so nothing takes longer than about half a second. A
  meal and its insulin shown as one row move as one.
- **Then it settles.** The store deletes the entries only once the last row has gone. The list
  closes up, the day totals roll and the Undo toast rises together, after the rows. The day's
  time in range bar comes from readings, so it doesn't move for an entry.
- **Undo.** The same rows come back the other way round, bottom row first, growing in on the same
  steps. The day totals hold until the last row is back, then roll once. If something else
  arrives at the same moment (a sync), or only one row comes back, rows arrive as usual.
- **Both apps.** iPhone Select mode's Delete, and the Mac's ⌫ and Delete N Entries on a selection.
  Undo is the toast or ⌘Z.
- **VoiceOver.** The toast says "3 entries deleted" once. Undo says "Put back 3 entries" once, and
  holds back the day totals line that would otherwise follow it. Nothing is said per row.
- **Reduce Motion.** No cascade: the rows go, and come back, at once, as for a single delete.
  VoiceOver still hears each line once.

## Editing an entry

Opening an entry's edit sheet from the Logbook comes out of the row it was opened from and goes
back into it, rather than sliding up from the bottom of the screen. The rules are
`LogbookEditMorph` in Sources/Engine/LogbookEditMorph.swift, tested in LogbookEditMorphTests.

- **iPhone.** The sheet zooms out of what was tapped and shrinks back into it on Cancel, Save or a
  swipe down (the system zoom transition). That's a row on the home screen's Logbook card, Edit in
  a row's long-press menu in the full Logbook, the Edit button on an opened entry's card, or Edit
  for one entry in a grouped row's menu (from the grouped row). Each surface has its own zoom
  source (`LogbookEditMorph.sourceID`), so the home card's row and the same entry's row in the full
  Logbook underneath never compete. If the row has gone by the time the sheet closes (the entry
  moved to another day), the sheet closes the usual way.
- **Mac.** Edit… (menu, double-click or Return on a line) opens the editor in place over the
  dashboard: it fades in over a light scrim, settling from 97% size, and fades out again on
  Cancel, Save or Delete. Nothing behind it takes clicks, keys or VoiceOver while it's open. A new
  entry still opens as the usual sheet.
- **Reduce Motion.** A plain cross-fade on both: on iPhone the sheet appears without its slide and
  its content fades in; on the Mac nothing scales.
- **VoiceOver.** Once the sheet has landed (0.55 s, or 0.25 s under Reduce Motion) focus moves to
  its title ("Edit Insulin", "Edit Food"…), which is marked as a header.
- **Power.** It plays once per open and once per close. Nothing loops.

### Sensor coverage

Round 81: the Insights Sensor coverage card opens the Logbook around its longest gap, an hour
either side, on the unlisted **Around a gap** chip (`LogbookFilter.aroundGap`). No kind chip; the
period chip ("Around Yesterday 2:10 am") says it all. See [SensorCoverage.md](SensorCoverage.md).
