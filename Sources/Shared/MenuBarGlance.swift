import Foundation

/// Everything the Mac menu bar item shows, worked out from the snapshot. Plain values only, so two
/// glances compare equal exactly when the item would look the same: the item is redrawn only when
/// this changes, never on a timer. The drawing itself lives in the app (MenuBarStatusItem.swift).
struct MenuBarGlance: Equatable {
    enum State: Equatable {
        /// No account set up yet.
        case notConnected
        /// Signed in, no reading yet.
        case waiting
        case live
        /// The latest reading is older than `GlucoseSnapshot.staleAfter`.
        case stale
    }

    var state: State
    /// "6.4", or "––" with no reading.
    var valueText: String
    /// The reading in mg/dL, so a change can roll up or down. Nil with no reading.
    var mgdl: Double?
    /// Nil when stale: an old reading has no trend worth showing.
    var trend: Trend?
    /// "+0.3", when the change is turned on and the reading is live.
    var deltaText: String?
    /// "12m", "1h 5m": how old a stale reading is, to the minute.
    var ageText: String?
    var range: GlucoseRange?
    /// The last hour, oldest first, scaled to 0...1 and rounded to 1/24 so small wobbles in a
    /// reading's history don't count as a change. Empty when turned off or too few readings.
    var sparkline: [Double]
    /// Whether the value is drawn in its range colour (urgent lows always are).
    var colored: Bool

    var hasReading: Bool { state == .live || state == .stale }

    /// The text form, for anything that can't draw the item (and the tests).
    var text: String {
        switch state {
        case .notConnected, .waiting: return valueText
        case .stale: return "\(valueText) · \(ageText ?? "")"
        case .live:
            var t = valueText
            if let trend { t += " \(trend.arrow)" }
            if let deltaText { t += " \(deltaText)" }
            return t
        }
    }
}

extension MenuBarGlance {
    /// Sparkline buckets: twelve five-minute slots over the last hour.
    static let sparklineBuckets = 12
    static let sparklineWindow: TimeInterval = 3600
    /// The sparkline's vertical scale never shrinks below this (2 mmol/L), so a flat hour reads as
    /// flat instead of noise stretched to full height.
    static let sparklineMinSpanMgdl: Double = 36

    static func make(snapshot: GlucoseSnapshot,
                     recent: [GlucoseReading],
                     hasCredentials: Bool,
                     showDelta: Bool,
                     showSparkline: Bool,
                     colorByRange: Bool,
                     now: Date = Date()) -> MenuBarGlance {
        guard let current = snapshot.current else {
            return MenuBarGlance(state: hasCredentials ? .waiting : .notConnected, valueText: "––", mgdl: nil,
                                 trend: nil, deltaText: nil, ageText: nil, range: nil, sparkline: [], colored: false)
        }
        let stale = snapshot.isStale(at: now)
        let range = snapshot.range
        var deltaText: String?
        if !stale, showDelta, let d = snapshot.deltaMgdl {
            deltaText = snapshot.unit.formatDelta(mgdl: d)
        }
        return MenuBarGlance(
            state: stale ? .stale : .live,
            valueText: snapshot.unit.format(mgdl: current.mgdl),
            mgdl: current.mgdl,
            trend: stale ? nil : current.trend,
            deltaText: deltaText,
            ageText: stale ? age(current.age(at: now)) : nil,
            range: range,
            sparkline: showSparkline ? sparkline(recent + [current], endingAt: current.timestamp) : [],
            colored: !stale && (colorByRange || range == .urgentLow))
    }

    /// The next moment the glance would change with no new data: when a live reading goes stale,
    /// or when a stale reading's age ticks over to the next minute (the next day past a day).
    /// Nil with no reading. The item sets one timer for this instead of re-checking on a tick.
    static func nextChange(snapshot: GlucoseSnapshot, now: Date = Date()) -> Date? {
        guard let current = snapshot.current else { return nil }
        let age = current.age(at: now)
        if age <= GlucoseSnapshot.staleAfter {
            // isStale is "older than", so it flips just after the threshold.
            return current.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter + 1)
        }
        let step: TimeInterval = age >= 86_400 ? 86_400 : 60
        let next = (floor(age / step) + 1) * step
        return current.timestamp.addingTimeInterval(next)
    }

    /// "7m", "1h 5m", "2d", the same as the popover's age.
    static func age(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval)) / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(h / 24)d"
    }

    /// The hour up to `end`, averaged into five-minute slots (empty slots skipped), scaled to 0...1
    /// and rounded. Fewer than three slots with readings draws nothing.
    static func sparkline(_ readings: [GlucoseReading], endingAt end: Date) -> [Double] {
        let start = end.addingTimeInterval(-sparklineWindow)
        let slot = sparklineWindow / Double(sparklineBuckets)
        var sums = [Double](repeating: 0, count: sparklineBuckets)
        var counts = [Int](repeating: 0, count: sparklineBuckets)
        var seen = Set<Date>()
        for r in readings where r.timestamp > start && r.timestamp <= end && seen.insert(r.timestamp).inserted {
            let i = min(sparklineBuckets - 1, Int(r.timestamp.timeIntervalSince(start) / slot))
            sums[i] += r.mgdl
            counts[i] += 1
        }
        let values = zip(sums, counts).compactMap { $1 > 0 ? $0 / Double($1) : nil }
        guard values.count >= 3, let lo = values.min(), let hi = values.max() else { return [] }
        let span = max(sparklineMinSpanMgdl, hi - lo)
        let mid = (lo + hi) / 2
        let floorValue = mid - span / 2
        return values.map { v in
            let unit = min(1, max(0, (v - floorValue) / span))
            return (unit * 24).rounded() / 24
        }
    }
}
