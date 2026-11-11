import Foundation

// The short-term outlook the app works out and the widget shows: a glucose forecast with its
// likely range, and how much logged insulin and carbohydrate is still acting. Everything here is
// an estimate. It's never shown as a reading, never in a reading's colour, and never offered as
// advice on what to dose or eat.

/// What a forecast was built from.
enum ForecastBasis: String, Codable, Hashable, CaseIterable {
    /// The recent trend only, fading out over half an hour.
    case trend
    /// The recent trend handing over to the logged insulin and carbs still acting.
    case trendInsulinCarbs

    var title: String {
        switch self {
        case .trend: return "Recent trend"
        case .trendInsulinCarbs: return "Trend, insulin and carbs"
        }
    }
}

struct ForecastSample: Codable, Hashable, Identifiable {
    let date: Date
    let mgdl: Double
    /// The likely range: about 8 in 10 past forecasts at this distance landed inside it.
    let lowerMgdl: Double
    let upperMgdl: Double

    var id: Date { date }
}

/// What the widget and the popover need. Written into `GlucoseSnapshot.outlook`.
struct OutlookSnapshot: Codable, Hashable {
    /// The reading the forecast starts from.
    var issuedAt: Date
    var basis: ForecastBasis
    /// From the starting reading forward, every 5 minutes. Empty when no forecast could be made.
    var forecast: [ForecastSample] = []
    /// Fast-acting insulin not yet acted, units. Nil when no insulin is logged.
    var insulinOnBoard: Double?
    /// When the logged fast-acting insulin will have mostly finished acting.
    var insulinMostlyDoneAt: Date?
    /// Logged carbs not yet absorbed, grams.
    var carbsOnBoard: Double?
    /// When the forecast's central line first goes below the low threshold.
    var lowExpectedAt: Date?
    /// When the forecast's likely range first reaches below the low threshold.
    var lowPossibleAt: Date?
    /// Plain-language reason no forecast is shown, if none is.
    var unavailableReason: String?
    /// The user's usual post-wake rise, when the forecast includes it.
    var morning: MorningAdjustmentSnapshot?

    /// Only usable while the reading it started from is still current.
    func isCurrent(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) <= GlucoseSnapshot.staleAfter
    }

    var horizon: TimeInterval { forecast.last.map { $0.date.timeIntervalSince(issuedAt) } ?? 0 }

    /// The forecast point nearest `minutes` after the starting reading.
    func sample(minutesAhead minutes: Double) -> ForecastSample? {
        let target = issuedAt.addingTimeInterval(minutes * 60)
        guard let last = forecast.last, last.date >= target.addingTimeInterval(-60) else { return nil }
        return forecast.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }

    /// The insulin numbers are worth showing.
    var showsInsulin: Bool { (insulinOnBoard ?? 0) >= 0.05 }
    var showsCarbs: Bool { (carbsOnBoard ?? 0) >= 1 }
}

// MARK: - Mornings

/// How far a learnt morning pattern can be trusted, from how many mornings it's seen and how
/// much it improved past forecasts in a check that left each morning out.
enum MorningConfidence: String, Codable, Hashable, CaseIterable {
    case low, moderate, high

    var title: String {
        switch self {
        case .low: return "Low confidence"
        case .moderate: return "Moderate confidence"
        case .high: return "High confidence"
        }
    }
}

/// The post-wake adjustment in the current forecast, for the popover, widget and iPhone.
struct MorningAdjustmentSnapshot: Codable, Hashable {
    /// The logged wake-up the adjustment counts from.
    var wokeAt: Date
    /// How much the adjustment moves the forecast's last point, mg/dL (negative: a fall).
    var addedMgdl: Double
    var confidence: MorningConfidence
}
