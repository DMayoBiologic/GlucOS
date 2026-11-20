import XCTest
@testable import GlucOSEngine

/// The trend arrow turning on a new trend (improvement round 39): when it turns, when it
/// cross-fades instead, what VoiceOver says, and the spring the Mac menu bar item draws by hand.
final class TrendTurnTests: XCTestCase {
    func testTurnsOnlyBetweenTwoKnownDirections() {
        XCTAssertEqual(TrendTurn.between(.flat, .rising, reduceMotion: false), .turn)
        XCTAssertEqual(TrendTurn.between(.fallingQuickly, .risingQuickly, reduceMotion: false), .turn)
        XCTAssertEqual(TrendTurn.between(.rising, .rising, reduceMotion: false), .none)
        // Nothing to turn from or to: the arrow fades in or out instead.
        XCTAssertEqual(TrendTurn.between(nil, .rising, reduceMotion: false), .none)
        XCTAssertEqual(TrendTurn.between(.rising, nil, reduceMotion: false), .none)
        XCTAssertEqual(TrendTurn.between(.unknown, .rising, reduceMotion: false), .none)
        XCTAssertEqual(TrendTurn.between(.rising, .unknown, reduceMotion: false), .none)
    }

    func testReduceMotionCrossFadesInstead() {
        XCTAssertEqual(TrendTurn.between(.flat, .falling, reduceMotion: true), .crossFade)
        XCTAssertEqual(TrendTurn.between(.falling, .falling, reduceMotion: true), .none)
        XCTAssertLessThanOrEqual(TrendTurn.crossFadeDuration, 0.3)
    }

    func testVoiceOverHearsTheNewTrendOnce() {
        XCTAssertEqual(TrendTurn.announcement(from: .flat, to: .risingQuickly), "Trend now rising quickly")
        XCTAssertEqual(TrendTurn.announcement(from: .rising, to: .flat), "Trend now steady")
        // The same trend on the next reading, going stale, or the first reading: nothing.
        XCTAssertNil(TrendTurn.announcement(from: .rising, to: .rising))
        XCTAssertNil(TrendTurn.announcement(from: .rising, to: nil))
        XCTAssertNil(TrendTurn.announcement(from: nil, to: .rising))
        XCTAssertNil(TrendTurn.announcement(from: .unknown, to: .falling))
    }

    func testFollowerHearsTheTurnWithTheirName() {
        XCTAssertEqual(TrendTurn.announcement(from: .flat, to: .falling, name: "Sam"), "Sam's trend now falling")
        XCTAssertEqual(TrendTurn.announcement(from: .flat, to: .rising, name: "James"), "James' trend now rising")
        // A blank name falls back to the owner's wording; no turn, no announcement.
        XCTAssertEqual(TrendTurn.announcement(from: .flat, to: .rising, name: "  "), "Trend now rising")
        XCTAssertNil(TrendTurn.announcement(from: .rising, to: .rising, name: "Sam"))
        XCTAssertNil(TrendTurn.announcement(from: nil, to: .rising, name: "Sam"))
    }

    func testSpringIsOneShortSettle() {
        XCTAssertEqual(TrendTurn.springProgress(at: 0), 0)
        XCTAssertEqual(TrendTurn.springProgress(at: -1), 0)
        XCTAssertEqual(TrendTurn.springProgress(at: .infinity), 1)
        // A single small overshoot (a few percent), then settled within the 0.7 s arrival.
        let samples = stride(from: 0.0, through: 1.5, by: 1.0 / 120).map { TrendTurn.springProgress(at: $0) }
        let peak = samples.max() ?? 0
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThan(peak, 1.06)
        XCTAssertEqual(TrendTurn.springProgress(at: 0.7), 1, accuracy: 0.02)
        XCTAssertEqual(TrendTurn.springProgress(at: 1.5), 1, accuracy: 0.001)
        // No second swing back past the start: it never dips below where it began.
        XCTAssertGreaterThanOrEqual(samples.min() ?? -1, 0)
    }

    func testAngleRunsFromOldDirectionToNew() {
        XCTAssertEqual(TrendTurn.angle(from: .flat, to: .risingQuickly, at: 0), 0)
        XCTAssertEqual(TrendTurn.angle(from: .flat, to: .risingQuickly, at: 2), -90, accuracy: 0.01)
        XCTAssertEqual(TrendTurn.angle(from: .falling, to: .rising, at: 2), -45, accuracy: 0.01)
        let mid = TrendTurn.angle(from: .flat, to: .falling, at: 0.15)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 45)
    }
}
