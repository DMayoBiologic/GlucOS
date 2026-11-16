import XCTest
@testable import GlucOSEngine

/// The inline "Log treatment" button (docs/AlertActions.md, "Log treatment in the app"): when it
/// shows, when a logged treatment hides it, and what it says.
final class LowTreatButtonTests: XCTestCase {
    let now = referenceNow
    let low = 70.0

    func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    func reason(_ mgdl: Double?, predicted: Date? = nil, meals: [MealEntry] = [],
                contexts: [ContextEvent] = []) -> LowTreatButton.Reason? {
        LowTreatButton.reason(mgdl: mgdl, lowMgdl: low, predictedLowAt: predicted, meals: meals,
                              contexts: contexts, now: now)
    }

    // MARK: When it shows

    func testShowsDuringALow() {
        XCTAssertEqual(reason(62), .low)
    }

    func testShowsWhenALowIsPredicted() {
        let when = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(reason(85, predicted: when), .predicted(when))
    }

    func testALowReadingWinsOverAPrediction() {
        XCTAssertEqual(reason(65, predicted: now.addingTimeInterval(600)), .low)
    }

    func testHiddenInRangeWithNoLowPredicted() {
        XCTAssertNil(reason(110))
        // At the line counts as back in range.
        XCTAssertNil(reason(low))
    }

    func testHiddenWithoutAFreshReading() {
        XCTAssertNil(reason(nil, predicted: now.addingTimeInterval(600)))
    }

    // MARK: A logged treatment hides it

    func testFoodLoggedJustNowHidesIt() {
        XCTAssertNil(reason(60, meals: [MealEntry(timestamp: at(2), carbs: 15, food: "Jelly beans")]))
        // Food with no carbs typed still counts.
        XCTAssertNil(reason(60, meals: [MealEntry(timestamp: at(5), carbs: 0, food: "Juice")]))
    }

    func testAHypoTagHidesIt() {
        XCTAssertNil(reason(60, contexts: [ContextEvent(timestamp: at(3), tags: [.hypoTreatment])]))
    }

    func testOtherTagsDoNotHideIt() {
        XCTAssertEqual(reason(60, contexts: [ContextEvent(timestamp: at(3), tags: [.exercise])]), .low)
    }

    func testATreatmentAlsoHidesAPredictedLow() {
        XCTAssertNil(reason(85, predicted: now.addingTimeInterval(900),
                            meals: [MealEntry(timestamp: at(1), carbs: 15)]))
    }

    func testStillLowAQuarterHourAfterTreatingOffersItAgain() {
        // The rule of 15: recheck, and treat again if still low.
        XCTAssertNil(reason(60, meals: [MealEntry(timestamp: at(14), carbs: 15)]))
        XCTAssertEqual(reason(60, meals: [MealEntry(timestamp: at(16), carbs: 15)]), .low)
    }

    func testAnEntryAFewMinutesAheadStillCounts() {
        // Another device's clock running slightly fast.
        XCTAssertNil(reason(60, meals: [MealEntry(timestamp: now.addingTimeInterval(120), carbs: 15)]))
        XCTAssertEqual(reason(60, meals: [MealEntry(timestamp: now.addingTimeInterval(3600), carbs: 15)]), .low)
    }

    // MARK: Words

    func testCaptionAndSpokenLabel() {
        XCTAssertEqual(LowTreatButton.title, "Log treatment")
        XCTAssertEqual(LowTreatButton.caption(.low, now: now), "Low now")
        XCTAssertEqual(LowTreatButton.accessibilityLabel(.low, now: now), "Log treatment for this low")
        let soon = now.addingTimeInterval(12 * 60)
        XCTAssertEqual(LowTreatButton.caption(.predicted(soon), now: now), "Low predicted in about 12 min")
        XCTAssertEqual(LowTreatButton.accessibilityLabel(.predicted(soon), now: now),
                       "Log treatment. Low predicted in about 12 minutes")
        XCTAssertEqual(LowTreatButton.caption(.predicted(now.addingTimeInterval(30)), now: now),
                       "Low predicted any minute")
    }

    func testHintSaysNothingIsLogged() {
        XCTAssertTrue(LowTreatButton.accessibilityHint(hasUsual: true).contains("Nothing is logged"))
        XCTAssertTrue(LowTreatButton.accessibilityHint(hasUsual: false).contains("Nothing is logged"))
    }
}
