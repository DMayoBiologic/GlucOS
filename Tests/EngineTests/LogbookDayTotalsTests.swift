import XCTest
@testable import GlucOSEngine

final class LogbookDayTotalsTests: XCTestCase {
    private let base = LogbookDayTotals(units: 14, carbs: 120, entries: 4)

    func testFirstSightAndSameTotalsDoNotRoll() {
        XCTAssertEqual(DayTotalsRoll.between(nil, base, reduceMotion: false), .none)
        XCTAssertEqual(DayTotalsRoll.between(base, base, reduceMotion: false), .none)
        XCTAssertFalse(DayTotalsRoll.none.announces)
    }

    func testAddedEntryRollsUp() {
        let added = LogbookDayTotals(units: 18, carbs: 120, entries: 5)
        XCTAssertEqual(DayTotalsRoll.between(base, added, reduceMotion: false), .roll(countsDown: false))
        XCTAssertTrue(DayTotalsRoll.roll(countsDown: false).announces)
    }

    func testDeletedEntryRollsDown() {
        let deleted = LogbookDayTotals(units: 14, carbs: 75, entries: 3)
        XCTAssertEqual(DayTotalsRoll.between(base, deleted, reduceMotion: false), .roll(countsDown: true))
    }

    func testEditKeepsCountAndFollowsCarbsThenUnits() {
        XCTAssertEqual(DayTotalsRoll.between(base, LogbookDayTotals(units: 20, carbs: 100, entries: 4), reduceMotion: false),
                       .roll(countsDown: true))
        XCTAssertEqual(DayTotalsRoll.between(base, LogbookDayTotals(units: 12, carbs: 120, entries: 4), reduceMotion: false),
                       .roll(countsDown: true))
        XCTAssertEqual(DayTotalsRoll.between(base, LogbookDayTotals(units: 15, carbs: 120, entries: 4), reduceMotion: false),
                       .roll(countsDown: false))
    }

    func testReduceMotionIsInstantButStillAnnounces() {
        let changed = LogbookDayTotals(units: 4, carbs: 0, entries: 1)
        XCTAssertEqual(DayTotalsRoll.between(base, changed, reduceMotion: true), .instant)
        XCTAssertTrue(DayTotalsRoll.instant.announces)
        XCTAssertEqual(DayTotalsRoll.between(base, base, reduceMotion: true), .none)
    }

    func testSummaryAndAnnouncement() {
        XCTAssertEqual(DayTotalsText.summary(base), "14 units, 120 grams of carbs, 4 entries")
        XCTAssertEqual(DayTotalsText.summary(LogbookDayTotals(units: 1, carbs: 0, entries: 1)), "1 unit, 1 entry")
        XCTAssertEqual(DayTotalsText.summary(LogbookDayTotals(units: 0, carbs: 0, entries: 0)), "no entries")
        XCTAssertEqual(DayTotalsText.summary(LogbookDayTotals(units: 4.5, carbs: 32.25, entries: 2)),
                       "4.5 units, 32.25 grams of carbs, 2 entries")
        XCTAssertEqual(DayTotalsText.announcement(day: "Today", base), "Today now 14 units, 120 grams of carbs, 4 entries")
    }

    func testNumberDropsTrailingZeros() {
        XCTAssertEqual(DayTotalsText.number(4), "4")
        XCTAssertEqual(DayTotalsText.number(4.5), "4.5")
        XCTAssertEqual(DayTotalsText.number(0.35), "0.35")
        XCTAssertEqual(DayTotalsText.number(2.004), "2")
    }

    func testMemoryGivesBackWhatWasShown() {
        let m = DayTotalsMemory()
        XCTAssertNil(m.record("d", totals: base, text: "14 u · 120 g carbs"))
        XCTAssertEqual(m.lastText("d"), "14 u · 120 g carbs")
        let next = LogbookDayTotals(units: 18, carbs: 120, entries: 5)
        XCTAssertEqual(m.record("d", totals: next, text: "18 u · 120 g carbs"), base)
        XCTAssertEqual(m.lastTotals("d"), next)
        // A rebuilt copy of the header sees the same totals: nothing to roll or say again.
        XCTAssertEqual(DayTotalsRoll.between(m.record("d", totals: next, text: "18 u · 120 g carbs"), next,
                                             reduceMotion: false), .none)
        XCTAssertNil(m.lastText("other"))
    }

    func testAnnouncementsAreSpacedOut() {
        let m = DayTotalsMemory()
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(m.mayAnnounce(at: t))
        XCTAssertFalse(m.mayAnnounce(at: t.addingTimeInterval(0.5)))
        XCTAssertTrue(m.mayAnnounce(at: t.addingTimeInterval(DayTotalsMemory.announceGap + 0.1)))
    }

    func testBarRemembersItsLastSplit() {
        let d = DrawnOnce()
        XCTAssertNil(d.lastFigures("d"))
        let f = DayInRange(below: 0.1, inRange: 0.8, above: 0.1)
        d.remember("d", f)
        XCTAssertEqual(d.lastFigures("d"), f)
    }
}
