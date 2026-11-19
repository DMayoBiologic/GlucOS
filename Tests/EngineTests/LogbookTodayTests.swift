import XCTest
@testable import GlucOSEngine

final class LogbookTodayTests: XCTestCase {
    private var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        gmt.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testShowsOnlyOnceWellAwayFromTheTop() {
        // An 800 pt list: shows past 640, hides again back within 320.
        XCTAssertFalse(LogbookToday.shows(offset: 0, viewport: 800, showing: false))
        XCTAssertFalse(LogbookToday.shows(offset: 600, viewport: 800, showing: false))
        XCTAssertTrue(LogbookToday.shows(offset: 641, viewport: 800, showing: false))
        // Between the lines it keeps whatever it's doing, so it never blinks.
        XCTAssertTrue(LogbookToday.shows(offset: 400, viewport: 800, showing: true))
        XCTAssertFalse(LogbookToday.shows(offset: 400, viewport: 800, showing: false))
        XCTAssertFalse(LogbookToday.shows(offset: 320, viewport: 800, showing: true))
    }

    func testShortScreensStillNeedARealScroll() {
        XCTAssertFalse(LogbookToday.shows(offset: 300, viewport: 200, showing: false))
        XCTAssertTrue(LogbookToday.shows(offset: 361, viewport: 200, showing: false))
        XCTAssertTrue(LogbookToday.shows(offset: 181, viewport: 200, showing: true))
        XCTAssertFalse(LogbookToday.shows(offset: 180, viewport: 200, showing: true))
        // A zero height (before layout) never divides by nothing or shows at the top.
        XCTAssertFalse(LogbookToday.shows(offset: 0, viewport: 0, showing: false))
    }

    func testHideLineIsAlwaysBelowShowLine() {
        for viewport in stride(from: 0.0, through: 3000, by: 50) {
            let on = (0...5000).first { LogbookToday.shows(offset: Double($0), viewport: viewport, showing: false) }!
            let off = (0...5000).first { LogbookToday.shows(offset: Double($0), viewport: viewport, showing: true) }!
            XCTAssertLessThan(off, on, "viewport \(viewport)")
        }
    }

    func testTargetIsTheNewestListedDay() {
        XCTAssertNil(LogbookToday.target(shownDays: [Date]()))
        XCTAssertEqual(LogbookToday.target(shownDays: [at(2026, 11, 17), at(2026, 11, 19), at(2026, 11, 18)]),
                       at(2026, 11, 19))
    }

    func testTitleSaysTodayOrLatest() {
        let now = at(2026, 11, 19, 14)
        XCTAssertEqual(LogbookToday.title(target: at(2026, 11, 19), now: now, calendar: gmt), "Today")
        XCTAssertEqual(LogbookToday.title(target: nil, now: now, calendar: gmt), "Today")
        XCTAssertEqual(LogbookToday.title(target: at(2026, 11, 18), now: now, calendar: gmt), "Latest")
    }

    func testOneVoiceOverLabel() {
        let now = at(2026, 11, 19, 14)
        XCTAssertEqual(LogbookToday.accessibilityLabel(target: at(2026, 11, 19), now: now, calendar: gmt), "Back to today")
        XCTAssertEqual(LogbookToday.accessibilityLabel(target: at(2026, 11, 16), now: now, calendar: gmt),
                       "Back to the latest entries")
        XCTAssertEqual(LogbookToday.macHelp, "Back to today (⌘T)")
    }

    func testTopRequestsAreTheirOwnKind() {
        let day = at(2026, 11, 19)
        XCTAssertFalse(LogbookJumpRequest(day: day).toTop)
        XCTAssertTrue(LogbookJumpRequest(day: day, toTop: true).toTop)
        // A fresh token each tap, so tapping again still moves the list.
        XCTAssertNotEqual(LogbookJumpRequest(day: day, toTop: true), LogbookJumpRequest(day: day, toTop: true))
    }

    func testMacShortcutListNamesCommandT() {
        let rows = ShortcutCatalog.dashboard(globalKey: nil).flatMap(\.rows)
        XCTAssertEqual(rows.filter { $0.keys == "⌘T" }.map(\.action), ["In the Logbook: back to today"])
    }
}
