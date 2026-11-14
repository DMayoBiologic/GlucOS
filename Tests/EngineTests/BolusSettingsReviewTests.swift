import XCTest
@testable import GlucOSEngine

/// The settings review against simulated people whose true ratio and correction factor are known.
final class BolusSettingsReviewTests: XCTestCase {
    let now = referenceNow

    struct Person {
        var ratio: Double          // true g per unit
        var cf: Double             // true mg/dL per unit
        var baseline = 120.0
    }

    struct Day {
        var meals: [MealEntry] = []
        var doses: [InsulinDose] = []
        var contexts: [ContextEvent] = []
    }

    func settings(ratio: Double = 10, cf: Double = 50) -> BolusSettings {
        BolusSettings(blocks: [BolusScheduleBlock(startMinute: 0, carbRatio: ratio, correctionFactor: cf, targetMgdl: 100)],
                      increment: 0.05, maxBolus: 15, confirmedAt: now)
    }

    /// Days of readings every 5 minutes. Each day starts at the person's baseline, and glucose
    /// moves exactly as the engine's timing curves say, plus a little noise.
    func simulate(_ person: Person, days: Int, seed: UInt64 = 7, day make: (Date) -> Day)
        -> (readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent]) {
        var rng = SeededRandom(seed: seed)
        var readings: [GlucoseReading] = [], doses: [InsulinDose] = [], meals: [MealEntry] = [], contexts: [ContextEvent] = []
        let firstDay = utc.startOfDay(for: now).addingTimeInterval(-Double(days) * 86_400)
        for d in 0..<days {
            let start = firstDay.addingTimeInterval(Double(d) * 86_400)
            let day = make(start)
            doses += day.doses; meals += day.meals; contexts += day.contexts
            let timedDoses = day.doses.compactMap(TimedDose.init(fastPartOf:))
            let timedCarbs = day.meals.map { TimedCarbs(date: $0.timestamp, grams: $0.carbs) }
            var t = start
            while t < start.addingTimeInterval(86_400) && t <= now {
                let insulin = timedDoses.reduce(0) { $0 + $1.acting(from: $1.date, to: t) }
                let carbs = timedCarbs.reduce(0) { $0 + $1.absorbed(from: $1.date, to: t) }
                let g = person.baseline - person.cf * insulin + person.cf / person.ratio * carbs + rng.normal() * 2
                readings.append(reading(t, g))
                t = t.addingTimeInterval(300)
            }
        }
        return (readings, doses, meals, contexts)
    }

    func review(_ sim: (readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent]),
                settings s: BolusSettings) -> BolusSettingsReview {
        BolusSettingsReview.review(settings: s, readings: sim.readings, doses: sim.doses, meals: sim.meals,
                                   contexts: sim.contexts, lowMgdl: 70, now: now, calendar: utc)
    }

    /// Breakfast at 8:00, dosed with the user's ratio.
    func breakfast(_ start: Date, carbs: Double = 60, ratio: Double = 10) -> Day {
        let t = start.addingTimeInterval(8 * 3600)
        return Day(meals: [MealEntry(timestamp: t, carbs: carbs)],
                   doses: [InsulinDose(timestamp: t, units: carbs / ratio, kind: .rapid)])
    }

    func testRatioTooWeakIsNoticedAndOfferedAsAStepOfAtMost20Percent() throws {
        // Really 1 unit per 8 g, set to 1 per 10 g: meals end high.
        let sim = simulate(Person(ratio: 8, cf: 50), days: 30) { breakfast($0) }
        let r = review(sim, settings: settings())
        let s = try XCTUnwrap(r.suggestions.first { $0.setting == .carbRatio })
        XCTAssertEqual(s.observed, 8, accuracy: 0.4, "the examples point at the true ratio")
        XCTAssertEqual(s.suggested, 8, "10 × 0.8: the largest single step")
        XCTAssertEqual(s.confidence, .high)
        XCTAssertGreaterThan(s.averageChange, 50, "glucose ended well above where it started")
        XCTAssertGreaterThanOrEqual(s.examples.count, 25)
        XCTAssertFalse(s.explanation(unit: .mmol).isEmpty)
        XCTAssertTrue(s.confidenceText.hasPrefix("High"))
        XCTAssertNil(r.suggestions.first { $0.setting == .correctionFactor }, "no clean corrections")
    }

    func testAMealLoggedTwiceStillCountsAsAnExample() throws {
        // Every breakfast logged again 12 minutes later on another device: same food, same carbs.
        var sim = simulate(Person(ratio: 8, cf: 50), days: 30) { breakfast($0) }
        sim.meals += sim.meals.map { MealEntry(timestamp: $0.timestamp.addingTimeInterval(12 * 60), carbs: $0.carbs) }
        let s = try XCTUnwrap(review(sim, settings: settings()).suggestions.first { $0.setting == .carbRatio })
        XCTAssertGreaterThanOrEqual(s.examples.count, 25, "a repeat isn't other food")
        XCTAssertEqual(s.observed, 8, accuracy: 0.4)
    }

    func testSmallMismatchIsOfferedInFull() throws {
        // Really 1 per 9 g: the suggestion is 9 (within the 20% step), rounded to half grams.
        let sim = simulate(Person(ratio: 9, cf: 50), days: 30) { breakfast($0) }
        let s = try XCTUnwrap(review(sim, settings: settings()).suggestions.first)
        XCTAssertEqual(s.suggested, 9, accuracy: 0.5)
        XCTAssertEqual(s.suggested.truncatingRemainder(dividingBy: 0.5), 0, accuracy: 1e-9)
    }

    func testRightSettingsGiveNoSuggestion() {
        let sim = simulate(Person(ratio: 10, cf: 50), days: 30) { breakfast($0) }
        let r = review(sim, settings: settings())
        XCTAssertTrue(r.suggestions.isEmpty)
        XCTAssertGreaterThanOrEqual(r.mealExamples.values.reduce(0, +), 25, "it looked, and found them fine")
    }

    func testCorrectionFactorFromCleanCorrections() throws {
        // Corrections at 14:00 from a raised start, really 65 mg/dL per unit, set to 50.
        let sim = simulate(Person(ratio: 10, cf: 65, baseline: 220), days: 30) { start in
            Day(doses: [InsulinDose(timestamp: start.addingTimeInterval(14 * 3600), units: 2, kind: .rapid)])
        }
        let s = try XCTUnwrap(review(sim, settings: settings()).suggestions.first { $0.setting == .correctionFactor })
        XCTAssertEqual(s.observed, 65, accuracy: 3)
        XCTAssertLessThanOrEqual(s.suggested, 60 + 1e-9, "at most 20% above 50")
        XCTAssertGreaterThan(s.suggested, 55)
    }

    func testTooFewExamplesGiveNothing() {
        let sim = simulate(Person(ratio: 8, cf: 50), days: 4) { breakfast($0) }
        let r = review(sim, settings: settings())
        XCTAssertTrue(r.suggestions.isEmpty)
        XCTAssertLessThan(r.mealExamples.values.reduce(0, +), BolusSettingsReview.minimumExamples)
    }

    func testMessyMealsAreLeftOut() {
        // A snack 2 hours after breakfast, exercise, or a low each spoil the example.
        let sim = simulate(Person(ratio: 8, cf: 50), days: 30) { start in
            var d = breakfast(start)
            let day = Int(start.timeIntervalSince1970 / 86_400)
            switch day % 3 {
            case 0: d.meals.append(MealEntry(timestamp: start.addingTimeInterval(10 * 3600), carbs: 15))
            case 1: d.contexts.append(ContextEvent(timestamp: start.addingTimeInterval(7 * 3600), tags: [.exercise]))
            default: d.meals[0].carbs = 0   // food without a carb count
            }
            return d
        }
        let r = review(sim, settings: settings())
        XCTAssertTrue(r.suggestions.isEmpty)
        XCTAssertEqual(r.mealExamples.values.reduce(0, +), 0)
    }

    func testLowsSpoilTheExample() {
        // Overdosed meals that go low are left out: the low was probably treated.
        let sim = simulate(Person(ratio: 14, cf: 50, baseline: 100), days: 30) { breakfast($0) }
        let r = review(sim, settings: settings())
        XCTAssertEqual(r.mealExamples.values.reduce(0, +), 0)
    }

    func testOnlyTheMatchingTimeBlockIsChanged() throws {
        var s = settings()
        s.blocks.append(BolusScheduleBlock(startMinute: 12 * 60, carbRatio: 10, correctionFactor: 50, targetMgdl: 100))
        let sim = simulate(Person(ratio: 8, cf: 50), days: 30) { breakfast($0) }
        let suggestion = try XCTUnwrap(review(sim, settings: s).suggestions.first)
        XCTAssertEqual(suggestion.blockStartMinute, 0)
        let applied = s.applying(suggestion)
        XCTAssertEqual(applied.blocks[0].carbRatio, 8)
        XCTAssertEqual(applied.blocks[1].carbRatio, 10, "the afternoon block is untouched")
        XCTAssertEqual(applied.blocks[0].correctionFactor, 50)
    }

    func testReviewNeverChangesTheCalculator() {
        // The calculator only reads the settings passed to it; a review on its own changes nothing.
        let sim = simulate(Person(ratio: 8, cf: 50), days: 30) { breakfast($0) }
        let s = settings()
        _ = review(sim, settings: s)
        let request = BolusRequest(carbs: 60, now: now, readings: [reading(now, 100)], doses: [], lowMgdl: 70, therapy: .injections)
        XCTAssertEqual(BolusCalculator.suggest(request, settings: s, calendar: utc).units, 6)
    }
}
