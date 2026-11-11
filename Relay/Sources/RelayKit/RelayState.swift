import Foundation

/// Everything the relay remembers between restarts. One phone, one account: GlucOS is personal.
struct RelayState: Codable {
    struct ActivityRecord: Codable, Equatable {
        var id: String
        /// Update token (hex) for this activity.
        var token: String
        var startedAt: Date
    }

    var deviceToken: String?
    var pushToStartToken: String?
    var activity: ActivityRecord?
    var liveActivityEnabled = true
    var sandbox = false
    var account: RelayRegistration.Account?
    var display = RelayRegistration.Display(unit: GlucoseUnit.mmol.rawValue, lowMgdl: 70, highMgdl: 180)
    var alerts = AlertPreferences()

    /// Recent readings, oldest first, for the card's sparkline and the forecast.
    var readings: [GlucoseReading] = []
    var current: GlucoseReading?
    var sensor: SensorInfo?

    /// The relay ended an activity at iOS's 8-hour limit and is starting the next one.
    var pendingStart = false
    var startAttempts = 0
    var lastStartAttempt: Date?
    var lastActivityState: GlucoseActivityState?
    var lastActivityPushAt: Date?

    var lastFetchAt: Date?
    var lastError: String?
    var lastPushAt: Date?
    var lastPushError: String?

    /// How long readings are kept.
    static let readingRetention: TimeInterval = 48 * 3600

    mutating func merge(_ incoming: [GlucoseReading], now: Date) {
        var byTime = Dictionary(readings.map { ($0.timestamp, $0) }, uniquingKeysWith: { a, _ in a })
        for r in incoming { byTime[r.timestamp] = r }
        let cutoff = now.addingTimeInterval(-Self.readingRetention)
        readings = byTime.values.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }

    func snapshot() -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.current = current
        if let current {
            let cutoff = current.timestamp.addingTimeInterval(-12 * 3600)
            s.history = readings.filter { $0.timestamp >= cutoff && $0.timestamp < current.timestamp }
        }
        s.sensor = sensor
        s.unit = GlucoseUnit(rawValue: display.unit) ?? .mmol
        s.lowMgdl = display.lowMgdl
        s.highMgdl = display.highMgdl
        s.fetchedAt = lastFetchAt ?? .distantPast
        s.lastError = lastError
        return s
    }
}

/// Reads and writes `state.json` in the data directory. Credentials are in it, so it's owner-only.
struct StateStore: Sendable {
    let url: URL

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("state.json")
    }

    func load() -> RelayState {
        guard let data = try? Data(contentsOf: url) else { return RelayState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(RelayState.self, from: data)) ?? RelayState()
    }

    func save(_ state: RelayState) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
