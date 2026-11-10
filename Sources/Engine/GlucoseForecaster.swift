import Foundation

// Short-term glucose forecast.
//
// The forecast follows the recent trend at first and hands over, across half an hour, to the
// effect of the insulin and carbs the user logged that are still acting (Loop's momentum blending,
// in rate form):
//
//     dG/dt(τ) = w(τ) × trend + (1 − w(τ)) × (carb rate × K − insulin rate × S),   w(τ) = max(0, 1 − τ/30 min)
//
// where S and K are what `EffectProfileLearner` fitted from this user's history. When they can't
// be trusted, or something is going on the model can't describe (food without carbs, a hypo
// treatment, a site problem), the forecast uses the trend alone and only looks 30 minutes ahead.
// It always assumes nothing new is eaten or dosed, and that background insulin holds glucose level.

/// Why there's no forecast right now.
enum ForecastUnavailable: Hashable {
    case noReading
    case stale(age: TimeInterval)
    case outOfSensorRange
    case notEnoughRecentReadings
    case notAccurateEnough

    var message: String {
        switch self {
        case .noReading: return "No reading yet."
        case .stale: return "No forecast while the latest reading is old."
        case .outOfSensorRange: return "No forecast while the reading is outside the sensor's range."
        case .notEnoughRecentReadings: return "Needs a few readings from the last 20 minutes to see the trend."
        case .notAccurateEnough: return "Past forecasts haven't been accurate enough to show one."
        }
    }
}

/// Something that limits how far the forecast can be trusted, shown alongside it.
enum ForecastLimitation: Hashable {
    /// Fast-acting insulin is acting but its effect hasn't been learnt yet.
    case insulinNotLearned
    /// Carbs are being absorbed but their effect hasn't been learnt yet.
    case carbsNotLearned
    /// Food logged without carbs, or a hypo treatment, in the last few hours.
    case uncountedFood
    /// A site or delivery problem was logged recently: insulin may not have gone in.
    case deliveryProblem
    /// Exercise, illness and the like can change how glucose responds.
    case context(ContextTag)
    /// Glucose is changing fast, so the trend is less certain.
    case rapidChange
    /// Long-acting insulin isn't modelled; it's assumed to hold glucose level.
    case backgroundInsulin
    /// Accuracy hasn't been checked against this user's history yet, so a cautious range is used.
    case uncalibrated

    var message: String {
        switch self {
        case .insulinNotLearned:
            return "Insulin is still acting, but GlucOS hasn't seen enough of your doses to estimate its effect, so this only follows the trend."
        case .carbsNotLearned:
            return "Carbs are still being absorbed, but GlucOS hasn't seen enough of your meals to estimate their effect, so this only follows the trend."
        case .uncountedFood:
            return "Food was logged without carbs recently, so its effect can't be included. This only follows the trend."
        case .deliveryProblem:
            return "A site or delivery problem was logged, so insulin isn't included. This only follows the trend."
        case .context(let tag):
            return "\(tag.title) is logged, which can change how glucose responds. The range is wider to allow for it."
        case .rapidChange:
            return "Glucose is changing quickly, so the trend is less certain."
        case .backgroundInsulin:
            return "Long-acting insulin isn't modelled; it's assumed to be holding glucose level."
        case .uncalibrated:
            return "Not yet checked against enough of your history, so a cautious range is shown."
        }
    }

    /// Limitations that force a trend-only forecast.
    var forcesTrendOnly: Bool {
        switch self {
        case .insulinNotLearned, .carbsNotLearned, .uncountedFood, .deliveryProblem: return true
        default: return false
        }
    }
}

struct GlucoseForecast: Hashable {
    let issuedAt: Date
    let startMgdl: Double
    let basis: ForecastBasis
    /// Slope of the recent readings, mg/dL per minute.
    let trendPerMinute: Double
    /// Every 5 minutes from the starting reading, the first at τ = 0.
    let samples: [ForecastSample]
    let limitations: [ForecastLimitation]
    /// The accuracy figures the range came from, if any.
    let calibrated: Bool

    var horizon: TimeInterval { samples.last.map { $0.date.timeIntervalSince(issuedAt) } ?? 0 }

    func firstBelow(_ mgdl: Double) -> Date? { samples.first { $0.mgdl < mgdl }?.date }
    func firstRangeBelow(_ mgdl: Double) -> Date? { samples.first { $0.lowerMgdl < mgdl }?.date }
    func firstAbove(_ mgdl: Double) -> Date? { samples.first { $0.mgdl > mgdl }?.date }
}

struct ForecastInputs {
    var readings: GlucoseSeries
    var doses: [InsulinDose]
    var meals: [MealEntry]
    var contexts: [ContextEvent]
    var profile: EffectProfile
    var calibration: ForecastCalibration?
    var now: Date

    init(readings: GlucoseSeries, doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
         profile: EffectProfile, calibration: ForecastCalibration? = nil, now: Date) {
        self.readings = readings
        self.doses = doses
        self.meals = meals
        self.contexts = contexts
        self.profile = profile
        self.calibration = calibration
        self.now = now
    }
}

enum GlucoseForecaster {
    static let step: TimeInterval = 5 * 60
    /// How long the trend takes to hand over to the modelled effects.
    static let trendFade: TimeInterval = 30 * 60
    static let trendWindow: TimeInterval = 20 * 60
    static let maxTrendPerMinute = 4.0
    /// How far ahead each basis may look, before accuracy checks narrow it.
    static let trendHorizon: TimeInterval = 30 * 60
    static let modelHorizon: TimeInterval = 3 * 3600
    /// Without accuracy figures, a model-based forecast only looks this far.
    static let uncalibratedModelHorizon: TimeInterval = 60 * 60
    static let sensorRange: ClosedRange<Double> = 40...400

    /// The forecast, or why there isn't one. `maxHorizon` overrides the usual limit (backtesting
    /// uses it to look the full distance).
    static func forecast(_ input: ForecastInputs, maxHorizon: TimeInterval? = nil)
        -> Result<GlucoseForecast, ForecastFailure> {
        guard let latest = input.readings.last else { return .failure(.init(.noReading)) }
        let age = input.now.timeIntervalSince(latest.timestamp)
        guard age <= GlucoseSnapshot.staleAfter else { return .failure(.init(.stale(age: age))) }
        guard sensorRange.contains(latest.mgdl) else { return .failure(.init(.outOfSensorRange)) }
        guard let trend = trend(input.readings, at: latest.timestamp) else {
            return .failure(.init(.notEnoughRecentReadings))
        }

        let t0 = latest.timestamp
        var limitations: [ForecastLimitation] = []

        let fast = input.doses.compactMap(TimedDose.init(fastPartOf:)).filter { $0.date <= t0 && $0.end > t0 }
        let carbs = input.meals.filter { $0.carbs > 0 && $0.timestamp <= t0 }
            .map { TimedCarbs(date: $0.timestamp, grams: $0.carbs) }
            .filter { $0.end > t0 }
        let insulinLeft = fast.reduce(0) { $0 + $1.remaining(at: t0) }
        let carbsLeft = carbs.reduce(0) { $0 + $1.remaining(at: t0) }
        let insulinMatters = insulinLeft >= InsulinActivity.tailUnits
        let carbsMatter = carbsLeft >= CarbActivity.tailGrams

        let foodReach = CarbAbsorptionCurve.standard.totalDuration
        let uncounted = input.meals.contains { $0.carbs <= 0 && $0.timestamp <= t0 && t0.timeIntervalSince($0.timestamp) < foodReach }
            || input.contexts.contains { $0.tags.contains(.hypoTreatment) && $0.timestamp <= t0
                                         && t0.timeIntervalSince($0.timestamp) < foodReach }
        if uncounted { limitations.append(.uncountedFood) }
        if input.contexts.contains(where: { $0.tags.contains(.siteProblem) && $0.timestamp <= t0
                                            && t0.timeIntervalSince($0.timestamp) < 6 * 3600 }), insulinMatters {
            limitations.append(.deliveryProblem)
        }
        let S = input.profile.reliableInsulin?.value
        let K = input.profile.reliableCarbs?.value
        if insulinMatters && S == nil { limitations.append(.insulinNotLearned) }
        if carbsMatter && K == nil { limitations.append(.carbsNotLearned) }

        let activeTags = ContextTag.allCases.filter { tag in
            tag.isComparable && input.contexts.contains { c in
                c.tags.contains(tag) && c.timestamp <= t0 && t0.timeIntervalSince(c.timestamp) <= tag.reach
            }
        }
        limitations += activeTags.map(ForecastLimitation.context)
        if abs(trend) >= 2 { limitations.append(.rapidChange) }
        if input.doses.contains(where: { $0.kind == .long && $0.timestamp <= t0 && t0.timeIntervalSince($0.timestamp) < 36 * 3600 }) {
            limitations.append(.backgroundInsulin)
        }

        let trendOnly = limitations.contains(where: \.forcesTrendOnly) || (!insulinMatters && !carbsMatter)
        // With nothing acting, the model is the trend fading to level, so it's still "trend".
        let basis: ForecastBasis = trendOnly ? .trend : .trendInsulinCarbs

        var horizon = basis == .trend ? trendHorizon : modelHorizon
        let stats = input.calibration?.stats(for: basis)
        if let maxHorizon {
            horizon = maxHorizon
        } else if let allowed = input.calibration?.allowedHorizon(for: basis) {
            horizon = min(horizon, allowed)
            if horizon <= 0 { return .failure(.init(.notAccurateEnough, limitations: limitations)) }
        } else if basis == .trendInsulinCarbs {
            horizon = uncalibratedModelHorizon
        }
        let calibrated = maxHorizon == nil
            && stats?.contains { $0.samples >= ForecastCalibration.minimumSamples } == true
        if !calibrated && maxHorizon == nil { limitations.append(.uncalibrated) }

        // Integrate the rate minute by minute.
        let widen = activeTags.isEmpty ? 1.0 : 1.5
        var samples: [ForecastSample] = []
        var g = latest.mgdl
        var minute = 0.0
        let totalMinutes = horizon / 60
        func modelRate(at t: Date) -> Double {
            guard basis == .trendInsulinCarbs else { return 0 }
            let insulinPerMinute = fast.reduce(0) { $0 + $1.activityPerHour(at: t) } / 60
            let carbsPerMinute = carbs.reduce(0) { $0 + $1.ratePerHour(at: t) } / 60
            return (K ?? 0) * carbsPerMinute - (S ?? 0) * insulinPerMinute
        }
        func band(_ minutes: Double) -> (Double, Double) {
            let q = stats.flatMap { ForecastCalibration.interpolate($0, minutes: minutes) }
                ?? ForecastCalibration.defaultBand(minutes: minutes)
            return (q.lower * widen, q.upper * widen)
        }
        samples.append(ForecastSample(date: t0, mgdl: g, lowerMgdl: g, upperMgdl: g))
        while minute < totalMinutes {
            // Midpoint rule over each minute.
            let mid = minute + 0.5
            let w = max(0, 1 - mid * 60 / trendFade)
            let rate = w * trend + (1 - w) * modelRate(at: t0.addingTimeInterval(mid * 60))
            g += rate
            minute += 1
            if Int(minute) % Int(step / 60) == 0 {
                let central = min(max(g, sensorRange.lowerBound - 1), sensorRange.upperBound + 1)
                let (lo, hi) = band(minute)
                samples.append(ForecastSample(date: t0.addingTimeInterval(minute * 60), mgdl: central,
                                              lowerMgdl: max(sensorRange.lowerBound - 1, central + lo),
                                              upperMgdl: min(sensorRange.upperBound + 1, central + hi)))
            }
        }
        return .success(GlucoseForecast(issuedAt: t0, startMgdl: latest.mgdl, basis: basis, trendPerMinute: trend,
                                        samples: samples, limitations: limitations, calibrated: calibrated))
    }

    /// Slope of the readings in the 20 minutes up to `date`, mg/dL per minute. Needs at least
    /// two readings at least 9 minutes apart; falls back to nothing rather than guess from the arrow.
    static func trend(_ series: GlucoseSeries, at date: Date) -> Double? {
        let recent = series.slice(from: date.addingTimeInterval(-trendWindow), through: date)
        guard let first = recent.first, let last = recent.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 9 * 60 else { return nil }
        let x = recent.map { $0.timestamp.timeIntervalSince(date) / 60 }
        let y = recent.map(\.mgdl)
        guard let s = EngineMath.slope(x: x, y: y) else { return nil }
        return min(max(s, -maxTrendPerMinute), maxTrendPerMinute)
    }
}

struct ForecastFailure: Error, Hashable {
    let reason: ForecastUnavailable
    var limitations: [ForecastLimitation] = []

    init(_ reason: ForecastUnavailable, limitations: [ForecastLimitation] = []) {
        self.reason = reason
        self.limitations = limitations
    }
}
