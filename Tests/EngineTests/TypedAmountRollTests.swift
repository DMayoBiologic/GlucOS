import XCTest
@testable import GlucOSEngine

/// How a typed amount in the log sheets rolls to its next figure (`TypedAmountRoll`).
final class TypedAmountRollTests: XCTestCase {
    func testTypingADigitRollsUp() {
        XCTAssertEqual(TypedAmountRoll.between("", "4", reduceMotion: false), .roll(countsDown: false))
        XCTAssertEqual(TypedAmountRoll.between("4", "45", reduceMotion: false), .roll(countsDown: false))
        XCTAssertEqual(TypedAmountRoll.between("4.", "4.5", reduceMotion: false), .roll(countsDown: false))
    }

    func testBackspaceAndMinusRollDown() {
        XCTAssertEqual(TypedAmountRoll.between("45", "4", reduceMotion: false), .roll(countsDown: true))
        XCTAssertEqual(TypedAmountRoll.between("4.5", "4", reduceMotion: false), .roll(countsDown: true))
        XCTAssertEqual(TypedAmountRoll.between("4", "", reduceMotion: false), .roll(countsDown: true))
    }

    func testCommaCountsAsTheDecimalPoint() {
        XCTAssertEqual(TypedAmountRoll.value(of: "7,4"), 7.4)
        XCTAssertEqual(TypedAmountRoll.between("7,4", "7,2", reduceMotion: false), .roll(countsDown: true))
    }

    func testHalfTypedEntriesCountAsTheirDigits() {
        XCTAssertEqual(TypedAmountRoll.value(of: ""), 0)
        XCTAssertEqual(TypedAmountRoll.value(of: "."), 0)
        XCTAssertEqual(TypedAmountRoll.value(of: " 12 "), 12)
    }

    func testReduceMotionChangesAtOnce() {
        XCTAssertEqual(TypedAmountRoll.between("4", "45", reduceMotion: true), .instant)
        XCTAssertEqual(TypedAmountRoll.between("45", "4", reduceMotion: true), .instant)
    }

    func testNoChangePlaysNothing() {
        XCTAssertEqual(TypedAmountRoll.between("4", "4", reduceMotion: false), .none)
        XCTAssertEqual(TypedAmountRoll.between("4", "4", reduceMotion: true), .none)
    }
}
