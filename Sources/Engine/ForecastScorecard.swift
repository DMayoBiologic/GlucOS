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
        let rows = Self.rows(accuracy)
        guard rows.first?.minutes == Self.horizons.first else { return nil }
        self.rows = rows
        checks = rows.map(\.checks).reduce(0, +)
        insideRange = rows.map { $0.insideRange * Double($0.checks) }.reduce(0, +) / Double(checks)
    }

    func row(at minutes: Int) -> Row? { rows.first { $0.minutes == minutes } }

    var insidePercent: Int { Int((insideRange * 100).rounded()) }

    /// The horizons in `accuracy` with enough clean checks, shortest first.
    static func rows(_ accuracy: LiveAccuracy) -> [Row] {
        horizons.compactMap { m -> Row? in
            guard let h = accuracy.clean(at: m), h.checks >= minimumChecks else { return nil }
            return Row(minutes: m, checks: h.checks, error: h.meanAbsoluteError, noChange: h.naiveError,
                       insideRange: h.insideRange)
        }
    }
}

/// The card's figures for only the forecasts the installed version showed, next to the 7-day
/// ones. A week mixes several releases, so a change that made the forecast better or worse only
/// shows up slowly in the 7-day figure; this shows it from the first day.
struct ForecastSinceUpdate: Hashable {
    /// "1.2.0"
    let version: String
    /// When this device first recorded a forecast on this version.
    let since: Date
    /// Clean checks so far at 15 minutes.
    let checks: Int
    /// The horizons with enough checks (`ForecastScorecard.minimumChecks`), shortest first.
    let rows: [ForecastScorecard.Row]
    /// Every forecast in the 7-day figure came from this version, so there's nothing to split.
    let coversWeek: Bool

    /// Nil when this version hasn't recorded a forecast yet.
    init?(accuracy: LiveAccuracy, version: String, since: Date?, coversWeek: Bool) {
        guard let since else { return nil }
        self.version = version
        self.since = since
        checks = accuracy.clean(at: ForecastScorecard.horizons[0])?.checks ?? 0
        rows = ForecastScorecard.rows(accuracy)
        self.coversWeek = coversWeek
    }

    func row(at minutes: Int) -> ForecastScorecard.Row? { rows.first { $0.minutes == minutes } }
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
        noChange(row.noChange, unit: unit)
    }

    /// The same for a figure on its way to the row's, while it rolls.
    static func noChange(_ mgdl: Double, unit: GlucoseUnit) -> String {
        "No change ±\(unit.format(mgdl: mgdl))"
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

    /// "Since you updated to 1.2.0, 9 hours ago" or, when the whole week is on it, "All on 1.2.0".
    static func sinceUpdateTitle(_ u: ForecastSinceUpdate, now: Date = Date()) -> String {
        if u.coversWeek { return "Every forecast here was made on \(u.version), the version you have now." }
        return "Since you updated to \(u.version), \(ago(u.since, now: now))"
    }

    /// Under a row: "On 1.2.0: ±0.6 · Closer than no change · 42 checks". Nil when the version has
    /// too few checks at that horizon, or the whole week is on it already.
    static func sinceUpdateRow(_ u: ForecastSinceUpdate, minutes: Int, unit: GlucoseUnit) -> String? {
        guard !u.coversWeek, let r = u.row(at: minutes) else { return nil }
        return "On \(u.version): ±\(unit.format(mgdl: r.error)) · \(comparison(r)) · \(r.checks) checks"
    }

    /// While the version is still collecting: "1.2.0 has 12 of 30 checks at 15 minutes so far.
    /// Its own figures show once it has 30." Nil once its 15-minute figure shows.
    static func sinceUpdateCollecting(_ u: ForecastSinceUpdate) -> String? {
        guard !u.coversWeek, u.rows.isEmpty else { return nil }
        let m = ForecastScorecard.minimumChecks
        return "\(u.version) has \(u.checks) of \(m) checks at 15 minutes so far. Its own figures show "
            + "once it has \(m); until then the figures above include earlier versions."
    }

    static func sinceUpdateSpoken(_ u: ForecastSinceUpdate, minutes: Int, unit: GlucoseUnit) -> String? {
        guard !u.coversWeek, let r = u.row(at: minutes) else { return nil }
        return "On \(u.version) alone: typically \(unit.format(mgdl: r.error)) \(unit.label) off. "
            + "\(comparison(r)). \(r.checks) checks."
    }

    /// "under an hour ago", "9 hours ago", "3 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let hours = Int(now.timeIntervalSince(date) / 3600)
        if hours < 1 { return "under an hour ago" }
        if hours < 48 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        return "\(hours / 24) days ago"
    }

    /// Where the numbers come from, and what they're not.
    static func footnote(device: String) -> String {
        "From the forecasts made on this \(ForecastRecord.displayName(device: device)) in the last 7 days, checked "
            + "only when nothing was logged before the reading. \"No change\" is how far off you'd have been "
            + "assuming glucose stayed where it was. This shows how the forecast has done, not what to do: "
            + "it's never a guide to dosing."
    }

}

extension ForecastDetails {
    /// The forecast details card's range figures, from the scorecard: the same checks as the
    /// Insights card, so the two never disagree. None while the scorecard is still hidden.
    static func held(_ card: ForecastScorecard?) -> [HitRate] {
        (card?.rows ?? []).map { HitRate(minutes: $0.minutes, share: $0.insideRange, checks: $0.checks) }
    }
}
