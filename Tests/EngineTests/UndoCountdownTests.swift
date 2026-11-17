import XCTest
@testable import GlucOSEngine

/// The undo toast's draining bar: pausing under a finger or the pointer, carrying on, what restarts
/// it, and which swipes dismiss it.
final class UndoCountdownTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDrainsOverItsLifetime() {
        let c = UndoCountdown(total: 5, start: t0)
        XCTAssertEqual(c.fraction(at: t0), 1)
        XCTAssertEqual(c.fraction(at: t0 + 2.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.left(at: t0 + 9), 0)
        XCTAssertFalse(c.isOver(at: t0 + 4.9))
        XCTAssertTrue(c.isOver(at: t0 + 5))
    }

    func testPauseFreezesAndResumeCarriesOn() {
        var c = UndoCountdown(total: 5, start: t0)
        c.pause(at: t0 + 2)
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.left(at: t0 + 60), 3, accuracy: 1e-9)
        XCTAssertFalse(c.isOver(at: t0 + 60))
        c.pause(at: t0 + 30) // a second pause changes nothing
        XCTAssertEqual(c.left(at: t0 + 60), 3, accuracy: 1e-9)
        c.resume(at: t0 + 60)
        XCTAssertEqual(c.left(at: t0 + 61), 2, accuracy: 1e-9)
        XCTAssertTrue(c.isOver(at: t0 + 63))
    }

    func testLettingGoNearTheEndLeavesASecond() {
        var c = UndoCountdown(total: 5, start: t0)
        c.pause(at: t0 + 4.9)
        c.resume(at: t0 + 10)
        XCTAssertEqual(c.left(at: t0 + 10), UndoCountdown.minimumAfterPause, accuracy: 1e-9)
        // Never more than the whole lifetime, however short.
        var short = UndoCountdown(total: 0.5, start: t0)
        short.pause(at: t0 + 0.4)
        short.resume(at: t0 + 1)
        XCTAssertEqual(short.left(at: t0 + 1), 0.5, accuracy: 1e-9)
    }

    func testReduceMotionStepsInWholeSeconds() {
        let c = UndoCountdown(total: 5, start: t0)
        XCTAssertEqual(c.steppedFraction(at: t0), 1)
        XCTAssertEqual(c.steppedFraction(at: t0 + 0.5), 1)
        XCTAssertEqual(c.steppedFraction(at: t0 + 1.2), 0.8, accuracy: 1e-9)
        XCTAssertEqual(c.steppedFraction(at: t0 + 4.5), 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.steppedFraction(at: t0 + 5), 0)
    }

    func testOnlyANewDeleteRestarts() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(UndoCountdown.restarts(from: [], to: [a]))
        XCTAssertTrue(UndoCountdown.restarts(from: [a], to: [a, b]))
        XCTAssertFalse(UndoCountdown.restarts(from: [a, b], to: [a]))
        XCTAssertFalse(UndoCountdown.restarts(from: [a], to: [a]))
        XCTAssertFalse(UndoCountdown.restarts(from: [a], to: []))
    }

    func testSwipesThatDismiss() {
        XCTAssertEqual(UndoSwipe.dismissal(dx: 80, dy: 5, endX: 90, endY: 5), .trailing)
        XCTAssertEqual(UndoSwipe.dismissal(dx: -80, dy: 5, endX: -90, endY: 5), .leading)
        XCTAssertEqual(UndoSwipe.dismissal(dx: 3, dy: 75, endX: 3, endY: 80), .down)
        // A quick flick goes, even if short.
        XCTAssertEqual(UndoSwipe.dismissal(dx: -20, dy: 2, endX: -200, endY: 2), .leading)
        XCTAssertEqual(UndoSwipe.dismissal(dx: 0, dy: 30, endX: 0, endY: 200), .down)
        // Short and slow springs back; up never dismisses.
        XCTAssertNil(UndoSwipe.dismissal(dx: 30, dy: 10, endX: 40, endY: 10))
        XCTAssertNil(UndoSwipe.dismissal(dx: 0, dy: -120, endX: 0, endY: -300))
        XCTAssertNil(UndoSwipe.dismissal(dx: 0, dy: 0, endX: 0, endY: 0))
    }

    func testFollowsTheFingerWithGiveUpward() {
        let down = UndoSwipe.offset(dx: 10, dy: 40)
        XCTAssertEqual(down.x, 10); XCTAssertEqual(down.y, 40)
        let up = UndoSwipe.offset(dx: 0, dy: -50)
        XCTAssertEqual(up.y, -10, accuracy: 1e-9)
        XCTAssertLessThan(UndoSwipe.exit(.leading, width: 300).x, -300)
        XCTAssertGreaterThan(UndoSwipe.exit(.down, width: 300).y, 0)
    }
}
