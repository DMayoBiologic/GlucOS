import Foundation

// Low and high alerts grouped by episode (docs/AlertEpisodes.md). Every alert from one time below
// range (or one time above it) shares a notification identifier, so a newer one replaces the older
// one in Notification Centre instead of stacking, and still plays its sound: replacing never
// quietens an alert. When a reading is back in range, the episode's alert is replaced one last time
// by a quiet summary, "Back in range after 25 min", with the lowest (or highest) reading.
//
// The relay keeps the same rules in core.ts (`observeEpisodes`, `recordEpisodeAlert`), so local
// alerts and pushes are keyed alike. Plain Foundation, unit-tested in AlertEpisodesTests.

struct AlertEpisodes: Codable, Hashable {
    enum Side: String, Codable, Hashable {
        case low, high
    }

    /// An alert shown for an episode.
    struct Shown: Codable, Hashable {
        let kind: AlertNotice.Kind
        let at: Date
    }

    struct Episode: Codable, Hashable {
        let side: Side
        /// When it began: the first reading out of range, or the first heads-up before one.
        let key: Date
        /// The first and latest readings out of range. Nil while only a heads-up has fired.
        var outSince: Date?
        var lastOutAt: Date?
        /// Lowest reading (lows) or highest (highs) while out of range, mg/dL.
        var extremeMgdl: Double?
        var lastAlertAt: Date?
        /// The alerts shown for it, oldest first, at most `shownLimit`.
        var shown: [Shown] = []

        /// The notification identifier (and APNs collapse id) every alert of this episode uses.
        var identifier: String { "glucos.\(side.rawValue).\(Int(key.timeIntervalSince1970))" }
    }

    /// The quiet update that replaces an episode's alert once glucose is back in range.
    struct BackInRange: Hashable {
        let side: Side
        let identifier: String
        let minutes: Int
        let extremeMgdl: Double
        let nowMgdl: Double
        /// The alerts it replaces, so the Logbook can still record them (`AlertLogRecorder`).
        let shown: [Shown]

        func title() -> String { "Back in range after \(AlertEpisodes.duration(minutes))" }

        func body(unit: GlucoseUnit) -> String {
            let word = side == .low ? "Lowest" : "Highest"
            return "\(word) \(unit.format(mgdl: extremeMgdl, withUnit: true)), now \(unit.format(mgdl: nowMgdl, withUnit: true))."
        }
    }

    private(set) var low: Episode?
    private(set) var high: Episode?

    /// Readings that stop for longer than this end the episode without a summary: nobody knows
    /// when it was really over.
    static let gapLimit: TimeInterval = 30 * 60
    /// A heads-up that never became a reading out of range ends this long after its last alert.
    static let headsUpFor: TimeInterval = 45 * 60
    static let shownLimit = 12
    /// In a "Back in range" summary's userInfo / push payload: the side, "low" or "high".
    static let backInRangeKey = "backInRange"

    init() {}

    /// Which episode an alert belongs to. Nil for the rest (rapid change, no data, sensor…), which
    /// keep their own identifiers.
    static func side(of kind: AlertNotice.Kind) -> Side? {
        switch kind {
        case .urgentLow, .low, .predictedUrgentLow, .predictedLow: return .low
        case .high, .veryHigh, .predictedHigh, .predictedVeryHigh: return .high
        case .rapidChange, .stale, .sensorExpiring, .apiBroken: return nil
        }
    }

    /// Call with every reading, before `record`. Returns the episodes this reading ended that had
    /// an alert shown, as summaries to deliver.
    mutating func observe(_ s: GlucoseSnapshot, now: Date) -> [BackInRange] {
        guard let r = s.current, !s.isStale(at: now) else { return [] }
        switch GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl) {
        case .urgentLow, .low:
            high = nil
            mark(.low, r)
            return []
        case .high, .veryHigh:
            low = nil
            mark(.high, r)
            return []
        case .inRange:
            return [Side.low, .high].compactMap { end($0, at: r, now: now) }
        }
    }

    /// An alert about to be shown: its identifier, opening an episode if none is going, and the
    /// alerts it replaces. Nil for alerts that aren't part of an episode.
    mutating func record(_ kind: AlertNotice.Kind, now: Date) -> (identifier: String, earlier: [Shown])? {
        guard let side = Self.side(of: kind) else { return nil }
        var e = episode(side) ?? Episode(side: side, key: now)
        let earlier = e.shown
        e.shown.append(Shown(kind: kind, at: now))
        if e.shown.count > Self.shownLimit { e.shown.removeFirst(e.shown.count - Self.shownLimit) }
        e.lastAlertAt = now
        set(side, e)
        return (e.identifier, earlier)
    }

    /// The identifier for `notice`: its episode's, or its own.
    mutating func identifier(for notice: AlertNotice, now: Date) -> String {
        record(notice.kind, now: now)?.identifier ?? notice.identifier
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: -

    func episode(_ side: Side) -> Episode? { side == .low ? low : high }

    private mutating func set(_ side: Side, _ e: Episode?) {
        if side == .low { low = e } else { high = e }
    }

    private mutating func mark(_ side: Side, _ r: GlucoseReading) {
        var e = episode(side) ?? Episode(side: side, key: r.timestamp)
        if e.outSince == nil { e.outSince = r.timestamp }
        e.lastOutAt = r.timestamp
        let worse = side == .low ? min(e.extremeMgdl ?? r.mgdl, r.mgdl) : max(e.extremeMgdl ?? r.mgdl, r.mgdl)
        e.extremeMgdl = worse
        set(side, e)
    }

    private mutating func end(_ side: Side, at r: GlucoseReading, now: Date) -> BackInRange? {
        guard let e = episode(side) else { return nil }
        guard let since = e.outSince, let lastOut = e.lastOutAt, let extreme = e.extremeMgdl else {
            // Only a heads-up so far: it stays open a while, so a repeat replaces it.
            if let last = e.lastAlertAt, now.timeIntervalSince(last) < Self.headsUpFor { return nil }
            set(side, nil)
            return nil
        }
        set(side, nil)
        guard !e.shown.isEmpty, r.timestamp.timeIntervalSince(lastOut) <= Self.gapLimit else { return nil }
        let minutes = max(1, Int((r.timestamp.timeIntervalSince(since) / 60).rounded()))
        return BackInRange(side: side, identifier: e.identifier, minutes: minutes, extremeMgdl: extreme,
                           nowMgdl: r.mgdl, shown: e.shown)
    }
}

extension AlertEpisodes.Shown {
    /// In a notification's userInfo / push payload under `earlierKey`: [[kind, seconds since 1970]].
    static let earlierKey = "earlier"

    var userInfoValue: [Any] { [kind.rawValue, Int(at.timeIntervalSince1970)] }

    static func list(from value: Any?) -> [AlertEpisodes.Shown] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let pair = item as? [Any], pair.count == 2, let raw = pair[0] as? String,
                  let kind = AlertNotice.Kind(rawValue: raw) else { return nil }
            let seconds: Double
            switch pair[1] {
            case let i as Int: seconds = Double(i)
            case let d as Double: seconds = d
            case let n as NSNumber: seconds = n.doubleValue
            default: return nil
            }
            return AlertEpisodes.Shown(kind: kind, at: Date(timeIntervalSince1970: seconds))
        }
    }
}
