import XCTest
@testable import GlucOSEngine

/// One-tap repeats (docs/UsualEntries.md): what counts as usual, when each is offered, and the
/// check a repeat goes through before it's logged.
final class UsualEntriesTests: XCTestCase {
    /// 08:00 UTC on a weekday: breakfast.
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 8, minute: 0))!

    func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let day = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: now))!
        return utc.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func meal(_ date: Date, _ food: String, _ carbs: Double) -> MealEntry {
        MealEntry(timestamp: date, carbs: carbs, food: food)
    }

    func dose(_ date: Date, _ units: Double, kind: InsulinKind = .rapid, name: String = "NovoRapid") -> InsulinDose {
        InsulinDose(timestamp: date, units: units, kind: kind, name: name)
    }

    let inRange = UsualGlucose(mgdl: 120, ratePerMinute: 0, lowMgdl: 70, highMgdl: 180)
    let high = UsualGlucose(mgdl: 240, ratePerMinute: 0.5, lowMgdl: 70, highMgdl: 180)
    let low = UsualGlucose(mgdl: 62, ratePerMinute: -0.5, lowMgdl: 70, highMgdl: 180)

    // MARK: Slots

    func testSlotsFollowTheClock() {
        XCTAssertEqual(MealSlot.at(at(daysAgo: 0, hour: 7), calendar: utc), .breakfast)
        XCTAssertEqual(MealSlot.at(at(daysAgo: 0, hour: 12, minute: 30), calendar: utc), .lunch)
        XCTAssertEqual(MealSlot.at(at(daysAgo: 0, hour: 19), calendar: utc), .dinner)
        XCTAssertEqual(MealSlot.at(at(daysAgo: 0, hour: 15, minute: 30), calendar: utc), .snack)
        XCTAssertEqual(MealSlot.at(at(daysAgo: 0, hour: 2), calendar: utc), .snack)
    }

    // MARK: Usual meal

    func testUsualBreakfastIsTheMealOnMostMornings() {
        let meals = [
            meal(at(daysAgo: 1, hour: 7), "Toast and banana", 45),
            meal(at(daysAgo: 2, hour: 7, minute: 20), "toast and banana", 42),
            meal(at(daysAgo: 4, hour: 8), "Toast and Banana.", 48),
            meal(at(daysAgo: 3, hour: 7), "Porridge", 35),
            meal(at(daysAgo: 5, hour: 7), "Porridge", 35),
            // Same food at dinner doesn't count towards breakfast.
            meal(at(daysAgo: 1, hour: 19), "Porridge", 35),
        ]
        let doses = [dose(at(daysAgo: 1, hour: 7, minute: 5), 4.5)]
        let u = UsualEntries.usualMeal(meals, doses: doses, now: now, calendar: utc)
        XCTAssertEqual(u?.kind, .meal(.breakfast))
        XCTAssertEqual(u?.title, "Usual breakfast")
        // The latest time's own name and carbs, never an average.
        XCTAssertEqual(u?.food, "Toast and banana")
        XCTAssertEqual(u?.carbs, 45)
        XCTAssertEqual(u?.count, 3)
        // The bolus with it that morning is offered for the dose step.
        XCTAssertEqual(u?.units, 4.5)
        XCTAssertEqual(u?.insulinName, "NovoRapid")
        XCTAssertEqual(u?.detail, "Toast and banana · 45 g")
        // The popover's chip names the food itself.
        XCTAssertEqual(u?.shortTitle, "Toast and banana")
        XCTAssertEqual(u?.spokenLabel, "Usual breakfast: Toast and banana, 45 grams of carbs")
    }

    func testAMealNeedsThreeDifferentDays() {
        // Twice in one morning and once more is only two days.
        let meals = [
            meal(at(daysAgo: 1, hour: 7), "Toast", 30),
            meal(at(daysAgo: 1, hour: 9), "Toast", 30),
            meal(at(daysAgo: 2, hour: 7), "Toast", 30),
        ]
        XCTAssertNil(UsualEntries.usualMeal(meals, doses: [], now: now, calendar: utc))
    }

    func testOldMealsAndTiesGoToTheLatest() {
        let old = (30...33).map { meal(at(daysAgo: $0, hour: 7), "Muesli", 50) }
        XCTAssertNil(UsualEntries.usualMeal(old, doses: [], now: now, calendar: utc), "older than four weeks")
        let tie = [1, 3, 5].map { meal(at(daysAgo: $0, hour: 7), "Eggs", 5) }
            + [2, 4, 6].map { meal(at(daysAgo: $0, hour: 7), "Cereal", 40) }
        XCTAssertEqual(UsualEntries.usualMeal(tie, doses: [], now: now, calendar: utc)?.food, "Eggs")
    }

    func testCarbsOnlyMealsGroupByTheirCarbs() {
        let meals = [1, 2, 3].map { meal(at(daysAgo: $0, hour: 7), "", 40) }
        let u = UsualEntries.usualMeal(meals, doses: [], now: now, calendar: utc)
        XCTAssertEqual(u?.carbs, 40)
        XCTAssertEqual(u?.detail, "40 g")
        XCTAssertEqual(u?.shortTitle, "40 g carbs")
        XCTAssertNil(u?.units)
    }

    // MARK: Lows

    func testLowTreatmentLeadsDuringALowAndCorrectionIsHidden() {
        var meals = [1, 9].map { meal(at(daysAgo: $0, hour: 3), "Jelly beans", 15) }
        meals += [1, 2, 3].map { meal(at(daysAgo: $0, hour: 7), "Toast", 30) }
        let contexts = [1, 9].map { ContextEvent(timestamp: at(daysAgo: $0, hour: 3, minute: 2), tags: [.hypoTreatment]) }
        let corrections = [2, 3, 4].map { dose(at(daysAgo: $0, hour: 15), 2) }

        let during = UsualEntries.suggest(meals: meals, doses: corrections, contexts: contexts, now: now,
                                          glucose: low, logsInsulin: true, calendar: utc)
        XCTAssertEqual(during.map(\.kind), [.lowTreatment, .meal(.breakfast)])
        XCTAssertEqual(during.first?.detail, "Jelly beans · 15 g")
        XCTAssertEqual(during.first?.shortTitle, "Treat a low")
        XCTAssertNil(during.first?.units)

        // In range: no low treatment, and hypo food never counts as a usual meal.
        let calm = UsualEntries.suggest(meals: meals, doses: corrections, contexts: contexts, now: now,
                                        glucose: inRange, logsInsulin: true, calendar: utc)
        XCTAssertEqual(calm.map(\.kind), [.meal(.breakfast)])
    }

    func testHeadingLowCountsAsLow() {
        XCTAssertTrue(UsualGlucose(mgdl: 82, ratePerMinute: -1.5, lowMgdl: 70, highMgdl: 180).isLowOrHeadingLow)
        XCTAssertFalse(UsualGlucose(mgdl: 82, ratePerMinute: 0, lowMgdl: 70, highMgdl: 180).isLowOrHeadingLow)
        XCTAssertFalse(UsualGlucose(mgdl: nil, ratePerMinute: nil, lowMgdl: 70, highMgdl: 180).isLowOrHeadingLow)
    }

    func testOneLowTreatmentIsNotYetUsual() {
        let meals = [meal(at(daysAgo: 1, hour: 3), "Juice", 20)]
        let contexts = [ContextEvent(timestamp: at(daysAgo: 1, hour: 3), tags: [.hypoTreatment])]
        XCTAssertTrue(UsualEntries.suggest(meals: meals, doses: [], contexts: contexts, now: now, glucose: low,
                                           logsInsulin: true, calendar: utc).isEmpty)
    }

    // MARK: Corrections

    func testUsualCorrectionOnlyWhenHighAndNoRecentBolus() {
        let corrections = [dose(at(daysAgo: 2, hour: 15), 2), dose(at(daysAgo: 3, hour: 22), 2),
                           dose(at(daysAgo: 5, hour: 11), 3), dose(at(daysAgo: 6, hour: 16), 2)]
        // A meal dose doesn't count: food was logged with it.
        let mealDose = dose(at(daysAgo: 1, hour: 7), 5)
        let meals = [meal(at(daysAgo: 1, hour: 7, minute: 10), "Toast", 30)]
        let doses = corrections + [mealDose]

        let offered = UsualEntries.suggest(meals: meals, doses: doses, contexts: [], now: now, glucose: high,
                                           logsInsulin: true, calendar: utc)
        let c = offered.first { $0.kind == .correction }
        XCTAssertEqual(c?.units, 2)
        XCTAssertEqual(c?.count, 3)
        XCTAssertEqual(c?.detail, "2 u NovoRapid")
        XCTAssertEqual(c?.spokenLabel, "Usual correction: 2 units, NovoRapid")
        XCTAssertEqual(c?.shortTitle, "Correction 2 u")

        XCTAssertFalse(UsualEntries.suggest(meals: meals, doses: doses, contexts: [], now: now, glucose: inRange,
                                            logsInsulin: true, calendar: utc).contains { $0.kind == .correction })
        XCTAssertFalse(UsualEntries.suggest(meals: meals, doses: doses, contexts: [], now: now, glucose: high,
                                            logsInsulin: false, calendar: utc).contains { $0.kind == .correction })
        let justDosed = doses + [dose(now.addingTimeInterval(-40 * 60), 1)]
        XCTAssertFalse(UsualEntries.suggest(meals: meals, doses: justDosed, contexts: [], now: now, glucose: high,
                                            logsInsulin: true, calendar: utc).contains { $0.kind == .correction })
    }

    func testDosesMarkedForAMealOrFromTheCalculatorForCarbsAreNotCorrections() {
        var forMeal = dose(at(daysAgo: 1, hour: 15), 2)
        forMeal.purpose = .meal
        XCTAssertFalse(UsualEntries.isCorrection(forMeal, meals: [], contexts: []))
        var answered = dose(at(daysAgo: 1, hour: 15), 2)
        answered.purpose = .correction
        // The user's word wins even with a snack nearby.
        XCTAssertTrue(UsualEntries.isCorrection(answered, meals: [meal(at(daysAgo: 1, hour: 15), "", 10)], contexts: []))
        XCTAssertFalse(UsualEntries.isCorrection(dose(at(daysAgo: 1, hour: 15), 2, kind: .long), meals: [], contexts: []))
        XCTAssertFalse(UsualEntries.isCorrection(dose(at(daysAgo: 1, hour: 15), 0.3), meals: [], contexts: []))
    }

    // MARK: Logged twice?

    func testARepeatedMealIsCaught() {
        let earlier = meal(now.addingTimeInterval(-20 * 60), "Toast and banana", 45)
        let w = RepeatCheck.warning(at: now, units: nil, carbs: 45, food: "toast and banana", hypoTreatment: false,
                                    doses: [], meals: [earlier], contexts: [], now: now)
        XCTAssertEqual(w, "You logged Toast and banana (45 g) 20 minutes ago. If it's the same meal, don't log it again.")
        // About the same carbs under another name also counts; a different meal doesn't.
        XCTAssertNotNil(RepeatCheck.warning(at: now, units: nil, carbs: 43, food: "Toast", hypoTreatment: false,
                                            doses: [], meals: [earlier], contexts: [], now: now))
        XCTAssertNil(RepeatCheck.warning(at: now, units: nil, carbs: 20, food: "Apple", hypoTreatment: false,
                                         doses: [], meals: [earlier], contexts: [], now: now))
        // An hour apart is a different meal.
        XCTAssertNil(RepeatCheck.warning(at: now.addingTimeInterval(60 * 60), units: nil, carbs: 45, food: "toast and banana",
                                         hypoTreatment: false, doses: [], meals: [earlier], contexts: [], now: now))
    }

    func testARepeatedDoseIsCaughtWhateverItCameFrom() {
        // Typed by hand, not from the calculator: the calculator's own check wouldn't see it.
        let d = dose(now.addingTimeInterval(-12 * 60), 4)
        let w = RepeatCheck.warning(at: now, units: 4, carbs: nil, food: "", hypoTreatment: false,
                                    doses: [d], meals: [], contexts: [], now: now)
        XCTAssertEqual(w, "You logged 4 u 12 minutes ago. If it's the same dose, don't log it again.")
        let both = RepeatCheck.warning(at: now, units: 4, carbs: 45, food: "Toast", hypoTreatment: false,
                                       doses: [d], meals: [meal(now.addingTimeInterval(-15 * 60), "Toast", 45)],
                                       contexts: [], now: now)
        XCTAssertEqual(both, "You logged 4 u 12 minutes ago and Toast (45 g) 15 minutes ago. If it's the same meal or dose, don't log it again.")
        // A basal dose isn't a repeat of a bolus.
        XCTAssertNil(RepeatCheck.warning(at: now, units: 4, carbs: nil, food: "", hypoTreatment: false,
                                         doses: [dose(now.addingTimeInterval(-5 * 60), 20, kind: .long)], meals: [],
                                         contexts: [], now: now))
    }

    func testASecondLowTreatmentTooSoonIsCaught() {
        let first = ContextEvent(timestamp: now.addingTimeInterval(-6 * 60), tags: [.hypoTreatment])
        let w = RepeatCheck.warning(at: now, units: nil, carbs: 15, food: "Jelly beans", hypoTreatment: true,
                                    doses: [], meals: [], contexts: [first], now: now)
        XCTAssertEqual(w, "You logged a hypo treatment 6 minutes ago. Fast sugar takes about 15 minutes to work: check again before taking more.")
        let later = ContextEvent(timestamp: now.addingTimeInterval(-20 * 60), tags: [.hypoTreatment])
        XCTAssertNil(RepeatCheck.warning(at: now, units: nil, carbs: 15, food: "Jelly beans", hypoTreatment: true,
                                         doses: [], meals: [], contexts: [later], now: now))
    }

    func testWordingForAnEarlierTime() {
        let t = now.addingTimeInterval(-60 * 60)
        XCTAssertEqual(RepeatCheck.when(t.addingTimeInterval(-10 * 60), from: t, now: now), "10 minutes earlier")
        XCTAssertEqual(RepeatCheck.when(t.addingTimeInterval(5 * 60), from: t, now: now), "5 minutes later")
        XCTAssertEqual(RepeatCheck.when(now, from: now, now: now), "just now")
    }
}
