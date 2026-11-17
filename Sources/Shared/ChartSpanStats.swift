import Foundation

/// The numbers for a stretch of the iPhone Today chart: picked out by resting two fingers on the
/// chart and dragging them apart (`GlucoseChart.selectsSpans`), or stepped through with VoiceOver's
/// swipe up and down. Average, lowest, highest, share of readings in range and the change from the
/// first reading to the last, the same figures as the Mac Dashboard's selection summary.
///
/// Plain Foundation so it can be unit-tested; `GlucoseChart` draws the band and the card.
/// Descriptive only: nothing here suggests a dose.
struct ChartSpanStats: Equatable {
    /// The span itself, earlier end first, whichever way the fingers were placed.
    let start: Date
    let end: Date
    /// Readings inside the span, ends included.
    let count: Int
    let averageMgdl: Double
    let lowestMgdl: Double
    let highestMgdl: Double
    /// The share of those readings inside the target, its lines included (as `GlucoseStats`), 0…1.
    let inRange: Double
    /// The last reading in the span minus the first. Nil with only one reading.
    let changeMgdl: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Shorter than this isn't a span: two fingertips are always further apart than that on any
    /// chart length, so it only rules out a span squeezed to nothing.
    static let minimumSpan: TimeInterval = 5 * 60

    /// The figures for the readings between `a` and `b` (in either order). Nil when the span is
    /// shorter than `minimumSpan` or no reading falls inside it (a sensor gap): the card says so
    /// rather than showing numbers from outside it.
    ///
    /// - Parameter readings: in any order.
    static func compute(readings: [GlucoseReading], from a: Date, to b: Date,
                        lowMgdl: Double, highMgdl: Double) -> ChartSpanStats? {
        let start = min(a, b), end = max(a, b)
        guard end.timeIntervalSince(start) >= minimumSpan else { return nil }
        let inside = readings.filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = inside.first, let last = inside.last else { return nil }
        let values = inside.map(\.mgdl)
        let inRange = values.filter { $0 >= lowMgdl && $0 <= highMgdl }.count
        return ChartSpanStats(
            start: start, end: end, count: values.count,
            averageMgdl: values.reduce(0, +) / Double(values.count),
            lowestMgdl: values.min() ?? first.mgdl,
            highestMgdl: values.max() ?? first.mgdl,
            inRange: Double(inRange) / Double(values.count),
            changeMgdl: inside.count > 1 ? last.mgdl - first.mgdl : nil)
    }

    /// "85%", whole percent.
    var inRangeText: String { "\(Int((inRange * 100).rounded()))%" }

    /// "+1.3", "−0.4" or "0.0" (no sign when it rounds to nothing), or "–" with one reading.
    func changeText(unit: GlucoseUnit) -> String {
        guard let change = changeMgdl else { return "–" }
        return Self.roundsToZero(change, unit: unit) ? unit.format(mgdl: 0) : unit.formatDelta(mgdl: change)
    }

    /// "Up 1.3", "Down 0.4", "No change", for VoiceOver.
    func spokenChange(unit: GlucoseUnit) -> String? {
        guard let change = changeMgdl else { return nil }
        if Self.roundsToZero(change, unit: unit) { return "No change" }
        return (change > 0 ? "Up " : "Down ") + unit.format(mgdl: abs(change))
    }

    private static func roundsToZero(_ mgdl: Double, unit: GlucoseUnit) -> Bool {
        let shown = unit.value(fromMgdl: abs(mgdl))
        return unit == .mmol ? shown < 0.05 : shown < 0.5
    }
}

// MARK: - Telling a span from a pinch

/// Two fingers on the chart are a pinch (change its hours, `chartHoursPinch`) or a span. A span is
/// a press first: both fingers rest for `holdDuration` without the gap between them changing by
/// more than `pinchDrift`. A pinch moves straight away, so it never arms a span, and once a span
/// has armed the pinch stands down until the fingers lift (`ChartSpanActiveKey`).
enum ChartSpanHold {
    static let holdDuration: TimeInterval = 0.3
    /// How much the fingers' gap may grow or shrink, as a share of where it started, before it
    /// counts as a pinch.
    static let pinchDrift = 0.15

    /// Whether the gap has moved enough from `first` to `current` to be a pinch.
    static func isPinch(firstWidth first: TimeInterval, currentWidth current: TimeInterval) -> Bool {
        guard first > 0 else { return current > 0 }
        return abs(current - first) / first > pinchDrift
    }

    /// Whether a touch that has rested `held` seconds, starting `first` apart and now `current`
    /// apart, should turn into a span. Never once it has been a pinch (`wasPinch`).
    static func arms(held: TimeInterval, firstWidth first: TimeInterval, currentWidth current: TimeInterval,
                     wasPinch: Bool) -> Bool {
        !wasPinch && held >= holdDuration && !isPinch(firstWidth: first, currentWidth: current)
    }
}

// MARK: - VoiceOver

/// VoiceOver's span: swipe up for a longer one, down for a shorter one, always ending at the newest
/// reading. Swiping down past the shortest goes back to the chart's own summary.
enum ChartSpanVoiceOver {
    /// The spans offered, in minutes. Only those that fit the chart's hours.
    static let steps = [30, 60, 120, 180, 360, 720, 1440]

    static func steps(hours: Double) -> [Int] {
        let fit = steps.filter { Double($0) <= hours * 60 + 0.5 }
        return fit.isEmpty ? [steps[0]] : fit
    }

    /// The span after one swipe from `current` (nil: no span yet).
    static func step(_ current: Int?, up: Bool, hours: Double) -> Int? {
        let offered = steps(hours: hours)
        guard let current else { return up ? offered.first : nil }
        let index = offered.lastIndex(where: { $0 <= current }) ?? -1
        if up { return offered[min(index + 1, offered.count - 1)] }
        return index <= 0 ? nil : offered[index - 1]
    }

    /// The span still offered after the chart's hours change: the longest that fits, if the one
    /// chosen no longer does.
    static func clamped(_ current: Int?, hours: Double) -> Int? {
        guard let current else { return nil }
        let offered = steps(hours: hours)
        return offered.last(where: { $0 <= current }) ?? offered.first
    }

    /// "30 minutes", "1 hour", "12 hours".
    static func words(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let h = minutes / 60
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    /// What VoiceOver reads as the chart's value while a span is chosen, e.g.
    /// "Last 1 hour. Average 6.2, lowest 5.1, highest 7.4 millimoles per litre. 85 percent in
    /// range. Up 1.3."
    static func spoken(_ stats: ChartSpanStats?, minutes: Int, unit: GlucoseUnit) -> String {
        let period = "Last \(words(minutes: minutes))"
        guard let s = stats else { return "\(period). No readings." }
        let unitWords = unit == .mmol ? "millimoles per litre" : "milligrams per decilitre"
        var parts = [
            period,
            "Average \(unit.format(mgdl: s.averageMgdl)), lowest \(unit.format(mgdl: s.lowestMgdl)), "
                + "highest \(unit.format(mgdl: s.highestMgdl)) \(unitWords)",
            "\(Int((s.inRange * 100).rounded())) percent in range",
        ]
        if let change = s.spokenChange(unit: unit) { parts.append(change) }
        return parts.joined(separator: ". ") + "."
    }
}
