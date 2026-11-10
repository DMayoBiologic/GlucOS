import Foundation

// When the forecast says glucose is heading out of range soon. Pure decision logic, so it can be
// tested; `AlertManager` turns a decision into a notification. These alerts are a heads-up from an
// estimate, worded as such, and are extra to the alerts on actual readings (never a replacement).

enum PredictedExcursion: String, CaseIterable, Hashable {
    case urgentLow, low, high, veryHigh

    var isLow: Bool { self == .urgentLow || self == .low }
}

struct PredictiveAlertDecision: Hashable {
    let kind: PredictedExcursion
    /// When the forecast's central line crosses the threshold.
    let expectedAt: Date
    /// The threshold crossed, mg/dL.
    let thresholdMgdl: Double
    /// The forecast value at the crossing, mg/dL.
    let forecastMgdl: Double
    let basis: ForecastBasis

    func minutesAway(from date: Date) -> Int { max(0, Int((expectedAt.timeIntervalSince(date) / 60).rounded())) }
}

struct PredictiveAlertSettings: Hashable {
    var lows = true
    var highs = true
    /// How far ahead a crossing may be to alert.
    var leadTime: TimeInterval = 30 * 60
    var lowMgdl: Double = 70
    var highMgdl: Double = 180
    /// Above-target predictions only alert when high alerts on readings are also on.
    var highAlertsOn = true
}

enum PredictiveAlertRules {
    static let urgentLowMgdl = 54.0
    static let veryHighMgdl = 250.0
    /// A predicted low needs glucose to be actually falling at least this fast (mg/dL per minute),
    /// so sensor noise around a flat reading doesn't raise it. About 0.3 mmol/L per 20 minutes.
    static let minimumFall = -0.3
    /// …and a predicted high, rising at least this fast.
    static let minimumRise = 0.3
    /// Highs are slower and less urgent; allow a little more lead time but never less than the setting.
    static let highLeadFactor = 1.5

    /// The most urgent predicted excursion, if any. Nothing when the forecast isn't current, the
    /// reading is already past the threshold (the reading alerts cover that), or the trend doesn't
    /// agree with the direction.
    static func evaluate(_ forecast: GlucoseForecast, settings: PredictiveAlertSettings, now: Date) -> PredictiveAlertDecision? {
        guard now.timeIntervalSince(forecast.issuedAt) <= GlucoseSnapshot.staleAfter else { return nil }
        let start = forecast.startMgdl
        func crossing(below threshold: Double, within lead: TimeInterval) -> ForecastSample? {
            forecast.samples.first { $0.date.timeIntervalSince(forecast.issuedAt) <= lead && $0.mgdl < threshold }
        }
        func crossing(above threshold: Double, within lead: TimeInterval) -> ForecastSample? {
            forecast.samples.first { $0.date.timeIntervalSince(forecast.issuedAt) <= lead && $0.mgdl > threshold }
        }

        if settings.lows, forecast.trendPerMinute <= minimumFall {
            if start >= urgentLowMgdl, let s = crossing(below: urgentLowMgdl, within: settings.leadTime) {
                return PredictiveAlertDecision(kind: .urgentLow, expectedAt: s.date, thresholdMgdl: urgentLowMgdl,
                                               forecastMgdl: s.mgdl, basis: forecast.basis)
            }
            if start >= settings.lowMgdl, let s = crossing(below: settings.lowMgdl, within: settings.leadTime) {
                return PredictiveAlertDecision(kind: .low, expectedAt: s.date, thresholdMgdl: settings.lowMgdl,
                                               forecastMgdl: s.mgdl, basis: forecast.basis)
            }
        }
        if settings.highs, forecast.trendPerMinute >= minimumRise {
            let lead = settings.leadTime * highLeadFactor
            if start <= veryHighMgdl, let s = crossing(above: veryHighMgdl, within: lead) {
                return PredictiveAlertDecision(kind: .veryHigh, expectedAt: s.date, thresholdMgdl: veryHighMgdl,
                                               forecastMgdl: s.mgdl, basis: forecast.basis)
            }
            if settings.highAlertsOn, start <= settings.highMgdl,
               let s = crossing(above: settings.highMgdl, within: lead) {
                return PredictiveAlertDecision(kind: .high, expectedAt: s.date, thresholdMgdl: settings.highMgdl,
                                               forecastMgdl: s.mgdl, basis: forecast.basis)
            }
        }
        return nil
    }
}
