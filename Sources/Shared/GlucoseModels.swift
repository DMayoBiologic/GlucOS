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

    /// Signed delta, e.g. "+0.3" or "−12".
    func formatDelta(mgdl: Double) -> String {
        let v = value(fromMgdl: mgdl)
        let sign = v >= 0 ? "+" : "−"
        switch self {
        case .mmol: return String(format: "%@%.1f", sign, abs(v))
        case .mgdl: return String(format: "%@%.0f", sign, abs(v))
        }
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

    static func classify(mgdl: Double, low: Double, high: Double) -> GlucoseRange {
        if mgdl < 54 { return .urgentLow }           // 3.0 mmol/L
        if mgdl < low { return .low }
        if mgdl > 250 { return .veryHigh }           // 13.9 mmol/L
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

    static func compute(_ readings: [GlucoseReading], low: Double, high: Double) -> GlucoseStats? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map(\.mgdl)
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(1, n - 1)
        let below = Double(values.filter { $0 < low }.count) / n
        let above = Double(values.filter { $0 > high }.count) / n
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        let span = (sorted.last!.timestamp.timeIntervalSince(sorted.first!.timestamp)) / 3600
        return GlucoseStats(
            count: values.count,
            meanMgdl: mean,
            minMgdl: values.min()!,
            maxMgdl: values.max()!,
            sdMgdl: variance.squareRoot(),
            timeInRange: 1 - below - above,
            timeBelowRange: below,
            timeAboveRange: above,
            spanHours: span
        )
    }
}

// MARK: - Snapshot (what the app writes and the widget reads)

struct GlucoseSnapshot: Codable {
    var current: GlucoseReading?
    var history: [GlucoseReading] = []      // oldest → newest, ~12 h
    var sensor: SensorInfo?
    var unit: GlucoseUnit = .mmol
    var lowMgdl: Double = 70                 // 3.9 mmol/L
    var highMgdl: Double = 180               // 10.0 mmol/L
    var fetchedAt: Date = .distantPast
    var lastError: String?

    static let staleAfter: TimeInterval = 6 * 60
    static let empty = GlucoseSnapshot()

    func isStale(at now: Date = Date()) -> Bool {
        guard let current else { return true }
        return current.age(at: now) > Self.staleAfter
    }

    var previous: GlucoseReading? {
        guard let current else { return nil }
        // Most recent historical point at least ~4 minutes older than the current one.
        return history.last { current.timestamp.timeIntervalSince($0.timestamp) >= 240 }
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
