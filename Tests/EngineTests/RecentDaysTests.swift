import XCTest
@testable import GlucOSEngine

/// The last 7 days card behind the time-in-range figure (`RecentDays`): which days it shows, the
/// words, VoiceOver's line per day and the Logbook link to each day.
final class RecentDaysTests: XCTestCase {
    // referenceNow is Monday 21 September 2026, 14:00 UTC. Low line 70, high line 180, days in UTC.
    private var today: Date { utc.startOfDay(for: referenceNow) }
    private func daysAgo(_ n: Int) -> Date { utc.date(byAdding: .day, value: -n, to: today)! }

    /// Readings every 5 minutes from `start` until `end`, at `value`.
    private func readings(from start: Date, to end: Date, _ value: (Date) -> Double = { _ in 120 }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = start
        while t < end {
            out.append(reading(t, value(t)))
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ r: [GlucoseReading]) -> RecentDays {
        RecentDays.compute(readings: r, low: 70, high: 180, now: referenceNow, calendar: utc)
    }

    func testSevenDaysOldestFirstTodayLast() {
        let r = compute(readings(from: daysAgo(10), to: referenceNow))
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.days.map(\.start), (0..<7).reversed().map(daysAgo))
        XCTAssertEqual(r.days.last?.start, today)
        XCTAssertTrue(r.days.allSatisfy { $0.figures != nil })
        XCTAssertTrue(r.hasFigures)
    }

    func testDayWithoutEnoughReadingsKeepsItsPlaceWithNoBar() {
        // Nothing on Thursday 17 September (4 days ago).
        let r = compute(readings(from: daysAgo(6), to: referenceNow).filter { !utc.isDate($0.timestamp, inSameDayAs: daysAgo(4)) })
        XCTAssertEqual(r.days.count, 7)
        XCTAssertNil(r.days[2].figures)
        XCTAssertEqual(r.days[2].start, daysAgo(4))
        XCTAssertEqual(RecentDaysText.barFigure(r.days[2]), "–")
        XCTAssertNotNil(r.days[3].figures)
    }

    func testNoReadingsMeansNoBars() {
        let r = compute([])
        XCTAssertEqual(r.days.count, 7)
        XCTAssertFalse(r.hasFigures)
    }

    func testSharesMatchTheLogbookDayBar() throws {
        // Yesterday high from midnight to 6 am, in range after; today in range so far.
        let yesterday = daysAgo(1)
        let r = readings(from: yesterday, to: referenceNow) { t in
            t < yesterday.addingTimeInterval(6 * 3600) ? 220 : 120
        }
        let days = compute(r)
        let y = try XCTUnwrap(days.days[5].figures)
        let logbook = try XCTUnwrap(DayInRange.compute(readings: r, days: [yesterday], low: 70, high: 180,
                                                       now: referenceNow, calendar: utc)[yesterday])
        XCTAssertEqual(y, logbook)
        XCTAssertEqual(y.above, 0.25, accuracy: 0.001)
        XCTAssertEqual(RecentDaysText.barFigure(days.days[5]), "75%")
        // Today runs midnight to now.
        let t = try XCTUnwrap(days.days[6].figures)
        XCTAssertEqual(t.spanMinutes, 14 * 60)
        XCTAssertEqual(t.inRange, 1, accuracy: 0.001)
    }

    func testBarLabels() {
        let days = compute(readings(from: daysAgo(6), to: referenceNow)).days
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(RecentDaysText.barLabel(days[6], now: referenceNow, calendar: utc, locale: en), "Today")
        XCTAssertEqual(RecentDaysText.barLabel(days[5], now: referenceNow, calendar: utc, locale: en), "Sun")
        XCTAssertEqual(RecentDaysText.barLabel(days[0], now: referenceNow, calendar: utc, locale: en), "Tue")
    }

    func testVoiceOverReadsOneLinePerDay() {
        let r = compute(readings(from: daysAgo(6), to: referenceNow).filter { !utc.isDate($0.timestamp, inSameDayAs: daysAgo(4)) })
        let lines = r.days.map { RecentDaysText.spoken($0, now: referenceNow, calendar: utc) }
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines[6], "Today so far, 100% in range")
        XCTAssertEqual(lines[5], "Yesterday, 100% in range")
        XCTAssertTrue(lines[2].hasSuffix(", not enough readings"), lines[2])
        XCTAssertTrue(lines[0].hasSuffix(", 100% in range"), lines[0])
        XCTAssertEqual(Set(lines).count, 7)
    }

    func testWordsGiveNoAdvice() {
        let r = compute(readings(from: daysAgo(6), to: referenceNow))
        let words = [RecentDaysText.title, RecentDaysText.caption, RecentDaysText.empty, RecentDaysText.barHint,
                     RecentDaysText.showAction] + r.days.map { RecentDaysText.spoken($0, now: referenceNow, calendar: utc) }
        for w in words {
            for banned in ["dose", "insulin", "bolus", "units", "should", "carb"] {
                XCTAssertFalse(w.lowercased().contains(banned), "\(w) says \(banned)")
            }
        }
    }

    func testBarsGrowOldestFirstWithTodayLast() {
        let delays = (0..<RecentDays.count).map(RecentDays.growDelay)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(Set(delays).count, RecentDays.count)
        XCTAssertEqual(RecentDays.growDelay(0), RecentDays.barDelay)
        XCTAssertLessThan(delays.last!, 0.5)
    }

    func testLinkOpensTheLogbookOnThatDay() {
        let link = LogbookLink.recentDay(daysAgo(1).addingTimeInterval(3600), now: referenceNow, calendar: utc)
        XCTAssertEqual(link.filter, .recentDay)
        XCTAssertNil(link.kindChip)
        XCTAssertEqual(link.period.interval, DateInterval(start: daysAgo(1), end: today))
        XCTAssertEqual(link.period.label, "Yesterday")
        XCTAssertEqual(link.period.phrase, "yesterday")
        XCTAssertEqual(link.sourceID, "logbook-recentDay")

        let now = LogbookLink.recentDay(today, now: referenceNow, calendar: utc)
        XCTAssertEqual(now.period.label, "Today")
        XCTAssertEqual(now.period.phrase, "today")
        // Today's day runs on to tonight's midnight, so something logged after the last reading shows.
        XCTAssertEqual(now.period.interval.end, daysAgo(-1))

        let older = LogbookLink.recentDay(daysAgo(5), now: referenceNow, calendar: utc, locale: Locale(identifier: "en_AU"))
        XCTAssertTrue(older.period.phrase.hasPrefix("on "), older.period.phrase)
        XCTAssertEqual(older.period.phrase, "on " + older.period.label)
        XCTAssertEqual(older.period.interval.duration, 86_400)
    }

    func testOneDayChipIsUnlistedAndLetsEverythingThrough() {
        XCTAssertFalse(LogbookFilter.recentDay.isListed)
        XCTAssertEqual(LogbookFilter.recentDay.title, "One day")
        XCTAssertEqual(LogbookFilter.recentDay.insightsCard, .recentDay)
        let entry = LogEntry.meal(MealEntry(timestamp: referenceNow, carbs: 20, food: "Toast"))
        XCTAssertTrue(LogbookFilter.recentDay.matches(entry, lowIDs: []))
    }
}
