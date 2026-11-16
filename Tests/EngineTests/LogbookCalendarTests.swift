import XCTest
@testable import GlucOSEngine

final class LogbookCalendarTests: XCTestCase {
    // referenceNow is Monday 21 September 2026, 14:00 UTC. 1 September 2026 is a Tuesday.
    private let en = Locale(identifier: "en_AU")

    private func cal(firstWeekday: Int) -> Calendar {
        var c = utc
        c.firstWeekday = firstWeekday
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testCountsGroupByLocalDay() {
        let c = LogbookCalendar.counts([day(2026, 9, 3).addingTimeInterval(3600),
                                        day(2026, 9, 3).addingTimeInterval(23 * 3600),
                                        day(2026, 9, 4).addingTimeInterval(60)], calendar: utc)
        XCTAssertEqual(c[day(2026, 9, 3)], 2)
        XCTAssertEqual(c[day(2026, 9, 4)], 1)
        XCTAssertNil(c[day(2026, 9, 5)])
    }

    func testGridSitsUnderItsWeekday() {
        let monday = LogbookCalendar.month(referenceNow, counts: [:], now: referenceNow,
                                           calendar: cal(firstWeekday: 2), locale: en)
        XCTAssertEqual(monday.leadingBlanks, 1)
        XCTAssertEqual(monday.cells.count, 30)
        XCTAssertEqual(monday.weekdays.count, 7)
        XCTAssertEqual(monday.weekdays.first?.first, "M")
        let sunday = LogbookCalendar.month(referenceNow, counts: [:], now: referenceNow,
                                           calendar: cal(firstWeekday: 1), locale: en)
        XCTAssertEqual(sunday.leadingBlanks, 2)
        XCTAssertEqual(sunday.weekdays.first?.first, "S")
        XCTAssertTrue(sunday.title.contains("2026"))
    }

    func testOnlyDaysWithEntriesCanBePicked() {
        let counts = [day(2026, 9, 3): 2, day(2026, 9, 21): 1]
        let m = LogbookCalendar.month(referenceNow, counts: counts, now: referenceNow, calendar: utc, locale: en)
        let picked = m.cells.filter(\.canPick).map(\.number)
        XCTAssertEqual(picked, [3, 21])
        XCTAssertTrue(m.cells[20].isToday)
        XCTAssertTrue(m.cells[21].isFuture)
        XCTAssertFalse(m.cells[19].isFuture)
    }

    func testMonthLimitsRunFromFirstEntryToNow() {
        let counts = [day(2026, 7, 30): 1, day(2026, 9, 1): 1]
        let now = LogbookCalendar.month(referenceNow, counts: counts, now: referenceNow, calendar: utc, locale: en)
        XCTAssertTrue(now.hasEarlier)
        XCTAssertFalse(now.hasLater)
        let july = LogbookCalendar.month(day(2026, 7, 4), counts: counts, now: referenceNow, calendar: utc, locale: en)
        XCTAssertFalse(july.hasEarlier)
        XCTAssertTrue(july.hasLater)
        let empty = LogbookCalendar.month(referenceNow, counts: [:], now: referenceNow, calendar: utc, locale: en)
        XCTAssertFalse(empty.hasEarlier)
    }

    func testShiftCrossesYears() {
        XCTAssertEqual(LogbookCalendar.shifted(day(2026, 1, 20), by: -1, calendar: utc), day(2025, 12, 1))
        XCTAssertEqual(LogbookCalendar.shifted(day(2025, 12, 31), by: 1, calendar: utc), day(2026, 1, 1))
    }

    func testLatestDay() {
        XCTAssertEqual(LogbookCalendar.latestDay([day(2026, 9, 1): 1, day(2026, 9, 9): 3, day(2026, 9, 12): 0]),
                       day(2026, 9, 9))
        XCTAssertNil(LogbookCalendar.latestDay([:]))
    }

    func testPlan() {
        let counts = [day(2026, 9, 3): 2, day(2026, 9, 4): 1]
        let shown: Set<Date> = [day(2026, 9, 3)]
        XCTAssertEqual(LogbookJump.plan(day: day(2026, 9, 3).addingTimeInterval(5000), shownDays: shown,
                                        counts: counts, calendar: utc), .scroll(day(2026, 9, 3)))
        XCTAssertEqual(LogbookJump.plan(day: day(2026, 9, 4), shownDays: shown, counts: counts, calendar: utc),
                       .clearFiltersThenScroll(day(2026, 9, 4)))
        XCTAssertEqual(LogbookJump.plan(day: day(2026, 9, 5), shownDays: shown, counts: counts, calendar: utc), .none)
    }

    func testSectionIDMatchesPhoneDays() {
        XCTAssertEqual(LogbookJump.sectionID(Date(timeIntervalSince1970: 1_789_948_800)), "1789948800")
    }

    func testSpoken() {
        let m = LogbookCalendar.month(referenceNow, counts: [day(2026, 9, 8): 3, day(2026, 9, 9): 1],
                                      now: referenceNow, calendar: utc, locale: en)
        let name = { (d: Date) in DayInRangeText.spokenDay(.other(d), calendar: utc, locale: self.en) }
        XCTAssertEqual(LogbookJump.spoken(m.cells[7], now: referenceNow, calendar: utc, locale: en),
                       name(day(2026, 9, 8)) + ", 3 entries")
        XCTAssertEqual(LogbookJump.spoken(m.cells[8], now: referenceNow, calendar: utc, locale: en),
                       name(day(2026, 9, 9)) + ", 1 entry")
        XCTAssertEqual(LogbookJump.spoken(m.cells[9], now: referenceNow, calendar: utc, locale: en),
                       name(day(2026, 9, 10)) + ", nothing logged")
        XCTAssertEqual(LogbookJump.spoken(m.cells[20], now: referenceNow, calendar: utc, locale: en),
                       "Today, nothing logged")
        XCTAssertEqual(LogbookJump.spoken(m.cells[25], now: referenceNow, calendar: utc, locale: en),
                       name(day(2026, 9, 26)))
        XCTAssertEqual(LogbookJump.announcement(day(2026, 9, 20), now: referenceNow, calendar: utc, locale: en),
                       "Showing Yesterday")
    }

    func testEachPickIsANewRequest() {
        XCTAssertNotEqual(LogbookJumpRequest(day: day(2026, 9, 3)), LogbookJumpRequest(day: day(2026, 9, 3)))
    }
}
