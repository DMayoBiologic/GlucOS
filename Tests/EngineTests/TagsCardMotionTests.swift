import XCTest
@testable import GlucOSEngine

final class TagsCardMotionTests: XCTestCase {
    func testGrowDelaySteppedAndCapped() {
        XCTAssertEqual(TagsCardMotion.growDelay(order: 0), 0.15, accuracy: 1e-9)
        XCTAssertEqual(TagsCardMotion.growDelay(order: 2), 0.25, accuracy: 1e-9)
        XCTAssertEqual(TagsCardMotion.growDelay(order: -3), 0.15, accuracy: 1e-9)
        XCTAssertEqual(TagsCardMotion.growDelay(order: 40), TagsCardMotion.growLimit, accuracy: 1e-9)
    }

    func testFractionClamps() {
        XCTAssertEqual(TagsCardMotion.fraction(0.62), 0.62, accuracy: 1e-9)
        XCTAssertEqual(TagsCardMotion.fraction(-1), 0)
        XCTAssertEqual(TagsCardMotion.fraction(1.4), 1)
        XCTAssertEqual(TagsCardMotion.fraction(.nan), 0)
    }

    func testChange() {
        XCTAssertTrue(TagsCardMotion.change(from: ["a", "b"], to: ["a", "b"]).isEmpty)
        let c = TagsCardMotion.change(from: ["a", "b", "c"], to: ["b", "a", "d"])
        XCTAssertEqual(c.added, ["d"])
        XCTAssertEqual(c.removed, ["c"])
        XCTAssertTrue(c.reordered)
        // Only an arrival at the end: the shared tags keep their order.
        let tail = TagsCardMotion.change(from: ["a", "b"], to: ["a", "b", "c"])
        XCTAssertFalse(tail.reordered)
        XCTAssertEqual(tail.added, ["c"])
    }

    func testFiguresOnlyStayQuiet() {
        XCTAssertNil(TagsCardMotion.announcement(oldNames: ["Exercise", "Sick"], newNames: ["Exercise", "Sick"],
                                                 periodChanged: false, periodSpoken: "the last 14 days"))
        // Spelling differences don't count as a change.
        XCTAssertNil(TagsCardMotion.announcement(oldNames: ["exercise"], newNames: ["Exercise"],
                                                 periodChanged: false, periodSpoken: "the last 14 days"))
    }

    func testPeriodChangeSaysTheLeadOnce() {
        let line = TagsCardMotion.announcement(oldNames: ["Exercise", "Sick"], newNames: ["Sick", "Exercise", "Stress"],
                                               periodChanged: true, periodSpoken: "the last 30 days")
        XCTAssertEqual(line, "Tags over the last 30 days: Sick first. Added Stress.")
    }

    func testArrivalsAndDepartures() {
        XCTAssertEqual(TagsCardMotion.announcement(oldNames: ["Exercise"], newNames: ["Exercise", "Sick"],
                                                   periodChanged: false, periodSpoken: "the last 7 days"),
                       "Tags: Added Sick.")
        XCTAssertEqual(TagsCardMotion.announcement(oldNames: ["Exercise", "Sick"], newNames: ["Sick", "Exercise"],
                                                   periodChanged: false, periodSpoken: "the last 7 days"),
                       "Tags: Sick now first.")
        XCTAssertEqual(TagsCardMotion.announcement(oldNames: ["Exercise", "Sick", "Stress"], newNames: ["Exercise"],
                                                   periodChanged: false, periodSpoken: "the last 7 days"),
                       "Tags: No longer listed: Sick and Stress.")
        XCTAssertEqual(TagsCardMotion.announcement(oldNames: ["Exercise"], newNames: [],
                                                   periodChanged: true, periodSpoken: "the last 7 days"),
                       "Tags: nothing tagged in the last 7 days.")
    }

    func testOnlyAReorderBehindTheLead() {
        XCTAssertEqual(TagsCardMotion.announcement(oldNames: ["A", "B", "C"], newNames: ["A", "C", "B"],
                                                   periodChanged: false, periodSpoken: "the last 7 days"),
                       "Tags: new order.")
    }
}
