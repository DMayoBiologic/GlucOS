import Foundation

/// Today's readings as the Settings target-range editor previews them (round 54): the day's trace
/// from midnight to now, drawn once, and the share of it inside whatever range is being set. The
/// trace never depends on the range, so it is worked out once per new reading; only the figure is
/// recounted as low or high change, which is cheap (at most 288 points).
struct TargetRangePreview: Equatable {
    /// Local midnight today.
    let start: Date
    /// Where the chart's time axis ends: now, or the newest reading if that is later.
    let end: Date
    /// The day so far as runs of 5-minute means, the same points as a Logbook day chart.
    let segments: [[DayChartPoint]]

    /// Fewer points than this (half an hour of readings) is too little to say anything about a range.
    static let minimumPoints = 6

    /// Today's trace from `readings` (any order), or nil until there is half an hour of it.
    static func today(_ readings: [GlucoseReading], now: Date = Date(),
                      calendar: Calendar = .autoupdatingCurrent) -> TargetRangePreview? {
        let start = calendar.startOfDay(for: now)
        let segments = DayChart.segments(readings, from: start, to: DayChart.end(of: start, calendar: calendar))
        let points = segments.joined()
        guard points.count >= minimumPoints, let last = points.last else { return nil }
        return TargetRangePreview(start: start, end: max(now, last.date), segments: segments)
    }

    /// Every point of the trace, oldest first.
    var points: [DayChartPoint] { Array(segments.joined()) }

    /// The share of today's 5-minute points from `low` to `high` inclusive, 0–1: the same counting
    /// as "Today so far" (`TodaySoFar.figures`).
    func timeInRange(low: Double, high: Double) -> Double {
        let all = points
        guard !all.isEmpty else { return 0 }
        return Double(all.filter { $0.mgdl >= low && $0.mgdl <= high }.count) / Double(all.count)
    }

    /// The glucose axis, in mg/dL. It covers today's readings and every range the editor allows
    /// (54–300), so moving a limit slides the band across a still axis instead of rescaling it.
    var yDomain: ClosedRange<Double> {
        let values = points.map(\.mgdl)
        return (min(values.min() ?? 54, 54) - 6)...(max(values.max() ?? 300, 300) + 6)
    }

    /// "Today, 72% in range with this range": what VoiceOver says for the preview.
    func spoken(low: Double, high: Double) -> String {
        "Today so far, \(Format.percent(timeInRange(low: low, high: high))) in range with this target range"
    }
}
