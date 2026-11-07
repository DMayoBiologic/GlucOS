import Foundation

// MARK: - Units

enum GlucoseUnit: String, Codable, CaseIterable, Identifiable {
    case mmol
    case mgdl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mmol: return "mmol/L"
        case .mgdl: return "mg/dL"
        }
    }

    static let mgdlPerMmol = 18.0182

    func value(fromMgdl mgdl: Double) -> Double {
        switch self {
        case .mmol: return mgdl / Self.mgdlPerMmol
        case .mgdl: return mgdl
        }
    }

    func mgdl(fromDisplay value: Double) -> Double {
        switch self {
        case .mmol: return value * Self.mgdlPerMmol
        case .mgdl: return value
        }
    }

    func format(mgdl: Double, withUnit: Bool = false) -> String {
        let v = value(fromMgdl: mgdl)
        let s: String
        switch self {
        case .mmol: s = String(format: "%.1f", v)
        case .mgdl: s = String(format: "%.0f", v)
        }
        return withUnit ? "\(s) \(label)" : s
    }

    /// Signed delta, e.g. "+0.3", "−12" or "±0.0". The sign follows the *displayed* value, so a
    /// tiny negative change never shows as "−0.0".
    func formatDelta(mgdl: Double) -> String {
        let v = value(fromMgdl: mgdl)
        let digits = self == .mmol ? 1 : 0
        let scale = digits == 1 ? 10.0 : 1.0
        let rounded = (v * scale).rounded() / scale
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "±")
        return sign + String(format: "%.\(digits)f", abs(rounded))
    }
}

// MARK: - Trend

enum Trend: Int, Codable {
    case unknown = 0
    case fallingQuickly = 1
    case falling = 2
    case flat = 3
    case rising = 4
    case risingQuickly = 5

    var arrow: String {
        switch self {
        case .fallingQuickly: return "↓"
        case .falling: return "↘"
        case .flat: return "→"
        case .rising: return "↗"
        case .risingQuickly: return "↑"
        case .unknown: return "?"
        }
    }

    var systemImage: String {
        switch self {
        case .fallingQuickly: return "arrow.down"
        case .falling: return "arrow.down.right"
        case .flat: return "arrow.right"
        case .rising: return "arrow.up.right"
        case .risingQuickly: return "arrow.up"
        case .unknown: return "questionmark"
        }
    }

    var description: String {
        switch self {
        case .fallingQuickly: return "Falling quickly"
        case .falling: return "Falling"
        case .flat: return "Steady"
        case .rising: return "Rising"
        case .risingQuickly: return "Rising quickly"
        case .unknown: return "Unknown"
        }
    }

    var isRapid: Bool { self == .fallingQuickly || self == .risingQuickly }
}

// MARK: - Reading

struct GlucoseReading: Codable, Identifiable, Hashable {
    let timestamp: Date
    let mgdl: Double
    let trend: Trend

    var id: Date { timestamp }
    var mmol: Double { mgdl / GlucoseUnit.mgdlPerMmol }

    func age(at now: Date = Date()) -> TimeInterval { now.timeIntervalSince(timestamp) }
}

// MARK: - Sensor

struct SensorInfo: Codable, Hashable {
    let serial: String
    let activated: Date
    let lifetimeDays: Int

    var expires: Date { activated.addingTimeInterval(Double(lifetimeDays) * 86_400) }

    func daysRemaining(at now: Date = Date()) -> Double {
        max(0, expires.timeIntervalSince(now) / 86_400)
    }
}

// MARK: - Range classification

enum GlucoseRange {
    case urgentLow, low, inRange, high, veryHigh

    static let urgentLowMgdl = 54.0     // 3.0 mmol/L
    static let veryHighMgdl = 250.0     // 13.9 mmol/L

    static func classify(mgdl: Double, low: Double, high: Double) -> GlucoseRange {
        if mgdl < urgentLowMgdl { return .urgentLow }
        if mgdl < low { return .low }
        // A user high threshold above 13.9 must not make in-range readings "very high".
        if mgdl > max(veryHighMgdl, high) { return .veryHigh }
        if mgdl > high { return .high }
        return .inRange
    }
}

// MARK: - Stats

struct GlucoseStats: Codable, Hashable {
    let count: Int
    let meanMgdl: Double
    let minMgdl: Double
    let maxMgdl: Double
    let sdMgdl: Double
    let timeInRange: Double     // 0...1
    let timeBelowRange: Double
    let timeAboveRange: Double
    let spanHours: Double

    /// Glucose Management Indicator (%). Only meaningful over ~14 days, but shown as a hint.
    var gmiPercent: Double { 3.31 + 0.02392 * meanMgdl }
    var coefficientOfVariation: Double { meanMgdl > 0 ? sdMgdl / meanMgdl : 0 }

    /// Longest gap a single reading is allowed to "cover". Bigger gaps are treated as missing data
    /// rather than stretching the previous value across them.
    static let maxGap: TimeInterval = 15 * 60

    /// Time-weighted stats: each reading counts for the time until the next one (capped at
    /// `maxGap`). The history mixes 15-min graph points with 1-min live readings, so a plain
    /// count-weighted average would massively over-weight the most recent minutes.
    static func compute(_ readings: [GlucoseReading], low: Double, high: Double) -> GlucoseStats? {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        var weights = [Double](repeating: 0, count: sorted.count)
        for i in sorted.indices {
            if i + 1 < sorted.count {
                weights[i] = min(max(0, sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)), maxGap)
            } else {
                weights[i] = 60   // the latest reading stands for roughly the next minute
            }
        }
        let total = weights.reduce(0, +)
        let values = sorted.map(\.mgdl)

        var mean = 0.0, below = 0.0, above = 0.0
        for (v, w) in zip(values, weights) {
            mean += v * w
            if v < low { below += w } else if v > high { above += w }
        }
        mean /= total
        let variance = zip(values, weights).reduce(0) { $0 + $1.1 * ($1.0 - mean) * ($1.0 - mean) } / total

        return GlucoseStats(
            count: values.count,
            meanMgdl: mean,
            minMgdl: values.min()!,
            maxMgdl: values.max()!,
            sdMgdl: variance.squareRoot(),
            timeInRange: max(0, 1 - below / total - above / total),
            timeBelowRange: below / total,
            timeAboveRange: above / total,
            spanHours: last.timestamp.timeIntervalSince(first.timestamp) / 3600
        )
    }
}

// MARK: - Snapshot (what the app writes and the widget reads)

struct GlucoseSnapshot: Codable, Equatable {
    var current: GlucoseReading?
    var history: [GlucoseReading] = []      // oldest → newest, up to `historyWindow`, includes `current`
    var sensor: SensorInfo?
    var unit: GlucoseUnit = .mmol
    var lowMgdl: Double = 70                 // 3.9 mmol/L
    var highMgdl: Double = 180               // 10.0 mmol/L
    var fetchedAt: Date = .distantPast
    var lastError: String?

    static let staleAfter: TimeInterval = 6 * 60
    static let historyWindow: TimeInterval = 24 * 3600
    /// Don't report a delta against a reading this far back — it'd be meaningless.
    static let maxDeltaGap: TimeInterval = 20 * 60
    static let empty = GlucoseSnapshot()

    func isStale(at now: Date = Date()) -> Bool {
        guard let current else { return true }
        return current.age(at: now) > Self.staleAfter
    }

    var previous: GlucoseReading? {
        guard let current else { return nil }
        // Most recent historical point at least ~4 minutes older than the current one.
        guard let p = history.last(where: { current.timestamp.timeIntervalSince($0.timestamp) >= 240 }),
              current.timestamp.timeIntervalSince(p.timestamp) <= Self.maxDeltaGap
        else { return nil }
        return p
    }

    var deltaMgdl: Double? {
        guard let current, let previous else { return nil }
        return current.mgdl - previous.mgdl
    }

    var range: GlucoseRange? {
        current.map { GlucoseRange.classify(mgdl: $0.mgdl, low: lowMgdl, high: highMgdl) }
    }

    func stats(hours: Double? = nil) -> GlucoseStats? {
        var points = history
        if let current, !points.contains(where: { $0.timestamp == current.timestamp }) {
            points.append(current)
        }
        if let hours, let latest = points.last {
            let cutoff = latest.timestamp.addingTimeInterval(-hours * 3600)
            points = points.filter { $0.timestamp >= cutoff }
        }
        return GlucoseStats.compute(points, low: lowMgdl, high: highMgdl)
    }

    /// Builds the history to keep from what we had, a fresh `/graph` response and the live reading.
    ///
    /// The graph endpoint only returns ~12 h of 15-minute points, while the live reading updates
    /// every minute. To get a chart that reaches "now", a usable delta and 24 h of stats, we keep:
    ///   • our own older points from before the graph's window (extends history past 12 h),
    ///   • the graph points themselves (authoritative for their window),
    ///   • live readings collected after the last graph point.
    /// Live and graph points are never interleaved: the two series are smoothed differently
    /// and mixing them makes the line zig-zag.
    static func mergeHistory(previous: [GlucoseReading],
                             graph: [GlucoseReading],
                             current: GlucoseReading?,
                             window: TimeInterval = historyWindow) -> [GlucoseReading] {
        let graph = graph.sorted { $0.timestamp < $1.timestamp }
        var live = previous
        if let current { live.append(current) }

        var merged: [GlucoseReading]
        if let gFirst = graph.first?.timestamp, let gLast = graph.last?.timestamp {
            let older = previous.filter { $0.timestamp < gFirst.addingTimeInterval(-30) }
            let newer = live.filter { $0.timestamp > gLast.addingTimeInterval(30) }
            merged = older + graph + newer
        } else {
            merged = live
        }

        // Sort and drop duplicate timestamps (later entries win).
        var byTime: [Date: GlucoseReading] = [:]
        for r in merged { byTime[r.timestamp] = r }
        merged = byTime.values.sorted { $0.timestamp < $1.timestamp }

        guard let latest = merged.last?.timestamp else { return [] }
        let cutoff = latest.addingTimeInterval(-window)
        return merged.filter { $0.timestamp >= cutoff }
    }

    /// Text for the menu bar / small widget.
    var compactText: String {
        guard let current else { return "––" }
        return "\(unit.format(mgdl: current.mgdl)) \(current.trend.arrow)"
    }
}

// MARK: - Shared store (~/Library/Application Support/GlucOS)

enum SharedStore {
    /// The real ~/Library/Application Support/GlucOS. Inside the widget's sandbox the home
    /// directory APIs point at its container, so this goes through the password database.
    /// The widget's entitlements grant read-only access to exactly this folder.
    static var containerURL: URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        let url = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/GlucOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("snapshot.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load() -> GlucoseSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(GlucoseSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: GlucoseSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func age(_ interval: TimeInterval) -> String {
        if interval < 60 { return "now" }
        let m = Int(interval / 60)
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m ago" }
        return "\(h / 24)d ago"
    }

    /// "45 s", "4 min", "15 min".
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func days(_ d: Double) -> String {
        if d >= 2 { return String(format: "%.0f days", d.rounded(.down)) }
        if d >= 1 { return "1 day" }
        let h = Int(d * 24)
        return h <= 1 ? "<1 hour" : "\(h) hours"
    }
}
