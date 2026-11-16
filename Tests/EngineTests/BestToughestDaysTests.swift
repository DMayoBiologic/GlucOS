import XCTest
@testable import GlucOSEngine

/// Insights "Best and toughest days" (`BestToughestDays`): the period's whole days with the most
/// and least time in range, their charts, the words, and the Logbook link to each day.
final class BestToughestDaysTests: XCTestCase {
    // referenceNow is Monday 21 September 2026, 14:00 UTC. Readings every 5 minutes for 30 days,
    // 120 mg/dL unless `value` says otherwise. Low line 70, high line 180, days in UTC. Today (21 Sep)
    // is under way, so the last 14 days are 7–20 September.

    private let calendar = utc

    private func history(days: Double = 30, end: Date = referenceNow, skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = end.addingTimeInterval(-days * 86_400 + 300)
        while t <= end {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], _ period: BestToughestDays.Period = .fortnight,
                         now: Date = referenceNow) -> BestToughestDays? {
        BestToughestDays.compute(readings: readings, low: 70, high: 180, period: period, now: now, calendar: calendar)
    }

    private func day(_ d: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: d))!
    }

    private func on(_ t: Date, _ days: Int...) -> Bool {
        days.contains { calendar.isDate(t, inSameDayAs: day($0)) }
    }

    private func minuteOfDay(_ t: Date) -> Int { Int(t.timeIntervalSince(calendar.startOfDay(for: t)) / 60) }

    func testPicksTheMostAndLeastTimeInRangeOverWholeDays() throws {
        // 12 Sep high until 10 am (120 of 288 buckets), 17 Sep low until 2:25 am (29 buckets), and
        // today high all day, which doesn't count while it's under way.
        let s = try XCTUnwrap(compute(history(value: { t in
            if self.on(t, 12) && self.minuteOfDay(t) < 600 { return 250 }
            if self.on(t, 17) && self.minuteOfDay(t) < 145 { return 60 }
            if self.on(t, 21) { return 250 }
            return nil
        })))
        XCTAssertEqual(s.countedDays, 14)
        // Every other day is all in range; the latest of them is the best.
        XCTAssertEqual(s.best.start, day(20))
        XCTAssertEqual(s.best.end, day(21))
        XCTAssertEqual(s.best.figures.inRange, 1, accuracy: 0.0001)
        XCTAssertEqual(s.toughest.start, day(12))
        XCTAssertEqual(s.toughest.figures.inRange, 168.0 / 288.0, accuracy: 0.0001)
        XCTAssertEqual(s.toughest.figures.above, 120.0 / 288.0, accuracy: 0.0001)
        XCTAssertFalse(s.muchAlike)
        XCTAssertEqual(BestToughestDaysText.line(s), "The best day had 42 points more time in range than the toughest.")
        XCTAssertEqual(BestToughestDaysText.toughLine(s, lowLine: "3.9 mmol/L", highLine: "10.0 mmol/L"),
                       "Most of the toughest day's time out of range was above 10.0 mmol/L.")
        XCTAssertEqual(BestToughestDaysText.caption(s.best), "all in range")
        XCTAssertEqual(BestToughestDaysText.caption(s.toughest), "42% above")
        XCTAssertEqual(BestToughestDaysText.percent(s.toughest.figures.inRange), "58%")
        XCTAssertNil(BestToughestDaysText.countedLine(s))
        // Each day comes with its chart, midnight to midnight, in one unbroken run.
        XCTAssertEqual(s.best.segments.count, 1)
        XCTAssertEqual(s.best.segments.first?.count, 288)
        XCTAssertEqual(s.toughest.segments.joined().map(\.mgdl).max(), 250)
    }

    func testOnATieTheDayWithMoreTimeBelowIsTougher() throws {
        // 12 Sep and 17 Sep both have 29 buckets out of range: above on the 12th, below on the 17th.
        let s = try XCTUnwrap(compute(history(value: { t in
            guard self.minuteOfDay(t) < 145 else { return nil }
            if self.on(t, 12) { return 250 }
            if self.on(t, 17) { return 60 }
            return nil
        })))
        XCTAssertEqual(s.toughest.start, day(17))
        XCTAssertEqual(BestToughestDaysText.caption(s.toughest), "10% below")
        XCTAssertEqual(BestToughestDaysText.toughLine(s, lowLine: "3.9 mmol/L", highLine: "10.0 mmol/L"),
                       "Most of the toughest day's time out of range was below 3.9 mmol/L.")
    }

    func testAlikeDaysAreSaidToBeAlike() throws {
        let s = try XCTUnwrap(compute(history(), .week))
        XCTAssertEqual(s.countedDays, 7)
        XCTAssertEqual(s.best.start, day(20))
        // The best and the toughest are always two different days.
        XCTAssertEqual(s.toughest.start, day(19))
        XCTAssertTrue(s.muchAlike)
        XCTAssertEqual(BestToughestDaysText.line(s),
                       "The best and toughest days were within 5 points of each other in range, so the 7 days were much alike.")
        XCTAssertNil(BestToughestDaysText.toughLine(s, lowLine: "3.9 mmol/L", highLine: "10.0 mmol/L"))
    }

    func testADayWithTooFewReadingsIsLeftOut() throws {
        let s = try XCTUnwrap(compute(history(skip: { self.on($0, 15) || (self.on($0, 16) && self.minuteOfDay($0) < 780) },
                                              value: { self.on($0, 15, 16) ? 250 : nil })))
        // 15 Sep has nothing and 16 Sep under half a day (high all the same): neither counts.
        XCTAssertEqual(s.countedDays, 12)
        XCTAssertNotEqual(s.toughest.start, day(15))
        XCTAssertNotEqual(s.toughest.start, day(16))
        XCTAssertEqual(BestToughestDaysText.countedLine(s), "12 of the last 14 days had enough readings to count.")
    }

    func testDaysCountBackFromTheLastReadingWhenReadingsStop() throws {
        // Readings stopped at 2 pm on 18 Sep, three days ago. The last 7 days are 12–18 Sep.
        let stopped = referenceNow.addingTimeInterval(-3 * 86_400)
        let s = try XCTUnwrap(compute(history(end: stopped, value: { self.on($0, 11, 12) && self.minuteOfDay($0) < 600 ? 250 : nil }),
                                      .week))
        XCTAssertEqual(s.countedDays, 7)
        XCTAssertEqual(s.best.start, day(18))
        // 11 Sep is outside the 7 days, so the toughest is 12 Sep.
        XCTAssertEqual(s.toughest.start, day(12))
    }

    func testWaitsForTwoDays() {
        XCTAssertNil(compute(history(days: 1.5)))
        XCTAssertNil(compute([]))
        XCTAssertEqual(BestToughestDaysText.emptyLine(.week),
                       "Best and toughest days show here once GlucOS has readings for 2 full days in the last 7 days.")
    }

    func testTheLogbookOpensOnEachDay() throws {
        let s = try XCTUnwrap(compute(history(value: { self.on($0, 12) && self.minuteOfDay($0) < 600 ? 250 : nil })))
        let best = LogbookLink.bestDay(.best, s, now: referenceNow, calendar: calendar)
        XCTAssertEqual(best.filter, .bestDay)
        XCTAssertEqual(best.period.interval, DateInterval(start: day(20), end: day(21)))
        XCTAssertEqual(best.period.label, "Yesterday")
        XCTAssertEqual(best.period.phrase, "yesterday")
        XCTAssertEqual(best.sourceID, "logbook-bestDay")
        let tough = LogbookLink.bestDay(.toughest, s, now: referenceNow, calendar: calendar)
        XCTAssertEqual(tough.filter, .toughestDay)
        XCTAssertEqual(tough.period.interval, DateInterval(start: day(12), end: day(13)))
        XCTAssertTrue(tough.period.phrase.hasPrefix("on "))
        XCTAssertEqual(tough.sourceID, "logbook-toughestDay")
        // Both chips keep everything logged, aren't listed by themselves, and come back to one card.
        let dose = LogEntry.dose(InsulinDose(timestamp: day(12).addingTimeInterval(3_600), units: 2, kind: .rapid, name: "NovoRapid", note: ""))
        XCTAssertTrue(LogbookFilter.toughestDay.matches(dose, lowIDs: []))
        XCTAssertFalse(LogbookFilter.bestDay.isListed)
        XCTAssertFalse(LogbookFilter.toughestDay.isListed)
        XCTAssertFalse(LogbookFilter.available(entries: [dose], alerts: []).contains(.bestDay))
        XCTAssertEqual(LogbookFilter.toughestDay.insightsCard, .bestDay)
        XCTAssertEqual(LogbookFilter.bestDay.title, "Best day")
        XCTAssertEqual(LogbookFilter.toughestDay.title, "Toughest day")
    }
}
