import Foundation

/// What the Mac menu bar item's hover preview shows: the last two hours of readings as a small
/// chart, the reading with its trend, and how long ago it was taken. Plain values only, worked out
/// once when the preview opens (and again only if a new reading lands while it is open), so the
/// preview never ticks. The panel itself lives in the app (MenuBarHoverPanel.swift).
struct MenuBarHoverPreview: Equatable {
    /// One reading on the chart. `x` runs 0 (two hours ago) to 1 (now), `y` 0 (bottom) to 1 (top).
    struct Point: Equatable {
        var x: Double
        var y: Double
        var range: GlucoseRange
        /// A gap of more than `gapBreak` before this reading: the line lifts here.
        var startsSegment: Bool
    }

    /// "6.4"
    var valueText: String
    /// "mmol/L"
    var unitText: String
    /// Nil when stale or unknown.
    var trend: Trend?
    /// "Rising", "No trend" when stale.
    var trendText: String
    /// "Just now", "3 min ago", "1 h 5 min ago".
    var ageText: String
    var isStale: Bool
    var range: GlucoseRange
    var points: [Point]
    /// The target range on the chart's 0...1 scale, clamped to it.
    var bandLow: Double
    var bandHigh: Double
    /// "Up 2.1 over two hours", under the chart. Nil with less than an hour of readings.
    var movementText: String?
    /// Extra lines the item's old tooltip carried: back in range, alerts snoozed. The preview
    /// replaces the tooltip while it is on, so the app fills these from `MenuBarGlance.toolTip`.
    var notes: [String] = []

    // MARK: Timing

    /// How long the pointer rests on the item before the preview opens.
    static let hoverDelay: TimeInterval = 0.6
    static let fadeIn: TimeInterval = 0.16
    static let fadeOut: TimeInterval = 0.12
    /// The chart's span.
    static let chartSpan: TimeInterval = 2 * 3600
    /// Readings further apart than this are not joined.
    static let gapBreak: TimeInterval = 15 * 60
    /// The chart's vertical scale never shrinks below this (3 mmol/L), so a flat two hours read as
    /// flat.
    static let minSpanMgdl: Double = 54

    // MARK: Building

    /// The panel is hidden from VoiceOver and never takes focus: the item's own VoiceOver label
    /// already says the reading, trend, range and back-in-range time.
    ///
    /// Nil when there is nothing to preview: no reading yet, or a sensor warming up (the item
    /// already says that, and the old sensor's last readings would mislead).
    static func make(snapshot: GlucoseSnapshot, recent: [GlucoseReading], now: Date = Date()) -> MenuBarHoverPreview? {
        guard snapshot.warmUp(at: now) == nil, let current = snapshot.current else { return nil }
        let unit = snapshot.unit
        let stale = snapshot.isStale(at: now)
        let range = GlucoseRange.classify(mgdl: current.mgdl, low: snapshot.lowMgdl, high: snapshot.highMgdl)
        let trend: Trend? = stale || current.trend == .unknown ? nil : current.trend
        let age = ageText(current.age(at: now))

        let readings = window(recent + snapshot.history + [current], endingAt: now)
        let values = readings.map(\.mgdl) + [snapshot.lowMgdl, snapshot.highMgdl]
        let lo = values.min() ?? snapshot.lowMgdl
        let hi = values.max() ?? snapshot.highMgdl
        let span = max(minSpanMgdl, hi - lo) * 1.1
        let floorValue = (lo + hi) / 2 - span / 2
        func y(_ mgdl: Double) -> Double { min(1, max(0, (mgdl - floorValue) / span)) }
        let start = now.addingTimeInterval(-Self.chartSpan)
        var points: [Point] = []
        var last: Date?
        for r in readings {
            let x = min(1, max(0, r.timestamp.timeIntervalSince(start) / Self.chartSpan))
            let gap = last.map { r.timestamp.timeIntervalSince($0) > gapBreak } ?? true
            points.append(Point(x: x, y: y(r.mgdl),
                                range: GlucoseRange.classify(mgdl: r.mgdl, low: snapshot.lowMgdl, high: snapshot.highMgdl),
                                startsSegment: gap))
            last = r.timestamp
        }

        let valueText = unit.format(mgdl: current.mgdl)
        let trendText = trend?.description ?? "No trend"
        return MenuBarHoverPreview(valueText: valueText, unitText: unit.label, trend: trend, trendText: trendText,
                                   ageText: age, isStale: stale, range: range, points: points,
                                   bandLow: y(snapshot.lowMgdl), bandHigh: y(snapshot.highMgdl),
                                   movementText: movement(readings, unit: unit))
    }

    /// The two hours up to `end`, oldest first, one reading per minute (the archive, the snapshot's
    /// history and the current reading overlap).
    static func window(_ readings: [GlucoseReading], endingAt end: Date) -> [GlucoseReading] {
        let start = end.addingTimeInterval(-Self.chartSpan)
        var seen = Set<Int>()
        return readings
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert(Int($0.timestamp.timeIntervalSince1970 / 60)).inserted }
    }

    /// "Just now", "1 min ago", "12 min ago", "1 h ago", "2 h 5 min ago", "3 d ago".
    static func ageText(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval)) / 60
        if m < 1 { return "Just now" }
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) h ago" : "\(h) h \(m % 60) min ago" }
        return "\(h / 24) d ago"
    }

    /// "Up 2.1 over two hours", "Down 1.4 over two hours", "Level over two hours". Nil with fewer
    /// than an hour of readings.
    static func movement(_ readings: [GlucoseReading], unit: GlucoseUnit) -> String? {
        guard let first = readings.first, let last = readings.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 3600 else { return nil }
        let d = last.mgdl - first.mgdl
        if abs(d) < 9 { return "Level over two hours" }
        let amount = unit.format(mgdl: abs(d))
        return "\(d > 0 ? "Up" : "Down") \(amount) over two hours"
    }
}

// MARK: - When it shows

extension MenuBarHoverPreview {
    /// The hover's state. The pointer resting on the item starts the delay; anything the person
    /// does on the item (a click, a key, the popover opening) closes the preview and keeps it closed
    /// until the pointer leaves, so it never pops back under a closing popover.
    enum Phase: Equatable {
        case idle
        /// The pointer is on the item, waiting out `hoverDelay`.
        case pending
        case showing
        /// Closed by a click, a key or the popover, until the pointer leaves.
        case dismissed
    }

    enum Event: Equatable {
        case pointerEntered
        case pointerExited
        case delayElapsed
        /// A click on the item, a key press, or the popover opening.
        case interaction
    }

    /// The next phase. `allowed` is false while the setting is off, the popover is open, or there
    /// is nothing to show: the preview then never opens, and closes if it was open.
    static func next(_ phase: Phase, on event: Event, allowed: Bool) -> Phase {
        switch event {
        case .pointerExited:
            return .idle
        case .interaction:
            return phase == .idle ? .idle : .dismissed
        case .pointerEntered:
            guard allowed else { return phase == .dismissed ? .dismissed : .idle }
            return phase == .idle ? .pending : phase
        case .delayElapsed:
            guard phase == .pending else { return phase }
            return allowed ? .showing : .idle
        }
    }

    /// Whether the panel fades. Under Reduce Motion it appears and goes at once, as a still image.
    static func fades(reduceMotion: Bool) -> Bool { !reduceMotion }
}
