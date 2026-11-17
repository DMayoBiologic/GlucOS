import Foundation

/// Logbook days folded down to their header. Tapping a day's chevron (iPhone day header, Mac Day
/// cell) hides that day's rows; the header keeps its time-in-range bar and says how many rows it
/// holds ("4 entries · 1 alert"). The rules are here, plain Foundation so `swift test` covers
/// them; the rows are drawn by `PhoneLogbookView` on iPhone and `LogbookSection` on the Mac. See
/// docs/LogbookSearch.md "Folding a day".
///
/// - Folded days are kept per device (UserDefaults under `defaultsKey`), never synced: how a
///   screen is laid out is that screen's business.
/// - Today never starts folded: each time the Logbook opens, today is dropped from what was kept.
///   Days older than `keepDays` are dropped too, so the list stays small.
/// - A search has its own folds, starting with every day open, so every match shows. Clearing the
///   search brings the kept folds back (`LogbookFolds`).
/// - Jumping to a date, or opening an entry from elsewhere, reopens that day.
/// - Nothing here changes an entry. Export, sync and the totals all still see every row.
struct LogbookCollapse: Equatable, Sendable {
    /// Where the folded days are kept, on this device only.
    static let defaultsKey = "logbook.collapsedDays"
    /// How long a fold is kept: past this, the day has long scrolled away.
    static let keepDays = 120

    /// Each folded day's id (`id(_:)`).
    private(set) var days: Set<String>

    init(days: Set<String> = []) { self.days = days }

    /// A day's id: its local midnight in whole seconds since 1970, as `PhoneLogbookDay.id`.
    static func id(_ dayStart: Date) -> String { "\(Int(dayStart.timeIntervalSince1970))" }

    /// The id of the day `date` falls on.
    static func id(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        id(calendar.startOfDay(for: date))
    }

    /// What was kept, as the Logbook opens: today taken out (it never starts folded), days older
    /// than `keepDays` and anything unreadable dropped.
    static func restored(_ stored: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> LogbookCollapse {
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -keepDays, to: today) ?? today
        var out = Set<String>()
        for part in stored.split(separator: ",") {
            guard let seconds = Int(part.trimmingCharacters(in: .whitespaces)) else { continue }
            let start = Date(timeIntervalSince1970: TimeInterval(seconds))
            // Only days before today: today never starts folded, and a future day is junk.
            guard start >= oldest, start < today else { continue }
            out.insert(id(start))
        }
        return LogbookCollapse(days: out)
    }

    /// The text kept in UserDefaults: the ids, oldest first, comma separated.
    var stored: String {
        days.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ",")
    }

    func isFolded(_ id: String) -> Bool { days.contains(id) }

    /// Folded if it was open, open if it was folded.
    func toggled(_ id: String) -> LogbookCollapse {
        var copy = self
        if copy.days.contains(id) { copy.days.remove(id) } else { copy.days.insert(id) }
        return copy
    }

    /// The day opened, if it was folded.
    func reopened(_ id: String) -> LogbookCollapse {
        var copy = self
        copy.days.remove(id)
        return copy
    }
}

/// The folds in force: the ones kept on the device, and while a search runs, the search's own
/// (which start empty, so every day with a match shows open).
struct LogbookFolds: Equatable, Sendable {
    var kept: LogbookCollapse
    var search: LogbookCollapse

    init(kept: LogbookCollapse = LogbookCollapse(), search: LogbookCollapse = LogbookCollapse()) {
        self.kept = kept
        self.search = search
    }

    /// The folds the list draws.
    func shown(searching: Bool) -> LogbookCollapse { searching ? search : kept }

    func isFolded(_ id: String, searching: Bool) -> Bool { shown(searching: searching).isFolded(id) }

    /// Folds or opens a day in the folds the list is drawing. Returns whether it's folded now.
    @discardableResult
    mutating func toggle(_ id: String, searching: Bool) -> Bool {
        if searching { search = search.toggled(id) } else { kept = kept.toggled(id) }
        return isFolded(id, searching: searching)
    }

    /// A jump or an opened entry is heading for this day: opened in both, so it shows whether or
    /// not a search is running, and stays open once the search clears.
    mutating func reopen(_ id: String) {
        kept = kept.reopened(id)
        search = search.reopened(id)
    }

    /// The search cleared: its folds go, and the kept ones are drawn again.
    mutating func endSearch() { search = LogbookCollapse() }
}

/// How many rows a folded day holds.
struct LogbookDayCount: Equatable, Sendable {
    var entries = 0
    var alerts = 0

    var total: Int { entries + alerts }
}

enum LogbookFolding {
    /// Rows counted by the day they fall on (keyed by local midnight).
    static func counts<Row>(_ rows: [Row], timestamp: (Row) -> Date, isAlert: (Row) -> Bool,
                            calendar: Calendar = .autoupdatingCurrent) -> [Date: LogbookDayCount] {
        var out: [Date: LogbookDayCount] = [:]
        for row in rows {
            let start = calendar.startOfDay(for: timestamp(row))
            if isAlert(row) { out[start, default: LogbookDayCount()].alerts += 1 } else { out[start, default: LogbookDayCount()].entries += 1 }
        }
        return out
    }

    /// For lines listed newest first (the Mac table): each folded day's lines swapped for one line
    /// made by `folded`, in the place its newest line was. Open days are left as they were.
    static func fold<Line>(_ lines: [Line], timestamp: (Line) -> Date, isFolded: (String) -> Bool,
                           folded: (Date) -> Line, calendar: Calendar = .autoupdatingCurrent) -> [Line] {
        var out: [Line] = []
        var lastFolded: Date?
        for line in lines {
            let start = calendar.startOfDay(for: timestamp(line))
            guard isFolded(LogbookCollapse.id(start)) else {
                out.append(line)
                continue
            }
            if start != lastFolded {
                out.append(folded(start))
                lastFolded = start
            }
        }
        return out
    }

    /// A stable id for a folded day's line in the Mac table: never an entry's id, and the same
    /// every time for the same day, so selection and animation can follow it.
    static func lineID(_ dayStart: Date) -> UUID {
        let seconds = UInt64(bitPattern: Int64(dayStart.timeIntervalSince1970))
        var bytes: [UInt8] = [0x4C, 0x47, 0x42, 0x4B, 0xF0, 0x1D, 0x40, 0x00]  // "LGBK", fold, v4
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((seconds >> UInt64(shift)) & 0xFF)) }
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum LogbookCollapseText {
    /// "4 entries", "1 entry · 2 alerts", "1 alert".
    static func count(_ c: LogbookDayCount) -> String {
        var parts: [String] = []
        if c.entries > 0 || c.alerts == 0 { parts.append(c.entries == 1 ? "1 entry" : "\(c.entries) entries") }
        if c.alerts > 0 { parts.append(c.alerts == 1 ? "1 alert" : "\(c.alerts) alerts") }
        return parts.joined(separator: " · ")
    }

    /// The same, for VoiceOver: "4 entries, 1 alert".
    static func spokenCount(_ c: LogbookDayCount) -> String {
        count(c).replacingOccurrences(of: " · ", with: ", ")
    }

    static func spokenState(folded: Bool) -> String { folded ? "Collapsed" : "Expanded" }

    /// The VoiceOver action, and the Mac's menu and help text.
    static func actionName(folded: Bool) -> String { folded ? "Expand Day" : "Collapse Day" }

    /// Said once after a fold or an open: "Today collapsed, 4 entries" / "Today expanded".
    static func announcement(day: String, folded: Bool, count: LogbookDayCount) -> String {
        folded ? "\(day) collapsed, \(spokenCount(count))" : "\(day) expanded"
    }
}
