import XCTest
@testable import GlucOSEngine

final class OvernightCardMotionTests: XCTestCase {
    func testSharesAddUpToTheBar() {
        let s = OvernightCardMotion.shares(timeInRange: 0.8, timeBelow: 0.05)
        XCTAssertEqual(s.below, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.inRange, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.above, 0.15, accuracy: 1e-9)
        XCTAssertEqual(s.all.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testSharesClampBadValues() {
        let s = OvernightCardMotion.shares(timeInRange: 1.3, timeBelow: -0.2)
        XCTAssertEqual(s, .init(below: 0, inRange: 1, above: 0))
        let nan = OvernightCardMotion.shares(timeInRange: .nan, timeBelow: .infinity)
        XCTAssertEqual(nan, .init(below: 0, inRange: 0, above: 1))
        // Below and in range together never pass the end of the bar.
        let over = OvernightCardMotion.shares(timeInRange: 0.9, timeBelow: 0.3)
        XCTAssertEqual(over.below, 0.3, accuracy: 1e-9)
        XCTAssertEqual(over.inRange, 0.7, accuracy: 1e-9)
        XCTAssertEqual(over.above, 0, accuracy: 1e-9)
    }

    func testSliversAreNotDrawn() {
        XCTAssertFalse(OvernightCardMotion.shows(0))
        XCTAssertFalse(OvernightCardMotion.shows(0.0005))
        XCTAssertTrue(OvernightCardMotion.shows(0.01))
    }

    func testFillStartsAfterTheFirstFigure() {
        // RollingFigure's first count-up starts at 0.1 s.
        XCTAssertGreaterThan(OvernightCardMotion.fillDelay, 0.1)
        XCTAssertLessThanOrEqual(OvernightCardMotion.fillDelay, 0.45)
        XCTAssertEqual(OvernightCardMotion.reducedFade, 0.2, accuracy: 1e-9)
    }

    func testCrossFadesOnlyBetweenTwoDifferentSummaries() {
        let a = summary(range: 0.8), b = summary(range: 0.7)
        XCTAssertFalse(OvernightCardMotion.crossFades(from: nil, to: a))
        XCTAssertFalse(OvernightCardMotion.crossFades(from: a, to: nil))
        XCTAssertFalse(OvernightCardMotion.crossFades(from: a, to: a))
        XCTAssertTrue(OvernightCardMotion.crossFades(from: a, to: b))
    }

    func testSharesFromSummary() {
        let s = OvernightCardMotion.shares(summary(range: 0.75, below: 0.1))
        XCTAssertEqual(s.above, 0.15, accuracy: 1e-9)
    }

    private func summary(range: Double, below: Double = 0.02) -> OvernightSummary {
        OvernightSummary(period: .fortnight, end: Date(timeIntervalSince1970: 1_800_000_000),
                         nights: [], timeInRange: range, timeBelow: below)
    }
}
