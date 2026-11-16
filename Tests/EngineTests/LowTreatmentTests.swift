import XCTest
@testable import GlucOSEngine

/// Carbs logged for a low go on the fast curve in the forecast only (docs/ForecastAccuracy.md §37).
final class LowTreatmentTests: XCTestCase {
    let now = referenceNow
    let learned = EffectProfile(insulin: LearnedEffect(value: 50, standardError: 3, examples: 20),
                                carbs: LearnedEffect(value: 3, standardError: 0.3, examples: 20),
                                driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: referenceNow)

    func input(_ r: [GlucoseReading], meals: [MealEntry] = [], contexts: [ContextEvent] = []) -> ForecastInputs {
        ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: meals, contexts: contexts, profile: learned, now: now)
    }

    func success(_ r: Result<GlucoseForecast, ForecastFailure>, file: StaticString = #filePath, line: UInt = #line) throws -> GlucoseForecast {
        switch r {
        case .success(let f): return f
        case .failure(let e): XCTFail("No forecast: \(e.reason)", file: file, line: line); throw e
        }
    }

    func meal(minutesAgo m: Double, carbs: Double) -> MealEntry {
        MealEntry(timestamp: now.addingTimeInterval(-m * 60), carbs: carbs)
    }

    func testWhatCountsAsATreatment() {
        let low = GlucoseSeries(readings(endingAt: now, minutes: 30) { _ in 60 })
        let fine = GlucoseSeries(readings(endingAt: now, minutes: 30) { _ in 120 })
        let juice = meal(minutesAgo: 5, carbs: 20)
        XCTAssertTrue(LowTreatment.isTreatment(juice, readings: low, contexts: []))
        XCTAssertFalse(LowTreatment.isTreatment(juice, readings: fine, contexts: []))
        // A big meal while low is still a meal.
        XCTAssertFalse(LowTreatment.isTreatment(meal(minutesAgo: 5, carbs: 60), readings: low, contexts: []))
        // Food without carbs has nothing to model.
        XCTAssertFalse(LowTreatment.isTreatment(meal(minutesAgo: 5, carbs: 0), readings: low, contexts: []))
        // Tagged as a hypo treatment counts whatever the reading.
        let tag = ContextEvent(timestamp: now.addingTimeInterval(-4 * 60), tags: [.hypoTreatment])
        XCTAssertTrue(LowTreatment.isTreatment(juice, readings: fine, contexts: [tag]))
        // No reading near the log: not counted from the reading.
        XCTAssertFalse(LowTreatment.isTreatment(juice, readings: GlucoseSeries([]), contexts: []))
    }

    func testTreatmentRaisesTheForecastSoonInsteadOfFollowingTheTrend() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 60 }
        let juice = meal(minutesAgo: 5, carbs: 20)
        let f = try success(GlucoseForecaster.forecast(input(r, meals: [juice])))
        XCTAssertEqual(f.basis, .trendInsulinCarbs)
        XCTAssertTrue(f.limitations.contains(.lowTreatment))
        // Not held back as a fresh log: the fast curve was checked on the first hour.
        XCTAssertFalse(f.limitations.contains(.freshLog))
        // Fully absorbed 40 minutes after it was taken. Of its 20 g × 3 × 1.5 = 90 mg/dL, the part
        // absorbed while the trend still leads is blended away, as for any carbs: 53 mg/dL (the
        // §37 prototype gives the same).
        let full = try success(GlucoseForecaster.forecast(input(r, meals: [juice]), maxHorizon: 60 * 60))
        XCTAssertEqual(full.samples.last!.mgdl - 60, 53.2, accuracy: 0.5)
        let at45 = try XCTUnwrap(full.samples.first { $0.date == now.addingTimeInterval(45 * 60) })
        XCTAssertEqual(full.samples.last!.mgdl, at45.mgdl, accuracy: 0.01)

        // Without the curve it's as before: a fresh meal, trend only.
        var plain = input(r, meals: [juice])
        plain.lowTreatmentCurve = false
        let before = try success(GlucoseForecaster.forecast(plain))
        XCTAssertEqual(before.basis, .trend)
        XCTAssertTrue(before.limitations.contains(.freshLog))
        XCTAssertFalse(before.limitations.contains(.lowTreatment))
    }

    func testOnceAbsorbedTheTreatmentDropsOut() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 140 }
        let old = meal(minutesAgo: 50, carbs: 20)
        // The reading at the time was low (it's a treatment); by now nothing of it is left.
        let rs = readings(endingAt: now.addingTimeInterval(-45 * 60), minutes: 30) { _ in 60 } + r
        let f = try success(GlucoseForecaster.forecast(input(rs, meals: [old])))
        XCTAssertFalse(f.limitations.contains(.lowTreatment))
        XCTAssertEqual(f.basis, .trend)
    }

    func testTaggedTreatmentWithCarbsIsCounted() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 90 }
        let tag = ContextEvent(timestamp: now.addingTimeInterval(-10 * 60), tags: [.hypoTreatment])
        let f = try success(GlucoseForecaster.forecast(input(r, meals: [meal(minutesAgo: 10, carbs: 15)], contexts: [tag])))
        XCTAssertFalse(f.limitations.contains(.uncountedFood))
        XCTAssertTrue(f.limitations.contains(.lowTreatment))
        // A tag with no carbs beside it is still food that can't be counted.
        let bare = try success(GlucoseForecaster.forecast(input(r, contexts: [tag])))
        XCTAssertTrue(bare.limitations.contains(.uncountedFood))
        XCTAssertEqual(bare.basis, .trend)
    }

    func testPredictedAlertsReadTheForecastWithoutTheTreatment() throws {
        // Falling fast towards an urgent low, juice logged two minutes ago at 64.
        let r = readings(endingAt: now, minutes: 30, step: 1) { m in 62 + 1.0 * m }
        let juice = meal(minutesAgo: 2, carbs: 20)
        let model = OutlookModel(profile: learned, calibration: nil, patterns: [], learnedAt: now)
        let o = OutlookEngine.outlook(readings: r, doses: [], meals: [juice], contexts: [], model: model, now: now)
        let shown = try XCTUnwrap(o.glucoseForecast)
        XCTAssertTrue(shown.limitations.contains(.lowTreatment))
        let alertForecast = try XCTUnwrap(o.alertForecast)
        XCTAssertFalse(alertForecast.limitations.contains(.lowTreatment))

        var plain = input(r, meals: [juice])
        plain.lowTreatmentCurve = false
        let before = try success(GlucoseForecaster.forecast(plain))
        XCTAssertEqual(alertForecast, before)
        let settings = PredictiveAlertSettings()
        let warned = PredictiveAlertRules.evaluate(alertForecast, settings: settings, now: now)
        XCTAssertEqual(warned, PredictiveAlertRules.evaluate(before, settings: settings, now: now))
        XCTAssertEqual(warned?.kind, .urgentLow)
        // The shown forecast comes back up sooner than the one alerts read.
        XCTAssertGreaterThan(shown.samples.last!.mgdl, alertForecast.samples.last!.mgdl)

        // With nothing logged for the low, alerts read the shown forecast as always.
        let none = OutlookEngine.outlook(readings: r, doses: [], meals: [], contexts: [], model: model, now: now)
        XCTAssertNil(none.withoutLowTreatment)
        XCTAssertEqual(none.alertForecast, none.glucoseForecast)
    }

    func testDosingCurvesAreUntouched() {
        // Carbs on board and the bolus calculator keep the meal curve for the same entry.
        let juice = meal(minutesAgo: 30, carbs: 20)
        let cob = CarbActivity.compute(meals: [juice], at: now)
        XCTAssertEqual(cob.onBoard, 20 * CarbAbsorptionCurve.standard.fractionRemaining(after: 30 * 60), accuracy: 0.01)
    }
}
