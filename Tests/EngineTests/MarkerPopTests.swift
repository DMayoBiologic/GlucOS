import XCTest
@testable import GlucOSEngine

/// Which logged markers pop in or shrink out on the chart, and what VoiceOver hears.
final class MarkerPopTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()

    func testNewMarkerIsAddedAndEditsAreNotChanges() {
        let change = MarkerPop.change(from: [a, b], to: [a, b, c])
        XCTAssertEqual(change.added, [c])
        XCTAssertEqual(change.removed, [])
        XCTAssertTrue(change.animates)
        XCTAssertTrue(MarkerPop.change(from: [a, b], to: [b, a]).isEmpty)
        XCTAssertFalse(MarkerPop.change(from: [a], to: [a]).animates)
    }

    func testDeleteThenUndoShrinksOutThenPopsBack() {
        let deleted = MarkerPop.change(from: [a, b], to: [a])
        XCTAssertEqual(deleted.removed, [b])
        XCTAssertEqual(deleted.added, [])
        let undone = MarkerPop.change(from: [a], to: [a, b])
        XCTAssertEqual(undone.added, [b])
        XCTAssertTrue(undone.animates)
    }

    func testAWholeLogbookArrivingAtOnceDoesNotAnimate() {
        XCTAssertTrue(MarkerPop.change(from: [], to: [a, b, c, d]).animates)
        XCTAssertFalse(MarkerPop.change(from: [], to: [a, b, c, d, e]).animates)
        XCTAssertFalse(MarkerPop.change(from: [a, b, c, d, e, f], to: []).animates)
    }

    func testAnnouncements() {
        XCTAssertEqual(MarkerPop.announcement(added: [.meal], removed: []), "Meal added to chart")
        XCTAssertEqual(MarkerPop.announcement(added: [], removed: [.treatment]), "Treatment removed from chart")
        // Each kind once, in a fixed order, whichever was stored first.
        XCTAssertEqual(MarkerPop.announcement(added: [.insulin, .meal], removed: []), "Meal and insulin added to chart")
        XCTAssertEqual(MarkerPop.announcement(added: [.insulin, .insulin], removed: []), "Insulin added to chart")
        XCTAssertEqual(MarkerPop.announcement(added: [.wake, .insulin, .meal], removed: []),
                       "Meal, insulin and wake-up added to chart")
        XCTAssertEqual(MarkerPop.announcement(added: [.meal], removed: [.insulin]),
                       "Meal added to chart. Insulin removed from chart")
        XCTAssertNil(MarkerPop.announcement(added: [], removed: []))
    }

    func testMealCountsAsTreatmentOnlyWithATagAtTheSameTime() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(MarkerPop.isTreatment(mealAt: t, treatmentTags: [t]))
        XCTAssertTrue(MarkerPop.isTreatment(mealAt: t, treatmentTags: [t.addingTimeInterval(45)]))
        XCTAssertFalse(MarkerPop.isTreatment(mealAt: t, treatmentTags: [t.addingTimeInterval(-600)]))
        XCTAssertFalse(MarkerPop.isTreatment(mealAt: t, treatmentTags: []))
    }
}
