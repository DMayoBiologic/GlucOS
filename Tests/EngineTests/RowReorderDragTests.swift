import XCTest
@testable import GlucOSEngine

/// Dragging a saved insulin to a new place in Settings (`RowReorderDrag`, round 97).
final class RowReorderDragTests: XCTestCase {
    private let even = [44.0, 44, 44, 44]

    func testRestingRowIsFlat() {
        XCTAssertEqual(RowReorderDrag.look(lifted: false, reduceMotion: false, increasedContrast: false), .resting)
        XCTAssertEqual(RowReorderDrag.look(lifted: false, reduceMotion: true, increasedContrast: true), .resting)
    }

    func testPickedUpRowGrowsAndCastsAShadow() {
        let look = RowReorderDrag.look(lifted: true, reduceMotion: false, increasedContrast: false)
        XCTAssertEqual(look.scale, 1.03, accuracy: 0.0001)
        XCTAssertGreaterThan(look.shadowOpacity, 0)
    }

    func testReduceMotionShowsOnlyTheShadow() {
        let look = RowReorderDrag.look(lifted: true, reduceMotion: true, increasedContrast: false)
        XCTAssertEqual(look.scale, 1)
        XCTAssertGreaterThan(look.shadowOpacity, 0)
    }

    func testIncreaseContrastDropsTheShadow() {
        XCTAssertEqual(RowReorderDrag.look(lifted: true, reduceMotion: false, increasedContrast: true).shadowOpacity, 0)
    }

    func testRowTakesAPlaceOnceItsMiddleIsPassed() {
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 21, heights: even), 0)
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 23, heights: even), 1)
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 67, heights: even), 2)
        XCTAssertEqual(RowReorderDrag.target(from: 3, translation: -23, heights: even), 2)
        XCTAssertEqual(RowReorderDrag.target(from: 3, translation: -21, heights: even), 3)
    }

    func testTargetStaysInsideTheList() {
        XCTAssertEqual(RowReorderDrag.target(from: 1, translation: 1000, heights: even), 3)
        XCTAssertEqual(RowReorderDrag.target(from: 1, translation: -1000, heights: even), 0)
        XCTAssertEqual(RowReorderDrag.target(from: 5, translation: 50, heights: even), 5)
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 50, heights: []), 0)
    }

    func testTallRowsNeedMoreTravel() {
        let heights = [44.0, 80, 44]
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 39, heights: heights), 0)
        XCTAssertEqual(RowReorderDrag.target(from: 0, translation: 41, heights: heights), 1)
    }

    func testPassedRowsSlideAsideByThePickedRowsHeight() {
        let heights = [60.0, 44, 44, 44]
        // Row 0 dragged down over row 2: rows 1 and 2 move up by 60, row 3 stays.
        XCTAssertEqual(RowReorderDrag.shift(of: 1, from: 0, target: 2, heights: heights), -60)
        XCTAssertEqual(RowReorderDrag.shift(of: 2, from: 0, target: 2, heights: heights), -60)
        XCTAssertEqual(RowReorderDrag.shift(of: 3, from: 0, target: 2, heights: heights), 0)
        XCTAssertEqual(RowReorderDrag.shift(of: 0, from: 0, target: 2, heights: heights), 0)
        // Row 3 dragged up over row 1: rows 1 and 2 move down by 44.
        XCTAssertEqual(RowReorderDrag.shift(of: 1, from: 3, target: 1, heights: heights), 44)
        XCTAssertEqual(RowReorderDrag.shift(of: 2, from: 3, target: 1, heights: heights), 44)
        XCTAssertEqual(RowReorderDrag.shift(of: 0, from: 3, target: 1, heights: heights), 0)
        // Hovering where it started moves nothing.
        XCTAssertEqual(RowReorderDrag.shift(of: 1, from: 2, target: 2, heights: heights), 0)
    }

    func testMoveDestinationMatchesOnMove() {
        XCTAssertNil(RowReorderDrag.moveDestination(from: 2, target: 2))
        XCTAssertEqual(RowReorderDrag.moveDestination(from: 0, target: 2), 3)
        XCTAssertEqual(RowReorderDrag.moveDestination(from: 3, target: 1), 1)

        for from in 0..<4 {
            for target in 0..<4 {
                var list = ["a", "b", "c", "d"]
                let picked = list[from]
                if let destination = RowReorderDrag.moveDestination(from: from, target: target) {
                    // What SwiftUI's `move(fromOffsets:toOffset:)` does for one row (it isn't
                    // available without SwiftUI): the destination counts the row still in place.
                    let row = list.remove(at: from)
                    list.insert(row, at: destination > from ? destination - 1 : destination)
                }
                XCTAssertEqual(list.firstIndex(of: picked), target, "from \(from) to \(target)")
            }
        }
    }

    func testPickupIsQuick() {
        XCTAssertLessThanOrEqual(RowReorderDrag.duration, 0.3)
        XCTAssertLessThan(RowReorderDrag.pickupDelay, 0.5)
    }

    func testReorderHapticsAreLightTicks() {
        for event in [HapticEvent.rowPicked, .rowDropped] {
            guard case .lightImpact = event.feel else { return XCTFail("\(event) should be a light impact") }
            XCTAssertTrue(event.isTick)
        }
    }
}
