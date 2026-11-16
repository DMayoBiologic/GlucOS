# Logbook export for clinic visits (iPhone)

Round 23 of the improvement loop. The Logbook's share button (top right) opens **Export for a
clinic visit**: pick the days, pick PDF or CSV, then share the file through the usual share sheet
(Mail, Messages, AirDrop, Save to Files, Print).

## Days

14, 30 or 90 days up to today, or a custom From/To. Whole calendar days in the phone's time zone.
A custom range never ends after today and is capped at 90 days, the most the phone keeps; the
latest 90 are kept. The footer shows the dates and how many entries fall in them.

## PDF summary (A4)

Page 1 is the summary, so it prints as one sheet:

- **Glucose.** Time in range (the person's own target), average, lows (runs below the low
  threshold of 15 minutes or more, as in Insights), GMI in % and mmol/mol, below range with very
  low (< 3.0 mmol/L), above range with very high (> 13.9 mmol/L), variability (CV and SD), and
  sensor data (share of 15-minute slots with a reading, and days with readings). Then one bar of
  time in each band, each band labelled with its share so it reads in black and white.
- **Logged.** Doses and units, food entries and carbs, each with a per-day figure, site changes and
  hypo treatments. These are sums of what was logged, nothing more.
- **Your usual day.** The Insights card's pattern (`DayPattern`) worked out over the chosen days:
  middle line, middle half, 8 in 10 readings, the target band, and the card's lines under it. It
  needs 5 days of readings, as the card does.

Then **Entries**, on a new page: every entry oldest first, grouped by day with the day's units
and carbs in its heading. Time, type, details (insulin name and type, purpose, site, foods),
note, insulin and carbs. Each page has the footer and "Page n of m".

Figures use 5-minute buckets like Week in review and the usual day, so they agree with Insights.

## CSV

One row per entry, oldest first: Date, Time, Type, Details, Insulin (u), Insulin type, Carbs (g),
Site, Glucose, Note. RFC 4180 quoting, CRLF line ends, dot decimals whatever the locale. With
**Include glucose readings** on, every stored reading in the period is a `Glucose` row in the
person's unit, between the entries. A field that starts with `=`, `+`, `-` or `@` (and isn't a
number) gets a leading apostrophe so a spreadsheet never runs a note as a formula.

## Privacy and offline

- Made on the phone from what's already stored there: `GlucoseStore.archive` (the owner's own
  readings) and `LogbookStore.entries`. Nothing is fetched, so it works with no connection.
- Nothing about anyone the person follows is read: no followed readings, check-ins or share
  links. Alert rows aren't included. Follower-only phones don't have a Logbook, so no export.
- The file is written to the app's temporary folder with complete file protection, and that
  folder is cleared before each new export. Nothing leaves the phone until it's shared.

## Not changed

No dosing maths. The export reports what was logged and measured, like Insights, and never
suggests a change.

## Code

- Rules and words: `Sources/Engine/LogbookExport.swift` (`LogbookExport.Period`, `summary`,
  `report`, `row`, `csv`), tested by `LogbookExportTests`. `DayPattern.compute(readings:from:to:days:)`
  gives the usual day over any days; the Insights card's 14/30-day call is unchanged.
- PDF drawing: `Sources/iOS/Export/LogbookPDF.swift` (UIGraphicsPDFRenderer, fixed print colours).
- Screen: `Sources/iOS/Export/PhoneExportView.swift`, opened from `PhoneLogbookView`'s toolbar.
- UI is compile-checked in CI only.
