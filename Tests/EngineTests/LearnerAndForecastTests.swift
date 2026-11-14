import XCTest
@testable import GlucOSEngine

final class EngineMathTests: XCTestCase {
    func testSolve() {
        let x = EngineMath.solve([[2, 1], [1, 3]], [3, 5])!
        XCTAssertEqual(x[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(x[1], 1.4, accuracy: 1e-9)
        XCTAssertNil(EngineMath.solve([[1, 2], [2, 4]], [1, 2]))
    }

    func testInverse() {
        let inv = EngineMath.inverse([[4, 7], [2, 6]])!
        XCTAssertEqual(inv[0][0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(inv[0][1], -0.7, accuracy: 1e-9)
        XCTAssertEqual(inv[1][0], -0.2, accuracy: 1e-9)
        XCTAssertEqual(inv[1][1], 0.4, accuracy: 1e-9)
    }

    func testQuantileAndSlope() {
        XCTAssertEqual(EngineMath.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(EngineMath.quantile([5], 0.9), 5)
        XCTAssertEqual(EngineMath.slope(x: [0, 1, 2], y: [1, 3, 5])!, 2, accuracy: 1e-12)
        XCTAssertNil(EngineMath.slope(x: [1, 1], y: [1, 2]))
    }
}

final class GlucoseSeriesTests: XCTestCase {
    func testInterpolatesOnlyAcrossShortGaps() {
        let t = referenceNow
        let s = GlucoseSeries([reading(t, 100), reading(t.addingTimeInterval(600), 120),
                               reading(t.addingTimeInterval(3600 * 2), 200)])
        XCTAssertEqual(s.value(at: t.addingTimeInterval(300))!, 110, accuracy: 1e-9)
        XCTAssertEqual(s.value(at: t.addingTimeInterval(600)), 120)
        // An hour into the gap: nothing.
        XCTAssertNil(s.value(at: t.addingTimeInterval(3600)))
        // Close to a reading at the edge of the gap: that reading.
        XCTAssertEqual(s.value(at: t.addingTimeInterval(600 + 120)), 120)
        XCTAssertNil(s.value(at: t.addingTimeInterval(-3600)))
    }

    func testUpTo() {
        let t = referenceNow
        let s = GlucoseSeries([reading(t, 100), reading(t.addingTimeInterval(300), 110), reading(t.addingTimeInterval(600), 120)])
        XCTAssertEqual(s.upTo(t.addingTimeInterval(300)).readings.count, 2)
        XCTAssertEqual(s.upTo(t.addingTimeInterval(-1)).readings.count, 0)
    }
}

final class EffectProfileLearnerTests: XCTestCase {
    func testRecoversKnownEffects() throws {
        let person = SimulatedPerson()
        let sim = person.run()
        let p = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                           low: 70, now: referenceNow, calendar: utc)
        let insulin = try XCTUnwrap(p.reliableInsulin)
        let carbs = try XCTUnwrap(p.reliableCarbs)
        XCTAssertEqual(insulin.value, person.insulinEffect, accuracy: person.insulinEffect * 0.2)
        XCTAssertEqual(carbs.value, person.carbEffect, accuracy: person.carbEffect * 0.2)
        XCTAssertGreaterThan(p.intervals, 500)
        XCTAssertEqual(p.days, 30)
    }

    func testDifferentPersonDifferentAnswer() {
        let person = SimulatedPerson(insulinEffect: 100, carbEffect: 6, seed: 7)
        let sim = person.run()
        let p = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                           low: 70, now: referenceNow, calendar: utc)
        XCTAssertEqual(try XCTUnwrap(p.reliableInsulin).value, 100, accuracy: 20)
        XCTAssertEqual(try XCTUnwrap(p.reliableCarbs).value, 6, accuracy: 1.2)
    }

    func testNoLogsLearnsNothing() {
        let sim = SimulatedPerson(days: 10).run()
        let p = EffectProfileLearner.learn(readings: sim.readings, doses: [], meals: [], contexts: [],
                                           low: 70, now: referenceNow, calendar: utc)
        XCTAssertNil(p.insulin)
        XCTAssertNil(p.carbs)
        XCTAssertNil(p.reliableInsulin)
    }

    func testTooFewDosesIsNotReliable() {
        let sim = SimulatedPerson(days: 2).run()
        let p = EffectProfileLearner.learn(readings: sim.readings, doses: Array(sim.doses.prefix(3)), meals: Array(sim.meals.prefix(3)),
                                           contexts: [], low: 70, now: referenceNow, calendar: utc)
        XCTAssertNil(p.reliableInsulin)
        XCTAssertNil(p.reliableCarbs)
    }

    func testTaggedAndLowIntervalsAreLeftOut() {
        let t0 = referenceNow.addingTimeInterval(-6 * 3600)
        let flat = readings(endingAt: referenceNow, minutes: 6 * 60) { _ in 120 }
        let all = EffectProfileLearner.rows(series: GlucoseSeries(flat), doses: [], meals: [], contexts: [], low: 70,
                                            from: t0, to: referenceNow, calendar: utc)
        XCTAssertEqual(all.count, 12)
        let exercise = ContextEvent(timestamp: referenceNow.addingTimeInterval(-2 * 3600), tags: [.exercise])
        let tagged = EffectProfileLearner.rows(series: GlucoseSeries(flat), doses: [], meals: [], contexts: [exercise], low: 70,
                                               from: t0, to: referenceNow, calendar: utc)
        XCTAssertLessThan(tagged.count, all.count)
        let withLow = flat.map { r in r.timestamp == referenceNow.addingTimeInterval(-3 * 3600) ? reading(r.timestamp, 60) : r }
        let lowRows = EffectProfileLearner.rows(series: GlucoseSeries(withLow), doses: [], meals: [], contexts: [], low: 70,
                                                from: t0, to: referenceNow, calendar: utc)
        XCTAssertLessThan(lowRows.count, all.count)
        let toast = MealEntry(timestamp: referenceNow.addingTimeInterval(-2 * 3600), carbs: 0, food: "Toast")
        let untimed = EffectProfileLearner.rows(series: GlucoseSeries(flat), doses: [], meals: [toast], contexts: [], low: 70,
                                                from: t0, to: referenceNow, calendar: utc)
        XCTAssertLessThan(untimed.count, all.count)
    }

    func testReliabilityRules() {
        XCTAssertTrue(EffectProfileLearner.isReliable(LearnedEffect(value: 50, standardError: 5, examples: 10), kind: .insulin))
        XCTAssertFalse(EffectProfileLearner.isReliable(LearnedEffect(value: 50, standardError: 30, examples: 10), kind: .insulin))
        XCTAssertFalse(EffectProfileLearner.isReliable(LearnedEffect(value: 50, standardError: 5, examples: 2), kind: .insulin))
        XCTAssertFalse(EffectProfileLearner.isReliable(LearnedEffect(value: 2, standardError: 0.1, examples: 10), kind: .insulin))
        XCTAssertFalse(EffectProfileLearner.isReliable(LearnedEffect(value: -10, standardError: 1, examples: 10), kind: .insulin))
        XCTAssertFalse(EffectProfileLearner.isReliable(LearnedEffect(value: 40, standardError: 1, examples: 10), kind: .carbs))
    }
}

final class GlucoseForecasterTests: XCTestCase {
    let now = referenceNow
    let learned = EffectProfile(insulin: LearnedEffect(value: 50, standardError: 3, examples: 20),
                                carbs: LearnedEffect(value: 4, standardError: 0.3, examples: 20),
                                driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: referenceNow)

    func input(_ r: [GlucoseReading], doses: [InsulinDose] = [], meals: [MealEntry] = [], contexts: [ContextEvent] = [],
               profile: EffectProfile = .empty, calibration: ForecastCalibration? = nil, at: Date? = nil) -> ForecastInputs {
        ForecastInputs(readings: GlucoseSeries(r), doses: doses, meals: meals, contexts: contexts, profile: profile,
                       calibration: calibration, now: at ?? now)
    }

    func success(_ r: Result<GlucoseForecast, ForecastFailure>, file: StaticString = #filePath, line: UInt = #line) throws -> GlucoseForecast {
        switch r {
        case .success(let f): return f
        case .failure(let e): XCTFail("No forecast: \(e.reason)", file: file, line: line); throw e
        }
    }

    func testSteadyStaysSteady() throws {
        let f = try success(GlucoseForecaster.forecast(input(readings(endingAt: now, minutes: 30) { _ in 110 })))
        XCTAssertEqual(f.basis, .trend)
        XCTAssertEqual(f.horizon, 30 * 60)
        XCTAssertEqual(f.samples.count, 7)
        for s in f.samples { XCTAssertEqual(s.mgdl, 110, accuracy: 0.01) }
        XCTAssertTrue(f.limitations.contains(.uncalibrated))
        // The range widens with distance.
        XCTAssertLessThan(f.samples[1].upperMgdl - f.samples[1].lowerMgdl, f.samples[6].upperMgdl - f.samples[6].lowerMgdl)
    }

    func testTrendFadesOverHalfAnHour() throws {
        // Rising 1 mg/dL per minute.
        let f = try success(GlucoseForecaster.forecast(input(readings(endingAt: now, minutes: 20) { m in 120 - m })))
        XCTAssertEqual(f.trendPerMinute, 1, accuracy: 1e-6)
        // ∫₀³⁰ (1 − τ/30) dτ = 15.
        XCTAssertEqual(f.samples.last!.mgdl, 135, accuracy: 0.01)
        XCTAssertEqual(f.firstAbove(130).map { $0.timeIntervalSince(now) } ?? 0, 15 * 60, accuracy: 5 * 60)
    }

    func testNoForecastFromStaleOrSparseData() {
        let old = readings(endingAt: now.addingTimeInterval(-20 * 60), minutes: 30) { _ in 110 }
        guard case .failure(let e) = GlucoseForecaster.forecast(input(old)), case .stale = e.reason else {
            return XCTFail("expected stale")
        }
        let single = [reading(now, 110)]
        guard case .failure(let e2) = GlucoseForecaster.forecast(input(single)), e2.reason == .notEnoughRecentReadings else {
            return XCTFail("expected not enough readings")
        }
        let outOfRange = readings(endingAt: now, minutes: 20) { _ in 39 }
        guard case .failure(let e3) = GlucoseForecaster.forecast(input(outOfRange)), e3.reason == .outOfSensorRange else {
            return XCTFail("expected out of range")
        }
        guard case .failure(let e4) = GlucoseForecaster.forecast(input([])), e4.reason == .noReading else {
            return XCTFail("expected no reading")
        }
    }

    func testActiveInsulinWithLearntEffectPullsTheForecastDown() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 180 }
        // Over an hour ago, so the forecast isn't "fresh" (see testFreshLogsFollowTheTrendUntilEarned).
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-70 * 60), units: 3, kind: .rapid)
        let f = try success(GlucoseForecaster.forecast(input(r, doses: [dose], profile: learned)))
        XCTAssertEqual(f.basis, .trendInsulinCarbs)
        XCTAssertEqual(f.horizon, GlucoseForecaster.uncalibratedModelHorizon)
        XCTAssertLessThan(f.samples.last!.mgdl, 165)
        // Monotonic fall: a flat trend handing over to insulin only.
        for (a, b) in zip(f.samples, f.samples.dropFirst()) { XCTAssertLessThanOrEqual(b.mgdl, a.mgdl + 1e-9) }
        // With a long horizon the full remaining effect plays out: 3 u × remaining share × 50.
        let full = try success(GlucoseForecaster.forecast(input(r, doses: [dose], profile: learned), maxHorizon: 6 * 3600))
        let expectedDrop = 3 * InsulinActionCurve.rapid.fractionRemaining(after: 70 * 60) * 50
        XCTAssertEqual(180 - full.samples.last!.mgdl, expectedDrop, accuracy: expectedDrop * 0.12)
    }

    func testCarbsPushTheForecastUp() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 120 }
        let meal = MealEntry(timestamp: now.addingTimeInterval(-70 * 60), carbs: 40)
        let f = try success(GlucoseForecaster.forecast(input(r, meals: [meal], profile: learned)))
        XCTAssertEqual(f.basis, .trendInsulinCarbs)
        XCTAssertGreaterThan(f.samples.last!.mgdl, 135)
    }

    func testFreshLogsFollowTheTrendUntilEarned() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 120 }
        let meal = MealEntry(timestamp: now.addingTimeInterval(-20 * 60), carbs: 40)
        // No checks yet of forecasts made this soon after a log: trend only.
        let early = try success(GlucoseForecaster.forecast(input(r, meals: [meal], profile: learned)))
        XCTAssertEqual(early.basis, .trend)
        XCTAssertTrue(early.limitations.contains(.freshLog))
        XCTAssertEqual(early.horizon, GlucoseForecaster.trendHorizon)

        // Once those forecasts have beaten "no change", the meal is modelled, with their own range.
        func stats(_ m: Int, mae: Double, naive: Double) -> HorizonStats {
            HorizonStats(minutes: m, samples: 40, meanAbsoluteError: mae, naiveError: naive, bias: 0,
                         lower: -2 * Double(m), upper: 2 * Double(m))
        }
        var cal = ForecastCalibration(byBasis: [:], origins: 100, computedAt: now)
        cal.freshModel = [stats(15, mae: 8, naive: 12), stats(30, mae: 12, naive: 20), stats(45, mae: 30, naive: 25)]
        XCTAssertEqual(cal.freshModelAllowedHorizon, 30 * 60)
        let earned = try success(GlucoseForecaster.forecast(input(r, meals: [meal], profile: learned, calibration: cal)))
        XCTAssertEqual(earned.basis, .trendInsulinCarbs)
        XCTAssertTrue(earned.fresh)
        XCTAssertFalse(earned.limitations.contains(.freshLog))
        XCTAssertEqual(earned.horizon, 30 * 60)
        let at30 = earned.samples.last!
        XCTAssertEqual(at30.upperMgdl - at30.mgdl, 60, accuracy: 0.01)

        // An hour on, it's an ordinary forecast again.
        let old = MealEntry(timestamp: now.addingTimeInterval(-61 * 60), carbs: 40)
        let settled = try success(GlucoseForecaster.forecast(input(r, meals: [old], profile: learned)))
        XCTAssertEqual(settled.basis, .trendInsulinCarbs)
        XCTAssertFalse(settled.fresh)
    }

    func testTrendGainPullsTheForecastTowardsNoChange() throws {
        let r = readings(endingAt: now, minutes: 20) { m in 120 - m }   // rising 1 mg/dL per minute
        var half = input(r)
        half.tuning.trendGain = 0.5
        let full = try success(GlucoseForecaster.forecast(input(r)))
        let damped = try success(GlucoseForecaster.forecast(half))
        XCTAssertEqual(full.samples.last!.mgdl - 120, 15, accuracy: 0.01)
        XCTAssertEqual(damped.samples.last!.mgdl - 120, 7.5, accuracy: 0.01)
        // The trend itself is reported as measured.
        XCTAssertEqual(damped.trendPerMinute, 1, accuracy: 1e-6)
    }

    func testUnlearntInsulinFallsBackToTrend() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 180 }
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-30 * 60), units: 3, kind: .rapid)
        let f = try success(GlucoseForecaster.forecast(input(r, doses: [dose])))
        XCTAssertEqual(f.basis, .trend)
        XCTAssertTrue(f.limitations.contains(.insulinNotLearned))
        XCTAssertEqual(f.horizon, 30 * 60)
    }

    func testUnlearntCarbsFallBackToTrendEvenWithInsulinLearnt() throws {
        var profile = learned
        profile.carbs = nil
        let r = readings(endingAt: now, minutes: 30) { _ in 150 }
        let meal = MealEntry(timestamp: now.addingTimeInterval(-10 * 60), carbs: 50)
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-10 * 60), units: 5, kind: .rapid)
        let f = try success(GlucoseForecaster.forecast(input(r, doses: [dose], meals: [meal], profile: profile)))
        // Insulin without its carbs would forecast a false low.
        XCTAssertEqual(f.basis, .trend)
        XCTAssertTrue(f.limitations.contains(.carbsNotLearned))
    }

    func testUncountedFoodAndSiteProblemsFallBackToTrend() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 150 }
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-30 * 60), units: 3, kind: .rapid)
        let toast = MealEntry(timestamp: now.addingTimeInterval(-20 * 60), carbs: 0, food: "Toast")
        let a = try success(GlucoseForecaster.forecast(input(r, doses: [dose], meals: [toast], profile: learned)))
        XCTAssertEqual(a.basis, .trend)
        XCTAssertTrue(a.limitations.contains(.uncountedFood))

        let hypo = ContextEvent(timestamp: now.addingTimeInterval(-10 * 60), tags: [.hypoTreatment])
        let b = try success(GlucoseForecaster.forecast(input(r, doses: [dose], contexts: [hypo], profile: learned)))
        XCTAssertEqual(b.basis, .trend)

        let site = ContextEvent(timestamp: now.addingTimeInterval(-60 * 60), tags: [.siteProblem])
        let c = try success(GlucoseForecaster.forecast(input(r, doses: [dose], contexts: [site], profile: learned)))
        XCTAssertEqual(c.basis, .trend)
        XCTAssertTrue(c.limitations.contains(.deliveryProblem))
    }

    func testContextWidensTheRange() throws {
        let r = readings(endingAt: now, minutes: 30) { _ in 120 }
        let plain = try success(GlucoseForecaster.forecast(input(r)))
        let run = ContextEvent(timestamp: now.addingTimeInterval(-3600), tags: [.exercise])
        let tagged = try success(GlucoseForecaster.forecast(input(r, contexts: [run])))
        XCTAssertTrue(tagged.limitations.contains(.context(.exercise)))
        let w0 = plain.samples.last!.upperMgdl - plain.samples.last!.lowerMgdl
        let w1 = tagged.samples.last!.upperMgdl - tagged.samples.last!.lowerMgdl
        XCTAssertEqual(w1, w0 * 1.5, accuracy: 0.01)
    }

    func testForecastStaysInsideSensorRange() throws {
        let r = readings(endingAt: now, minutes: 20) { m in 60 + m * 4 }   // falling 4/min towards 60
        let f = try success(GlucoseForecaster.forecast(input(r)))
        for s in f.samples {
            XCTAssertGreaterThanOrEqual(s.mgdl, 39)
            XCTAssertGreaterThanOrEqual(s.lowerMgdl, 39)
            XCTAssertLessThanOrEqual(s.upperMgdl, 401)
        }
        XCTAssertNotNil(f.firstBelow(54))
    }

    func testCalibrationLimitsHorizonAndSetsRange() throws {
        func stats(_ m: Int, mae: Double, naive: Double) -> HorizonStats {
            HorizonStats(minutes: m, samples: 100, meanAbsoluteError: mae, naiveError: naive, bias: 0,
                         lower: -Double(m), upper: Double(m))
        }
        let cal = ForecastCalibration(byBasis: [.trendInsulinCarbs: [stats(15, mae: 5, naive: 10), stats(30, mae: 10, naive: 15),
                                                                     stats(45, mae: 14, naive: 18), stats(60, mae: 25, naive: 20)]],
                                      origins: 100, computedAt: now)
        XCTAssertEqual(cal.allowedHorizon(for: .trendInsulinCarbs), 45 * 60)
        XCTAssertNil(cal.allowedHorizon(for: .trend))
        let r = readings(endingAt: now, minutes: 30) { _ in 180 }
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-70 * 60), units: 3, kind: .rapid)
        let f = try success(GlucoseForecaster.forecast(input(r, doses: [dose], profile: learned, calibration: cal)))
        XCTAssertEqual(f.horizon, 45 * 60)
        XCTAssertTrue(f.calibrated)
        XCTAssertFalse(f.limitations.contains(.uncalibrated))

        let useless = ForecastCalibration(byBasis: [.trend: [stats(15, mae: 12, naive: 10)]], origins: 100, computedAt: now)
        XCTAssertEqual(useless.allowedHorizon(for: .trend), 0)
        guard case .failure(let e) = GlucoseForecaster.forecast(input(readings(endingAt: now, minutes: 30) { _ in 110 },
                                                                      calibration: useless)),
              e.reason == .notAccurateEnough else { return XCTFail("expected not accurate enough") }
    }

    func testCalibratedBandIsNeverFalselyNarrow() {
        let tight = [HorizonStats(minutes: 30, samples: 100, meanAbsoluteError: 1, naiveError: 10, bias: 0, lower: -1, upper: 1)]
        let band = ForecastCalibration.interpolate(tight, minutes: 30)!
        let floor = ForecastCalibration.defaultBand(minutes: 30)
        XCTAssertLessThanOrEqual(band.lower, floor.lower * 0.6)
        XCTAssertGreaterThanOrEqual(band.upper, floor.upper * 0.6)
    }
}

final class BacktestTests: XCTestCase {
    func testModelBeatsNoChangeOnASimulatedPerson() throws {
        let person = SimulatedPerson(days: 21)
        let sim = person.run()
        let profile = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                                 low: 70, now: referenceNow, calendar: utc)
        // Checked honestly: each stretch is replayed with a profile that never saw it.
        let heldOut = EffectProfileLearner.heldOut(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                                   profile: profile, low: 70, backtestDays: 21, now: referenceNow, calendar: utc)
        let cal = ForecastBacktest.run(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                       profile: profile, days: 21, now: referenceNow, profileAt: heldOut)
        XCTAssertGreaterThan(cal.origins, 300)
        let model = try XCTUnwrap(cal.stats(for: .trendInsulinCarbs))
        let at60 = try XCTUnwrap(model.first { $0.minutes == 60 })
        XCTAssertGreaterThanOrEqual(at60.samples, ForecastCalibration.minimumSamples)
        XCTAssertTrue(at60.beatsNaive, "MAE \(at60.meanAbsoluteError) vs no-change \(at60.naiveError)")
        XCTAssertGreaterThanOrEqual(cal.allowedHorizon(for: .trendInsulinCarbs) ?? 0, 60 * 60)
        // The 80% range really holds about 80% (between 10th and 90th percentiles by construction).
        XCTAssertLessThan(at60.lower, 0)
        XCTAssertGreaterThan(at60.upper, 0)
    }

    func testHeldOutProfilesLeaveOutTheirOwnStretch() throws {
        let sim = SimulatedPerson(days: 21).run()
        let profile = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                                 low: 70, now: referenceNow, calendar: utc)
        let heldOut = EffectProfileLearner.heldOut(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                                   profile: profile, low: 70, backtestDays: 21, now: referenceNow, calendar: utc)
        let early = heldOut(referenceNow.addingTimeInterval(-20 * 86_400))
        let late = heldOut(referenceNow.addingTimeInterval(-86_400))
        // Fitted on fewer intervals than the full profile, and on different ones.
        XCTAssertLessThan(early.intervals, profile.intervals)
        XCTAssertLessThan(late.intervals, profile.intervals)
        XCTAssertNotEqual(early.insulin?.value, late.insulin?.value)
        // Still close to the real effect: leaving a few days out shouldn't lose it.
        let s = try XCTUnwrap(early.reliableInsulin?.value)
        XCTAssertEqual(s, profile.insulin?.value ?? 0, accuracy: 15)
    }

    func testNothingToReplay() {
        let cal = ForecastBacktest.run(readings: [], doses: [], meals: [], contexts: [], profile: .empty, now: referenceNow)
        XCTAssertEqual(cal.origins, 0)
        XCTAssertNil(cal.allowedHorizon(for: .trend))
    }
}
