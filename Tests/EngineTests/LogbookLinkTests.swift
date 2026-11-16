import XCTest
@testable import GlucOSEngine

/// Opening the Logbook from the Insights Lows card (docs/LogbookSearch.md, "From the Lows card").
final class LogbookLinkTests: XCTestCase {
    /// Wednesday 25 November 2026, 2 pm in Perth.
    private let now = Date(timeIntervalSince1970: 1_795_586_400)

    private func dose(at date: Date) -> LogEntry {
        .dose(InsulinDose(timestamp: date, units: 2, kind: .rapid, name: "NovoRapid", note: ""))
    }

    func testTheLinkCoversTheSameDaysTheCardCounted() {
        let newest = now.addingTimeInterval(-10 * 60)
        for period in LowsSummary.Period.allCases {
            let link = LogbookLink.lows(period, newestReading: newest, now: now)
            XCTAssertEqual(link.filter, .lows)
            XCTAssertEqual(link.period.interval.start, newest.addingTimeInterval(-Double(period.days) * 86_400))
            XCTAssertEqual(link.period.interval.end, now)
            XCTAssertEqual(link.period.label, "Last \(period.days) days")
            XCTAssertEqual(link.period.phrase, "in the last \(period.days) days")
        }
    }

    func testAnEarlyLowOnTheFirstDayIsNotCutOffAtMidnight() {
        // 14 × 24 h back from 1:50 pm starts at 1:50 pm; "last 14 days" typed would start at midnight
        // 13 days ago and miss the morning of the 14th day back.
        let link = LogbookLink.lows(.fortnight, newestReading: now.addingTimeInterval(-600), now: now)
        let earlyOnDay14 = now.addingTimeInterval(-14 * 86_400 + 3_600)
        XCTAssertTrue(link.period.interval.contains(earlyOnDay14))
        XCTAssertFalse(link.period.interval.contains(now.addingTimeInterval(-15 * 86_400)))
    }

    func testWithNoReadingsItRunsBackFromNow() {
        let link = LogbookLink.lows(.week, newestReading: nil, now: now)
        XCTAssertEqual(link.period.interval, DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
    }

    func testATreatmentLoggedAfterTheLastReadingStillShows() {
        let link = LogbookLink.lows(.week, newestReading: now.addingTimeInterval(-3 * 3_600), now: now)
        let query = LogbookQuery.parse("", now: now).linked(link.period)
        XCTAssertTrue(LogbookSearch.matches(dose(at: now.addingTimeInterval(-600)), query))
    }

    func testTheLinkedPeriodNarrowsTheSearchUntilADayIsTyped() {
        let link = LogbookLink.lows(.week, newestReading: now, now: now)
        let blank = LogbookQuery.parse("", now: now).linked(link.period)
        XCTAssertEqual(blank.period, link.period)
        XCTAssertFalse(blank.isEmpty)
        XCTAssertFalse(LogbookSearch.matches(dose(at: now.addingTimeInterval(-8 * 86_400)), blank))
        XCTAssertTrue(LogbookSearch.matches(dose(at: now.addingTimeInterval(-6 * 86_400)), blank))

        let words = LogbookQuery.parse("novorapid", now: now).linked(link.period)
        XCTAssertEqual(words.terms, ["novorapid"])
        XCTAssertEqual(words.period, link.period)

        let typedDay = LogbookQuery.parse("yesterday", now: now)
        XCTAssertEqual(typedDay.linked(link.period), typedDay)
        XCTAssertEqual(LogbookQuery.parse("", now: now).linked(nil), LogbookQuery.parse("", now: now))
    }

    func testTheZoomSourceStaysPutWhenThePeriodMovesOn() {
        let a = LogbookLink.lows(.week, newestReading: now, now: now)
        let b = LogbookLink.lows(.month, newestReading: now.addingTimeInterval(300), now: now.addingTimeInterval(300))
        XCTAssertEqual(a.sourceID, b.sourceID)
        XCTAssertEqual(a.sourceID, LogbookLink.sourceID(for: .lows))
        XCTAssertNotEqual(a, b)
    }

    func testTheMacSearchesPastTheToolbarPeriodWhenLinked() {
        let link = LogbookLink.lows(.month, newestReading: now, now: now)
        let q = LogbookQuery.parse("", now: now).linked(link.period)
        XCTAssertTrue(LogbookSearch.looksPastToolbarPeriod(q, allDates: false))
        // Nothing found under Lows: "Search All Dates" is offered, as for a typed day.
        XCTAssertTrue(LogbookSearch.offersAllDates(q, filter: .lows, allDates: false))
        XCTAssertEqual(LogbookSearch.noMatchMessage(q, filter: .lows), "Nothing in Lows in the last 30 days.")
    }
}

extension LogbookLinkTests {
    func testTheCardRowSaysWhereItGoes() {
        XCTAssertEqual(LowsSummaryText.logbookLine(.fortnight), "See the last 14 days in the Logbook")
        XCTAssertEqual(LowsSummaryText.logbookHint, "Opens the Logbook on Lows over the same days")
    }
}
