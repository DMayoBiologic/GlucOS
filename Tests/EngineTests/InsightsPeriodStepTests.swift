import XCTest
@testable import GlucOSEngine

/// Stepping Insights back through earlier periods (`InsightsPeriodStep`, docs/InsightsPeriodStep.md).
final class InsightsPeriodStepTests: XCTestCase {
    private let locale = Locale(identifier: "en_AU")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private lazy var perth = calendar("Australia/Perth")
    private lazy var sydney = calendar("Australia/Sydney")
    private lazy var london = calendar("Europe/London")

    private func date(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func parts(_ cal: Calendar, _ d: Date) -> [Int] {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    /// One reading every 15 minutes from `from` to `to`, oldest first.
    private func readings(from: Date, to: Date) -> [GlucoseReading] {
        stride(from: from.timeIntervalSince1970, through: to.timeIntervalSince1970, by: 900).map {
            GlucoseReading(timestamp: Date(timeIntervalSince1970: $0), mgdl: 110, trend: .flat)
        }
    }

    // MARK: Where a period ends

    func testLatestIsUnchangedAndNeverStepsPastToday() {
        let now = date(perth, 2026, 11, 17, 9, 30)
        XCTAssertEqual(InsightsPeriodStep.end(latest: now, days: 7, back: 0, calendar: perth), now)
        XCTAssertEqual(InsightsPeriodStep.end(latest: now, days: 7, back: -3, calendar: perth), now)
        XCTAssertEqual(InsightsPeriodStep.end(latest: now, hours: 24, back: -1, calendar: perth), now)
    }

    func testStepsByItsOwnLength() {
        let now = date(perth, 2026, 11, 17, 9, 30)
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: now, days: 7, back: 1, calendar: perth)), [2026, 11, 10, 9, 30])
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: now, days: 14, back: 2, calendar: perth)), [2026, 10, 20, 9, 30])
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: now, days: 30, back: 1, calendar: perth)), [2026, 10, 18, 9, 30])
    }

    func testKeepsClockTimeAcrossDaylightSavingStart() {
        // Sydney clocks went forward an hour on Sunday 4 October 2026.
        let latest = date(sydney, 2026, 10, 8, 17, 30)
        let end = InsightsPeriodStep.end(latest: latest, days: 7, back: 1, calendar: sydney)
        XCTAssertEqual(parts(sydney, end), [2026, 10, 1, 17, 30])
        XCTAssertEqual(latest.timeIntervalSince(end), 7 * 86_400 - 3_600)
    }

    func testKeepsClockTimeAcrossDaylightSavingEnd() {
        // London clocks went back an hour on Sunday 25 October 2026.
        let latest = date(london, 2026, 10, 28, 9)
        let end = InsightsPeriodStep.end(latest: latest, days: 7, back: 1, calendar: london)
        XCTAssertEqual(parts(london, end), [2026, 10, 21, 9, 0])
        XCTAssertEqual(latest.timeIntervalSince(end), 7 * 86_400 + 3_600)
        // At a glance on 24h steps a calendar day too: 25 hours that day.
        let day = InsightsPeriodStep.end(latest: date(london, 2026, 10, 25, 12), hours: 24, back: 1, calendar: london)
        XCTAssertEqual(parts(london, day), [2026, 10, 24, 12, 0])
        XCTAssertEqual(date(london, 2026, 10, 25, 12).timeIntervalSince(day), 25 * 3_600)
    }

    func testRollsOverMonthYearAndLeapDay() {
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: date(perth, 2026, 3, 1, 8), days: 7, back: 1, calendar: perth)),
                       [2026, 2, 22, 8, 0])
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: date(perth, 2026, 3, 31, 8), days: 30, back: 1, calendar: perth)),
                       [2026, 3, 1, 8, 0])
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: date(perth, 2027, 1, 5), days: 14, back: 1, calendar: perth)),
                       [2026, 12, 22, 12, 0])
        XCTAssertEqual(parts(perth, InsightsPeriodStep.end(latest: date(perth, 2028, 3, 1, 7), hours: 24, back: 1, calendar: perth)),
                       [2028, 2, 29, 7, 0])
    }

    func testHoursThatArentWholeDaysStepByTheHour() {
        let latest = date(sydney, 2026, 10, 4, 6)
        XCTAssertEqual(latest.timeIntervalSince(InsightsPeriodStep.end(latest: latest, hours: 6, back: 2, calendar: sydney)),
                       12 * 3_600)
    }

    // MARK: The readings a card sees

    func testReadingsThroughEndAreCutInclusively() {
        let all = readings(from: date(perth, 2026, 11, 1, 0), to: date(perth, 2026, 11, 17, 0))
        XCTAssertEqual(InsightsPeriodStep.readings(all, through: date(perth, 2026, 11, 18)), all)
        let cut = InsightsPeriodStep.readings(all, through: date(perth, 2026, 11, 10, 6))
        XCTAssertEqual(cut.last?.timestamp, date(perth, 2026, 11, 10, 6))
        XCTAssertEqual(cut.first, all.first)
        XCTAssertTrue(InsightsPeriodStep.readings(all, through: date(perth, 2026, 10, 1)).isEmpty)
        XCTAssertTrue(InsightsPeriodStep.readings([], through: date(perth, 2026, 10, 1)).isEmpty)
    }

    func testCardReadingsEndAPeriodBeforeTheNewest() {
        let newest = date(perth, 2026, 11, 17, 9)
        let all = readings(from: date(perth, 2026, 10, 1, 0), to: newest)
        XCTAssertEqual(InsightsPeriodStep.readings(all, days: 14, back: 0, calendar: perth), all)
        XCTAssertEqual(InsightsPeriodStep.readings(all, days: 14, back: 1, calendar: perth).last?.timestamp,
                       date(perth, 2026, 11, 3, 9))
        XCTAssertEqual(InsightsPeriodStep.readings(all, days: 7, back: 2, calendar: perth).last?.timestamp,
                       date(perth, 2026, 11, 3, 9))
    }

    func testGlanceWindowIsTheHoursBeforeTheEnd() {
        let all = readings(from: date(perth, 2026, 11, 1, 0), to: date(perth, 2026, 11, 17, 0))
        let slice = InsightsPeriodStep.window(all, end: date(perth, 2026, 11, 10, 12), hours: 24)
        XCTAssertEqual(slice.first?.timestamp, date(perth, 2026, 11, 9, 12))
        XCTAssertEqual(slice.last?.timestamp, date(perth, 2026, 11, 10, 12))
        XCTAssertEqual(slice.count, 97)
    }

    // MARK: Stepping

    func testStepNeverGoesPastLatestOrPastTheReadings() {
        let first = date(perth, 2026, 10, 25), latest = date(perth, 2026, 11, 17)
        XCTAssertEqual(InsightsPeriodStep.step(0, by: 1, firstReading: first, latest: latest, calendar: perth), 0)
        XCTAssertEqual(InsightsPeriodStep.step(2, by: 1, firstReading: first, latest: latest, calendar: perth), 1)
        XCTAssertEqual(InsightsPeriodStep.step(0, by: -1, firstReading: first, latest: latest, calendar: perth), 1)
        // 7-day steps: 10 Nov and 3 Nov still end after 25 Oct; 27 Oct does too; 20 Oct doesn't.
        XCTAssertTrue(InsightsPeriodStep.canGoEarlier(back: 2, firstReading: first, latest: latest, calendar: perth))
        XCTAssertFalse(InsightsPeriodStep.canGoEarlier(back: 3, firstReading: first, latest: latest, calendar: perth))
        XCTAssertEqual(InsightsPeriodStep.step(3, by: -1, firstReading: first, latest: latest, calendar: perth), 3)
        XCTAssertFalse(InsightsPeriodStep.canGoEarlier(back: 0, firstReading: nil, latest: nil, calendar: perth))
        XCTAssertFalse(InsightsPeriodStep.canGoEarlier(back: InsightsPeriodStep.maximumBack, firstReading: .distantPast,
                                                       latest: latest, calendar: perth))
    }

    func testSwipeDirection() {
        XCTAssertEqual(InsightsPeriodStep.swipeDirection(dx: 120, dy: 10), -1)
        XCTAssertEqual(InsightsPeriodStep.swipeDirection(dx: -120, dy: -20), 1)
        XCTAssertNil(InsightsPeriodStep.swipeDirection(dx: 40, dy: 0))
        XCTAssertNil(InsightsPeriodStep.swipeDirection(dx: 100, dy: 80))
        XCTAssertNil(InsightsPeriodStep.swipeDirection(dx: 0, dy: 300))
    }

    // MARK: Words

    func testLabels() {
        XCTAssertEqual(InsightsPeriodStep.label(back: 0), "Latest")
        XCTAssertEqual(InsightsPeriodStep.label(back: 1), "1 period earlier")
        XCTAssertEqual(InsightsPeriodStep.label(back: 4), "4 periods earlier")
    }

    func testCaptionNamesTheDates() {
        let end = date(perth, 2026, 11, 2)
        XCTAssertNil(InsightsPeriodStep.caption(days: 7, end: end, back: 0, calendar: perth, locale: locale))
        XCTAssertEqual(InsightsPeriodStep.caption(days: 7, end: end, back: 1, calendar: perth, locale: locale),
                       "7 days · 27 Oct – 2 Nov 2026")
        XCTAssertEqual(InsightsPeriodStep.caption(days: 14, end: date(perth, 2026, 11, 16), back: 1, calendar: perth, locale: locale),
                       "14 days · 3–16 Nov 2026")
        XCTAssertEqual(InsightsPeriodStep.caption(days: 14, end: date(perth, 2027, 1, 3), back: 2, calendar: perth, locale: locale),
                       "14 days · 21 Dec 2026 – 3 Jan 2027")
        XCTAssertEqual(InsightsPeriodStep.caption(days: 1, end: date(perth, 2026, 11, 16, 9), back: 1, calendar: perth, locale: locale),
                       "24 hours · 16 Nov 2026")
        XCTAssertEqual(InsightsPeriodStep.spokenCaption(days: 7, end: end, back: 1, calendar: perth, locale: locale),
                       "Showing the 7 days to 2 Nov 2026")
        XCTAssertNil(InsightsPeriodStep.spokenCaption(days: 7, end: end, back: 0, calendar: perth, locale: locale))
    }

    func testCaptionAcrossDaylightSaving() {
        // Seven dates either side of Sydney's clock change.
        XCTAssertEqual(InsightsPeriodStep.caption(days: 7, end: date(sydney, 2026, 10, 8, 1), back: 1, calendar: sydney, locale: locale),
                       "7 days · 2–8 Oct 2026")
    }

    func testSharedFooterForAnEarlierPeriod() {
        XCTAssertEqual(InsightsShare.footer(card: .lows, period: .days(14), now: date(perth, 2026, 11, 3), earlier: true,
                                            calendar: perth, locale: locale),
                       "Lows · 14 days · 20 Oct – 3 Nov 2026")
        XCTAssertEqual(InsightsShare.footer(card: .glance, period: .hours(24), now: date(perth, 2026, 11, 16, 18), earlier: true,
                                            calendar: perth, locale: locale),
                       "At a glance · 24 hours · 15–16 Nov 2026")
    }

    func testWhichCardsStep() {
        XCTAssertEqual(InsightsCard.allCases.filter(\.stepsWithPeriod),
                       [.glance, .lows, .highs, .alerts, .overnight, .weekdayWeekend, .bestDays, .tags, .dayPattern, .hourlyInRange, .sensorCoverage, .longestInRange])
        XCTAssertEqual(InsightsPeriodStep.days(for: .days(30)), 30)
        XCTAssertEqual(InsightsPeriodStep.days(for: .hours(24)), 1)
        XCTAssertNil(InsightsPeriodStep.days(for: .hours(6)))
        XCTAssertNil(InsightsPeriodStep.days(for: .twoWeeks))
        XCTAssertNil(InsightsPeriodStep.days(for: .allStored(since: nil)))
    }
}
