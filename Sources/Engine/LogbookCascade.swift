import Foundation

// How several Logbook rows leave and come back together, on iPhone and Mac (docs/LogbookSearch.md
// "Deleting several entries"). Display only: what is deleted or put back never changes here; this
// only says when each row moves, how long the whole thing takes, and what VoiceOver hears.
//
// Deleting a selection: the rows shrink out one after another from the top, a short step apart,
// and only once the last one has gone does the store delete them, so the day totals and the list
// settle once, after the rows. Undo brings them back the other way round, bottom row first, and
// the totals roll once the last row is back. Under Reduce Motion, or for a single row, nothing
// waits: the rows go and come back at once, as before.

/// One cascade: the rows in the order they move, each row being the entries it stands for (a
/// grouped meal and insulin row is both entries, and moves as one).
struct LogbookCascade: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        /// Deleting: shrinking out, top row first.
        case leaving
        /// Undone: coming back, bottom row first.
        case arriving
    }

    /// The gap between one row and the next, in seconds.
    static let step = 0.045
    /// However many rows there are, the last starts moving no later than this, in seconds, so a
    /// long selection still goes in about half a second.
    static let spread = 0.3
    /// How long each row takes to shrink out or grow back, in seconds.
    static let rowDuration = 0.2
    /// How small a row gets on the way out, and starts from on the way back.
    static let scale = 0.9

    let direction: Direction
    /// Each entry's delay, in seconds after the cascade starts.
    let delays: [UUID: Double]
    /// Every entry in the cascade, in the order the rows were given (top to bottom).
    let ids: [UUID]
    /// Whether the rows are hidden now: true while leaving (they shrink out as it's set), and
    /// for arriving rows until `revealed()` lets them grow back in.
    private(set) var hidden: Bool

    /// Whether several rows going or coming back cascade at all: only for two or more rows, and
    /// never under Reduce Motion.
    static func applies(rows: Int, reduceMotion: Bool) -> Bool {
        rows >= 2 && !reduceMotion
    }

    /// The step between rows for this many: `step`, tightened so the last row starts by `spread`.
    static func step(rows: Int) -> Double {
        guard rows > 1 else { return 0 }
        return min(step, spread / Double(rows - 1))
    }

    /// Each row's delay, in the order given. Leaving runs top to bottom; arriving runs the other
    /// way, so the bottom row is back first.
    static func delays(rows: Int, direction: Direction) -> [Double] {
        let s = step(rows: rows)
        let forward = (0..<max(rows, 0)).map { Double($0) * s }
        return direction == .leaving ? forward : forward.reversed()
    }

    /// From the first row moving to the last row landing, in seconds.
    static func total(rows: Int) -> Double {
        rows <= 0 ? 0 : Double(rows - 1) * step(rows: rows) + rowDuration
    }

    /// `rows` top to bottom as shown, each the entries it stands for. Empty rows are dropped, and
    /// an entry listed twice moves with its first row.
    init(rows: [[UUID]], direction: Direction) {
        var seen = Set<UUID>()
        let kept = rows.map { $0.filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
        let times = Self.delays(rows: kept.count, direction: direction)
        var out: [UUID: Double] = [:]
        for (row, t) in zip(kept, times) { for id in row { out[id] = t } }
        self.direction = direction
        self.delays = out
        self.ids = kept.flatMap { $0 }
        self.rowCount = kept.count
        // Leaving rows shrink out as soon as this is set; arriving rows wait hidden for `revealed()`.
        self.hidden = true
    }

    /// How many rows move.
    let rowCount: Int

    /// How long this cascade takes, first row moving to last landing.
    var total: Double { Self.total(rows: rowCount) }

    /// Arriving rows let go: they grow back in, each on its own delay.
    func revealed() -> LogbookCascade {
        var out = self
        out.hidden = false
        return out
    }

    /// Whether a row standing for these entries is in the cascade.
    func holds(_ entries: [UUID]) -> Bool {
        entries.contains { delays[$0] != nil }
    }

    /// Whether a row standing for these entries is hidden now.
    func hides(_ entries: [UUID]) -> Bool {
        hidden && holds(entries)
    }

    /// The row's delay: its earliest entry's, or nil when it isn't in the cascade.
    func delay(_ entries: [UUID]) -> Double? {
        entries.compactMap { delays[$0] }.min()
    }

    /// After an Undo: the rows that came back, in the order they were deleted, when they are the
    /// rows a cascade took away and there are still two or more of them. Rows that came back from
    /// elsewhere (a sync, one swipe) give nil, so they arrive as usual.
    static func restoring(added: Set<UUID>, deleted rows: [[UUID]]) -> [[UUID]]? {
        guard !added.isEmpty else { return nil }
        let back = rows.map { $0.filter(added.contains) }.filter { !$0.isEmpty }
        guard back.count >= 2 else { return nil }
        // Only when everything that arrived is ours: a sync bringing in others at the same time
        // shouldn't make them wait.
        let ours = Set(back.flatMap { $0 })
        guard added.isSubset(of: ours) else { return nil }
        return back
    }
}

/// What VoiceOver hears for a cascade: once per delete (the undo toast says it, "Deleted 3
/// entries") and once per Undo, never per row.
enum LogbookCascadeText {
    /// "Put back 3 entries", said once when an Undo has brought several rows back.
    static func restored(_ count: Int) -> String {
        count == 1 ? "Put back 1 entry" : "Put back \(count) entries"
    }
}
