import XCTest
@testable import GlucOSEngine

/// "Was that dose for a meal?" (docs/DoseQuestion.md): which doses are asked about, when, and how
/// the answer changes what the forecast and the learners make of the dose.
final class DoseMealCheckTests: XCTestCase {
    let now = referenceNow

    func dose(minutesAgo: Double, units: Double = 4, kind: InsulinKind = .rapid,
              purpose: DosePurpose? = nil) -> InsulinDose {
        var d = InsulinDose(timestamp: now.addingTimeInterval(-minutesAgo * 60), units: units, kind: kind)
        d.purpose = purpose
        return d
    }

    func meal(minutesAgo: Double, carbs: Double = 40) -> MealEntry {
        MealEntry(timestamp: now.addingTimeInterval(-minutesAgo * 60), carbs: carbs)
    }

    // MARK: Asking

    func testAsksAboutABolusWithNoFoodNearIt() {
        let d = dose(minutesAgo: 45)
        XCTAssertTrue(DoseMealCheck.isUnexplained(d, meals: [], contexts: []))
        XCTAssertTrue(DoseMealCheck.shouldAsk(d, meals: [], contexts: [], now: now))
        XCTAssertEqual(DoseMealCheck.pending(doses: [d], meals: [], contexts: [], now: now).map(\.id), [d.id])
    }

    func testFoodEitherSideExplainsTheDose() {
        let d = dose(minutesAgo: 60)
        // 20 minutes before the dose, 25 after, and food described without carbs all count.
        XCTAssertFalse(DoseMealCheck.isUnexplained(d, meals: [meal(minutesAgo: 80)], contexts: []))
        XCTAssertFalse(DoseMealCheck.isUnexplained(d, meals: [meal(minutesAgo: 35)], contexts: []))
        XCTAssertFalse(DoseMealCheck.isUnexplained(d, meals: [meal(minutesAgo: 50, carbs: 0)], contexts: []))
        // Two hours away doesn't.
        XCTAssertTrue(DoseMealCheck.isUnexplained(d, meals: [meal(minutesAgo: 180)], contexts: []))
        let hypo = ContextEvent(timestamp: now.addingTimeInterval(-55 * 60), tags: [.hypoTreatment])
        XCTAssertFalse(DoseMealCheck.isUnexplained(d, meals: [], contexts: [hypo]))
    }

    func testOnlyAsksOncePerDose() {
        for purpose in DosePurpose.allCases {
            XCTAssertFalse(DoseMealCheck.shouldAsk(dose(minutesAgo: 45, purpose: purpose), meals: [], contexts: [], now: now),
                           "\(purpose)")
        }
    }

    func testLeavesOutBasalSmallAndCalculatorDoses() throws {
        XCTAssertFalse(DoseMealCheck.isUnexplained(dose(minutesAgo: 45, kind: .long), meals: [], contexts: []))
        XCTAssertFalse(DoseMealCheck.isUnexplained(dose(minutesAgo: 45, kind: .premixed), meals: [], contexts: []))
        XCTAssertFalse(DoseMealCheck.isUnexplained(dose(minutesAgo: 45, units: 0.3), meals: [], contexts: []))
        let json = #"{"carbs":0,"carbRatio":10,"correctionFactor":50,"targetMgdl":100,"foodUnits":0,"correctionUnits":2,"insulinOnBoard":0,"suggestedUnits":2}"#
        var d = dose(minutesAgo: 45)
        d.calculation = try JSONDecoder().decode(BolusCalculation.self, from: Data(json.utf8))
        XCTAssertFalse(DoseMealCheck.isUnexplained(d, meals: [], contexts: []))
    }

    func testWaitsHalfAnHourAndStopsAfterTwelve() {
        XCTAssertFalse(DoseMealCheck.shouldAsk(dose(minutesAgo: 10), meals: [], contexts: [], now: now))
        XCTAssertTrue(DoseMealCheck.shouldAsk(dose(minutesAgo: 30), meals: [], contexts: [], now: now))
        XCTAssertTrue(DoseMealCheck.shouldAsk(dose(minutesAgo: 11 * 60), meals: [], contexts: [], now: now))
        XCTAssertFalse(DoseMealCheck.shouldAsk(dose(minutesAgo: 13 * 60), meals: [], contexts: [], now: now))

        // The notification goes half an hour after the dose, or straight away if that's passed.
        let fresh = dose(minutesAgo: 5)
        XCTAssertEqual(DoseMealCheck.askTime(for: fresh, meals: [], contexts: [], now: now),
                       fresh.timestamp.addingTimeInterval(30 * 60))
        XCTAssertEqual(DoseMealCheck.askTime(for: dose(minutesAgo: 90), meals: [], contexts: [], now: now), now)
        XCTAssertNil(DoseMealCheck.askTime(for: dose(minutesAgo: 13 * 60), meals: [], contexts: [], now: now))
        XCTAssertNil(DoseMealCheck.askTime(for: fresh, meals: [meal(minutesAgo: 0)], contexts: [], now: now))
    }

    func testNewestFirst() {
        let a = dose(minutesAgo: 300), b = dose(minutesAgo: 60)
        XCTAssertEqual(DoseMealCheck.pending(doses: [a, b], meals: [], contexts: [], now: now).map(\.id), [b.id, a.id])
    }

    // MARK: Storing the answer

    func testPurposeRoundTripsAndOldDosesStillDecode() throws {
        let d = dose(minutesAgo: 45, purpose: .correction)
        let back = try JSONDecoder().decode(InsulinDose.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back.purpose, .correction)

        // A dose saved before the question existed.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dose(minutesAgo: 45))) as! [String: Any]
        old.removeValue(forKey: "purpose")
        XCTAssertNil(try JSONDecoder().decode(InsulinDose.self, from: JSONSerialization.data(withJSONObject: old)).purpose)

        // An answer from a newer version doesn't lose the dose.
        old["purpose"] = "somethingNew"
        XCTAssertEqual(try JSONDecoder().decode(InsulinDose.self, from: JSONSerialization.data(withJSONObject: old)).purpose,
                       .unsure)
    }

    // MARK: What the answer changes

    func testMealAnswerWithNoFoodIsUncountedFood() {
        let marked = dose(minutesAgo: 60, purpose: .meal)
        XCTAssertEqual(DoseMealCheck.unloggedMealTimes(doses: [marked], meals: []), [marked.timestamp])
        // Food logged with it afterwards (even an hour on, for a long pre-bolus) is that meal.
        XCTAssertEqual(DoseMealCheck.unloggedMealTimes(doses: [marked], meals: [meal(minutesAgo: 5)]), [])
        // A meal-marked dose edited into basal insulin isn't food either.
        XCTAssertEqual(DoseMealCheck.unloggedMealTimes(doses: [dose(minutesAgo: 60, kind: .long, purpose: .meal)], meals: []), [])
        // Corrections and unanswered doses aren't food.
        XCTAssertEqual(DoseMealCheck.unloggedMealTimes(doses: [dose(minutesAgo: 60, purpose: .correction),
                                                               dose(minutesAgo: 60)], meals: []), [])
    }

    let learned = EffectProfile(insulin: LearnedEffect(value: 50, standardError: 3, examples: 20),
                                carbs: LearnedEffect(value: 4, standardError: 0.3, examples: 20),
                                driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: referenceNow)

    func forecast(_ doses: [InsulinDose]) -> GlucoseForecast? {
        let r = readings(endingAt: now, minutes: 30) { _ in 160 }
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: doses, meals: [], contexts: [], profile: learned, now: now)
        if case .success(let f) = GlucoseForecaster.forecast(input) { return f }
        return nil
    }

    func testForecastStopsExpectingTheFullDropForAMealDose() throws {
        // Unanswered or a correction: the insulin's drop is modelled, as before.
        for purpose in [nil, DosePurpose.correction] {
            let f = try XCTUnwrap(forecast([dose(minutesAgo: 90, units: 6, purpose: purpose)]))
            XCTAssertFalse(f.limitations.contains(.uncountedFood), "\(String(describing: purpose))")
        }
        // For a meal that isn't logged: food it can't count, so it follows the trend.
        let f = try XCTUnwrap(forecast([dose(minutesAgo: 90, units: 6, purpose: .meal)]))
        XCTAssertTrue(f.limitations.contains(.uncountedFood))
        XCTAssertEqual(f.basis, .trend)
    }

    func testForecastUsesTheUnloggedMealTimesItIsGiven() throws {
        // OutlookEngine works these out from every meal entry before repeats are removed, so a
        // meal logged twice (one copy close to the dose) still explains a dose marked as for a meal.
        let marked = dose(minutesAgo: 90, units: 6, purpose: .meal)
        let r = readings(endingAt: now, minutes: 30) { _ in 160 }
        var input = ForecastInputs(readings: GlucoseSeries(r), doses: [marked], meals: [], contexts: [],
                                   profile: learned, now: now)
        input.unloggedMealTimes = []
        guard case .success(let f) = GlucoseForecaster.forecast(input) else { return XCTFail("no forecast") }
        XCTAssertFalse(f.limitations.contains(.uncountedFood))
    }

    func testOnBoardFlagsAMealDoseAsUncountedFood() {
        let marked = dose(minutesAgo: 60, purpose: .meal)
        XCTAssertTrue(OnBoardNow(doses: [marked], meals: [], contexts: [], at: now).carbs.uncountedFood)
        XCTAssertFalse(OnBoardNow(doses: [dose(minutesAgo: 60, purpose: .correction)], meals: [], contexts: [], at: now)
            .carbs.uncountedFood)
    }

    func testLearnerLeavesOutTheMealDosesIntervals() {
        let r = readings(endingAt: now, minutes: 8 * 60) { _ in 150 }
        func rows(_ d: InsulinDose) -> [EffectProfileLearner.Row] {
            EffectProfileLearner.rows(series: GlucoseSeries(r), doses: [d], meals: [], contexts: [], low: 70,
                                      from: now.addingTimeInterval(-8 * 3600), to: now, calendar: utc)
        }
        let correction = dose(minutesAgo: 6 * 60, purpose: .correction)
        XCTAssertTrue(rows(correction).contains { $0.doseIDs.contains(correction.id) })

        let mealDose = dose(minutesAgo: 6 * 60, purpose: .meal)
        let reach = CarbAbsorptionCurve.standard.totalDuration
        let marked = rows(mealDose)
        XCTAssertLessThan(marked.count, rows(correction).count)
        XCTAssertFalse(marked.contains { $0.start >= mealDose.timestamp
            && $0.start.addingTimeInterval(EffectProfileLearner.interval) <= mealDose.timestamp.addingTimeInterval(reach) })
    }
}
