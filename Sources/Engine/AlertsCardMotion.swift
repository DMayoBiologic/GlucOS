import Foundation

/// How the Insights Alerts card moves (docs/InsightsAlerts.md, "Motion"): where each bar ends,
/// how far behind the one above it it starts, and what the zoom into Alert History keys on.
/// Plain numbers, so the rules are tested without SwiftUI.
enum AlertsCardMotion {
    /// What the iPhone's zoom grows from and shrinks back into, and the Mac's scroll target on the
    /// way back. Keyed on the card, not its period, so Back still finds it after the period moved.
    static let sourceID = "insights.alerts"

    /// The first bar starts this long after the card begins to rise, so it grows with the figures.
    static let growStart: Double = 0.15
    /// Each kind bar starts this much after the one above it, top to bottom.
    static let growStep: Double = 0.045
    /// The outcome bar starts after the last kind bar.
    static var endingStart: Double { growStart + growStep * Double(AlertsSummary.Group.allCases.count) }
    /// How long a cross-fade takes under Reduce Motion.
    static let reducedFade: Double = 0.2

    /// When a kind bar starts growing in, by its place in the list.
    static func growDelay(order: Int) -> Double { growStart + growStep * Double(max(0, order)) }

    /// The count a full-width kind bar stands for. With Compare on, the period before's counts
    /// share the scale, so its marks and today's bars can be read against each other; the scale
    /// changing when the switch flips is what makes the bars glide. Never below 1.
    static func scale(counts: [Int], previous: [Int]? = nil) -> Int {
        max(1, counts.max() ?? 0, previous?.max() ?? 0)
    }

    /// How much of the track a kind bar fills, 0...1. A bar with any alerts is never thinner than
    /// `minimum` of the track, so one alert still shows.
    static func fraction(_ n: Int, scale: Int, minimum: Double = 0) -> Double {
        guard n > 0, scale > 0 else { return 0 }
        return min(1, max(minimum, Double(n) / Double(scale)))
    }

    /// Each outcome's share of the outcome bar, in `AlertsSummary.Ending` order, summing to 1
    /// (or all 0 when there are none).
    static func shares(_ counts: [Int]) -> [Double] {
        let total = counts.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return counts.map { _ in 0 } }
        return counts.map { Double(max(0, $0)) / Double(total) }
    }

    /// The previous period's counts by kind, when Compare shows them; nil otherwise.
    static func previousKinds(_ previous: AlertsSummary?) -> [Int]? {
        previous.map { p in AlertsSummary.Group.allCases.map { p.count($0) } }
    }

    /// The previous period's counts by outcome, when Compare shows them; nil otherwise.
    static func previousEndings(_ previous: AlertsSummary?) -> [Int]? {
        previous.map { p in AlertsSummary.Ending.allCases.map { p.count($0) } }
    }
}
