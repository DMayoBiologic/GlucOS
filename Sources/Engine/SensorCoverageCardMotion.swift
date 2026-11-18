import Foundation

/// How the Insights Sensor coverage card moves (docs/SensorCoverage.md, "Motion"): the coverage
/// meter fills, then each gap's bar grows in a step behind the one above it, all sharing one scale
/// with the period before's marks while Compare is on. Plain numbers, so the rules are tested
/// without SwiftUI.
enum SensorCoverageCardMotion {
    /// The coverage meter starts filling this long after the card begins to rise, with the figures.
    static let meterStart: Double = 0.1
    /// The first gap bar starts this long after the card begins to rise.
    static let growStart: Double = 0.18
    /// Each gap bar starts this much after the one above it, longest (top) first.
    static let growStep: Double = 0.06
    /// How long a fade takes under Reduce Motion, for the bars and the compare marks.
    static let reducedFade: Double = 0.2

    /// When a gap bar (and its row) starts growing in, by its place in the list.
    static func growDelay(order: Int) -> Double {
        growStart + growStep * Double(min(max(0, order), SensorCoverage.longestShown))
    }

    /// The gaps' counted seconds, longest first, as the card lists them.
    static func lengths(_ s: SensorCoverage) -> [TimeInterval] {
        s.longest.map { s.counted($0) }
    }

    /// The period before's longest gaps by the same places, when Compare shows them; nil otherwise.
    static func previousLengths(_ previous: SensorCoverage?) -> [TimeInterval]? {
        previous.map(lengths)
    }

    /// The seconds a full-width gap bar stands for: the longest gap shown, or the period before's
    /// while Compare shows a longer one, so its marks and today's bars read against each other.
    /// Turning Compare on or off can change it, which is what glides the bars. Never below a minute.
    static func scale(lengths: [TimeInterval], previous: [TimeInterval]? = nil) -> TimeInterval {
        max(60, lengths.max() ?? 0, previous?.max() ?? 0)
    }

    /// How much of its track a bar fills, 0...1. A gap is never thinner than `minimum` of the track,
    /// so a 10-minute gap next to a day-long one still shows.
    static func fraction(_ seconds: TimeInterval, scale: TimeInterval, minimum: Double = 0) -> Double {
        guard seconds > 0, scale > 0 else { return 0 }
        return min(1, max(minimum, seconds / scale))
    }

    /// The period before's bar at the same place, for its compare mark: nil when it had fewer gaps.
    static func previousLength(at index: Int, in previous: [TimeInterval]?) -> TimeInterval? {
        guard let previous, previous.indices.contains(index), previous[index] > 0 else { return nil }
        return previous[index]
    }
}
