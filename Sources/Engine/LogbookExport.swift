import Foundation

// A Logbook export for a clinic visit: pick some days, then share a PDF summary (time in range, the
// average, lows, the usual day by time of day, and every entry) or a CSV of the entries.
//
// Everything here is worked out on the device (iPhone or Mac) from what's already stored on it: the owner's own
// readings (`GlucoseStore.archive`, up to 90 days) and the owner's own logbook entries. Nothing is
// fetched, so it works offline, and nothing about anyone the owner follows (their readings,
// check-ins, share links) is read at all. Alert rows aren't included either.
//
// Method, matching Insights so the figures agree with what the person sees in the app:
// 1. Readings are averaged into 5-minute buckets (as `WeekInReview` and `DayPattern` do), so a
//    stretch of 1-minute Bluetooth readings counts the same as LibreLinkUp's 15-minute history.
// 2. Time in range, below and above are shares of those buckets, using the person's own target.
//    Very low (under 3.0 mmol/L, 54 mg/dL) and very high (over 13.9, 250) are the consensus cut-offs.
// 3. Lows are runs below the low threshold lasting 15 minutes or more (`TodaySoFar.lowRuns`).
// 4. Sensor coverage is the share of the period's 15-minute slots holding a reading.
// 5. The usual day is `DayPattern` over the chosen days.
//
// Observational only, like Insights: it reports what was logged and measured and never suggests a
// change to insulin or settings. The logged-insulin and carb totals are sums of what the person
// entered, nothing more. Plain Foundation, so it's unit-tested; the PDF itself is drawn by
// Sources/App/Export/LogbookPDF.swift, one file for both the iPhone and the Mac.

enum LogbookExport {
    /// The archive holds 90 days, so a longer period would only add empty days.
    static let maximumDays = 90
    static let bucketMinutes = 5
    static let coverageMinutes = 15
    static let veryLowMgdl = 54.0
    static let veryHighMgdl = 250.0

    enum Format: String, CaseIterable, Identifiable, Hashable {
        case pdf, csv

        var id: String { rawValue }
        var title: String { self == .pdf ? "PDF summary" : "CSV" }
        var fileExtension: String { rawValue }
    }

    /// Whole calendar days, from the start of `first` to the end of `last`.
    struct Period: Hashable {
        let start: Date
        /// The moment after the last day ends (exclusive).
        let end: Date
        let days: Int

        /// `first`...`last` as whole days, in order, capped at `maximumDays` (keeping the latest).
        /// Never ends after today.
        static func days(from first: Date, to last: Date, now: Date = Date(),
                         calendar: Calendar = .autoupdatingCurrent) -> Period {
            let today = calendar.startOfDay(for: now)
            var a = calendar.startOfDay(for: min(first, last))
            var b = calendar.startOfDay(for: max(first, last))
            if b > today { b = today }
            if a > b { a = b }
            if let n = calendar.dateComponents([.day], from: a, to: b).day, n >= maximumDays {
                a = calendar.date(byAdding: .day, value: -(maximumDays - 1), to: b) ?? a
            }
            let end = calendar.date(byAdding: .day, value: 1, to: b) ?? b.addingTimeInterval(86_400)
            let days = (calendar.dateComponents([.day], from: a, to: b).day ?? 0) + 1
            return Period(start: a, end: end, days: days)
        }

        /// The last `count` days, today included.
        static func last(_ count: Int, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Period {
            let today = calendar.startOfDay(for: now)
            let first = calendar.date(byAdding: .day, value: -(max(1, count) - 1), to: today) ?? today
            return days(from: first, to: today, now: now, calendar: calendar)
        }

        /// The last day in the period (its start).
        func lastDay(calendar: Calendar = .autoupdatingCurrent) -> Date {
            calendar.date(byAdding: .day, value: -1, to: end) ?? end
        }

        func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    /// The quick choices on the export screen.
    enum Preset: Int, CaseIterable, Identifiable, Hashable {
        case fortnight = 14
        case month = 30
        case quarter = 90

        var id: Int { rawValue }
        var label: String { "\(rawValue) days" }
    }

    // MARK: Summary

    struct Summary: Hashable {
        /// Raw readings in the period.
        var readings: Int
        /// 5-minute buckets behind the figures.
        var buckets: Int
        /// Days with any readings.
        var daysWithReadings: Int
        /// Share of the period's 15-minute slots with a reading, 0...1.
        var coverage: Double
        var timeInRange: Double
        var below: Double
        var veryLow: Double
        var above: Double
        var veryHigh: Double
        var meanMgdl: Double
        var sdMgdl: Double
        /// Runs below range lasting 15 minutes or more.
        var lows: Int

        var coefficientOfVariation: Double { meanMgdl > 0 ? sdMgdl / meanMgdl : 0 }
        /// Glucose management indicator (%), the consensus estimate of HbA1c from the average.
        var gmiPercent: Double { 3.31 + 0.02392 * meanMgdl }
        /// The same, in mmol/mol (IFCC), as Australian clinics usually quote HbA1c.
        var gmiMmolPerMol: Double { 12.71 + 4.70587 * meanMgdl }
    }

    /// Nil when the period has no readings.
    static func summary(readings: [GlucoseReading], period: Period, low: Double, high: Double) -> Summary? {
        let inPeriod = readings.filter { $0.mgdl > 0 && period.contains($0.timestamp) }
        guard !inPeriod.isEmpty else { return nil }

        let size = Double(bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in inPeriod {
            let key = Int((r.timestamp.timeIntervalSince1970 / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        let buckets: [(Date, Double)] = sums.keys.sorted().map { key in
            let b = sums[key]!
            return (Date(timeIntervalSince1970: Double(key) * size), b.sum / Double(b.n))
        }
        let values = buckets.map(\.1)
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.count > 1 ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1) : 0

        let slot = Double(coverageMinutes) * 60
        let filledSlots = Set(inPeriod.map { Int(($0.timestamp.timeIntervalSince(period.start) / slot).rounded(.down)) }).count
        let totalSlots = max(1, Int((period.end.timeIntervalSince(period.start) / slot).rounded()))
        let dayCount = Set(inPeriod.map { Int(($0.timestamp.timeIntervalSince(period.start) / 86_400).rounded(.down)) }).count

        func share(_ test: (Double) -> Bool) -> Double { Double(values.filter(test).count) / n }
        return Summary(readings: inPeriod.count,
                       buckets: values.count,
                       daysWithReadings: min(dayCount, period.days),
                       coverage: min(1, Double(filledSlots) / Double(totalSlots)),
                       timeInRange: share { $0 >= low && $0 <= high },
                       below: share { $0 < low },
                       veryLow: share { $0 < veryLowMgdl },
                       above: share { $0 > high },
                       veryHigh: share { $0 > veryHighMgdl },
                       meanMgdl: mean,
                       sdMgdl: variance.squareRoot(),
                       lows: TodaySoFar.lowRuns(buckets, low: low))
    }

    // MARK: Entries

    /// What was logged in the period, as sums of what the person entered.
    struct Totals: Hashable {
        var doses: Int
        var units: Double
        var meals: Int
        var carbs: Double
        var siteChanges: Int
        var hypoTreatments: Int
    }

    /// The period's entries, oldest first (the order a clinic reads a diary in).
    static func entries(_ all: [LogEntry], period: Period) -> [LogEntry] {
        all.filter { period.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
    }

    static func totals(_ entries: [LogEntry]) -> Totals {
        var t = Totals(doses: 0, units: 0, meals: 0, carbs: 0, siteChanges: 0, hypoTreatments: 0)
        for e in entries {
            switch e {
            case .dose(let d): t.doses += 1; t.units += d.units
            case .meal(let m): t.meals += 1; t.carbs += m.carbs
            case .siteChange: t.siteChanges += 1
            case .context(let c): if c.tags.contains(.hypoTreatment) { t.hypoTreatments += 1 }
            }
        }
        return t
    }

    /// One entry as table cells, shared by the PDF and the CSV so they always say the same.
    struct Row: Hashable {
        var timestamp: Date
        var type: String
        var details: String
        var insulinUnits: Double?
        var insulinType: String
        var carbs: Double?
        var site: String
        var note: String
    }

    static func row(_ entry: LogEntry) -> Row {
        switch entry {
        case .dose(let d):
            var details = d.displayName
            if d.viaPump { details += " (pump)" }
            if let purpose = d.purpose?.label { details += ", \(purpose.lowercased())" }
            return Row(timestamp: d.timestamp, type: "Insulin", details: details, insulinUnits: d.units,
                       insulinType: d.kind.title, carbs: nil, site: d.site?.title ?? "", note: d.note)
        case .meal(let m):
            var details = m.food
            if let items = m.items, !items.isEmpty {
                let list = items.map { item in
                    "\(item.name) (\(item.portion ?? "\(LogFormat.number(item.grams.rounded())) g"))"
                }.joined(separator: "; ")
                details = details.isEmpty ? list : "\(details): \(list)"
            }
            return Row(timestamp: m.timestamp, type: "Food", details: details, insulinUnits: nil,
                       insulinType: "", carbs: m.carbs > 0 ? m.carbs : nil, site: "", note: m.note)
        case .siteChange(let s):
            return Row(timestamp: s.timestamp, type: "Site change", details: "New infusion site", insulinUnits: nil,
                       insulinType: "", carbs: nil, site: s.site.title, note: s.note)
        case .context(let c):
            let type: String
            if c.tags == [.wokeUp] { type = "Woke up" }
            else if c.tags == [.bedtime] { type = "Went to sleep" }
            else if c.tags.contains(.hypoTreatment) { type = "Hypo treatment" }
            else { type = "Event" }
            let details = c.sortedTags.filter { $0.title != type }.map(\.title).joined(separator: ", ")
            return Row(timestamp: c.timestamp, type: type, details: details, insulinUnits: nil,
                       insulinType: "", carbs: nil, site: "", note: c.note)
        }
    }

    // MARK: Report

    /// Everything the PDF shows, worked out in one go (off the main thread) so drawing only lays it out.
    struct Report: Hashable {
        var period: Period
        var unit: GlucoseUnit
        var lowMgdl: Double
        var highMgdl: Double
        var summary: Summary?
        var pattern: DayPattern?
        var totals: Totals
        /// The period's entries as table rows, oldest first.
        var rows: [Row]
        var made: Date
        /// Which app made it, for the footer ("Made on this Mac").
        var device: Device = .iPhone
    }

    /// The app making the export. Only changes the words, never the figures.
    enum Device: String, Hashable {
        case iPhone, mac

        var name: String { self == .mac ? "Mac" : "iPhone" }
    }

    static func report(readings: [GlucoseReading], entries all: [LogEntry], period: Period, unit: GlucoseUnit,
                       low: Double, high: Double, device: Device = .iPhone, now: Date = Date(),
                       calendar: Calendar = .autoupdatingCurrent) -> Report {
        let inPeriod = entries(all, period: period)
        return Report(period: period, unit: unit, lowMgdl: low, highMgdl: high,
                      summary: summary(readings: readings, period: period, low: low, high: high),
                      pattern: DayPattern.compute(readings: readings, from: period.start, to: period.end,
                                                  days: period.days, calendar: calendar),
                      totals: totals(inPeriod), rows: inPeriod.map(row), made: now, device: device)
    }

    /// Rows grouped by calendar day, oldest first, for the PDF's day headings.
    static func days(_ rows: [Row], calendar: Calendar = .autoupdatingCurrent) -> [(day: Date, rows: [Row])] {
        var out: [(day: Date, rows: [Row])] = []
        for r in rows {
            let d = calendar.startOfDay(for: r.timestamp)
            if out.last?.day == d { out[out.count - 1].rows.append(r) } else { out.append((d, [r])) }
        }
        return out
    }

    /// "12 u · 140 g carbs" for a day heading, or "" when nothing adds up.
    static func dayTotals(_ rows: [Row]) -> String {
        let units = rows.compactMap(\.insulinUnits).reduce(0, +)
        let carbs = rows.compactMap(\.carbs).reduce(0, +)
        var parts: [String] = []
        if units > 0 { parts.append(LogFormat.units(units)) }
        if carbs > 0 { parts.append("\(LogFormat.grams(carbs)) carbs") }
        return parts.joined(separator: " · ")
    }

    // MARK: CSV

    static let csvHeader = ["Date", "Time", "Type", "Details", "Insulin (u)", "Insulin type", "Carbs (g)", "Site", "Glucose", "Note"]

    /// The entries as CSV (RFC 4180: quoted where needed, CRLF line ends), oldest first. With
    /// `readings`, each reading in the period is a "Glucose" row between them, in `unit`.
    static func csv(entries: [LogEntry], readings: [GlucoseReading] = [], period: Period, unit: GlucoseUnit,
                    calendar: Calendar = .autoupdatingCurrent) -> String {
        let date = dateFormatter("yyyy-MM-dd", calendar: calendar)
        let time = dateFormatter("HH:mm", calendar: calendar)
        var header = csvHeader
        header[8] = "Glucose (\(unit.label))"

        enum Line { case entry(Row), reading(GlucoseReading) }
        let entryLines: [(Date, Line)] = self.entries(entries, period: period).map { e in (e.timestamp, Line.entry(row(e))) }
        let readingLines: [(Date, Line)] = readings.filter { $0.mgdl > 0 && period.contains($0.timestamp) }
            .map { g in (g.timestamp, Line.reading(g)) }
        let lines = entryLines + readingLines
        // Stable: at the same minute an entry comes before the reading.
        let ordered = lines.enumerated().sorted { a, b in
            a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0
        }.map(\.element.1)

        var out = [header.map(csvField).joined(separator: ",")]
        for line in ordered {
            let cells: [String]
            switch line {
            case .entry(let r):
                cells = [date.string(from: r.timestamp), time.string(from: r.timestamp), r.type, r.details,
                         r.insulinUnits.map(LogFormat.plain) ?? "", r.insulinType, r.carbs.map(LogFormat.plain) ?? "",
                         r.site, "", r.note]
            case .reading(let g):
                cells = [date.string(from: g.timestamp), time.string(from: g.timestamp), "Glucose", "", "", "", "", "",
                         unit.format(mgdl: g.mgdl), ""]
            }
            out.append(cells.map(csvField).joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// One CSV field, quoted when it holds a comma, quote or line break. A field starting with
    /// = + - @ is prefixed with an apostrophe, so a spreadsheet never runs a note as a formula.
    static func csvField(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@".contains(first), Double(v) == nil { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Words

    /// "GlucOS Logbook 2026-11-02 to 2026-11-15.pdf".
    static func fileName(_ period: Period, format: Format, calendar: Calendar = .autoupdatingCurrent) -> String {
        let f = dateFormatter("yyyy-MM-dd", calendar: calendar)
        let first = f.string(from: period.start), last = f.string(from: period.lastDay(calendar: calendar))
        let span = first == last ? first : "\(first) to \(last)"
        return "GlucOS Logbook \(span).\(format.fileExtension)"
    }

    /// "2 Nov – 15 Nov 2026 (14 days)".
    static func periodLine(_ period: Period, calendar: Calendar = .autoupdatingCurrent) -> String {
        let last = period.lastDay(calendar: calendar)
        let sameYear = calendar.component(.year, from: period.start) == calendar.component(.year, from: last)
        let a = dateFormatter(sameYear ? "d MMM" : "d MMM yyyy", calendar: calendar).string(from: period.start)
        let b = dateFormatter("d MMM yyyy", calendar: calendar).string(from: last)
        let days = period.days == 1 ? "1 day" : "\(period.days) days"
        return period.days == 1 ? "\(b) (1 day)" : "\(a) – \(b) (\(days))"
    }

    /// Lows as a count, "None" when there were none.
    static func lowsValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    /// "4.2 a day", from a count over the period's days.
    static func perDay(_ value: Double, days: Int) -> String {
        LogFormat.number(((value / Double(max(1, days))) * 10).rounded() / 10)
    }

    /// The lines under the summary figures.
    static func loggedLines(_ t: Totals, days: Int) -> [String] {
        var lines: [String] = []
        if t.doses > 0 {
            lines.append("Insulin logged: \(t.doses) \(t.doses == 1 ? "dose" : "doses"), \(LogFormat.units(t.units)) in all (about \(perDay(t.units, days: days)) u a day).")
        }
        if t.meals > 0 {
            lines.append("Food logged: \(t.meals) \(t.meals == 1 ? "entry" : "entries"), \(LogFormat.grams(t.carbs)) carbs in all (about \(perDay(t.carbs, days: days)) g a day).")
        }
        if t.siteChanges > 0 { lines.append("Site changes: \(t.siteChanges).") }
        if t.hypoTreatments > 0 { lines.append("Hypo treatments logged: \(t.hypoTreatments).") }
        if lines.isEmpty { lines.append("Nothing was logged in these days.") }
        return lines
    }

    static var footnote: String { footnote(.iPhone) }

    static func footnote(_ device: Device) -> String {
        "Made on this \(device.name) by GlucOS from its own readings and logbook. Totals are what was logged, not what was delivered. Observations, not advice. Personal use, not a medical device."
    }

    static var noReadingsLine: String { noReadingsLine(.iPhone) }

    static func noReadingsLine(_ device: Device) -> String {
        "No glucose readings were stored on this \(device.name) for these days."
    }

    static func dateFormatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

extension LogFormat {
    /// "4.5", "45": a plain number for CSV, with a dot and no grouping whatever the locale.
    static func plain(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)
    }
}
