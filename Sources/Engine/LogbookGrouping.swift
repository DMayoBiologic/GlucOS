import Foundation

/// Logbook rows that belong together (a meal and the insulin for it) shown as one combined row,
/// which opens out into the separate entries. The rules are here, plain Foundation so `swift test`
/// covers them; the rows are drawn by `PhoneLogbookView` on iPhone and `LogbookSection` on the Mac.
/// See docs/LogbookSearch.md "Grouped rows".
///
/// The rule, in order:
/// - Only meals and doses group. Site changes, moments and alerts always stand alone.
/// - A group is a run of neighbouring rows in the list as shown: anything else between two entries
///   (an alert, a moment, a site change) keeps them apart, so the list never reorders.
/// - It starts at its first (oldest) entry and takes in the entries after it while the whole run
///   still fits in `window` (15 minutes) and stays on the same calendar day.
/// - It needs a meal and a dose. Two doses close together never fold into one row, so a second
///   dose is always seen as its own row; the same for two meals.
///
/// Grouping runs on the rows the chips, tags and search leave showing, so they still work per
/// entry: a search that finds only the meal shows the meal alone. Swipes, the right-click menu,
/// export and sync all keep working on the separate entries. Nothing here changes an entry.
enum LogbookGrouping {
    /// How far apart the first and last entry of a group can be.
    static let window: TimeInterval = 15 * 60

    /// Whether an entry can be part of a group.
    static func joins(_ entry: LogEntry) -> Bool {
        switch entry {
        case .meal, .dose: return true
        case .siteChange, .context: return false
        }
    }

    /// The list's rows (newest first, as both Logbooks list them) in runs: single rows as they
    /// were, and groups where the rule finds them. `entry` says which rows are entries.
    static func runs<Row>(_ rows: [Row], entry: (Row) -> LogEntry?,
                          calendar: Calendar = .autoupdatingCurrent) -> [LogbookRun<Row>] {
        // Worked out oldest first, so a group starts from what was logged first (a dose taken
        // before eating still finds its meal), then turned back round.
        var out: [LogbookRun<Row>] = []
        var pending: [(row: Row, entry: LogEntry)] = []

        func flush() {
            if pending.count > 1, isMixed(pending.map(\.entry)) {
                out.append(.group(LogbookGroup(members: pending.map(\.entry))))
            } else {
                out.append(contentsOf: pending.map { .single($0.row) })
            }
            pending = []
        }

        for row in rows.reversed() {
            guard let e = entry(row), joins(e) else {
                flush()
                out.append(.single(row))
                continue
            }
            if let first = pending.first?.entry,
               e.timestamp.timeIntervalSince(first.timestamp) > window
                || !calendar.isDate(e.timestamp, inSameDayAs: first.timestamp) {
                flush()
            }
            pending.append((row, e))
        }
        flush()
        return out.reversed()
    }

    /// The rows to draw: each group's combined row, followed by its entries when it's open.
    static func listed<Row>(_ runs: [LogbookRun<Row>], expanded: Set<UUID>) -> [LogbookListed<Row>] {
        var out: [LogbookListed<Row>] = []
        for run in runs {
            switch run {
            case .single(let row): out.append(.row(row))
            case .group(let g):
                let open = expanded.contains(g.id)
                out.append(.group(g, expanded: open))
                if open { out.append(contentsOf: g.newestFirst.map { .member($0, group: g.id) }) }
            }
        }
        return out
    }

    /// The group an entry is folded into, if any: so the Logbook can open it before showing the
    /// entry (the "last logged" line, the Mac's reveal).
    static func group<Row>(containing id: UUID, in runs: [LogbookRun<Row>]) -> LogbookGroup? {
        for run in runs {
            if case .group(let g) = run, g.contains(id) { return g }
        }
        return nil
    }

    /// The groups' entry ids, each mapped to its group's id.
    static func memberships<Row>(_ runs: [LogbookRun<Row>]) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for run in runs {
            if case .group(let g) = run { for m in g.members { out[m.id] = g.id } }
        }
        return out
    }

    private static func isMixed(_ entries: [LogEntry]) -> Bool {
        entries.contains { if case .meal = $0 { return true } else { return false } }
            && entries.contains { if case .dose = $0 { return true } else { return false } }
    }
}

/// A row of the list once grouped: as it was, or a group of entries.
enum LogbookRun<Row> {
    case single(Row)
    case group(LogbookGroup)
}

/// What the list draws: a plain row, a group's combined row (open or not), or one of an open
/// group's entries, drawn indented under it.
enum LogbookListed<Row> {
    case row(Row)
    case group(LogbookGroup, expanded: Bool)
    case member(LogEntry, group: UUID)
}

/// Entries logged close together, shown as one row.
struct LogbookGroup: Equatable, Identifiable {
    /// Oldest first.
    let members: [LogEntry]

    init(members: [LogEntry]) {
        self.members = members.sorted { $0.timestamp < $1.timestamp }
    }

    /// Its own id, made from its first entry's, so it stays the same (and stays open) when an
    /// entry joins later, and never equals an entry's id.
    var id: UUID { Self.id(for: members[0].id) }

    static func id(for first: UUID) -> UUID {
        var bytes = first.uuid
        // Flips every bit of the first bytes: the same input always gives the same id, and it
        // can't be the entry's own.
        bytes.0 ^= 0xFF; bytes.1 ^= 0xFF; bytes.2 ^= 0xFF; bytes.3 ^= 0xFF
        return UUID(uuid: bytes)
    }

    /// The first entry's time: where the group sits in the list.
    var timestamp: Date { members[0].timestamp }
    var end: Date { members[members.count - 1].timestamp }
    var newestFirst: [LogEntry] { members.reversed() }
    var ids: [UUID] { members.map(\.id) }

    func contains(_ id: UUID) -> Bool { members.contains { $0.id == id } }

    var meals: [MealEntry] { members.compactMap { if case .meal(let m) = $0 { return m } else { return nil } } }
    var doses: [InsulinDose] { members.compactMap { if case .dose(let d) = $0 { return d } else { return nil } } }

    /// "Meal and insulin", or "2 meals and insulin".
    var title: String {
        let food = meals.count == 1 ? "Meal" : "\(meals.count) meals"
        let insulin = doses.count == 1 ? "insulin" : "\(doses.count) doses"
        return "\(food) and \(insulin)"
    }

    /// Both parts in the order they were logged: "45 g · Toast + 4 u NovoRapid".
    var parts: String { members.map(\.shortTitle).joined(separator: " + ") }

    /// What was logged in all, only the parts there are: "45 g carbs · 4 u". The logged amounts
    /// added up, as the day headers do; nothing is worked out from them.
    var totals: String {
        let carbs = meals.reduce(0) { $0 + $1.carbs }
        let units = doses.reduce(0) { $0 + $1.units }
        var out: [String] = []
        if carbs > 0 { out.append("\(LogFormat.grams(carbs)) carbs") }
        if units > 0 { out.append(LogFormat.units(units)) }
        return out.joined(separator: " · ")
    }

    /// "8:02 am", or "8:02–8:10 am" style when the entries are minutes apart (the clock labels
    /// of the first and the last).
    func timeRange(_ label: (Date) -> String) -> String {
        let a = label(timestamp), b = label(end)
        return a == b ? a : "\(a) – \(b)"
    }

    /// What VoiceOver reads for the row, as one item: "Meal and insulin, 2 entries: 45 g · Toast,
    /// 4 u NovoRapid". The time and open/closed state come as the value.
    var spoken: String {
        "\(title), \(members.count) entries: \(members.map(\.shortTitle).joined(separator: ", "))"
    }

    /// The row's state for VoiceOver.
    func spokenState(expanded: Bool) -> String { expanded ? "Expanded" : "Collapsed" }

    /// The VoiceOver action, named for what it does next.
    func actionName(expanded: Bool) -> String { expanded ? "Collapse" : "Expand" }

    /// Said once after the row opens or closes.
    func announcement(expanded: Bool) -> String {
        expanded ? "Showing \(members.count) entries" : "Entries grouped"
    }
}
