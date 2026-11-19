import XCTest
@testable import GlucOSEngine

/// Dragging the forecast details card down to put it away (`ForecastCardDrag`, round 93).
final class ForecastCardDragTests: XCTestCase {
    func testFollowsTheFingerDownAndGivesALittleUp() {
        XCTAssertEqual(ForecastCardDrag.offset(40, style: .widen), 40)
        XCTAssertEqual(ForecastCardDrag.offset(-20, style: .widen), -4, accuracy: 1e-9)
        // Never more than the limit the wrong way, however far the finger goes.
        XCTAssertEqual(ForecastCardDrag.offset(-400, style: .widen), -ForecastCardDrag.upwardLimit)
    }

    func testReduceMotionNeverMovesOrShrinksTheCard() {
        XCTAssertEqual(ForecastCardDrag.offset(80, style: .crossFade), 0)
        XCTAssertEqual(ForecastCardDrag.offset(-80, style: .crossFade), 0)
        XCTAssertEqual(ForecastCardDrag.scale(80, style: .crossFade), 1)
        // It still dims, the one cue that it's going.
        XCTAssertLessThan(ForecastCardDrag.opacity(80), 1)
    }

    func testFadesAndShrinksUpToTheDistanceThenHolds() {
        XCTAssertEqual(ForecastCardDrag.opacity(0), 1)
        XCTAssertEqual(ForecastCardDrag.opacity(-30), 1)
        XCTAssertEqual(ForecastCardDrag.opacity(32), 1 - ForecastCardDrag.fadeAtDistance / 2, accuracy: 1e-9)
        XCTAssertEqual(ForecastCardDrag.opacity(ForecastCardDrag.distance), 1 - ForecastCardDrag.fadeAtDistance, accuracy: 1e-9)
        XCTAssertEqual(ForecastCardDrag.opacity(500), ForecastCardDrag.opacity(ForecastCardDrag.distance))
        XCTAssertEqual(ForecastCardDrag.scale(ForecastCardDrag.distance, style: .widen),
                       1 - ForecastCardDrag.shrinkAtDistance, accuracy: 1e-9)
        XCTAssertEqual(ForecastCardDrag.scale(0, style: .widen), 1)
    }

    func testPutAwayPastTheDistanceOrByAFlickDown() {
        XCTAssertTrue(ForecastCardDrag.dismisses(64, predicted: 64))
        XCTAssertFalse(ForecastCardDrag.dismisses(40, predicted: 60))
        XCTAssertTrue(ForecastCardDrag.dismisses(20, predicted: 180))
        // A flick that began by going up, or a still touch, springs back.
        XCTAssertFalse(ForecastCardDrag.dismisses(-5, predicted: 200))
        XCTAssertFalse(ForecastCardDrag.dismisses(0, predicted: 200))
    }

    func testDropsClearOfItsOwnHeightAndNeverBackUp() {
        XCTAssertEqual(ForecastCardDrag.dropOffset(from: 70, height: 220), 220 + ForecastCardDrag.dropOvershoot)
        XCTAssertEqual(ForecastCardDrag.dropOffset(from: 400, height: 220), 400)
        XCTAssertEqual(ForecastCardDrag.dropOffset(from: 70, height: -10), 70)
    }

    func testTheDropIsQuickerThanTheCardsOwnClose() {
        XCTAssertLessThan(ForecastCardDrag.dropDuration, ForecastCardEntrance.closeDuration(.widen))
        XCTAssertLessThan(ForecastCardDrag.minimumDistance, ForecastCardDrag.distance)
    }
}
