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

    var glucoseForecast: GlucoseForecast? {
        if case .success(let f) = forecast { return f }
        return nil
    }

    var limitations: [ForecastLimitation] {
        switch forecast {
        case .success(let f): return f.limitations
        case .failure(let e): return e.limitations
        }
    }

    /// The compact form written into the shared snapshot for the widget and popover.
    func snapshot(lowMgdl: Double) -> OutlookSnapshot {
        let f = glucoseForecast
        var s = OutlookSnapshot(issuedAt: f?.issuedAt ?? at, basis: f?.basis ?? .trend)
        s.forecast = f?.samples ?? []
        s.insulinOnBoard = insulin.doseCount > 0 ? insulin.onBoard : nil
        s.insulinMostlyDoneAt = insulin.mostlyDoneAt
        s.carbsOnBoard = carbs.mealCount > 0 ? carbs.onBoard : nil
        s.lowExpectedAt = f?.firstBelow(lowMgdl)
        s.lowPossibleAt = f?.firstRangeBelow(lowMgdl)
        if case .failure(let e) = forecast { s.unavailableReason = e.reason.message }
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
        let series = GlucoseSeries(readings)
        let input = ForecastInputs(readings: series, doses: doses, meals: meals, contexts: contexts,
                                   profile: model.profile, calibration: model.calibration,
                                   morning: model.morning.isUsable ? model.morning : nil,
                                   tuning: model.tuning.tuning, now: now)
        let hypo = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        return Outlook(at: now,
                       forecast: GlucoseForecaster.forecast(input),
                       insulin: InsulinActivity.compute(doses: doses, at: now),
                       background: BackgroundInsulinActivity.compute(doses: doses, at: now),
                       carbs: CarbActivity.compute(meals: meals, hypoTreatments: hypo, at: now),
                       model: model)
    }
}
