import Foundation

/// The forecast details card (improvement round 73): tap the forecast's dashed line or its range on
/// iPhone Today, or click it in the Mac popover, and a small card says where the forecast puts
/// glucose in 30 and 60 minutes with its likely range, how often that range held at each distance
/// in this device's recent checks (the scorecard's figures, `ForecastScorecard`), and in one plain
/// line what the forecast was made from. Plain Foundation so it can be unit-tested; it's built by
/// the screen around the chart (which has the scorecard) and drawn by `ForecastDetailsCard`.
///
/// Every line describes the forecast. None of it says what to do.
struct ForecastDetails: Equatable, Sendable {
    /// How often the reading landed inside the likely range at one distance ahead, over the
    /// scorecard's checks (this device, last 7 days, clean points only).
    struct HitRate: Equatable, Sendable {
        let minutes: Int
        /// 0...1.
        let share: Double
        let checks: Int

        var percent: Int { Int((share * 100).rounded()) }
    }

    /// One distance ahead on the card.
    struct Horizon: Equatable, Sendable {
        let minutes: Int
        let mgdl: Double
        let lowerMgdl: Double
        let upperMgdl: Double
        /// Nil while this distance has too few recent checks to say (`ForecastScorecard.minimumChecks`).
        let held: HitRate?
    }

    /// What the forecast was made from, for its one plain line.
    enum Driver: String, Equatable, Sendable, CaseIterable {
        case trend
        case trendAndMeal
        case trendAndInsulin
        case trendMealAndInsulin

        /// "Based on the recent trend and logged insulin still acting."
        var line: String {
            switch self {
            case .trend: return "Based on the recent trend."
            case .trendAndMeal: return "Based on the recent trend and a logged meal still being absorbed."
            case .trendAndInsulin: return "Based on the recent trend and logged insulin still acting."
            case .trendMealAndInsulin: return "Based on the recent trend, a logged meal still being absorbed and logged insulin still acting."
            }
        }

        var systemImage: String {
            switch self {
            case .trend: return "arrow.forward"
            case .trendAndMeal: return "fork.knife"
            case .trendAndInsulin: return "syringe"
            case .trendMealAndInsulin: return "fork.knife"
            }
        }

        /// From the forecast's basis and what's still acting. A trend-only forecast says only the
        /// trend, even with insulin or carbs logged: they didn't move it (the caveat line says why).
        static func of(basis: ForecastBasis, insulinActing: Bool, carbsActing: Bool) -> Driver {
            guard basis == .trendInsulinCarbs else { return .trend }
            switch (carbsActing, insulinActing) {
            case (true, true): return .trendMealAndInsulin
            case (true, false): return .trendAndMeal
            case (false, true): return .trendAndInsulin
            case (false, false): return .trend
            }
        }
    }

    /// The distances the card shows, when the forecast reaches them.
    static let horizons = [30, 60]

    /// 30 and 60 minutes, or as many as the forecast reaches. A forecast cut short of 30 minutes
    /// (`ForecastLiveHorizon`) shows its last point instead, so the card is never empty.
    let horizons: [Horizon]
    let driver: Driver
    /// The reading the forecast starts from.
    let issuedAt: Date

    /// Nil when there's no forecast to describe, or it's only its starting reading.
    init?(outlook: OutlookSnapshot, held: [HitRate]) {
        guard outlook.horizon >= 5 * 60 else { return nil }
        let rate = { (m: Int) in held.first { $0.minutes == m } }
        var shown: [Horizon] = Self.horizons.compactMap { m in
            guard let s = outlook.sample(minutesAhead: Double(m)) else { return nil }
            return Horizon(minutes: m, mgdl: s.mgdl, lowerMgdl: s.lowerMgdl, upperMgdl: s.upperMgdl, held: rate(m))
        }
        if shown.isEmpty, let last = outlook.forecast.last {
            let m = Int((last.date.timeIntervalSince(outlook.issuedAt) / 60).rounded())
            shown = [Horizon(minutes: m, mgdl: last.mgdl, lowerMgdl: last.lowerMgdl, upperMgdl: last.upperMgdl, held: rate(m))]
        }
        horizons = shown
        driver = .of(basis: outlook.basis, insulinActing: outlook.showsInsulin, carbsActing: outlook.showsCarbs)
        issuedAt = outlook.issuedAt
    }

    // MARK: Wording

    static let title = "Forecast"
    /// Under the figures, so the card never reads as a reading or a guide.
    static let footnote = "An estimate, not a reading. Range checks are from this device's last 7 days."
    /// VoiceOver's action on the chart that opens the card.
    static let voiceOverActionName = "Show forecast details"

    /// "In 30 min"
    static func heading(_ h: Horizon) -> String { "In \(h.minutes) min" }

    /// "6.8 mmol/L"
    static func value(_ h: Horizon, unit: GlucoseUnit) -> String { unit.format(mgdl: h.mgdl, withUnit: true) }

    /// "Likely 5.9–7.7"
    static func range(_ h: Horizon, unit: GlucoseUnit) -> String {
        "Likely \(unit.format(mgdl: h.lowerMgdl))–\(unit.format(mgdl: h.upperMgdl))"
    }

    /// "Range held 74% of 42 recent checks", or why there's no figure yet.
    static func held(_ h: Horizon) -> String {
        guard let r = h.held else { return "Too few recent checks to say how often the range held" }
        return "Range held \(r.percent)% of \(r.checks) recent checks"
    }

    /// The whole card as one VoiceOver sentence: "Forecast. In 30 minutes, about 6.8 millimoles
    /// per litre, likely between 5.9 and 7.7. The range held 74% of the time in 42 recent checks.
    /// … Based on the recent trend. An estimate, not a reading."
    static func spoken(_ d: ForecastDetails, unit: GlucoseUnit) -> String {
        var parts = [title + "."]
        for h in d.horizons {
            parts.append("In \(h.minutes) minutes, about \(unit.format(mgdl: h.mgdl)) \(spokenUnit(unit)), "
                         + "likely between \(unit.format(mgdl: h.lowerMgdl)) and \(unit.format(mgdl: h.upperMgdl)).")
            if let r = h.held {
                parts.append("The range held \(r.percent)% of the time in \(r.checks) recent checks.")
            } else {
                parts.append("Too few recent checks to say how often the range held.")
            }
        }
        parts.append(d.driver.line)
        parts.append("An estimate, not a reading.")
        return parts.joined(separator: " ")
    }

    private static func spokenUnit(_ unit: GlucoseUnit) -> String {
        unit == .mmol ? "millimoles per litre" : "milligrams per decilitre"
    }

    // MARK: Where it answers

    /// How far past the band's edges (points) a tap still counts, so the dashed line is easy to hit
    /// even when the range is thin.
    static let hitSlop: Double = 12
    /// The band is never thinner than this either side of the line (points).
    static let minimumHalfHeight: Double = 16

    /// One forecast point on screen: its x, and the range's top and bottom y (y grows downwards).
    struct PlotPoint: Equatable, Sendable {
        let x: Double
        let top: Double
        let bottom: Double
        let line: Double
    }

    /// The outline a tap or click on the forecast lands inside: along the range's top edge, back
    /// along its bottom, padded by `hitSlop` and never thinner than `minimumHalfHeight` round the
    /// line. Empty for fewer than two points.
    static func outline(_ points: [PlotPoint], slop: Double = hitSlop,
                        minimumHalfHeight: Double = minimumHalfHeight) -> [(x: Double, y: Double)] {
        guard points.count >= 2 else { return [] }
        let tops = points.map { p in (x: p.x, y: min(p.top - slop, p.line - minimumHalfHeight)) }
        let bottoms = points.reversed().map { p in (x: p.x, y: max(p.bottom + slop, p.line + minimumHalfHeight)) }
        return tops + bottoms
    }

    /// The forecast point the card grows out of: the one nearest where it was tapped, or the
    /// 30-minute point (else the last) when it was opened by VoiceOver or the keyboard.
    static func anchor(tapped: Date?, in forecast: [ForecastSample]) -> ForecastSample? {
        guard let first = forecast.first else { return nil }
        guard let tapped else {
            let target = first.date.addingTimeInterval(30 * 60)
            return forecast.first { $0.date >= target.addingTimeInterval(-60) } ?? forecast.last
        }
        return forecast.min { abs($0.date.timeIntervalSince(tapped)) < abs($1.date.timeIntervalSince(tapped)) }
    }
}
