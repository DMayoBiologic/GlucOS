import Foundation

// The Insights card's numbers: how far off the forecasts shown in the last week typically were
// at 15, 30 and 60 minutes, next to what assuming no change would have scored on the same
// moments, and how often the reading landed inside the forecast's likely range.
//
// Only points with nothing logged before the reading count (the forecast is explicitly "if
// nothing else changes"), and a horizon is shown only once it has enough checks to mean
// something. The card is hidden until the 15-minute horizon gets there. Every line describes how
// the forecast has done; none of it says what to do.

struct ForecastScorecard: Hashable {
    enum Comparison: Hashable {
        /// At least 5% less error than no change.
        case better
        case aboutTheSame
        /// At least 5% more error than no change.
        case worse
    }

    struct Row: Hashable {
        let minutes: Int
        let checks: Int
        /// Typical (mean absolute) error of the forecast, mg/dL.
        let error: Double
        /// Typical error of assuming glucose stays where it was, on the same points, mg/dL.
        let noChange: Double
        /// Share of readings inside the forecast's likely range.
        let insideRange: Double

        var comparison: Comparison {
            guard noChange > 0 else { return error > 0 ? .worse : .aboutTheSame }
            let ratio = error / noChange
            return ratio <= 0.95 ? .better : ratio >= 1.05 ? .worse : .aboutTheSame
        }
    }

    static let horizons = [15, 30, 60]
    /// Clean checks a horizon needs before it's shown: about 8 hours of forecasts, one every 15
    /// minutes. Fewer swing too much from one meal or one sensor glitch to be fair.
    static let minimumChecks = 30
    /// What the likely range is drawn to hold.
    static let rangeTarget = 0.8

    /// The horizons with enough checks, shortest first. Always starts at 15 minutes.
    let rows: [Row]
    /// Share of readings inside the range across the shown horizons.
    let insideRange: Double
    /// Checks behind `insideRange` (the shown horizons together).
    let checks: Int

    /// Nil until the 15-minute horizon has `minimumChecks` clean checks.
    init?(_ accuracy: LiveAccuracy) {
        let rows = Self.horizons.compactMap { m -> Row? in
            guard let h = accuracy.clean(at: m), h.checks >= Self.minimumChecks else { return nil }
            return Row(minutes: m, checks: h.checks, error: h.meanAbsoluteError, noChange: h.naiveError,
                       insideRange: h.insideRange)
        }
        guard rows.first?.minutes == Self.horizons.first else { return nil }
        self.rows = rows
        checks = rows.map(\.checks).reduce(0, +)
        insideRange = rows.map { $0.insideRange * Double($0.checks) }.reduce(0, +) / Double(checks)
    }

    func row(at minutes: Int) -> Row? { rows.first { $0.minutes == minutes } }

    var insidePercent: Int { Int((insideRange * 100).rounded()) }
}

/// The card's wording, shared by the Mac and iPhone so both say exactly the same thing.
enum ForecastScorecardText {
    static let title = "How close the forecasts were"

    static func comparison(_ row: ForecastScorecard.Row) -> String {
        switch row.comparison {
        case .better: return "Closer than no change"
        case .aboutTheSame: return "About the same as no change"
        case .worse: return "Further off than no change"
        }
    }

    /// "±0.6 mmol/L"
    static func error(_ mgdl: Double, unit: GlucoseUnit) -> String { "±\(unit.format(mgdl: mgdl)) \(unit.label)" }

    /// "No change ±0.7"
    static func noChange(_ row: ForecastScorecard.Row, unit: GlucoseUnit) -> String {
        "No change ±\(unit.format(mgdl: row.noChange))"
    }

    /// "15 minutes ahead: typically ±0.6 mmol/L off. Assuming no change: ±0.7. Closer than no change. 96 checks."
    static func spoken(_ row: ForecastScorecard.Row, unit: GlucoseUnit) -> String {
        "\(row.minutes) minutes ahead: typically \(unit.format(mgdl: row.error)) \(unit.label) off. "
            + "Assuming no change: \(unit.format(mgdl: row.noChange)). \(comparison(row)). \(row.checks) checks."
    }

    /// How often the reading landed inside the range, against what the range aims for.
    static func rangeLine(_ card: ForecastScorecard) -> String {
        let pct = card.insidePercent
        let base = "The reading landed inside the likely range \(pct)% of the time. The range aims for about 8 in 10."
        if card.insideRange < ForecastScorecard.rangeTarget - 0.1 {
            return base + " That's short of the aim, so GlucOS widens the range on the forecasts that follow."
        }
        if card.insideRange > ForecastScorecard.rangeTarget + 0.1 {
            return base + " It's held more than that, so the range may be wider than it needs to be."
        }
        return base
    }

    /// Where the numbers come from, and what they're not.
    static func footnote(device: String) -> String {
        "From the forecasts made on this \(ForecastRecord.displayName(device: device)) in the last 7 days, checked "
            + "only when nothing was logged before the reading. \"No change\" is how far off you'd have been "
            + "assuming glucose stayed where it was. This shows how the forecast has done, not what to do: "
            + "it's never a guide to dosing."
    }

}
