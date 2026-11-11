import XCTest
@testable import GlucOSEngine

/// Someone whose glucose rises after waking by a known amount, with sensor noise.
private struct SimulatedMornings {
    var days = 30
    /// Total rise over `riseMinutes` after waking, mg/dL.
    var rise = 40.0
    var riseMinutes = 60.0
    var noise = 1.5
    var seed: UInt64 = 7

    struct Output {
        var readings: [GlucoseReading]
        var wakes: [ContextEvent]
    }

    func run(endingAt end: Date = referenceNow) -> Output {
        var rng = SeededRandom(seed: seed)
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        // Wake between 6:00 and 7:00 each day (UTC, the reference calendar).
        var wakeTimes: [Date] = []
        var day = utc.startOfDay(for: start)
        while day < end {
            let w = day.addingTimeInterval(6 * 3600 + rng.uniform(0...3600))
            if w > start && w < end.addingTimeInterval(-4 * 3600) { wakeTimes.append(w) }
            day = day.addingTimeInterval(86_400)
        }
        var out: [GlucoseReading] = []
        var t = start
        var g = 110.0
        while t <= end {
            // Underlying level: 110, plus the wake rise, easing back down 2–4 h after waking.
            var target = 110.0
            if let w = wakeTimes.last(where: { $0 <= t }) {
                let m = t.timeIntervalSince(w) / 60
                if m < riseMinutes { target += rise * m / riseMinutes }
                else if m < 120 { target += rise }
                else if m < 240 { target += rise * (1 - (m - 120) / 120) }
            }
            g += (target - g) * 0.8 + rng.normal() * noise
            out.append(reading(t, g))
            t = t.addingTimeInterval(5 * 60)
        }
        return Output(readings: out, wakes: wakeTimes.map { WakeLog.entry(at: $0) })
    }
}

final class MorningPatternTests: XCTestCase {
    func testLearnsTheRiseAfterWakingAndUsesIt() throws {
        let sim = SimulatedMornings().run()
        let p = MorningPatternLearner.learn(readings: sim.readings, doses: [], meals: [], contexts: sim.wakes,
                                            profile: .empty, low: 70, now: referenceNow)
        XCTAssertGreaterThanOrEqual(p.mornings, 25)
        let peak = try XCTUnwrap(p.peak)
        XCTAssertEqual(peak.mgdl, 40, accuracy: 8)
        XCTAssertEqual(Double(peak.minutes), 60, accuracy: 30)
        let v = try XCTUnwrap(p.validation)
        XCTAssertGreaterThan(v.improvement, 0.2)
        XCTAssertTrue(p.isUsable)
        XCTAssertNotNil(p.confidence)
        XCTAssertTrue(p.summary(unit: .mgdl).contains("rises about"))
    }

    func testLevelMorningsAreNotUsed() {
        let sim = SimulatedMornings(rise: 0).run()
        let p = MorningPatternLearner.learn(readings: sim.readings, doses: [], meals: [], contexts: sim.wakes,
                                            profile: .empty, low: 70, now: referenceNow)
        XCTAssertFalse(p.isUsable)
        XCTAssertNil(p.confidence)
        XCTAssertTrue(p.summary(unit: .mgdl).contains("fairly level"))
    }

    func testNeedsFiveMornings() {
        let sim = SimulatedMornings(days: 4).run()
        let p = MorningPatternLearner.learn(readings: sim.readings, doses: [], meals: [], contexts: sim.wakes,
                                            profile: .empty, low: 70, now: referenceNow)
        XCTAssertLessThan(p.mornings, 5)
        XCTAssertGreaterThan(p.morningsNeeded, 0)
        XCTAssertNil(p.validation)
        XCTAssertFalse(p.isUsable)
    }

    func testCarbsWithoutALearntEffectAreLeftOut() {
        // A meal at waking with no learnt carb effect: every step while it absorbs is skipped,
        // leaving only the first 15 minutes (before absorption gets going).
        let sim = SimulatedMornings(days: 10).run()
        let meals = sim.wakes.map { MealEntry(timestamp: $0.timestamp, carbs: 40) }
        let p = MorningPatternLearner.learn(readings: sim.readings, doses: [], meals: meals, contexts: sim.wakes,
                                            profile: .empty, low: 70, now: referenceNow)
        XCTAssertLessThanOrEqual(p.stepChange.count, 1)
        XCTAssertEqual(p.duration, Double(p.stepChange.count) * MorningPattern.step)
    }

    func testIllnessSpoilsAMorning() {
        let sim = SimulatedMornings(days: 10).run()
        let ill = sim.wakes.map { ContextEvent(timestamp: $0.timestamp.addingTimeInterval(-3600), tags: [.illness]) }
        let p = MorningPatternLearner.learn(readings: sim.readings, doses: [], meals: [], contexts: sim.wakes + ill,
                                            profile: .empty, low: 70, now: referenceNow)
        XCTAssertEqual(p.mornings, 0)
    }

    func testDuplicateWakeUpsCountOnce() {
        let t = referenceNow
        let times = MorningPatternLearner.wakeTimes([WakeLog.entry(at: t), WakeLog.entry(at: t.addingTimeInterval(600)),
                                                     WakeLog.entry(at: t.addingTimeInterval(86_400))])
        XCTAssertEqual(times.count, 2)
    }

    // MARK: Forecast

    private func usablePattern() -> MorningPattern {
        MorningPattern(stepChange: [10, 10, 10, 10], stepExamples: [10, 10, 10, 10], loggedWakes: 12, mornings: 12,
                       validation: MorningValidation(checks: 40, errorWith: 6, errorWithout: 10), learnedAt: referenceNow)
    }

    func testForecastAddsTheUsualRiseAfterWaking() throws {
        let now = referenceNow
        let wake = WakeLog.entry(at: now.addingTimeInterval(-5 * 60))
        let series = GlucoseSeries(readings(endingAt: now, minutes: 30) { _ in 110 })
        let without = try GlucoseForecaster.forecast(
            ForecastInputs(readings: series, doses: [], meals: [], contexts: [wake], profile: .empty, now: now)).get()
        let with = try GlucoseForecaster.forecast(
            ForecastInputs(readings: series, doses: [], meals: [], contexts: [wake], profile: .empty,
                           morning: usablePattern(), now: now)).get()
        XCTAssertNil(without.morning)
        let m = try XCTUnwrap(with.morning)
        XCTAssertEqual(m.wokeAt, wake.timestamp)
        XCTAssertEqual(m.confidence, .moderate)
        let endWith = try XCTUnwrap(with.samples.last).mgdl
        let endWithout = try XCTUnwrap(without.samples.last).mgdl
        XCTAssertGreaterThan(endWith, endWithout + 5)
        XCTAssertEqual(endWith - endWithout, m.addedMgdl, accuracy: 0.01)
    }

    func testNoAdjustmentOnceThePatternHasPassed() throws {
        let now = referenceNow
        let wake = WakeLog.entry(at: now.addingTimeInterval(-2 * 3600))
        let series = GlucoseSeries(readings(endingAt: now, minutes: 30) { _ in 110 })
        let f = try GlucoseForecaster.forecast(
            ForecastInputs(readings: series, doses: [], meals: [], contexts: [wake], profile: .empty,
                           morning: usablePattern(), now: now)).get()
        XCTAssertNil(f.morning)
    }

    func testNoAdjustmentWhenTheForecastCantTrustTheLogbook() throws {
        let now = referenceNow
        let wake = WakeLog.entry(at: now.addingTimeInterval(-10 * 60))
        let toast = MealEntry(timestamp: now.addingTimeInterval(-5 * 60), carbs: 0, food: "Toast")
        let series = GlucoseSeries(readings(endingAt: now, minutes: 30) { _ in 110 })
        let f = try GlucoseForecaster.forecast(
            ForecastInputs(readings: series, doses: [], meals: [toast], contexts: [wake], profile: .empty,
                           morning: usablePattern(), now: now)).get()
        XCTAssertNil(f.morning)
    }

    func testOutlookOnlyUsesAUsablePattern() {
        let now = referenceNow
        let wake = WakeLog.entry(at: now.addingTimeInterval(-5 * 60))
        let rs = readings(endingAt: now, minutes: 30) { _ in 110 }
        var model = OutlookModel.empty
        model.morning = usablePattern()
        model.morning.validation = MorningValidation(checks: 40, errorWith: 10, errorWithout: 10)
        let unused = OutlookEngine.outlook(readings: rs, doses: [], meals: [], contexts: [wake], model: model, now: now)
        XCTAssertNil(unused.snapshot(lowMgdl: 70).morning)
        model.morning = usablePattern()
        let used = OutlookEngine.outlook(readings: rs, doses: [], meals: [], contexts: [wake], model: model, now: now)
        XCTAssertEqual(used.snapshot(lowMgdl: 70).morning?.confidence, .moderate)
    }

    func testWakeUpsDontChangeTheLearntEffects() {
        let sim = SimulatedPerson(days: 14).run()
        let wakes = stride(from: 0, to: 14, by: 1).map {
            WakeLog.entry(at: referenceNow.addingTimeInterval(-Double($0) * 86_400 - 17 * 3600))
        }
        let a = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: [],
                                           low: 70, now: referenceNow, calendar: utc)
        let b = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals, contexts: wakes,
                                           low: 70, now: referenceNow, calendar: utc)
        XCTAssertEqual(a.intervals, b.intervals)
        XCTAssertEqual(a.insulin, b.insulin)
    }

    // MARK: Prompt

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        utc.startOfDay(for: referenceNow).addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3600 + Double(minute) * 60)
    }

    func testPromptsInTheMorningUntilLoggedOrDismissed() {
        XCTAssertTrue(WakeLog.shouldPrompt(contexts: [], now: at(7), dismissedOn: nil, calendar: utc))
        XCTAssertFalse(WakeLog.shouldPrompt(contexts: [], now: at(15), dismissedOn: nil, calendar: utc))
        XCTAssertFalse(WakeLog.shouldPrompt(contexts: [], now: at(3), dismissedOn: nil, calendar: utc))
        XCTAssertFalse(WakeLog.shouldPrompt(contexts: [], now: at(7), dismissedOn: WakeLog.dayKey(at(7), calendar: utc), calendar: utc))
        XCTAssertTrue(WakeLog.shouldPrompt(contexts: [], now: at(7), dismissedOn: WakeLog.dayKey(at(7, day: -1), calendar: utc), calendar: utc))
        XCTAssertFalse(WakeLog.shouldPrompt(contexts: [WakeLog.entry(at: at(6, 30))], now: at(7), dismissedOn: nil, calendar: utc))
        // Yesterday's wake-up doesn't cover today.
        XCTAssertTrue(WakeLog.shouldPrompt(contexts: [WakeLog.entry(at: at(6, 30, day: -1))], now: at(7), dismissedOn: nil, calendar: utc))
    }

    func testSuggestsTheFirstUseOfTheMorning() {
        var first: Date? = nil
        first = WakeLog.noteActive(previous: first, now: at(2), calendar: utc)
        XCTAssertNil(first, "Night-time checks aren't a wake-up")
        first = WakeLog.noteActive(previous: first, now: at(6, 41, ), calendar: utc)
        first = WakeLog.noteActive(previous: first, now: at(8), calendar: utc)
        XCTAssertEqual(first, at(6, 41))
        XCTAssertEqual(WakeLog.suggestedTime(firstActive: first, now: at(9), calendar: utc), at(6, 41))
        XCTAssertNil(WakeLog.suggestedTime(firstActive: first, now: at(9, day: 1), calendar: utc), "Yesterday's")
        // The next day starts over.
        XCTAssertEqual(WakeLog.noteActive(previous: first, now: at(7, day: 1), calendar: utc), at(7, day: 1))
    }

    func testRecentWakeUpIsNotRepeated() {
        let w = WakeLog.entry(at: at(6))
        XCTAssertEqual(WakeLog.recent([w], now: at(7))?.id, w.id)
        XCTAssertNil(WakeLog.recent([w], now: at(10)))
    }

    func testWakeTagRoundTripsAndDoesntAffectResponses() throws {
        let e = WakeLog.entry(at: referenceNow)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(ContextEvent.self, from: data)
        XCTAssertTrue(back.isWake)
        XCTAssertFalse(ContextTag.wokeUp.affectsResponses)
        XCTAssertFalse(ContextTag.wokeUp.isComparable)
        XCTAssertTrue(ContextTag.exercise.affectsResponses)
    }
}
