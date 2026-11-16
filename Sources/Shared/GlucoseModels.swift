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

    /// The direction of travel as a turn of a right-pointing arrow, in degrees clockwise: −90 points
    /// up (rising quickly), 90 points down. One arrow turned to this angle replaces the five arrow
    /// glyphs wherever the trend can change in place, so a new trend swings the arrow round rather
    /// than swapping one glyph for another (`TrendDial`, `TrendArrow`). Unknown sits level.
    var needleAngle: Double {
        switch self {
        case .risingQuickly: return -90
        case .rising: return -45
        case .flat, .unknown: return 0
        case .falling: return 45
        case .fallingQuickly: return 90
        }
    }

    var isRapid: Bool { self == .fallingQuickly || self == .risingQuickly }
    var isFalling: Bool { self == .fallingQuickly || self == .falling }
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

/// A new sensor's first hour, before it gives any readings (Libre 2 Plus and Libre 3 both take 60
/// minutes). LibreLinkUp reports the new sensor's start straight away, while its last reading is
/// still the old sensor's, so "warming up" is a sensor that started under an hour ago with no
/// reading of its own yet. Shown as a countdown on iPhone Today and the Live Activity.
struct SensorWarmUp: Hashable {
    static let duration: TimeInterval = 60 * 60
    /// After the hour, how long "any minute now" is still said before the usual waiting screen:
    /// LibreLinkUp often takes a few minutes to pass the first reading on.
    static let grace: TimeInterval = 20 * 60

    let startedAt: Date
    var endsAt: Date { startedAt.addingTimeInterval(Self.duration) }

    /// The warm-up going on now, or nil: no sensor, it's past the hour (plus the grace), or the
    /// new sensor has already given a reading.
    static func current(sensor: SensorInfo?, current: GlucoseReading?, at now: Date = Date()) -> SensorWarmUp? {
        guard let sensor else { return nil }
        let started = sensor.activated
        // A start in the future is a clock problem, not a warm-up; allow a minute of skew.
        guard started.timeIntervalSince(now) <= 60,
              now.timeIntervalSince(started) < duration + grace else { return nil }
        if let current, current.timestamp >= started { return nil }
        return SensorWarmUp(startedAt: started)
    }

    func remaining(at now: Date = Date()) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }

    /// How much of the hour has passed, 0...1.
    func fraction(at now: Date = Date()) -> Double {
        min(1, max(0, now.timeIntervalSince(startedAt) / Self.duration))
    }

    /// Whole minutes left, rounded up, so it never says 0 while there's still time to go.
    func minutesLeft(at now: Date = Date()) -> Int {
        Int((remaining(at: now) / 60).rounded(.up))
    }

    /// "Readings start in about 42 min", then "any minute now" once the hour is up.
    func headline(at now: Date = Date()) -> String {
        let m = minutesLeft(at: now)
        if m <= 0 { return "Readings start any minute now" }
        return "Readings start in about \(m) min"
    }

    /// The next moment the countdown reads differently with no new data: each minute of the hour,
    /// then the end of the grace, when the warm-up gives way to the usual waiting screen. Nil once
    /// it's over. The Mac menu bar item sets one timer for this instead of ticking.
    func nextChange(after now: Date) -> Date? {
        let m = minutesLeft(at: now)
        if m > 0 { return endsAt.addingTimeInterval(-Double(m - 1) * 60) }
        let over = endsAt.addingTimeInterval(Self.grace)
        return over > now ? over : nil
    }

    /// Every such moment from `now` to the end of the grace, for a view that redraws only then.
    func changeMoments(from now: Date) -> [Date] {
        var out: [Date] = []
        var t = now
        while let next = nextChange(after: t), out.count < 100 {
            out.append(next)
            t = next
        }
        return out
    }
}

/// Signed in and connected, but LibreLinkUp has no reading at all: what to do about it, for the
/// iPhone's Today and the Mac popover. Nil while the first fetch is still going, or when there's a
/// connection problem (its own notice already says what to do).
struct NoReadingsStep: Equatable {
    let title: String
    let detail: String
    let systemImage: String

    static func current(snapshot s: GlucoseSnapshot, hasConnectionProblem: Bool, at now: Date = Date()) -> NoReadingsStep? {
        guard s.current == nil, !hasConnectionProblem, s.fetchedAt != .distantPast else { return nil }
        if let sensor = s.sensor, sensor.daysRemaining(at: now) <= 0 {
            return NoReadingsStep(
                title: "Your sensor has ended",
                detail: "Apply a new sensor and start it in the LibreLink app. GlucOS counts down its hour of warm-up here, then shows the first reading.",
                systemImage: "sensor.tag.radiowaves.forward")
        }
        return NoReadingsStep(
            title: "No readings yet",
            detail: "Starting a new sensor? Start it in the LibreLink app; readings arrive about an hour later and GlucOS counts down to them here. Already wearing one? Open LibreLink on the phone that reads the sensor so it can upload.",
            systemImage: "drop")
    }
}

extension GlucoseSnapshot {
    func warmUp(at now: Date = Date()) -> SensorWarmUp? {
        SensorWarmUp.current(sensor: sensor, current: current, at: now)
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
    /// Forecast and insulin/carbs still acting, worked out by the app. Estimates only.
    var outlook: OutlookSnapshot?
    /// Today so far against your usual day, worked out by the app for the large widget. Nil until
    /// today has an hour of readings.
    var today: TodayGlance?
    /// The "Your usual" entries for now, worked out by the iPhone app for the Your usual widget
    /// (docs/UsualEntries.md). Nil on the Mac, or before the logbook has loaded.
    var usuals: [UsualGlance]?

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

// MARK: - Shared store (~/Library/Application Support/GlucOS on the Mac, the app group on iPhone)

enum SharedStore {
    #if os(iOS)
    /// Shared between the iPhone app and its widgets (Lock Screen card, Home Screen widgets).
    static let appGroup = "group.au.com.declanmayo.glucos"

    /// Settings the app shares with its extensions (the Messages app). Falls back to the app's own
    /// defaults in a build without the app group.
    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    /// The app group's folder. A build without the app group (an unsigned CI build) falls back
    /// to the app's own Application Support, where only the app can see it.
    static var containerURL: URL? {
        let fm = FileManager.default
        guard let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
                ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("GlucOS", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    #else
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
    #endif

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
