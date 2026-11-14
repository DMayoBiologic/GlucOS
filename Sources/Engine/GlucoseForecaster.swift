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
//
// After a logged wake-up, the user's usual post-wake change (`MorningPattern`, only once it has
// been shown to improve their past forecasts) is added to the modelled rate the same way.
//
// Two things keep it from claiming more than it knows:
//   • the trend counts for only as much as it has earned (`ForecastTuning.trendGain`, from the
//     replay): a Libre trend measured over 20 minutes carries on at roughly half strength, so
//     following it fully made the 15-minute forecast worse than assuming no change;
//   • for the first hour after a meal or a dose, the modelled effects are mostly still to come and
//     their timing varies, so the forecast follows the trend alone until the replay shows that
//     forecasts made this soon after a log beat assuming no change (`ForecastCalibration.freshModel`).

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
    /// A meal or dose was logged within the last hour, and forecasts made that soon after a log
    /// haven't yet beaten assuming no change.
    case freshLog

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
        case .freshLog:
            return "Insulin or carbs were logged in the last hour, before their effect is clear. Until your history shows forecasts this soon after a log are reliable, this only follows the trend."
        }
    }

    /// A short stable name, for the forecast log.
    var code: String {
        switch self {
        case .insulinNotLearned: return "insulinNotLearned"
        case .carbsNotLearned: return "carbsNotLearned"
        case .uncountedFood: return "uncountedFood"
        case .deliveryProblem: return "deliveryProblem"
        case .context(let tag): return "context:\(tag.rawValue)"
        case .rapidChange: return "rapidChange"
        case .backgroundInsulin: return "backgroundInsulin"
        case .uncalibrated: return "uncalibrated"
        case .freshLog: return "freshLog"
        }
    }

    /// Limitations that force a trend-only forecast.
    var forcesTrendOnly: Bool {
        switch self {
        case .insulinNotLearned, .carbsNotLearned, .uncountedFood, .deliveryProblem, .freshLog: return true
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
    /// The post-wake adjustment included, if any.
    var morning: AppliedMorningAdjustment? = nil
    /// How much the range was widened to match how this device's forecasts actually did: the
    /// largest widening anywhere along it.
    var rangeScale: Double = 1
    /// The widening at each 5-minute sample, by minutes ahead.
    var rangeScales: [Int: Double] = [:]
    /// Insulin and carbs were modelled within the first hour after a log.
    var fresh = false

    /// The widening `minutes` ahead.
    func rangeScale(atMinutes minutes: Int) -> Double { rangeScales[minutes] ?? rangeScale }

    var horizon: TimeInterval { samples.last.map { $0.date.timeIntervalSince(issuedAt) } ?? 0 }

    func firstBelow(_ mgdl: Double) -> Date? { samples.first { $0.mgdl < mgdl }?.date }
    func firstRangeBelow(_ mgdl: Double) -> Date? { samples.first { $0.lowerMgdl < mgdl }?.date }
    func firstAbove(_ mgdl: Double) -> Date? { samples.first { $0.mgdl > mgdl }?.date }
}

/// How much wider to draw the likely range, for each kind of forecast. The range is meant to
/// hold 4 readings in 5; when the forecasts shown on this device have landed outside it more
/// often than that, it's widened until it would have held them (`ForecastLedger.rangeScale`).
/// Never narrowed: the backtest already sets the range, this only corrects it when it's too
/// confident.
struct ForecastRangeScale: Hashable, Codable {
    var byBasis: [ForecastBasis: Double] = [:]
    /// The same per checked horizon (minutes ahead), where that horizon has enough shown points of
    /// its own. Errors grow at different rates at different distances, so one figure per kind left
    /// the range too narrow at 15 and 45 minutes and wider than needed elsewhere.
    var byHorizon: [ForecastBasis: [Int: Double]] = [:]
    /// Shown forecast points the figures came from.
    var checks: Int = 0

    static let unchanged = ForecastRangeScale()
    static let maximum = 2.5

    private static func clamp(_ x: Double) -> Double { min(maximum, max(1, x)) }

    func factor(for basis: ForecastBasis) -> Double { Self.clamp(byBasis[basis] ?? 1) }

    /// The widening `minutes` ahead: interpolated between the horizons that have their own figure,
    /// held flat before the first and after the last, and the kind's overall figure without any.
    func factor(for basis: ForecastBasis, minutes: Double) -> Double {
        let points = (byHorizon[basis] ?? [:]).sorted { $0.key < $1.key }
        guard let first = points.first, let last = points.last else { return factor(for: basis) }
        if minutes <= Double(first.key) { return Self.clamp(first.value) }
        if minutes >= Double(last.key) { return Self.clamp(last.value) }
        for (a, b) in zip(points, points.dropFirst()) where minutes <= Double(b.key) {
            let f = (minutes - Double(a.key)) / Double(b.key - a.key)
            return Self.clamp(a.value + (b.value - a.value) * f)
        }
        return Self.clamp(last.value)
    }

    var isWidened: Bool { largest > 1.005 }
    /// The largest widening in use.
    var largest: Double {
        (byBasis.values + byHorizon.values.flatMap(\.values)).max().map(Self.clamp) ?? 1
    }
}

/// The forecast's own timing, tuned to the user once their history shows a different setting
/// forecasts better (`ForecastTuner`). The standard values are Loop's.
struct ForecastTuning: Hashable, Codable {
    /// How long the recent trend takes to hand over to the modelled effects (or to level).
    var trendFade: TimeInterval = GlucoseForecaster.trendFade
    /// How far back the trend is measured.
    var trendWindow: TimeInterval = GlucoseForecaster.trendWindow
    /// How much of the recent trend the forecast carries forward, 0–1. Standard is all of it
    /// (Loop's momentum); the tuner lowers it when the user's history shows their trend usually
    /// carries on at only part strength, which pulls the forecast towards "no change".
    var trendGain: Double = 1

    static let standard = ForecastTuning()
    var isStandard: Bool { self == .standard }

    /// "the trend eases off over 20 min, measured over the last 15 min of readings, at half strength".
    var summary: String {
        let strength = trendGain >= 0.995 ? "" : ", counted at \(Int((trendGain * 100).rounded()))% strength"
        return "the trend eases off over \(Int(trendFade / 60)) min, measured over the last \(Int(trendWindow / 60)) min of readings\(strength)"
    }
}

struct ForecastInputs {
    var readings: GlucoseSeries
    var doses: [InsulinDose]
    var meals: [MealEntry]
    var contexts: [ContextEvent]
    var profile: EffectProfile
    var calibration: ForecastCalibration?
    /// The user's usual post-wake change. Pass it only once it's usable (`isUsable`).
    var morning: MorningPattern?
    /// Trend timing. Standard until the user's history shows something else forecasts better.
    var tuning: ForecastTuning
    /// Range widening from this device's shown forecasts.
    var rangeScale: ForecastRangeScale
    /// Whether to model insulin and carbs within the first hour after a log. Nil: only once the
    /// calibration shows those forecasts beat "no change". The backtest sets it to measure both.
    var freshModel: Bool? = nil
    var now: Date

    init(readings: GlucoseSeries, doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
         profile: EffectProfile, calibration: ForecastCalibration? = nil, morning: MorningPattern? = nil,
         tuning: ForecastTuning = .standard, rangeScale: ForecastRangeScale = .unchanged, now: Date) {
        self.readings = readings
        self.doses = doses
        self.meals = meals
        self.contexts = contexts
        self.profile = profile
        self.calibration = calibration
        self.morning = morning
        self.tuning = tuning
        self.rangeScale = rangeScale
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
    /// A meal or fast-acting dose logged this recently makes the forecast "fresh": most of its
    /// effect is still to come and the replay checks those forecasts separately.
    static let freshLogWindow: TimeInterval = 60 * 60
    static let sensorRange: ClosedRange<Double> = 40...400

    /// The forecast, or why there isn't one. `maxHorizon` overrides the usual limit (backtesting
    /// uses it to look the full distance).
    static func forecast(_ input: ForecastInputs, maxHorizon: TimeInterval? = nil)
        -> Result<GlucoseForecast, ForecastFailure> {
        guard let latest = input.readings.last else { return .failure(.init(.noReading)) }
        let age = input.now.timeIntervalSince(latest.timestamp)
        guard age <= GlucoseSnapshot.staleAfter else { return .failure(.init(.stale(age: age))) }
        guard sensorRange.contains(latest.mgdl) else { return .failure(.init(.outOfSensorRange)) }
        guard let trend = trend(input.readings, at: latest.timestamp, window: input.tuning.trendWindow) else {
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

        // In the first hour after a meal or dose, model it only once that has been shown to work.
        let latestLog = (input.doses.filter { $0.timestamp <= t0 && TimedDose(fastPartOf: $0) != nil }.map(\.timestamp)
                         + input.meals.filter { $0.carbs > 0 && $0.timestamp <= t0 }.map(\.timestamp)).max()
        let fresh = latestLog.map { t0.timeIntervalSince($0) < freshLogWindow } ?? false
        if fresh, insulinMatters || carbsMatter, !limitations.contains(where: \.forcesTrendOnly),
           !(input.freshModel ?? (input.calibration?.freshModelAllowedHorizon.map { $0 > 0 } ?? false)) {
            limitations.append(.freshLog)
        }
        let forced = limitations.contains(where: \.forcesTrendOnly)
        let trendOnly = forced || (!insulinMatters && !carbsMatter)
        let freshModel = fresh && !trendOnly
        // The usual post-wake change, while inside it. Not when the forecast can't trust the
        // logbook (it's learnt on top of what insulin and carbs explain).
        var morningWake: Date?
        if !forced, let p = input.morning, !p.stepChange.isEmpty,
           let wake = WakeLog.latest(input.contexts, before: t0), t0.timeIntervalSince(wake.timestamp) < p.duration {
            morningWake = wake.timestamp
        }
        // With nothing acting, the model is the trend fading to level, so it's still "trend".
        let basis: ForecastBasis = trendOnly ? .trend : .trendInsulinCarbs

        var horizon = basis == .trend ? trendHorizon : modelHorizon
        let stats = freshModel ? input.calibration?.freshModel.flatMap { $0.isEmpty ? nil : $0 }
                               : input.calibration?.stats(for: basis)
        let allowedHorizon = freshModel ? input.calibration?.freshModelAllowedHorizon
                                        : input.calibration?.allowedHorizon(for: basis)
        if let maxHorizon {
            horizon = maxHorizon
        } else if let allowed = allowedHorizon {
            horizon = min(horizon, allowed)
            if horizon <= 0 { return .failure(.init(.notAccurateEnough, limitations: limitations)) }
        } else if basis == .trendInsulinCarbs {
            horizon = uncalibratedModelHorizon
        }
        let calibrated = maxHorizon == nil
            && stats?.contains { $0.samples >= ForecastCalibration.minimumSamples } == true
        if !calibrated && maxHorizon == nil { limitations.append(.uncalibrated) }

        // Integrate the rate minute by minute.
        let scaled = maxHorizon == nil
        let rangeScale = scaled ? input.rangeScale.factor(for: basis) : 1
        let contextWiden = activeTags.isEmpty ? 1.0 : 1.5
        var rangeScales: [Int: Double] = [:]
        let fade = max(60, input.tuning.trendFade)
        let gain = min(1, max(0, input.tuning.trendGain))
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
        func morningRate(at t: Date) -> Double {
            guard let wake = morningWake, let p = input.morning else { return 0 }
            return p.ratePerMinute(after: t.timeIntervalSince(wake))
        }
        var morningAdded = 0.0
        func band(_ minutes: Double) -> (Double, Double) {
            let q = stats.flatMap { ForecastCalibration.interpolate($0, minutes: minutes) }
                ?? ForecastCalibration.defaultBand(minutes: minutes)
            let scale = scaled ? input.rangeScale.factor(for: basis, minutes: minutes) : 1
            rangeScales[Int(minutes.rounded())] = scale
            let widen = contextWiden * scale
            return (q.lower * widen, q.upper * widen)
        }
        samples.append(ForecastSample(date: t0, mgdl: g, lowerMgdl: g, upperMgdl: g))
        while minute < totalMinutes {
            // Midpoint rule over each minute.
            let mid = minute + 0.5
            let w = max(0, 1 - mid * 60 / fade)
            let at = t0.addingTimeInterval(mid * 60)
            let fromMorning = (1 - w) * morningRate(at: at)
            let rate = w * gain * trend + (1 - w) * modelRate(at: at) + fromMorning
            morningAdded += fromMorning
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
        let morning = morningWake.map {
            AppliedMorningAdjustment(wokeAt: $0, addedMgdl: morningAdded, confidence: input.morning?.confidence)
        }
        return .success(GlucoseForecast(issuedAt: t0, startMgdl: latest.mgdl, basis: basis, trendPerMinute: trend,
                                        samples: samples, limitations: limitations, calibrated: calibrated,
                                        morning: morning, rangeScale: max(rangeScale, rangeScales.values.max() ?? 1),
                                        rangeScales: rangeScales, fresh: freshModel))
    }

    /// Slope of the readings in the `window` (normally 20 minutes) up to `date`, mg/dL per minute.
    /// Needs at least two readings at least 9 minutes apart; falls back to nothing rather than
    /// guess from the arrow.
    static func trend(_ series: GlucoseSeries, at date: Date, window: TimeInterval = trendWindow) -> Double? {
        let recent = series.slice(from: date.addingTimeInterval(-max(window, 10 * 60)), through: date)
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
