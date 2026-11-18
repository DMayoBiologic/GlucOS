import Foundation

// Alert History export for a clinic visit (docs/AlertHistory.md, "Export"): the alerts the history
// is showing, under the chips picked (`AlertHistory.FilterPick`), as a CSV or an A4 PDF. Each alert
// gives its time, which alert, the reading at the time, what happened to it and its note.
//
// Built only from what the history itself lists: the owner's own alert records (follower copies of
// a shared person's alerts are never recorded, docs/AlertLog.md), the owner's own stored readings
// and the owner's own Logbook notes. Nothing about anyone the owner follows is read. Test alerts
// are never recorded, so they never appear. Made on the device; nothing is sent until the person
// shares the file. Reuses the Logbook export's pieces (`LogbookExport.Period`, `.Format`,
// `.csvField`, `.dateFormatter`, `.Device`); the PDF is drawn by Sources/App/Export/AlertHistoryPDF.swift.
// Plain Foundation so it's unit-tested.

enum AlertHistoryExport {
    /// One alert as exported: the history's row and its note.
    struct Row: Hashable {
        let item: AlertHistory.Item
        /// The Logbook note saved at the alert's time (`AlertNote.existing`), or "".
        let note: String
    }

    /// How many of the exported alerts ended each way.
    struct OutcomeCount: Hashable {
        let outcome: AlertHistory.OutcomeFilter
        let count: Int
    }

    struct Report: Hashable {
        /// The history's 7 days.
        let period: LogbookExport.Period
        /// The chips picked when it was made.
        let pick: AlertHistory.FilterPick
        let unit: GlucoseUnit
        /// The alerts the chips let through, oldest first (a clinic reads a log forwards).
        let rows: [Row]
        /// Every alert in the 7 days, before the chips.
        let totalAlerts: Int
        let made: Date
        let device: LogbookExport.Device

        var outcomeCounts: [OutcomeCount] { AlertHistoryExport.outcomeCounts(rows) }
    }

    /// The history's alerts under `pick`, with their notes. Exactly what the screen lists, so the
    /// file never holds an alert the person didn't see, or misses one they did.
    static func report(records: [AlertRecord], readings: [GlucoseReading], notes: [ContextEvent],
                       pick: AlertHistory.FilterPick, unit: GlucoseUnit, device: LogbookExport.Device,
                       now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Report {
        let all = AlertHistory.items(records: records, readings: readings, now: now, calendar: calendar)
        let rows = pick.apply(all)
            .sorted { $0.firedAt < $1.firedAt }
            .map { Row(item: $0, note: AlertNote.existing(near: $0.firedAt, in: notes)?.note ?? "") }
        return Report(period: .last(AlertHistory.days, now: now, calendar: calendar), pick: pick, unit: unit,
                      rows: rows, totalAlerts: all.count, made: now, device: device)
    }

    /// Non-zero outcome counts, in the chips' order.
    static func outcomeCounts(_ rows: [Row]) -> [OutcomeCount] {
        AlertHistory.OutcomeFilter.allCases.compactMap { o in
            let n = rows.filter { o.matches($0.item.outcome) }.count
            return n > 0 ? OutcomeCount(outcome: o, count: n) : nil
        }
    }

    /// The alerts by local day, oldest day first.
    static func days(_ rows: [Row], calendar: Calendar = .autoupdatingCurrent) -> [(day: Date, rows: [Row])] {
        var out: [(day: Date, rows: [Row])] = []
        for r in rows {
            let d = calendar.startOfDay(for: r.item.firedAt)
            if out.last?.day == d { out[out.count - 1].rows.append(r) } else { out.append((d, [r])) }
        }
        return out
    }

    // MARK: CSV

    static let csvHeader = ["Date", "Time", "Alert", "Type", "Glucose", "Outcome", "Responded", "Note"]

    /// The report as CSV (RFC 4180 via `LogbookExport.csvField`, CRLF line ends), oldest first.
    /// "Responded" is the time of the button or dismissal, with its date when that was another day.
    static func csv(_ report: Report, calendar: Calendar = .autoupdatingCurrent) -> String {
        let date = LogbookExport.dateFormatter("yyyy-MM-dd", calendar: calendar)
        let time = LogbookExport.dateFormatter("HH:mm", calendar: calendar)
        var header = csvHeader
        header[4] = "Glucose (\(report.unit.label))"
        var out = [header.map(LogbookExport.csvField).joined(separator: ",")]
        for row in report.rows {
            let item = row.item
            let responded: String = item.respondedAt.map { at in
                calendar.isDate(at, inSameDayAs: item.firedAt)
                    ? time.string(from: at)
                    : "\(date.string(from: at)) \(time.string(from: at))"
            } ?? ""
            let cells = [date.string(from: item.firedAt), time.string(from: item.firedAt), item.title,
                         typeName(item.kind), item.readingMgdl.map { report.unit.format(mgdl: $0) } ?? "",
                         item.outcome.text, responded, row.note]
            out.append(cells.map(LogbookExport.csvField).joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// Which kind chip the alert falls under: "Low", "High" or "Predicted".
    static func typeName(_ kind: AlertNotice.Kind) -> String {
        if AlertHistory.KindFilter.predicted.matches(kind) { return "Predicted" }
        return kind.treatment == .low ? "Low" : "High"
    }

    // MARK: Words

    /// "GlucOS Alert History 2026-11-12 to 2026-11-18.pdf", with the chips when some are picked:
    /// "GlucOS Alert History 2026-11-12 to 2026-11-18 (Snoozed low alerts).csv".
    static func fileName(_ report: Report, format: LogbookExport.Format,
                         calendar: Calendar = .autoupdatingCurrent) -> String {
        let f = LogbookExport.dateFormatter("yyyy-MM-dd", calendar: calendar)
        let first = f.string(from: report.period.start)
        let last = f.string(from: report.period.lastDay(calendar: calendar))
        let span = first == last ? first : "\(first) to \(last)"
        let filter = report.pick.isFiltered ? " (\(filterLine(report.pick)))" : ""
        return "GlucOS Alert History \(span)\(filter).\(format.fileExtension)"
    }

    /// What the chips let through, for the PDF header: "All alerts", "Snoozed low alerts".
    static func filterLine(_ pick: AlertHistory.FilterPick) -> String {
        guard pick.isFiltered else { return "All alerts" }
        let phrase = AlertHistoryText.pickPhrase(pick)
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// "Showing: Snoozed low alerts · 3 of 12 alerts", "Showing: All alerts · 12 alerts".
    static func showingLine(_ report: Report) -> String {
        let n = report.rows.count
        let count = report.pick.isFiltered ? "\(n) of \(AlertHistoryText.count(report.totalAlerts))"
                                           : AlertHistoryText.count(n)
        return "Showing: \(filterLine(report.pick)) · \(count)"
    }

    /// "Tapped Log treatment 3 · Snoozed 5 · No response 1", or nil when nothing's listed.
    static func outcomeLine(_ report: Report) -> String? {
        let counts = report.outcomeCounts
        guard !counts.isEmpty else { return nil }
        return counts.map { "\($0.outcome.spoken) \($0.count)" }.joined(separator: " · ")
    }

    static func footnote(_ device: LogbookExport.Device) -> String {
        "Made on this \(device.name) by GlucOS from its own alerts, readings and notes. \"Tapped Log treatment\" means the alert's button was tapped, not that a low was treated. Observations, not advice. Personal use, not a medical device."
    }

    static func emptyLine(_ pick: AlertHistory.FilterPick) -> String {
        pick.isFiltered ? AlertHistoryText.filteredEmptyMessage(pick) : "No alerts in the last 7 days."
    }
}

/// The words on the history's export row, shared by the iPhone and the Mac.
enum AlertHistoryExportText {
    static let button = "Export"
    static let hint = "Makes a file of the alerts shown, with the chips picked."

    /// The menu's items: "Share PDF" / "Share CSV" on the iPhone, "Save PDF…" / "Save CSV…" on the Mac.
    static func item(_ format: LogbookExport.Format, device: LogbookExport.Device) -> String {
        let name = format == .pdf ? "PDF" : "CSV"
        return device == .mac ? "Save \(name)…" : "Share \(name)"
    }

    /// Above the menu: "12 alerts shown", "3 of 12 alerts shown".
    static func shown(_ shown: Int, of total: Int) -> String {
        shown == total ? "\(AlertHistoryText.count(total)) shown" : "\(shown) of \(AlertHistoryText.count(total)) shown"
    }

    static func saved(_ name: String) -> String { "Saved \u{201C}\(name)\u{201D}" }
    static func problem(_ device: LogbookExport.Device) -> String {
        "Couldn't make the file. Check this \(device.name) has some free space, then try again."
    }
}
