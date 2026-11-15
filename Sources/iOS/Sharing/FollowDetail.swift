import Foundation

// The follower view's data on the phone (docs/Sharing.md "What followers see"): up to 14 days of
// the owner's readings, topped up a few rows at a time from the share function's /v1/detail, and
// their last 48 hours of logbook. Plain Foundation so `swift test` covers the merging. Not in
// Sources/Core because it needs the logbook sync types, which the Messages app doesn't build.

/// Everything the follower view shows beyond the Lock Screen card: readings for the chart and
/// time in range, and the owner's recent logbook. Mirrors `ShareDetail` in
/// supabase/functions/share/detail.ts.
struct ShareDetail: Decodable, Equatable {
    /// [seconds since 1970, mg/dL] in 5-minute buckets after the `since` asked for, oldest first.
    var readings: [[Double]]
    var showsLogbook: Bool
    /// The last 48 hours of doses, meals, site changes and moments (notes blanked), newest first.
    /// Nil when the owner hides it or has never signed in to logbook sync.
    var logbook: [LogbookRecord]?
    var generatedAt: Double
}

/// Someone's readings as this phone has them: one per 5-minute bucket, oldest first.
struct FollowHistory: Equatable {
    static let bucket: TimeInterval = 5 * 60
    static let keep: TimeInterval = 14 * 86_400

    private var byBucket: [Int: GlucoseReading] = [:]
    /// Sorted, oldest first.
    private(set) var readings: [GlucoseReading] = []

    init() {}

    var isEmpty: Bool { readings.isEmpty }

    /// What to ask for next: the start of the newest bucket, which may still have been filling
    /// when it was fetched. Nil: everything.
    var since: Double? {
        readings.last.map { (floor($0.timestamp.timeIntervalSince1970 / Self.bucket) * Self.bucket) }
    }

    /// Adds `rows` ([seconds, mg/dL], as the share function sends them); a bucket seen again
    /// replaces the old one. Readings older than `keep` are dropped.
    mutating func merge(_ rows: [[Double]], now: Date = Date()) {
        for row in rows where row.count >= 2 && row[1] > 0 {
            let key = Int(floor(row[0] / Self.bucket))
            byBucket[key] = GlucoseReading(timestamp: Date(timeIntervalSince1970: row[0]), mgdl: row[1], trend: .unknown)
        }
        let cutoff = Int(floor((now.timeIntervalSince1970 - Self.keep) / Self.bucket))
        byBucket = byBucket.filter { $0.key >= cutoff }
        readings = byBucket.sorted { $0.key < $1.key }.map(\.value)
    }

    func readings(lastHours hours: Double, now: Date = Date()) -> [GlucoseReading] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        guard let first = readings.firstIndex(where: { $0.timestamp >= cutoff }) else { return [] }
        return Array(readings[first...])
    }
}

/// The owner's recent logbook as a follower sees it.
struct FollowLogbook: Equatable {
    var contents = LogbookContents()

    init(records: [LogbookRecord]) {
        var state = LogbookSyncState()
        LogbookMerge.apply(records, to: &contents, state: &state)
    }

    /// Newest first.
    var entries: [LogEntry] {
        let all: [LogEntry] = contents.doses.map(LogEntry.dose) + contents.meals.map(LogEntry.meal)
            + contents.siteChanges.map(LogEntry.siteChange) + contents.contexts.map(LogEntry.context)
        return all.sorted { $0.timestamp > $1.timestamp }
    }
}

/// Everything the follower view has for one person.
struct FollowDetail: Equatable {
    var history = FollowHistory()
    /// Nil while it's hidden, unavailable, or not fetched yet.
    var logbook: FollowLogbook?
    /// The owner shares their logbook on this link.
    var showsLogbook = true
    var fetchedAt: Date?

    mutating func apply(_ d: ShareDetail, now: Date = Date()) {
        history.merge(d.readings, now: now)
        showsLogbook = d.showsLogbook
        logbook = d.logbook.map(FollowLogbook.init(records:))
        fetchedAt = now
    }
}
