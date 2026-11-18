import Foundation

// Picking several Logbook rows at once (docs/LogbookSearch.md "Selecting several entries"): the
// iPhone's Select mode with checkmarks, and the Mac table's Shift-click and ⌘-click. What's picked
// can be deleted or tagged together, and one Undo on the toast takes the whole change back.
//
// Plain Foundation, so `swift test` covers the rules; the rows are drawn by `PhoneLogbookView` and
// `LogbookSection`. Nothing here works out an amount: deleting and tagging only remove an entry or
// change its tags, and Undo puts back each entry exactly as it was saved, under its own id.

/// The rows picked in the Logbook. A row is picked by its id: an entry's id for an entry's row, a
/// group's id for a meal and its insulin shown as one row (`LogbookGroup`), so a group is always
/// picked as a unit and acts on all of its entries. Alert rows can't be picked.
struct LogbookSelection: Equatable {
    private(set) var picked: Set<UUID> = []

    var isEmpty: Bool { picked.isEmpty }

    func contains(_ row: UUID) -> Bool { picked.contains(row) }

    /// Picks the row, or lets it go.
    mutating func toggle(_ row: UUID) {
        if picked.contains(row) { picked.remove(row) } else { picked.insert(row) }
    }

    mutating func set(_ rows: Set<UUID>) { picked = rows }

    mutating func clear() { picked = [] }

    /// Drops rows that aren't shown any more (a search, a chip, a folded day, a delete on the other
    /// device), so Delete never reaches an entry the user can't see.
    mutating func keep(only shown: Set<UUID>) { picked.formIntersection(shown) }

    /// The ids a row can be picked by, in the list's runs: each lone entry's id and each group's
    /// id. Alert rows (`entry` gives nil) aren't among them.
    static func pickable<Row>(_ runs: [LogbookRun<Row>], entry: (Row) -> LogEntry?) -> [UUID] {
        runs.compactMap { run in
            switch run {
            case .single(let row): return entry(row)?.id
            case .group(let g): return g.id
            }
        }
    }

    /// The entries the picked rows stand for, newest first: an entry's row is that entry, a group's
    /// row is every entry in it. Rows not in `runs` (no longer shown) count for nothing.
    func entries<Row>(in runs: [LogbookRun<Row>], entry: (Row) -> LogEntry?) -> [LogEntry] {
        var out: [LogEntry] = []
        for run in runs {
            switch run {
            case .single(let row):
                if let e = entry(row), picked.contains(e.id) { out.append(e) }
            case .group(let g):
                if picked.contains(g.id) { out.append(contentsOf: g.newestFirst) }
            }
        }
        return out
    }

    /// Whether every pickable row is picked, so the button offers "Deselect All" instead.
    static func allPicked(_ selection: LogbookSelection, of pickable: [UUID]) -> Bool {
        !pickable.isEmpty && pickable.allSatisfy(selection.contains)
    }
}

/// What the selection says, on iPhone and Mac. Counts entries, not rows: a meal and its insulin
/// shown as one row are two entries, as the Undo toast and the Delete button count them.
enum LogbookSelectionText {
    /// The iPhone's title while selecting: "Select Entries", "1 Selected", "3 Selected".
    static func title(_ count: Int) -> String {
        count == 0 ? "Select Entries" : "\(count) Selected"
    }

    /// What VoiceOver hears after a pick changes, and the Mac's count label: "None selected",
    /// "1 entry selected", "3 entries selected".
    static func spoken(_ count: Int) -> String {
        switch count {
        case 0: return "None selected"
        case 1: return "1 entry selected"
        default: return "\(count) entries selected"
        }
    }

    /// "Delete", "Delete 3".
    static func deleteName(_ count: Int) -> String {
        count <= 1 ? "Delete" : "Delete \(count)"
    }

    /// A row's VoiceOver hint while selecting.
    static func rowHint(picked: Bool) -> String {
        picked ? "Removes it from the selection" : "Adds it to the selection"
    }
}

/// Adding or removing one tag on several entries at once. Only `labels` change: never an amount,
/// time, note or anything else, and entries that wouldn't change are left alone (not even
/// re-saved), so sync only sends what really changed.
enum LogbookBulkTag {
    /// The entries as they'll be saved with `tag` added. Skipped: entries that already show under
    /// that tag (including a moment's matching "What else is going on?" choice) and entries that
    /// already hold `LogbookTags.maxPerEntry` tags. Empty when the tag cleans to nothing.
    static func adding(_ tag: String, to entries: [LogEntry]) -> [LogEntry] {
        guard let t = LogbookTags.cleaned(tag) else { return [] }
        return entries.compactMap { e in
            guard !LogbookTags.contains(e.filterTags, t), e.labels.count < LogbookTags.maxPerEntry else { return nil }
            return e.withLabels(e.labels + [t])
        }
    }

    /// The entries as they'll be saved with `tag` (in any spelling) taken off. Entries without it
    /// are skipped. A moment's "What else is going on?" choices are never touched.
    static func removing(_ tag: String, from entries: [LogEntry]) -> [LogEntry] {
        entries.compactMap { e in
            guard LogbookTags.contains(e.labels, tag) else { return nil }
            let k = LogbookTags.key(tag)
            return e.withLabels(e.labels.filter { LogbookTags.key($0) != k })
        }
    }

    /// The tags the picked entries hold between them, for "Remove Tag": most used first, then by
    /// name, each once.
    static func removable(_ entries: [LogEntry]) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for e in entries {
            for t in e.labels { counts[LogbookTags.key(t), default: (t, 0)].count += 1 }
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCompare($1.name) == .orderedAscending }
            .map(\.name)
    }

    /// Whether every one of `entries` shows under `tag`, so its menu item shows a checkmark.
    static func allHave(_ tag: String, _ entries: [LogEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { LogbookTags.contains($0.filterTags, tag) }
    }

    /// The Undo toast's text: "Added Exercise to 3 entries", "Added Exercise to 4 u NovoRapid",
    /// "Removed Exercise from 3 entries".
    static func title(_ tag: String, adding: Bool, changed: [LogEntry]) -> String {
        let what: String
        if changed.count == 1, let e = changed.first, !e.shortTitle.isEmpty { what = e.shortTitle } else {
            what = changed.count == 1 ? "1 entry" : "\(changed.count) entries"
        }
        return adding ? "Added \(tag) to \(what)" : "Removed \(tag) from \(what)"
    }

    /// Said when nothing changed, so a tap is never silent: every entry already had the tag, or
    /// none had it to remove.
    static func nothingToDo(_ tag: String, adding: Bool) -> String {
        adding ? "Already tagged \(tag)" : "None of these are tagged \(tag)"
    }
}
