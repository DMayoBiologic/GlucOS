import XCTest
@testable import GlucOSEngine

final class LogKeyboardTests: XCTestCase {
    // The tiles are 3 wide: 6 for injections or a pump, 4 without insulin.

    func testFirstArrowStartsOnTheFirstTile() {
        for d in [LogKeyboard.Direction.left, .right, .up, .down] {
            XCTAssertEqual(LogKeyboard.move(from: nil, d, count: 6, columns: 3), 0)
        }
        XCTAssertNil(LogKeyboard.move(from: nil, .down, count: 0, columns: 3))
        // A stale index (the therapy changed and there are fewer tiles) restarts too.
        XCTAssertEqual(LogKeyboard.move(from: 7, .left, count: 4, columns: 3), 0)
    }

    func testLeftAndRightRunAlongTheListWithoutWrapping() {
        XCTAssertEqual(LogKeyboard.move(from: 0, .right, count: 6, columns: 3), 1)
        // End of the first row goes on to the start of the next.
        XCTAssertEqual(LogKeyboard.move(from: 2, .right, count: 6, columns: 3), 3)
        XCTAssertEqual(LogKeyboard.move(from: 3, .left, count: 6, columns: 3), 2)
        XCTAssertEqual(LogKeyboard.move(from: 0, .left, count: 6, columns: 3), 0)
        XCTAssertEqual(LogKeyboard.move(from: 5, .right, count: 6, columns: 3), 5)
    }

    func testUpAndDownKeepTheColumn() {
        XCTAssertEqual(LogKeyboard.move(from: 1, .down, count: 6, columns: 3), 4)
        XCTAssertEqual(LogKeyboard.move(from: 4, .up, count: 6, columns: 3), 1)
        XCTAssertEqual(LogKeyboard.move(from: 1, .up, count: 6, columns: 3), 1)
        XCTAssertEqual(LogKeyboard.move(from: 4, .down, count: 6, columns: 3), 4)
    }

    func testDownOntoAShortLastRowLandsOnItsLastTile() {
        // 4 tiles: row 0 = 0 1 2, row 1 = 3.
        XCTAssertEqual(LogKeyboard.move(from: 0, .down, count: 4, columns: 3), 3)
        XCTAssertEqual(LogKeyboard.move(from: 2, .down, count: 4, columns: 3), 3)
        XCTAssertEqual(LogKeyboard.move(from: 3, .down, count: 4, columns: 3), 3)
        XCTAssertEqual(LogKeyboard.move(from: 3, .up, count: 4, columns: 3), 0)
    }

    func testOneColumnGridMovesOneAtATime() {
        XCTAssertEqual(LogKeyboard.move(from: 0, .down, count: 3, columns: 1), 1)
        XCTAssertEqual(LogKeyboard.move(from: 2, .up, count: 3, columns: 0), 1)
    }

    func testSpaceAlwaysTogglesAndStays() {
        XCTAssertEqual(LogKeyboard.action(return: false, tileIsOn: false, opensPart: true, canLog: false), .toggle)
        XCTAssertEqual(LogKeyboard.action(return: false, tileIsOn: true, opensPart: true, canLog: true), .toggle)
        XCTAssertEqual(LogKeyboard.action(return: false, tileIsOn: true, opensPart: false, canLog: true), .toggle)
    }

    func testReturnPicksAndMovesOnThenLogs() {
        // Eating or Bolus: on, and on to the carbs or units field.
        XCTAssertEqual(LogKeyboard.action(return: true, tileIsOn: false, opensPart: true, canLog: false), .pickAndContinue)
        // Woke up: on; Return again logs it.
        XCTAssertEqual(LogKeyboard.action(return: true, tileIsOn: false, opensPart: false, canLog: false), .toggle)
        XCTAssertEqual(LogKeyboard.action(return: true, tileIsOn: true, opensPart: false, canLog: true), .log)
        // Already on but not ready (no carbs yet): Return never turns it back off.
        XCTAssertEqual(LogKeyboard.action(return: true, tileIsOn: true, opensPart: true, canLog: false), .nothing)
    }

    func testHotKeyDisplayFollowsAppleModifierOrder() {
        XCTAssertEqual(LogHotKey.suggested.display, "⌃⌥⌘L")
        XCTAssertEqual(LogHotKey.suggested.spoken, "Control Option Command L")
        let k = LogHotKey(keyCode: 37, modifiers: [.command, .shift, .option, .control], key: "l")
        XCTAssertEqual(k.display, "⌃⌥⇧⌘L")
    }

    func testHotKeyNeedsTwoModifiersWithCommandOrControl() {
        XCTAssertNil(LogHotKey.suggested.problem)
        XCTAssertNil(LogHotKey(keyCode: 37, modifiers: [.control, .option], key: "L").problem)
        XCTAssertNil(LogHotKey(keyCode: 37, modifiers: [.command, .shift], key: "L").problem)
        XCTAssertNil(LogHotKey(keyCode: 12, modifiers: [.command, .option], key: "Q").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 37, modifiers: [], key: "L").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 37, modifiers: [.option], key: "L").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 37, modifiers: [.option, .shift], key: "L").problem)
        // One modifier takes a shortcut other apps use: ⌘L is the browser address bar.
        XCTAssertNotNil(LogHotKey(keyCode: 37, modifiers: [.command], key: "L").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 0, modifiers: [.control], key: "A").problem)
    }

    func testHotKeyCantTakeWhatMacOSUses() {
        XCTAssertNotNil(LogHotKey(keyCode: 49, modifiers: [.command, .option], key: "Space").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 48, modifiers: [.command, .shift], key: "Tab").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 20, modifiers: [.command, .shift], key: "3").problem)
        XCTAssertNotNil(LogHotKey(keyCode: 6, modifiers: [.command, .shift], key: "z").problem)
        XCTAssertNil(LogHotKey(keyCode: 20, modifiers: [.command, .shift, .control], key: "3").problem)
    }

    func testHotKeyRoundTripsThroughStorage() throws {
        let data = try JSONEncoder().encode(LogHotKey.suggested)
        XCTAssertEqual(try JSONDecoder().decode(LogHotKey.self, from: data), .suggested)
    }

    func testListsShowTheGlobalShortcutOnlyWhenItIsOn() {
        XCTAssertFalse(ShortcutCatalog.popover(globalKey: nil).contains { $0.title == "From any app" })
        let on = ShortcutCatalog.popover(globalKey: .suggested)
        XCTAssertEqual(on.last?.rows, [ShortcutRow(keys: "⌃⌥⌘L", action: "Open the log window")])
        XCTAssertEqual(ShortcutCatalog.logSheet(momentCount: 6, globalKey: .suggested).count, 2)
        XCTAssertEqual(ShortcutCatalog.dashboard(globalKey: nil).count, 1)
        // ⌘F searches the Logbook from anywhere in the dashboard; ⌃⌘F stays full screen.
        let dashboardKeys = ShortcutCatalog.dashboard(globalKey: nil).flatMap(\.rows).map(\.keys)
        XCTAssertTrue(dashboardKeys.contains("⌘F"))
        XCTAssertTrue(dashboardKeys.contains("⌃⌘F"))
        // The Logbook export for a clinic visit.
        XCTAssertTrue(dashboardKeys.contains("⇧⌘E"))
    }

    func testEveryListOffersCommandQuestionMarkAndLogging() {
        for groups in [ShortcutCatalog.popover(globalKey: nil),
                       ShortcutCatalog.logSheet(momentCount: 6, globalKey: nil),
                       ShortcutCatalog.dashboard(globalKey: nil)] {
            let keys = groups.flatMap(\.rows).map(\.keys)
            XCTAssertTrue(keys.contains { $0.contains("⌘?") })
            XCTAssertTrue(keys.contains { $0.contains("⌘L") } || keys.contains("←  →  ↑  ↓"))
        }
    }

    func testMomentShortcutRangeFollowsTheTiles() {
        let rows = ShortcutCatalog.logging(momentCount: 6).rows.map(\.keys)
        XCTAssertTrue(rows.contains("⌘1 – ⌘6"))
        XCTAssertTrue(ShortcutCatalog.logging(momentCount: 1).rows.map(\.keys).contains("⌘1"))
        XCTAssertFalse(ShortcutCatalog.logging(momentCount: 0).rows.map(\.keys).contains { $0.hasPrefix("⌘1") })
        // No row repeats its keys within a list.
        for groups in [ShortcutCatalog.popover(globalKey: .suggested), ShortcutCatalog.logSheet(momentCount: 6, globalKey: .suggested),
                       ShortcutCatalog.dashboard(globalKey: .suggested)] {
            let keys = groups.flatMap(\.rows).map(\.keys)
            XCTAssertEqual(keys.count, Set(keys).count, "\(keys)")
        }
    }

    func testPopoverListsCommandLDuringALow() {
        let rows = ShortcutCatalog.popover(globalKey: nil).flatMap(\.rows)
        XCTAssertTrue(rows.contains(ShortcutCatalog.lowTreatment))
        XCTAssertFalse(ShortcutCatalog.logSheet(momentCount: 6, globalKey: nil).flatMap(\.rows).contains(ShortcutCatalog.lowTreatment))
    }

    func testUsualKeysCoverTheFirstThreeEntries() {
        XCTAssertEqual(UsualKeys.display(for: 0), "⌥⌘1")
        XCTAssertEqual(UsualKeys.display(for: 2), "⌥⌘3")
        XCTAssertNil(UsualKeys.display(for: 3))
        XCTAssertNil(UsualKeys.digit(for: -1))
        XCTAssertEqual(UsualKeys.spoken(for: 1), "Option Command 2")
        XCTAssertNil(UsualKeys.range(count: 0))
        XCTAssertEqual(UsualKeys.range(count: 1), "⌥⌘1")
        XCTAssertEqual(UsualKeys.range(count: 2), "⌥⌘1 – ⌥⌘2")
        XCTAssertEqual(UsualKeys.range(count: 5), "⌥⌘1 – ⌥⌘3")
    }

    func testUsualKeysAreListedOnlyWhenOffered() {
        // The sheet lists them for the entries it's offering, never for none.
        let none = ShortcutCatalog.logging(momentCount: 6, usualCount: 0).rows.map(\.keys)
        XCTAssertFalse(none.contains { $0.hasPrefix("⌥⌘") })
        let two = ShortcutCatalog.logSheet(momentCount: 6, usualCount: 2, globalKey: nil).flatMap(\.rows)
        XCTAssertTrue(two.contains(ShortcutRow(keys: "⌥⌘1 – ⌥⌘2", action: "Fill in one of Your usual")))
        // The popover always lists them: its row shows up to three.
        let popover = ShortcutCatalog.popover(globalKey: nil).flatMap(\.rows).map(\.keys)
        XCTAssertTrue(popover.contains("⌥⌘1 – ⌥⌘3"))
        // ⌥⌘ digits never take ⌘1–⌘3, which stay the chart range there.
        XCTAssertTrue(popover.contains("⌘1  ⌘2  ⌘3"))
        let keys = ShortcutCatalog.logSheet(momentCount: 6, usualCount: 3, globalKey: .suggested).flatMap(\.rows).map(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testMomentCountsPerTherapyFitTheThreeWideGrid() {
        XCTAssertEqual(LogFlow.moments(logsInsulin: true, pump: false).count, 6)
        XCTAssertEqual(LogFlow.moments(logsInsulin: true, pump: true).count, 6)
        XCTAssertEqual(LogFlow.moments(logsInsulin: false, pump: false).count, 4)
    }
}
