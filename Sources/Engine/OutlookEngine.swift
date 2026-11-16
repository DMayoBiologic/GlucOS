import Foundation

/// What the engine learns slowly from history. Worked out in the background when the logbook
/// changes or a few hours have passed; cheap to keep and pass around.
struct OutlookModel: Hashable {
    var profile: EffectProfile
    var calibration: ForecastCalibration?
    var patterns: [RecurringPattern]
    var learnedAt: Date
    /// What glucose usually does after the user wakes, from their logged wake-ups.
    var morning: MorningPattern = .empty
    /// The trend timing tuned to this user's history, and how much it helped.
    var tuning: ForecastTuningResult = .untuned
    /// How much wider the likely range is drawn, from how the forecasts shown on this device
    /// actually did (`ForecastLedger.rangeScale`). Set by the app from its forecast log.
    var rangeScale: ForecastRangeScale = .unchanged
    /// How far ahead the forecast may be drawn, from how this device's own forecasts did against
    /// no change (`ForecastLedger.liveHorizon`). Set by the app from its forecast log.
    var liveHorizon: ForecastLiveHorizon = .unlimited
    /// How this device's "back in range in about X min" estimates have done (`BackInRange.check`),
    /// which decides whether one is shown. Set by the app from its forecast log.
    var backInRange: BackInRangeCheck = .none

    static let empty = OutlookModel(profile: .empty, calibration: nil, patterns: [], learnedAt: .distantPast)
}

/// Everything the outlook shows at one moment.
struct Outlook {
    let at: Date
    let forecast: Result<GlucoseForecast, ForecastFailure>
    let insulin: InsulinActivity
    /// Long-acting, NPH and the slow part of premixed insulin. Not in the forecast.
    let background: BackgroundInsulinActivity
    let carbs: CarbActivity
    let model: OutlookModel
    /// When carbs logged for a low were modelled on the fast low-treatment curve: the forecast
    /// without that curve, the way it was before §37. Predicted alerts read this one.
    var withoutLowTreatment: Result<GlucoseForecast, ForecastFailure>? = nil

    var glucoseForecast: GlucoseForecast? {
        if case .success(let f) = forecast { return f }
        return nil
    }

    /// The forecast predicted alerts read: the one shown, or, when it includes a low treatment's
    /// fast curve, the same forecast without it. A logged treatment raises the forecast, so this
    /// keeps a predicted low from ever being warned of later than before (§37).
    var alertForecast: GlucoseForecast? {
        guard let plain = withoutLowTreatment else { return glucoseForecast }
        if case .success(let f) = plain { return f }
        return nil
    }

    /// What goes in the forecast log: the drawn forecast with its cut-off part, or, when live
    /// checks cut it back to nothing, the forecast that wasn't drawn.
    var forecastToLog: GlucoseForecast? {
        switch forecast {
        case .success(let f): return f
        case .failure(let e): return e.unshown
        }
    }

    var limitations: [ForecastLimitation] {
        switch forecast {
        case .success(let f): return f.limitations
        case .failure(let e): return e.limitations
        }
    }

    /// The compact form written into the shared snapshot for the widget and popover. With
    /// `highMgdl`, a forecast that comes back down into range says when (`BackInRange`).
    func snapshot(lowMgdl: Double, highMgdl: Double? = nil) -> OutlookSnapshot {
        let f = glucoseForecast
        var s = OutlookSnapshot(issuedAt: f?.issuedAt ?? at, basis: f?.basis ?? .trend)
        s.forecast = f?.samples ?? []
        s.insulinOnBoard = insulin.doseCount > 0 ? insulin.onBoard : nil
        s.insulinMostlyDoneAt = insulin.mostlyDoneAt
        s.carbsOnBoard = carbs.mealCount > 0 ? carbs.onBoard : nil
        s.lowExpectedAt = f?.firstBelow(lowMgdl)
        s.lowPossibleAt = f?.firstRangeBelow(lowMgdl)
        if let f, let highMgdl { s.backInRangeAt = BackInRange.estimate(f, high: highMgdl, check: model.backInRange) }
        if case .failure(let e) = forecast { s.unavailableReason = e.reason.message }
        s.caveat = ForecastCaveat.pick(forecast)
        s.morning = f?.morning.map {
            MorningAdjustmentSnapshot(wokeAt: $0.wokeAt, addedMgdl: $0.addedMgdl, confidence: $0.confidence ?? .low)
        }
        return s
    }
}

enum OutlookEngine {
    /// The slow part: effect profile, forecast accuracy and recurring patterns.
    static func learn(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                      low: Double, high: Double, now: Date = Date(), calendar: Calendar = .current) -> OutlookModel {
        let meals = LogCleanup.mealsWithoutRepeats(meals)
        let profile = EffectProfileLearner.learn(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                                 low: low, now: now, calendar: calendar)
        // Each replayed forecast uses a profile fitted without the stretch it's checked against.
        let heldOut = EffectProfileLearner.heldOut(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                                   profile: profile, low: low, now: now, calendar: calendar)
        // Pick the trend timing that has forecast this user best, then measure accuracy with it.
        let tuning = ForecastTuner.tune(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                        profile: profile, now: now, profileAt: heldOut)
        var calibration = ForecastBacktest.run(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                               profile: profile, now: now, profileAt: heldOut, tuning: tuning.tuning)
        calibration.tuning = tuning.tuning
        let patterns = RecurringPatternFinder.find(readings: readings, low: low, high: high, now: now, calendar: calendar)
        let morning = MorningPatternLearner.learn(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                                  profile: profile, low: low, now: now)
        return OutlookModel(profile: profile, calibration: calibration.origins > 0 ? calibration : nil,
                            patterns: patterns, learnedAt: now, morning: morning, tuning: tuning)
    }

    /// The quick part, run on every new reading. `readings` only needs the last hour or so.
    static func outlook(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                        model: OutlookModel, now: Date = Date()) -> Outlook {
        // Doses marked as for a meal are matched against every meal entry, repeats included.
        let unloggedMeals = DoseMealCheck.unloggedMealTimes(doses: doses, meals: meals)
        let meals = LogCleanup.mealsWithoutRepeats(meals)
        let series = GlucoseSeries(readings)
        var input = ForecastInputs(readings: series, doses: doses, meals: meals, contexts: contexts,
                                   profile: model.profile, calibration: model.calibration,
                                   morning: model.morning.isUsable ? model.morning : nil,
                                   tuning: model.tuning.tuning, rangeScale: model.rangeScale, now: now)
        input.unloggedMealTimes = unloggedMeals
        input.liveHorizon = model.liveHorizon
        let hypo = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
            + unloggedMeals
        let forecast = GlucoseForecaster.forecast(input)
        var plain: Result<GlucoseForecast, ForecastFailure>?
        if forecast.usesLowTreatment {
            input.lowTreatmentCurve = false
            plain = GlucoseForecaster.forecast(input)
        }
        return Outlook(at: now,
                       forecast: forecast,
                       insulin: InsulinActivity.compute(doses: doses, at: now),
                       background: BackgroundInsulinActivity.compute(doses: doses, at: now),
                       carbs: CarbActivity.compute(meals: meals, hypoTreatments: hypo, at: now),
                       model: model,
                       withoutLowTreatment: plain)
    }
}

extension Result where Success == GlucoseForecast, Failure == ForecastFailure {
    /// Whether a low treatment's fast curve went into it (success or not).
    var usesLowTreatment: Bool {
        switch self {
        case .success(let f): return f.limitations.contains(.lowTreatment)
        case .failure(let e): return e.limitations.contains(.lowTreatment)
        }
    }
}
