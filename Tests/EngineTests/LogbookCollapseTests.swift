import XCTest
@testable import GlucOSEngine

/// Folding Logbook days (`LogbookCollapse`, `LogbookFolds`, `LogbookFolding`): kept per device,
/// today never starts folded, a search has its own folds, and a jump reopens its day.
final class LogbookCollapseTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    /// Local midnight `daysAgo` days before 17 Nov 2026 in Perth.
    private func day(_ daysAgo: Int) -> Date {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        return calendar.date(byAdding: .day, value: -daysAgo, to: today)!
    }

    private var now: Date { day(0).addingTimeInterval(14 * 3600) }

    private func id(_ daysAgo: Int) -> String { LogbookCollapse.id(day(daysAgo)) }

    func testIDMatchesThePhoneDayID() {
        let start = day(3)
        XCTAssertEqual(LogbookCollapse.id(start), "\(Int(start.timeIntervalSince1970))")
        XCTAssertEqual(LogbookCollapse.id(of: start.addingTimeInterval(9 * 3600 + 12), calendar: calendar), id(3))
    }

    func testRoundTripsThroughStoredText() {
        let c = LogbookCollapse(days: [id(4), id(1), id(9)])
        XCTAssertEqual(c.stored, [id(9), id(4), id(1)].joined(separator: ","))
        XCTAssertEqual(LogbookCollapse.restored(c.stored, now: now, calendar: calendar), c)
    }

    func testTodayNeverStartsFolded() {
        let stored = [id(2), id(0)].joined(separator: ",")
        let restored = LogbookCollapse.restored(stored, now: now, calendar: calendar)
        XCTAssertFalse(restored.isFolded(id(0)))
        XCTAssertTrue(restored.isFolded(id(2)))
    }

    func testOldFutureAndJunkDropped() {
        let future = LogbookCollapse.id(calendar.date(byAdding: .day, value: 2, to: day(0))!)
        let stored = [id(LogbookCollapse.keepDays + 1), id(LogbookCollapse.keepDays), "pizza", "", future, id(1)]
            .joined(separator: ",")
        let restored = LogbookCollapse.restored(stored, now: now, calendar: calendar)
        XCTAssertEqual(restored.days, [id(LogbookCollapse.keepDays), id(1)])
    }

    func testEmptyStoredIsNothingFolded() {
        XCTAssertTrue(LogbookCollapse.restored("", now: now, calendar: calendar).days.isEmpty)
    }

    func testToggleFoldsThenOpens() {
        let c = LogbookCollapse()
        let folded = c.toggled(id(1))
        XCTAssertTrue(folded.isFolded(id(1)))
        XCTAssertFalse(folded.toggled(id(1)).isFolded(id(1)))
        XCTAssertEqual(folded.reopened(id(1)), c)
        XCTAssertEqual(c.reopened(id(1)), c)
    }

    func testTodayCanBeFoldedForNow() {
        var folds = LogbookFolds()
        XCTAssertTrue(folds.toggle(id(0), searching: false))
        XCTAssertTrue(folds.isFolded(id(0), searching: false))
        // ...but the next time the Logbook opens it's open again.
        XCTAssertFalse(LogbookCollapse.restored(folds.kept.stored, now: now, calendar: calendar).isFolded(id(0)))
    }

    func testSearchStartsWithEveryDayOpenAndLeavesKeptFoldsAlone() {
        var folds = LogbookFolds(kept: LogbookCollapse(days: [id(1), id(2)]))
        XCTAssertFalse(folds.isFolded(id(1), searching: true))
        XCTAssertTrue(folds.toggle(id(3), searching: true))
        XCTAssertTrue(folds.isFolded(id(3), searching: true))
        XCTAssertFalse(folds.isFolded(id(3), searching: false))
        XCTAssertEqual(folds.kept.days, [id(1), id(2)])
        folds.endSearch()
        XCTAssertFalse(folds.isFolded(id(3), searching: true))
        XCTAssertTrue(folds.isFolded(id(1), searching: false))
    }

    func testJumpReopensTheDayEverywhere() {
        var folds = LogbookFolds(kept: LogbookCollapse(days: [id(1), id(5)]), search: LogbookCollapse(days: [id(5)]))
        folds.reopen(id(5))
        XCTAssertFalse(folds.isFolded(id(5), searching: false))
        XCTAssertFalse(folds.isFolded(id(5), searching: true))
        XCTAssertTrue(folds.isFolded(id(1), searching: false))
    }

    func testCountsByDay() {
        let rows: [(Date, Bool)] = [
            (day(0).addingTimeInterval(3600 * 9), false),
            (day(0).addingTimeInterval(3600 * 8), true),
            (day(1).addingTimeInterval(3600 * 23.9), false),
            (day(1).addingTimeInterval(60), false),
        ]
        let c = LogbookFolding.counts(rows, timestamp: \.0, isAlert: \.1, calendar: calendar)
        XCTAssertEqual(c[day(0)], LogbookDayCount(entries: 1, alerts: 1))
        XCTAssertEqual(c[day(1)], LogbookDayCount(entries: 2, alerts: 0))
        XCTAssertNil(c[day(2)])
    }

    func testFoldSwapsAFoldedDayForOneLineInPlace() {
        // Newest first: two today, three yesterday, one the day before.
        let times: [Date] = [
            day(0).addingTimeInterval(3600 * 10), day(0).addingTimeInterval(3600 * 7),
            day(1).addingTimeInterval(3600 * 20), day(1).addingTimeInterval(3600 * 12), day(1).addingTimeInterval(3600),
            day(2).addingTimeInterval(3600 * 15),
        ]
        let lines = times.enumerated().map { "row\($0.offset)@\($0.element.timeIntervalSince1970)" }
        let stamp: (String) -> Date = { Date(timeIntervalSince1970: Double($0.split(separator: "@")[1])!) }
        let folded = LogbookFolding.fold(lines, timestamp: stamp, isFolded: { $0 == self.id(1) },
                                         folded: { "folded@\($0.timeIntervalSince1970)" }, calendar: calendar)
        XCTAssertEqual(folded.count, 4)
        XCTAssertEqual(Array(folded.prefix(2)), Array(lines.prefix(2)))
        XCTAssertEqual(folded[2], "folded@\(day(1).timeIntervalSince1970)")
        XCTAssertEqual(folded[3], lines[5])
    }

    func testFoldWithNothingFoldedChangesNothing() {
        let lines = [day(0), day(1)].map { $0.addingTimeInterval(3600) }
        XCTAssertEqual(LogbookFolding.fold(lines, timestamp: { $0 }, isFolded: { _ in false }, folded: { $0 },
                                           calendar: calendar), lines)
    }

    func testLineIDIsStableAndPerDay() {
        XCTAssertEqual(LogbookFolding.lineID(day(1)), LogbookFolding.lineID(day(1)))
        XCTAssertNotEqual(LogbookFolding.lineID(day(1)), LogbookFolding.lineID(day(2)))
    }

    func testCountText() {
        XCTAssertEqual(LogbookCollapseText.count(LogbookDayCount(entries: 4, alerts: 0)), "4 entries")
        XCTAssertEqual(LogbookCollapseText.count(LogbookDayCount(entries: 1, alerts: 2)), "1 entry · 2 alerts")
        XCTAssertEqual(LogbookCollapseText.count(LogbookDayCount(entries: 0, alerts: 1)), "1 alert")
        XCTAssertEqual(LogbookCollapseText.count(LogbookDayCount()), "0 entries")
        XCTAssertEqual(LogbookCollapseText.spokenCount(LogbookDayCount(entries: 2, alerts: 1)), "2 entries, 1 alert")
    }

    func testSpokenState() {
        XCTAssertEqual(LogbookCollapseText.spokenState(folded: true), "Collapsed")
        XCTAssertEqual(LogbookCollapseText.spokenState(folded: false), "Expanded")
        XCTAssertEqual(LogbookCollapseText.actionName(folded: true), "Expand Day")
        XCTAssertEqual(LogbookCollapseText.actionName(folded: false), "Collapse Day")
        XCTAssertEqual(LogbookCollapseText.announcement(day: "Yesterday", folded: true,
                                                        count: LogbookDayCount(entries: 3, alerts: 0)),
                       "Yesterday collapsed, 3 entries")
        XCTAssertEqual(LogbookCollapseText.announcement(day: "Yesterday", folded: false, count: LogbookDayCount()),
                       "Yesterday expanded")
    }
}
