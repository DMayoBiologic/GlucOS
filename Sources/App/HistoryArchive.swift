import Foundation

/// Every reading GlucOS has seen, kept on disk so the dashboard can show days and weeks of history.
/// LibreLinkUp only ever returns the last ~12 hours, so long ranges are built up locally while
/// GlucOS runs (and each fetch back-fills the 12 hours before it, covering sleep and restarts).
///
/// Purely additive: it records what `GlucoseStore` already fetched and never affects fetching,
/// the widget snapshot, or alerts.
struct HistoryArchive {
    /// How long readings are kept.
    static let retention: TimeInterval = 90 * 86_400
    /// At most one reading per slot. Libre's graph data is 5–15 min apart and the current reading
    /// changes every minute, so without this the minute-by-minute readings taken while the Mac is
    /// awake would outweigh the back-filled ones in every average.
    static let slot: TimeInterval = 5 * 60

    /// Oldest → newest.
    private(set) var readings: [GlucoseReading] = []
    private var slots = Set<Int>()

    private static var url: URL? {
        SharedStore.containerURL?.appendingPathComponent("history.json")
    }

    private static let writeQueue = DispatchQueue(label: "au.com.declanmayo.glucos.history", qos: .utility)

    private static func slotKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / slot).rounded(.down))
    }

    static func load() -> HistoryArchive {
        var archive = HistoryArchive()
        guard let url, let data = try? Data(contentsOf: url) else { return archive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let stored = try? decoder.decode([GlucoseReading].self, from: data) {
            _ = archive.merge(stored)
        }
        return archive
    }

    /// Adds readings whose 5-minute slot isn't filled yet and drops readings past retention.
    /// Returns whether anything changed.
    mutating func merge(_ incoming: [GlucoseReading], now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var added = false
        for r in incoming where r.timestamp >= cutoff && r.timestamp <= now.addingTimeInterval(600) {
            if slots.insert(Self.slotKey(r.timestamp)).inserted {
                readings.append(r)
                added = true
            }
        }
        if added { readings.sort { $0.timestamp < $1.timestamp } }

        var pruned = false
        if let first = readings.first, first.timestamp < cutoff {
            let keep = readings.firstIndex { $0.timestamp >= cutoff } ?? readings.endIndex
            for r in readings[..<keep] { slots.remove(Self.slotKey(r.timestamp)) }
            readings.removeFirst(keep)
            pruned = true
        }
        return added || pruned
    }

    /// Writes to disk off the main thread. Writes are serialised so an older copy never lands last.
    func save() {
        guard let url = Self.url else { return }
        let snapshot = readings
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
