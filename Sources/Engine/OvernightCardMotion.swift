import Foundation

/// How the Insights Overnight card moves (docs/Mornings.md, "The night before"): the shares its
/// range bar draws, when the bar fills in as the card rises, and how long a cross-fade takes under
/// Reduce Motion. Plain values, so the rules are tested without SwiftUI.
enum OvernightCardMotion {
    /// The bar starts filling this long after the card begins to rise, just after the figures,
    /// which count up from 0.1 s a step apart.
    static let fillDelay: Double = 0.2
    /// The bar fills on this spring (the Lows and Tags bars' spring), then glides to new shares
    /// on `DSMotion.emphasized` when the period or the data changes.
    static let fillResponse: Double = 0.6
    static let fillDamping: Double = 0.82
    /// How long a cross-fade takes under Reduce Motion: the bar fading in, and the whole card
    /// fading to a new period.
    static let reducedFade: Double = 0.2
    /// A share smaller than this isn't drawn, so a rounding sliver never shows as a colour.
    static let smallestShare: Double = 0.001

    /// One night bar's three shares, below / in range / above, always in that order so a share
    /// that grows from nothing widens into place rather than shifting the others along.
    struct Shares: Equatable {
        var below: Double
        var inRange: Double
        var above: Double

        var all: [Double] { [below, inRange, above] }
    }

    /// The shares for a summary's time in range and time below. Each is clamped to 0...1, and
    /// above is what's left, so the three never add up to more than the bar.
    static func shares(timeInRange: Double, timeBelow: Double) -> Shares {
        let below = clamp(timeBelow)
        let inRange = min(clamp(timeInRange), 1 - below)
        let above = max(0, 1 - below - inRange)
        return Shares(below: below, inRange: inRange, above: above)
    }

    static func shares(_ s: OvernightSummary) -> Shares {
        shares(timeInRange: s.timeInRange, timeBelow: s.timeBelow)
    }

    /// Whether a share is drawn at all.
    static func shows(_ share: Double) -> Bool { share > smallestShare }

    /// Whether a new summary is a new picture under Reduce Motion (it cross-fades) rather than the
    /// same one: a different period, or different figures.
    static func crossFades(from old: OvernightSummary?, to new: OvernightSummary?) -> Bool {
        guard let old, let new else { return false }
        return old != new
    }

    private static func clamp(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return min(1, max(0, x))
    }
}
