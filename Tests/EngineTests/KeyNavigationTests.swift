import XCTest
@testable import GlucOSEngine

/// Keyboard navigation on the Mac (docs/KeyboardNavigation.md): where Tab and the arrow keys
/// take the focus ring in the menu bar popover, Insights and the Logbook.
final class KeyNavigationTests: XCTestCase {
    // The popover as it registers its stops, top to bottom, during a low with three usuals.
    private let popover: [KeyStop] = [
        KeyStop("popover.hero"),
        KeyStop("popover.lowTreat"),
        KeyStop("popover.chart"),
        KeyStop("popover.summary"),
        KeyStop("popover.usual.0", row: "popover.usual"),
        KeyStop("popover.usual.1", row: "popover.usual"),
        KeyStop("popover.usual.2", row: "popover.usual"),
        KeyStop("popover.toolbar.log", row: "popover.toolbar"),
        KeyStop("popover.toolbar.refresh", row: "popover.toolbar"),
        KeyStop("popover.toolbar.Open Dashboard", row: "popover.toolbar"),
        KeyStop("popover.toolbar.Settings…", row: "popover.toolbar"),
    ]

    private func go(_ from: String?, _ move: KeyNavigation.Move, _ stops: [KeyStop]) -> String? {
        KeyNavigation.target(from: from, move, in: stops)
    }

    // MARK: Order

    func testPopoverTabOrderIsReadingOrder() {
        XCTAssertEqual(KeyNavigation.order(popover), popover.map(\.id))
        XCTAssertEqual(KeyNavigation.rows(popover).map(\.count), [1, 1, 1, 1, 3, 4])
    }

    func testRowsAreNeighboursWithTheSameRow() {
        // The same row name further down starts a new row: rows never jump over other stops.
        let stops = [KeyStop("a", row: "r"), KeyStop("b"), KeyStop("c", row: "r")]
        XCTAssertEqual(KeyNavigation.rows(stops), [["a"], ["b"], ["c"]])
    }

    func testAStopDrawnTwiceKeepsItsFirstPlace() {
        let stops = [KeyStop("a"), KeyStop("b"), KeyStop("a")]
        XCTAssertEqual(KeyNavigation.order(stops), ["a", "b"])
    }

    // MARK: Arrows in the popover

    func testUpAndDownMoveBetweenCards() {
        XCTAssertEqual(go("popover.hero", .down, popover), "popover.lowTreat")
        XCTAssertEqual(go("popover.chart", .down, popover), "popover.summary")
        XCTAssertEqual(go("popover.summary", .up, popover), "popover.chart")
        // Never round the ends.
        XCTAssertNil(go("popover.hero", .up, popover))
        XCTAssertNil(go("popover.toolbar.refresh", .down, popover))
    }

    func testLeftAndRightMoveAlongARowAndStopAtItsEnds() {
        XCTAssertEqual(go("popover.toolbar.log", .right, popover), "popover.toolbar.refresh")
        XCTAssertEqual(go("popover.toolbar.refresh", .left, popover), "popover.toolbar.log")
        XCTAssertNil(go("popover.toolbar.log", .left, popover))
        XCTAssertNil(go("popover.toolbar.Settings…", .right, popover))
        // A card alone on its row leaves ← → alone (the chart steps through readings with them).
        XCTAssertNil(go("popover.chart", .left, popover))
        XCTAssertNil(go("popover.chart", .right, popover))
    }

    func testDownIntoARowLandsNearTheSamePlace() {
        XCTAssertEqual(go("popover.summary", .down, popover), "popover.usual.0")
        // The last usual sits over the right-hand end of the toolbar.
        XCTAssertEqual(go("popover.usual.2", .down, popover), "popover.toolbar.Settings…")
        XCTAssertEqual(go("popover.usual.0", .down, popover), "popover.toolbar.log")
        XCTAssertEqual(go("popover.usual.1", .down, popover), "popover.toolbar.Open Dashboard")
        // Up from any toolbar button to the row above, then to the one card above it.
        XCTAssertEqual(go("popover.toolbar.Settings…", .up, popover), "popover.usual.2")
        XCTAssertEqual(go("popover.usual.1", .up, popover), "popover.summary")
    }

    func testNearestColumn() {
        XCTAssertEqual(KeyNavigation.nearest(column: 0, of: 1, in: 4), 0)
        XCTAssertEqual(KeyNavigation.nearest(column: 1, of: 2, in: 3), 2)
        XCTAssertEqual(KeyNavigation.nearest(column: 0, of: 2, in: 3), 0)
        XCTAssertEqual(KeyNavigation.nearest(column: 3, of: 4, in: 1), 0)
        XCTAssertEqual(KeyNavigation.nearest(column: 12, of: 24, in: 2), 1)
    }

    func testKeysOutsideTheStopsAreLeftAlone() {
        // The cursor in a text field, or nothing focused yet: the key isn't taken.
        XCTAssertNil(go(nil, .down, popover))
        XCTAssertNil(go("logbook.search", .down, popover))
        XCTAssertNil(go("popover.hero", .down, []))
    }

    // MARK: Insights

    /// Insights as its stops come up: each card wraps what's inside it (`KeyStop.card`), as the
    /// views' preferences do.
    private var insights: [KeyStop] {
        let sides = [KeyStop("insights.weekdayWeekend.weekdays", row: "insights.weekdayWeekend.sides"),
                     KeyStop("insights.weekdayWeekend.weekends", row: "insights.weekdayWeekend.sides")]
        return [KeyStop("insights.customise")]
            + KeyStop.card(KeyStop("insights.lows"), holding: [KeyStop("insights.lows.open")])
            + KeyStop.card(KeyStop("insights.weekdayWeekend"), holding: sides)
            + KeyStop.card(KeyStop("insights.dayPattern"), holding: [])
    }

    func testInsightsOrderGoesCardThenWhatIsInside() {
        XCTAssertEqual(KeyNavigation.order(insights), [
            "insights.customise",
            "insights.lows", "insights.lows.open",
            "insights.weekdayWeekend", "insights.weekdayWeekend.weekdays", "insights.weekdayWeekend.weekends",
            "insights.dayPattern",
        ])
        XCTAssertEqual(go("insights.lows", .down, insights), "insights.lows.open")
        XCTAssertEqual(go("insights.weekdayWeekend", .down, insights), "insights.weekdayWeekend.weekdays")
        XCTAssertEqual(go("insights.weekdayWeekend.weekdays", .right, insights), "insights.weekdayWeekend.weekends")
        XCTAssertEqual(go("insights.weekdayWeekend.weekends", .down, insights), "insights.dayPattern")
    }

    func testReturnOnACardGoesIntoIt() {
        XCTAssertEqual(KeyNavigation.firstInside("insights.lows", in: insights), "insights.lows.open")
        XCTAssertEqual(KeyNavigation.firstInside("insights.weekdayWeekend", in: insights), "insights.weekdayWeekend.weekdays")
        XCTAssertNil(KeyNavigation.firstInside("insights.dayPattern", in: insights))
        XCTAssertNil(KeyNavigation.firstInside("insights.customise", in: insights))
    }

    func testACardInsideACardKeepsItsNearerParent() {
        let inner = KeyStop.card(KeyStop("b"), holding: [KeyStop("c")])
        let outer = KeyStop.card(KeyStop("a"), holding: inner)
        XCTAssertEqual(outer.map(\.parent), [nil, "a", "b"])
        XCTAssertEqual(KeyNavigation.firstInside("a", in: outer), "b")
    }

    // MARK: Logbook

    func testLogbookBarsAreRowsAboveTheTable() {
        let stops = [
            KeyStop("logbook.back"),
            KeyStop("logbook.search", row: "logbook.searchBar", keeps: [.left, .right]),
            KeyStop("logbook.calendar", row: "logbook.searchBar"),
            KeyStop("logbook.edit", row: "logbook.searchBar"),
            KeyStop("logbook.filter", row: "logbook.filters"),
            KeyStop("logbook.alerts", row: "logbook.filters"),
            KeyStop("logbook.tag.Exercise", row: "logbook.filters"),
            KeyStop("logbook.table", keeps: [.up, .down, .left, .right]),
        ]
        XCTAssertEqual(go("logbook.back", .down, stops), "logbook.search")
        XCTAssertEqual(go("logbook.edit", .down, stops), "logbook.tag.Exercise")
        XCTAssertEqual(go("logbook.alerts", .down, stops), "logbook.table")
        XCTAssertEqual(go("logbook.filter", .right, stops), "logbook.alerts")
        XCTAssertEqual(go("logbook.calendar", .left, stops), "logbook.search")
        // The search field keeps ← → for its cursor; ↓ still leaves it.
        XCTAssertNil(go("logbook.search", .right, stops))
        XCTAssertEqual(go("logbook.search", .down, stops), "logbook.filter")
        // The table keeps every arrow for its rows: ↑ on it never jumps to the filter bar.
        for move in KeyNavigation.Move.allCases { XCTAssertNil(go("logbook.table", move, stops)) }
    }

    // MARK: When the ring shows

    func testRingShowsForTheKeyboardAndHidesOnAClick() {
        XCTAssertEqual(FocusRingVisibility.after(.key(48)), true)    // Tab
        XCTAssertEqual(FocusRingVisibility.after(.key(125)), true)   // ↓
        XCTAssertEqual(FocusRingVisibility.after(.click), false)
        // Typing, Return and ⌘-shortcuts leave it as it is.
        XCTAssertNil(FocusRingVisibility.after(.key(0)))             // A
        XCTAssertNil(FocusRingVisibility.after(.key(36)))            // Return
        XCTAssertNil(FocusRingVisibility.after(.key(123), modifiers: true))  // ⌘←
    }

    // MARK: Lists

    func testShortcutListsSayHowToMoveRound() {
        for groups in [ShortcutCatalog.popover(globalKey: nil), ShortcutCatalog.dashboard(globalKey: nil)] {
            let nav = groups.first { $0.title == "Moving around" }
            XCTAssertNotNil(nav)
            XCTAssertTrue(nav?.rows.contains { $0.keys.hasPrefix("Tab") } ?? false)
            XCTAssertTrue(nav?.rows.contains { $0.keys.hasPrefix("Esc") } ?? false)
            XCTAssertTrue(nav?.rows.contains { $0.keys.hasPrefix("Return") } ?? false)
        }
        // The log sheet keeps its own keys only.
        XCTAssertFalse(ShortcutCatalog.logSheet(momentCount: 6, globalKey: nil).contains { $0.title == "Moving around" })
    }

    func testSettingsListHasEveryGroupOnce() {
        let all = ShortcutCatalog.all(momentCount: 6, globalKey: .suggested)
        XCTAssertEqual(all.map(\.title), ["Moving around", "Menu bar", "Dashboard", "Logging", "From any app"])
        XCTAssertNil(ShortcutCatalog.all(momentCount: 6, globalKey: nil).first { $0.title == "From any app" })
        // No group repeats its keys, and ⌘? (which only shows the list in place) isn't in it.
        for group in all {
            let keys = group.rows.map(\.keys)
            XCTAssertEqual(keys.count, Set(keys).count, group.title)
        }
        XCTAssertFalse(all.first { $0.title == "Menu bar" }!.rows.contains(ShortcutCatalog.showList))
    }
}
