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
    /// What moves when the item goes from one glance to the next. The item draws a short run of
    /// frames for anything but `.none`, once, and never on a timer.
    enum Change: Equatable {
        /// Swaps at once: a setting, the age of a stale reading ticking over.
        case none
        /// A new value rolls in, up or down with the change.
        case roll
        /// The signal is lost: the value fades to grey and the strike draws in.
        case goingStale
        /// Data is back: the strike retracts and the colour returns (rolling too if the value moved).
        case comingBack
        /// The first reading after waiting (a sensor warming up, a new sign-in): it fades in.
        case firstReading

        /// Whether the value cross-fades between two colours rather than only rolling.
        var fadesColour: Bool { self == .goingStale || self == .comingBack }
        /// Whether the move is only a fade, so it still plays under Reduce Motion (as a quicker
        /// cross-fade with the strike whole) while rolls are dropped.
        var keepsUnderReduceMotion: Bool { self != .roll && self != .none }
    }

    static func change(from old: MenuBarGlance?, to new: MenuBarGlance) -> Change {
        guard let old else { return .none }
        if !old.hasReading { return new.hasReading ? .firstReading : .none }
        guard new.hasReading else { return .none }
        if old.state == .live && new.state == .stale { return .goingStale }
        if old.state == .stale && new.state == .live { return .comingBack }
        return old.valueText != new.valueText ? .roll : .none
    }

    /// How much of the strike is drawn at `progress` (0...1) through a change: it draws in over
    /// the first part going stale, retracts coming back, and is whole or absent otherwise. Under
    /// Reduce Motion it doesn't travel; the line is whole and fades with the value instead.
    static func strikeDrawn(_ change: Change, state: State, progress: Double, reduceMotion: Bool) -> Double {
        let p = min(1, max(0, progress))
        // The line finishes drawing before the colour has finished fading, as in the apps.
        let lead = min(1, p / 0.4)
        switch change {
        case .goingStale: return reduceMotion ? 1 : lead
        case .comingBack: return reduceMotion ? 1 : 1 - lead
        case .none, .roll, .firstReading: return state == .stale ? 1 : 0
        }
    }

    /// The strike's opacity: it only fades (rather than draws) under Reduce Motion.
    static func strikeOpacity(_ change: Change, state: State, progress: Double, reduceMotion: Bool) -> Double {
        let p = min(1, max(0, progress))
        switch change {
        case .goingStale: return reduceMotion ? p : 1
        case .comingBack: return reduceMotion ? 1 - p : 1
        case .none, .roll, .firstReading: return state == .stale ? 1 : 0
        }
    }

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
