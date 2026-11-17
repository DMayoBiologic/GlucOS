import XCTest
@testable import GlucOSEngine

/// Settings rows that appear and disappear under a switch (docs/SettingsDependentRows.md).
final class DependentRowsTests: XCTestCase {
    func testTurningASwitchOnRevealsAndOffHides() {
        XCTAssertEqual(DependentRows.change(wasShown: false, isShown: true), .reveal)
        XCTAssertEqual(DependentRows.change(wasShown: true, isShown: false), .hide)
    }

    func testASecondSwitchForTheSameRowsChangesNothing() {
        // Predicted highs on while Predicted lows already shows Warn me ahead by.
        XCTAssertEqual(DependentRows.change(wasShown: true, isShown: true), .none)
        XCTAssertEqual(DependentRows.change(wasShown: false, isShown: false), .none)
    }

    func testRevealAndHideGlideUnlessReduceMotion() {
        XCTAssertTrue(DependentRows.glides(.reveal, reduceMotion: false))
        XCTAssertTrue(DependentRows.glides(.hide, reduceMotion: false))
        XCTAssertFalse(DependentRows.glides(.reveal, reduceMotion: true))
        XCTAssertFalse(DependentRows.glides(.hide, reduceMotion: true))
        XCTAssertFalse(DependentRows.glides(.none, reduceMotion: false))
    }

    func testOneRowIsNamed() {
        XCTAssertEqual(DependentRows.announcement(.reveal, rows: ["Warn me ahead by"]), "Now showing Warn me ahead by.")
    }

    func testTwoAndThreeRowsAreJoined() {
        XCTAssertEqual(DependentRows.announcement(.reveal, rows: ["Sync status", "Sync now"]),
                       "Now showing Sync status and Sync now.")
        XCTAssertEqual(DependentRows.announcement(.reveal, rows: ["A", "B", "C"]),
                       "Now showing A, B and C.")
    }

    func testManyRowsNameTwoAndCountTheRest() {
        let rows = ["High", "Rising or falling quickly", "No recent data", "Sensor ending",
                    "Predicted lows", "Predicted highs", "Repeat", "Send test alert"]
        XCTAssertEqual(DependentRows.announcement(.reveal, rows: rows),
                       "Now showing High, Rising or falling quickly and 6 more settings.")
    }

    func testNothingIsSaidWhenRowsGoOrStay() {
        XCTAssertNil(DependentRows.announcement(.hide, rows: ["Time"]))
        XCTAssertNil(DependentRows.announcement(.none, rows: ["Time"]))
    }

    func testBlankOrNoRowsSayNothing() {
        XCTAssertNil(DependentRows.announcement(.reveal, rows: []))
        XCTAssertNil(DependentRows.announcement(.reveal, rows: ["  ", ""]))
        XCTAssertEqual(DependentRows.announcement(.reveal, rows: ["", "Recap time"]), "Now showing Recap time.")
    }
}
