# Logbook export for clinic visits (iPhone and Mac)

Round 23 of the improvement loop built it on the iPhone; round 24 brought the same export to the
Mac.

- **iPhone.** The Logbook's share button (top right) opens **Export for a clinic visit**: pick the
  days, pick PDF or CSV, then share the file through the usual share sheet (Mail, Messages,
  AirDrop, Save to Files, Print).
- **Mac.** In the dashboard, **Export ▸ Logbook for a Clinic Visit…** (⇧⌘E, also in the ⌘? list)
  opens the same choices in a sheet. **Save PDF…** or **Save CSV…** asks where to save it, and a
  toast says when it's saved.

Both make the same file from the same code. The only difference is the footer's "Made on this
iPhone" or "Made on this Mac".

## Days

14, 30 or 90 days up to today, or a custom From/To. Whole calendar days in the device's time zone.
A custom range never ends after today and is capped at 90 days, the most either app keeps; the
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

- Made on the device from what's already stored there: `GlucoseStore.archive` (the owner's own
  readings) and `LogbookStore.entries`. Nothing is fetched, so it works with no connection. The Mac reads its own
  `GlucoseStore.archive` and `LogbookStore.entries` the same way.
- Nothing about anyone the person follows is read: no followed readings, check-ins or share
  links. Alert rows aren't included. Follower-only phones don't have a Logbook, so no export.
- iPhone: the file is written to the app's temporary folder with complete file protection, and
  that folder is cleared before each new export. Nothing leaves the phone until it's shared.
- Mac: the file is written only where the person picks in the save panel. Nothing else is kept.

## Not changed

No dosing maths. The export reports what was logged and measured, like Insights, and never
suggests a change.

## Code

- Rules and words: `Sources/Engine/LogbookExport.swift` (`LogbookExport.Period`, `summary`,
  `report`, `row`, `csv`), tested by `LogbookExportTests`. `DayPattern.compute(readings:from:to:days:)`
  gives the usual day over any days; the Insights card's 14/30-day call is unchanged.
  `LogbookExport.Device` (iPhone or Mac) only changes the footer and the no-readings line; a test
  checks the figures don't move with it.
- PDF drawing: `Sources/App/Export/LogbookPDF.swift`, one file for both apps (fixed sRGB print
  colours). Everything draws through Core Graphics and attributed-string drawing on a top-left
  origin page: UIGraphicsPDFRenderer on the iPhone, a Core Graphics PDF context with a flipped
  `NSGraphicsContext` on the Mac. The iPhone target lists the file in `project.yml`.
- Screens: `Sources/iOS/Export/PhoneExportView.swift` (opened from `PhoneLogbookView`'s toolbar)
  and `Sources/App/Export/MacExportView.swift` (opened from the dashboard's Export menu). Both keep
  the chosen days and format under the same `export.*` keys.
- UI is compile-checked in CI only.
