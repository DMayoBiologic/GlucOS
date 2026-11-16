import XCTest
@testable import GlucOSEngine

/// Insights "In-range streaks" (`InRangeStreaks`): days in a row at 70% or more in range, the run
/// going now and the longest, the row of dots, and the Logbook link to the longest run's days.
final class InRangeStreaksTests: XCTestCase {
    // referenceNow is Monday 21 September 2026, 14:00 UTC. Readings every 5 minutes for 30 days,
    // 120 mg/dL unless `value` says otherwise. Low line 70, high line 180, days in UTC. The first
    // afternoon (22 August, under half a day) doesn't count, so whole days run from 23 August.

    private let calendar = utc

    private func history(days: Double = 30, skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-days * 86_400 + 300)
        while t <= referenceNow {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading]) -> InRangeStreaks? {
        InRangeStreaks.compute(readings: readings, low: 70, high: 180, calendar: calendar)
    }

    /// Local midnight of a September (or August) day.
    private func day(_ d: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: d))!
    }

    private func on(_ t: Date, _ days: Int...) -> Bool {
        days.contains { calendar.isDate(t, inSameDayAs: day($0)) }
    }

    private func minuteOfDay(_ t: Date) -> Int { Int(t.timeIntervalSince(calendar.startOfDay(for: t)) / 60) }

    func testASteadyMonthIsOneRunThatTakesInToday() throws {
        let s = try XCTUnwrap(compute(history()))
        XCTAssertEqual(s.currentDays, 30)
        XCTAssertEqual(s.current?.start, day(23, month: 8))
        XCTAssertEqual(s.current?.end, day(22))
        XCTAssertEqual(s.best, s.current)
        XCTAssertTrue(s.currentIsBest)
        XCTAssertEqual(s.daysToBest, 0)
        XCTAssertEqual(s.countedDays, 30)
        XCTAssertEqual(InRangeStreaksText.currentCaption(s, now: referenceNow, calendar: calendar), "since 23 Aug")
        XCTAssertEqual(InRangeStreaksText.bestCaption(s, now: referenceNow, calendar: calendar), "the one going now")
        XCTAssertEqual(InRangeStreaksText.line(s), "The run going now is the longest in the readings kept.")
        XCTAssertEqual(InRangeStreaksText.spoken(s, now: referenceNow, calendar: calendar),
                       "Current streak 30 days, since 23 Aug. Longest 30 days, the one going now.")
    }

    func testAMissedDayEndsTheRun() throws {
        let s = try XCTUnwrap(compute(history(value: { self.on($0, 10) ? 250 : nil })))
        XCTAssertEqual(s.currentDays, 11)
        XCTAssertEqual(s.current?.start, day(11))
        XCTAssertEqual(s.best.days, 18)
        XCTAssertEqual(s.best.start, day(23, month: 8))
        XCTAssertEqual(s.best.end, day(10))
        XCTAssertFalse(s.currentIsBest)
        XCTAssertEqual(s.daysToBest, 7)
        XCTAssertEqual(InRangeStreaksText.bestCaption(s, now: referenceNow, calendar: calendar), "23 Aug – 9 Sep")
        XCTAssertEqual(InRangeStreaksText.line(s), "7 days more would match the longest run.")
        XCTAssertEqual(s.recent.first(where: { $0.start == day(10) })?.mark, .missed)
        XCTAssertEqual(InRangeStreaksText.dotsLine(s), "13 of the last 14 days at 70% or more.")
    }

    func testSeventyPercentIsEnough() throws {
        // 86 of 288 buckets high: 70.1% in range.
        let met = try XCTUnwrap(compute(history(value: { self.on($0, 10) && self.minuteOfDay($0) < 430 ? 250 : nil })))
        XCTAssertEqual(met.currentDays, 30)
        // 87 high: 69.8%.
        let missed = try XCTUnwrap(compute(history(value: { self.on($0, 10) && self.minuteOfDay($0) < 435 ? 250 : nil })))
        XCTAssertEqual(missed.currentDays, 11)
        XCTAssertEqual(missed.best.days, 18)
    }

    func testTodayUnderWayNeitherCountsNorBreaksTheRun() throws {
        let s = try XCTUnwrap(compute(history(value: { self.on($0, 21) ? 250 : nil })))
        XCTAssertEqual(s.currentDays, 29)
        XCTAssertEqual(s.current?.end, day(21))
        XCTAssertTrue(s.currentIsBest)
        XCTAssertEqual(s.recent.last?.start, day(21))
        XCTAssertEqual(s.recent.last?.mark, .underWay)
        let today = try XCTUnwrap(s.recent.last)
        XCTAssertEqual(InRangeStreaksText.spokenDay(today, now: referenceNow, calendar: calendar),
                       "Today so far, 0 percent in range")
    }

    func testADayWithTooFewReadingsEndsTheRun() throws {
        let s = try XCTUnwrap(compute(history(skip: { self.on($0, 15) })))
        XCTAssertEqual(s.currentDays, 6)
        XCTAssertEqual(s.current?.start, day(16))
        XCTAssertEqual(s.best.days, 23)
        XCTAssertEqual(s.best.end, day(15))
        XCTAssertEqual(s.recent.first(where: { $0.start == day(15) })?.mark, .noData)
        XCTAssertEqual(s.countedDays, 29)
    }

    func testNoRunGoingWhenYesterdayMissed() throws {
        let s = try XCTUnwrap(compute(history(value: { self.on($0, 20, 21) ? 250 : nil })))
        XCTAssertNil(s.current)
        XCTAssertEqual(s.currentDays, 0)
        XCTAssertEqual(s.best.days, 28)
        XCTAssertEqual(InRangeStreaksText.currentCaption(s, now: referenceNow, calendar: calendar), "none going")
        XCTAssertEqual(InRangeStreaksText.line(s),
                       "The last full day was under 70% in range, so a new run starts with the next one that gets there.")
        XCTAssertEqual(InRangeStreaksText.spoken(s, now: referenceNow, calendar: calendar),
                       "Current streak 0 days. Longest 28 days, 23 Aug – 19 Sep.")
    }

    func testOnATieTheLatestRunIsTheLongest() throws {
        // Misses on 30 Aug, 7 Sep and 15 Sep: three runs of 7 days, then 6 going now.
        let s = try XCTUnwrap(compute(history(value: {
            self.on($0, 7, 15) || self.calendar.isDate($0, inSameDayAs: self.day(30, month: 8)) ? 250 : nil
        })))
        XCTAssertEqual(s.best.days, 7)
        XCTAssertEqual(s.best.start, day(8))
        XCTAssertEqual(s.currentDays, 6)
    }

    func testNoDayAtTheGoal() throws {
        let s = try XCTUnwrap(compute(history(value: { _ in 250 })))
        XCTAssertNil(s.current)
        XCTAssertEqual(s.best.days, 0)
        XCTAssertEqual(InRangeStreaksText.bestCaption(s, now: referenceNow, calendar: calendar), "none yet")
        XCTAssertEqual(InRangeStreaksText.line(s), "No day has reached 70% in range yet in the readings kept.")
    }

    func testTooFewDaysWaits() {
        XCTAssertNil(compute(history(days: 2)))
        XCTAssertNil(compute([]))
    }

    func testTheDotsAreTheLastFourteenDaysEndingToday() throws {
        let s = try XCTUnwrap(compute(history()))
        XCTAssertEqual(s.recent.count, InRangeStreaks.dotDays)
        XCTAssertEqual(s.recent.first?.start, day(8))
        XCTAssertEqual(s.recent.last?.start, day(21))
        XCTAssertTrue(s.recent.allSatisfy { $0.mark == .met })
        // A short history pads the front with empty days.
        let short = try XCTUnwrap(compute(history(days: 5)))
        XCTAssertEqual(short.recent.count, InRangeStreaks.dotDays)
        XCTAssertEqual(short.recent.last?.start, day(21))
        XCTAssertEqual(short.recent.first?.mark, .noData)
    }

    func testTheLogbookOpensOnTheLongestRunsDays() throws {
        let s = try XCTUnwrap(compute(history(value: { self.on($0, 10) ? 250 : nil })))
        let link = LogbookLink.bestStreak(s.best, now: referenceNow, calendar: calendar)
        XCTAssertEqual(link.filter, .bestStreak)
        XCTAssertEqual(link.period.interval, DateInterval(start: day(23, month: 8), end: day(10)))
        XCTAssertEqual(link.period.label, "23 Aug – 9 Sep")
        XCTAssertEqual(link.period.phrase, "from 23 Aug to 9 Sep")
        XCTAssertFalse(LogbookFilter.bestStreak.isListed)
        XCTAssertEqual(LogbookFilter.bestStreak.insightsCard, .bestStreak)
        XCTAssertEqual(link.sourceID, "logbook-bestStreak")
        // A run going today takes in the rest of today.
        let going = try XCTUnwrap(compute(history()))
        XCTAssertTrue(LogbookLink.bestStreak(going.best, now: referenceNow, calendar: calendar)
            .period.interval.contains(referenceNow.addingTimeInterval(3_600)))
    }
}
