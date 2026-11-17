import XCTest
@testable import GlucOSEngine

/// What an empty Insights card or Logbook search says, and its one button (docs/EmptyStates.md).
final class EmptyStateTests: XCTestCase {
    // MARK: Insights cards fed by readings

    func testNoReadingsSaysSoWithoutAButton() {
        let s = InsightsEmptyState.readings(daysSoFar: 0, needed: 3, waiting: "Waiting.", currentDays: 14,
                                            longerWithData: 30)
        XCTAssertEqual(s.reason, .noReadings)
        XCTAssertNil(s.action)
        XCTAssertNil(s.actionTitle)
    }

    func testALongerPeriodWithFiguresIsOffered() {
        let s = InsightsEmptyState.readings(daysSoFar: 9, needed: 3, waiting: "Waiting.", currentDays: 7,
                                            longerWithData: 14)
        XCTAssertEqual(s.reason, .tryLonger(days: 14))
        XCTAssertEqual(s.action, .showPeriod(days: 14))
        XCTAssertEqual(s.actionTitle, "Show 14 Days")
        XCTAssertEqual(s.title, "Not enough in 7 days")
    }

    func testAShorterOrSamePeriodIsNeverOffered() {
        for longer in [7, 3] {
            let s = InsightsEmptyState.readings(daysSoFar: 2, needed: 3, waiting: "Waiting.", currentDays: 7,
                                                longerWithData: longer)
            XCTAssertEqual(s.reason, .gathering(daysSoFar: 2, needed: 3))
            XCTAssertNil(s.action)
        }
    }

    func testGatheringCountsTheDaysSoFar() {
        let s = InsightsEmptyState.readings(daysSoFar: 1, needed: 3, waiting: "Streaks show here soon.",
                                            currentDays: nil, longerWithData: nil)
        XCTAssertEqual(s.reason, .gathering(daysSoFar: 1, needed: 3))
        XCTAssertEqual(s.message, "Streaks show here soon. So far: 1 day of 3.")
        XCTAssertNil(s.action)
    }

    func testGatheringWithEnoughDaysKeepsTheCardsOwnLine() {
        // Enough days with a reading, but too thin for the card: no "so far" count that looks done.
        let s = InsightsEmptyState.readings(daysSoFar: 5, needed: 3, waiting: "Nights show here soon.",
                                            currentDays: 30, longerWithData: nil)
        XCTAssertEqual(s.message, "Nights show here soon.")
    }

    func testACardWithoutAPeriodNeverOffersOne() {
        let s = InsightsEmptyState.readings(daysSoFar: 2, needed: 4, waiting: "Waiting.", currentDays: nil,
                                            longerWithData: 30)
        XCTAssertEqual(s.reason, .gathering(daysSoFar: 2, needed: 4))
        XCTAssertEqual(s.message, "Waiting. So far: 2 days of 4.")
    }

    // MARK: The Tags card

    func testTagsOfferALongerPeriodFirst() {
        let s = InsightsEmptyState.tags(currentDays: 7, longerWithTags: 30, canLog: true)
        XCTAssertEqual(s.action, .showPeriod(days: 30))
        XCTAssertEqual(s.actionTitle, "Show 30 Days")
    }

    func testTagsFallBackToLogSomething() {
        let s = InsightsEmptyState.tags(currentDays: 14, longerWithTags: nil, canLog: true)
        XCTAssertEqual(s.reason, .nothingTagged(days: 14))
        XCTAssertEqual(s.action, .log)
        XCTAssertEqual(s.actionTitle, "Log Something")
    }

    func testTagsWithoutALogSheetHaveNoButton() {
        let s = InsightsEmptyState.tags(currentDays: 14, longerWithTags: nil, canLog: false)
        XCTAssertNil(s.action)
    }

    // MARK: Helpers

    func testLongerPeriodsAreShortestFirst() {
        XCTAssertEqual(InsightsEmptyState.longer(than: 7, in: [30, 7, 14]), [14, 30])
        XCTAssertEqual(InsightsEmptyState.longer(than: 30, in: [7, 14, 30]), [])
    }

    func testFirstWithDataStopsAtTheFirstHit() {
        var asked: [Int] = []
        let hit = InsightsEmptyState.firstWithData([30, 14]) { days in
            asked.append(days)
            return true
        }
        XCTAssertEqual(hit, 14)
        XCTAssertEqual(asked, [14])
        XCTAssertNil(InsightsEmptyState.firstWithData([14, 30]) { _ in false })
    }

    func testReadingDaysCountsLocalDaysWithAReading() {
        let day = 86_400.0
        let start = utc.startOfDay(for: referenceNow)
        let rs = [
            reading(start.addingTimeInterval(-2 * day + 60), 110),
            reading(start.addingTimeInterval(-2 * day + 3600), 112),
            reading(start.addingTimeInterval(-day + 60), 0),          // a gap marker doesn't count
            reading(start.addingTimeInterval(60), 120),
            reading(start.addingTimeInterval(day - 60), 125),
        ]
        XCTAssertEqual(InsightsEmptyState.readingDays(rs, calendar: utc), 2)
        XCTAssertEqual(InsightsEmptyState.readingDays([], calendar: utc), 0)
    }

    func testReadingDaysCopesWithUnsortedReadings() {
        let day = 86_400.0
        let start = utc.startOfDay(for: referenceNow)
        let rs = [reading(start.addingTimeInterval(60), 120),
                  reading(start.addingTimeInterval(-day + 60), 120),
                  reading(start.addingTimeInterval(120), 120)]
        XCTAssertEqual(InsightsEmptyState.readingDays(rs, calendar: utc), 2)
    }

    // MARK: Logbook: no matches

    private func query(_ text: String) -> LogbookQuery {
        LogbookQuery.parse(text, now: referenceNow, calendar: utc)
    }

    func testClearTitleNamesWhatItTakesAway() {
        XCTAssertEqual(LogbookSearch.clearTitle(query("pizza"), filter: nil), "Clear Search")
        XCTAssertEqual(LogbookSearch.clearTitle(query(""), filter: .meals), "Clear Filter")
        XCTAssertEqual(LogbookSearch.clearTitle(query(""), filter: nil, tag: "Exercise"), "Clear Filter")
        XCTAssertEqual(LogbookSearch.clearTitle(query("yesterday"), filter: nil), "Show All Dates")
        XCTAssertEqual(LogbookSearch.clearTitle(query("pizza"), filter: .meals), "Clear Filters")
        XCTAssertEqual(LogbookSearch.clearTitle(query("pizza yesterday"), filter: nil), "Clear Filters")
        XCTAssertEqual(LogbookSearch.clearTitle(query(""), filter: .meals, tag: "Exercise"), "Clear Filters")
    }

    func testAnInsightsCardsDaysAloneShowAllDates() {
        let period = LogbookQuery.Period(label: "Last 14 days", phrase: "over the last 14 days",
                                         interval: DateInterval(start: referenceNow.addingTimeInterval(-14 * 86_400),
                                                                end: referenceNow))
        XCTAssertEqual(LogbookSearch.clearTitle(query("").linked(period), filter: nil), "Show All Dates")
    }

    func testTheMacClearsADayBackToItsToolbarPeriod() {
        XCTAssertEqual(LogbookSearch.clearTitle(query("yesterday"), filter: nil, toAllDates: false), "Clear Search")
        XCTAssertEqual(LogbookSearch.clearTitle(query(""), filter: .lows, toAllDates: false), "Clear Filter")
    }
}
