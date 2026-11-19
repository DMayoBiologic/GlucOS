import XCTest
@testable import GlucOSEngine

/// Mac Insights cards lift on hover, and only on hover (`CardHoverLift`).
final class CardHoverLiftTests: XCTestCase {
    func testRestingCardIsFlat() {
        XCTAssertEqual(CardHoverLift.look(hovering: false, reduceMotion: false, increasedContrast: false), .resting)
        XCTAssertEqual(CardHoverLift.look(hovering: false, reduceMotion: true, increasedContrast: true), .resting)
    }

    func testHoveredCardGrowsSlightlyWithASoftShadow() {
        let look = CardHoverLift.look(hovering: true, reduceMotion: false, increasedContrast: false)
        XCTAssertEqual(look.scale, 1.01, accuracy: 0.0001)
        XCTAssertGreaterThan(look.shadowOpacity, 0)
        XCTAssertLessThanOrEqual(look.shadowOpacity, 0.2)
    }

    func testReduceMotionKeepsTheSizeAndOnlyFadesTheShadow() {
        let look = CardHoverLift.look(hovering: true, reduceMotion: true, increasedContrast: false)
        XCTAssertEqual(look.scale, 1)
        XCTAssertGreaterThan(look.shadowOpacity, 0)
    }

    func testIncreaseContrastDropsTheShadow() {
        let look = CardHoverLift.look(hovering: true, reduceMotion: false, increasedContrast: true)
        XCTAssertEqual(look.shadowOpacity, 0)
        XCTAssertEqual(look.scale, 1.01, accuracy: 0.0001)
    }

    func testLiftIsQuick() {
        XCTAssertEqual(CardHoverLift.duration, 0.15, accuracy: 0.0001)
    }

    func testEnteringACardHoversIt() {
        XCTAssertEqual(CardHoverLift.hovered(nil, card: "lows", hovering: true), "lows")
        XCTAssertEqual(CardHoverLift.hovered("highs", card: "lows", hovering: true), "lows")
    }

    func testLeavingTheHoveredCardClearsIt() {
        XCTAssertNil(CardHoverLift.hovered("lows", card: "lows", hovering: false))
    }

    func testLateLeaveFromThePreviousCardKeepsTheNewOne() {
        XCTAssertEqual(CardHoverLift.hovered("highs", card: "lows", hovering: false), "highs")
    }
}
