import XCTest
@testable import GlucOSEngine

/// Insights "Weekdays and weekends" (`WeekdayWeekend`): time in range, the average and lows on
/// weekdays beside the same on weekend days, and the Logbook chips its two sides open on.
final class WeekdayWeekendTests: XCTestCase {
    // referenceNow is Monday 21 September 2026, 14:00 UTC. Readings every 5 minutes for 30 days,
    // 120 mg/dL unless `value` says otherwise. Low line 70, high line 180, days in UTC with
    // Saturday and Sunday as the weekend.

    private let calendar: Calendar = {
        var c = utc
        c.locale = Locale(identifier: "en_AU")
        return c
    }()

    private func history(skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-30 * 86_400 + 300)
        while t <= referenceNow {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: WeekdayWeekend.Period = .fortnight) -> WeekdayWeekend? {
        WeekdayWeekend.compute(readings: readings, low: 70, high: 180, period: period, calendar: calendar)
    }

    private func isWeekend(_ t: Date) -> Bool { calendar.isDateInWeekend(t) }
    private func minuteOfDay(_ t: Date) -> Int { Int(t.timeIntervalSince(calendar.startOfDay(for: t)) / 60) }

    func testSteadyFortnight() throws {
        let w = try XCTUnwrap(compute(history()))
        // 14 × 24 h back from Monday 2 pm: that first Monday afternoon is under half a day and drops;
        // Tuesday 8th to Sunday 20th are whole, and this Monday has 14 hours.
        XCTAssertEqual(w.weekdays.days, 10)
        XCTAssertEqual(w.weekends.days, 4)
        XCTAssertEqual(w.weekdays.timeInRange, 1)
        XCTAssertEqual(w.weekends.timeInRange, 1)
        XCTAssertEqual(w.weekends.averageMgdl, 120, accuracy: 0.001)
        XCTAssertEqual(w.weekdays.lows, 0)
        XCTAssertNil(w.betterInRange)
        XCTAssertNil(w.moreLows)
        XCTAssertEqual(WeekdayWeekendText.caption(w.weekdays), "in range · 10 days")
        XCTAssertEqual(WeekdayWeekendText.average(w.weekends, unit: .mgdl), "120 mg/dL")
        XCTAssertEqual(WeekdayWeekendText.lows(w.weekends), "No lows")
        XCTAssertEqual(WeekdayWeekendText.rangeLine(w), "Time in range was about the same on weekdays and weekends.")
        XCTAssertNil(WeekdayWeekendText.lowsLine(w))
        XCTAssertEqual(WeekdayWeekendText.spoken(.weekends, w, lowLine: "70 mg/dL", unit: .mgdl),
                       "4 days. 100 percent in range. Average 120 mg/dL. No lows.")
    }

    func testAWeekHasTwoWeekendDays() throws {
        let w = try XCTUnwrap(compute(history(), period: .week))
        XCTAssertEqual(w.weekdays.days, 5)
        XCTAssertEqual(w.weekends.days, 2)
    }

    func testHigherWeekendAfternoons() throws {
        // Every weekend afternoon sits at 200 from noon to 6 pm: a quarter of the day above range.
        let w = try XCTUnwrap(compute(history { t in
            self.isWeekend(t) && (720..<1080).contains(self.minuteOfDay(t)) ? 200 : nil
        }))
        XCTAssertEqual(w.weekdays.timeInRange, 1)
        XCTAssertEqual(w.weekends.timeInRange, 0.75, accuracy: 0.001)
        XCTAssertEqual(w.weekends.averageMgdl, 140, accuracy: 0.001)
        XCTAssertEqual(w.rangeGapPoints, -25, accuracy: 0.001)
        XCTAssertEqual(w.betterInRange, .weekdays)
        XCTAssertEqual(WeekdayWeekendText.percent(w.weekends.timeInRange), "75%")
        XCTAssertEqual(WeekdayWeekendText.rangeLine(w), "Weekends ran 25 points lower in range than weekdays.")
    }

    func testLowerWeekdays() throws {
        // Weekday mornings at 200 from 8 to 2: weekends come out ahead.
        let w = try XCTUnwrap(compute(history { t in
            !self.isWeekend(t) && (480..<840).contains(self.minuteOfDay(t)) ? 200 : nil
        }))
        XCTAssertEqual(w.betterInRange, .weekends)
        XCTAssertTrue(WeekdayWeekendText.rangeLine(w).hasPrefix("Weekdays ran "))
        XCTAssertTrue(WeekdayWeekendText.rangeLine(w).hasSuffix(" points lower in range than weekend days."))
    }

    func testWeekendLowsCompareAsARate() throws {
        // A 30-minute low at 3 am on each weekend day; none on weekdays.
        let w = try XCTUnwrap(compute(history { t in
            self.isWeekend(t) && (180..<210).contains(self.minuteOfDay(t)) ? 60 : nil
        }))
        XCTAssertEqual(w.weekends.lows, 4)
        XCTAssertEqual(w.weekdays.lows, 0)
        XCTAssertEqual(w.weekends.lowsPerDay, 1)
        XCTAssertEqual(w.weekends.timeBelow, 6.0 / 288, accuracy: 0.0001)
        // Two points of range apart: about the same.
        XCTAssertNil(w.betterInRange)
        XCTAssertEqual(w.moreLows, .weekends)
        XCTAssertEqual(WeekdayWeekendText.lows(w.weekends), "4 lows")
        XCTAssertEqual(WeekdayWeekendText.lowsLine(w), "Lows were more frequent at weekends: 1 a day against 0.")
        XCTAssertEqual(WeekdayWeekendText.spoken(.weekends, w, lowLine: "70 mg/dL", unit: .mgdl),
                       "4 days. 98 percent in range, 2 percent below 70 mg/dL. Average 119 mg/dL. 4 lows.")
    }

    func testOneLowIsNotCompared() throws {
        let saturday = calendar.startOfDay(for: referenceNow).addingTimeInterval(-2 * 86_400)
        let w = try XCTUnwrap(compute(history { t in
            t >= saturday.addingTimeInterval(3 * 3_600) && t < saturday.addingTimeInterval(3.5 * 3_600) ? 60 : nil
        }))
        XCTAssertEqual(w.weekends.lows, 1)
        XCTAssertNil(w.moreLows)
        XCTAssertEqual(WeekdayWeekendText.lows(w.weekends), "1 low")
    }

    func testWaitsForTwoDaysOfEach() {
        // Readings only from Sunday on: one weekend day.
        let sunday = calendar.startOfDay(for: referenceNow).addingTimeInterval(-86_400)
        XCTAssertNil(compute(history(skip: { $0 < sunday })))
        XCTAssertNil(compute([]))
        XCTAssertEqual(WeekdayWeekendText.emptyLine(.fortnight),
                       "Weekdays and weekends over the last 14 days show here once GlucOS has readings from 2 days of each.")
    }

    func testADayWithUnderHalfItsReadingsIsLeftOut() throws {
        // Saturday 19th has readings only from 2 pm: under half the day.
        let saturday = calendar.startOfDay(for: referenceNow).addingTimeInterval(-2 * 86_400)
        let w = try XCTUnwrap(compute(history(skip: { $0 >= saturday && $0 < saturday.addingTimeInterval(14 * 3_600) })))
        XCTAssertEqual(w.weekends.days, 3)
    }

    func testRateWording() {
        XCTAssertEqual(WeekdayWeekendText.rate(0), "0")
        XCTAssertEqual(WeekdayWeekendText.rate(0.25), "0.3")
        XCTAssertEqual(WeekdayWeekendText.rate(1.0 / 3), "0.3")
        XCTAssertEqual(WeekdayWeekendText.rate(2), "2")
    }

    // MARK: Logbook

    func testEachSideOpensItsChipOverTheCardsDays() {
        let newest = referenceNow.addingTimeInterval(-600)
        for side in WeekdayWeekend.Side.allCases {
            for period in WeekdayWeekend.Period.allCases {
                let link = LogbookLink.weekPart(side, period, newestReading: newest, now: referenceNow)
                XCTAssertEqual(link.filter, side.filter)
                XCTAssertEqual(link.period.interval.start, newest.addingTimeInterval(-Double(period.days) * 86_400))
                XCTAssertEqual(link.period.interval.end, referenceNow)
                XCTAssertEqual(link.period.label, "Last \(period.days) days")
            }
        }
        XCTAssertNotEqual(LogbookLink.sourceID(for: .weekdays), LogbookLink.sourceID(for: .weekends))
    }

    func testTheChipsSplitEntriesByDayOfTheWeek() {
        // 2 pm UTC on Saturday is still the weekend anywhere from UTC−12 to UTC+14; Wednesday's
        // stays a weekday.
        let saturday = referenceNow.addingTimeInterval(-2 * 86_400)
        let wednesday = referenceNow.addingTimeInterval(-5 * 86_400)
        let dose = { (d: Date) in LogEntry.dose(InsulinDose(timestamp: d, units: 2, kind: .rapid, name: "NovoRapid", note: "")) }
        XCTAssertTrue(LogbookFilter.weekends.matches(dose(saturday), lowIDs: []))
        XCTAssertFalse(LogbookFilter.weekdays.matches(dose(saturday), lowIDs: []))
        XCTAssertTrue(LogbookFilter.weekdays.matches(dose(wednesday), lowIDs: []))
        XCTAssertFalse(LogbookFilter.weekends.matches(dose(wednesday), lowIDs: []))
    }

    func testTheChipsAreOnlyOfferedFromTheCard() {
        XCTAssertFalse(LogbookFilter.weekdays.isListed)
        XCTAssertFalse(LogbookFilter.weekends.isListed)
        XCTAssertTrue(LogbookFilter.meals.isListed)
        let dose = LogEntry.dose(InsulinDose(timestamp: referenceNow, units: 2, kind: .rapid, name: "NovoRapid", note: ""))
        let offered = LogbookFilter.available(entries: [dose], alerts: [])
        XCTAssertFalse(offered.contains(.weekdays))
        XCTAssertFalse(offered.contains(.weekends))
        // Back on the Mac goes to the one card either way.
        XCTAssertEqual(LogbookFilter.weekends.insightsCard, .weekdays)
        XCTAssertEqual(LogbookFilter.weekdays.insightsCard, .weekdays)
        XCTAssertEqual(LogbookFilter.lows.insightsCard, .lows)
    }
}
