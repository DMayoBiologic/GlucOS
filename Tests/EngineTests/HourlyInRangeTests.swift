import XCTest
@testable import GlucOSEngine

/// Insights "Time in range by hour" (`HourlyInRange`): one cell per local clock hour, the Logbook
/// link onto that hour, and clock changes.
final class HourlyInRangeTests: XCTestCase {
    // referenceNow is 14:00 UTC on 21 Sep 2026. Readings every 5 minutes for 30 days, 120 mg/dL unless
    // `value` says otherwise. Low line 70, high line 180.

    private func history(end: Date = referenceNow, days: Int = 30,
                         skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = end.addingTimeInterval(-Double(days) * 86_400 + 300)
        while t <= end {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: HourlyInRange.Period = .fortnight,
                         calendar: Calendar = utc) -> HourlyInRange? {
        HourlyInRange.compute(readings: readings, low: 70, high: 180, period: period, calendar: calendar)
    }

    private func hour(_ t: Date, _ calendar: Calendar = utc) -> Int { calendar.component(.hour, from: t) }

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Bucketing

    func testSteadyDaysFillEveryHour() throws {
        let s = try XCTUnwrap(compute(history()))
        XCTAssertEqual(s.hours.count, 24)
        XCTAssertEqual(s.counted.count, 24)
        XCTAssertEqual(s.timeInRange, 1)
        // 14 × 24 hours up to 2 pm: 13 whole days plus the two part days at each end.
        XCTAssertEqual(s.days, 15)
        XCTAssertEqual(s.hour(9)?.days, 14)
        XCTAssertEqual(s.hour(9)?.buckets, 14 * 12)
        XCTAssertEqual(s.hour(9)?.shade, .inRange)
        XCTAssertEqual(HourlyInRangeText.headline(s), "100% in range in every hour with readings.")
        XCTAssertEqual(HourlyInRangeText.targetLine(s), "24 of 24 hours at 70% or more in range.")
        XCTAssertEqual(HourlyInRangeText.spoken(s),
                       "Time in range by hour, the last 14 days. 100 percent in range overall. 24 of 24 hours at 70% or more in range.")
        XCTAssertEqual(HourlyInRangeText.footnote(s),
                       "Each cell is one hour of the clock. An hour counts on a day with readings for half of it, and needs 3 such days. Tap an hour to see what was logged then. Observations, not advice.")
    }

    func testHighMorningsAndLowNightsColourTheirHours() throws {
        let s = try XCTUnwrap(compute(history { t in
            switch self.hour(t) {
            case 3: return 60
            case 7: return 250
            default: return nil
            }
        }))
        XCTAssertEqual(s.hour(3)?.timeInRange, 0)
        XCTAssertEqual(s.hour(3)?.timeBelow, 1)
        XCTAssertEqual(s.hour(3)?.shade, .low(strong: true))
        XCTAssertEqual(s.hour(7)?.timeAbove, 1)
        XCTAssertEqual(s.hour(7)?.shade, .high(strong: true))
        XCTAssertEqual(s.hour(8)?.shade, .inRange)
        XCTAssertEqual(s.hoursMeetingTarget, 22)
        // Ties go to the earliest hour.
        XCTAssertEqual(s.best?.hour, 0)
        XCTAssertEqual(s.toughest?.hour, 3)
        XCTAssertEqual(HourlyInRangeText.headline(s), "Most in range midnight–1 am (100%), least 3–4 am (0%).")
        XCTAssertEqual(HourlyInRangeText.spokenCell(s.hour(7)), "0 percent in range, 100 percent above, over 14 days.")
        XCTAssertEqual(HourlyInRangeText.help(7, s.hour(7)), "7–8 am: 0% in range, 100% above, 14 days")
    }

    func testAPartlyHighHourIsFaint() throws {
        // 5 of the twelve 5-minute buckets from 10 am are high: 58% in range.
        let s = try XCTUnwrap(compute(history { t in
            self.hour(t) == 10 && utc.component(.minute, from: t) < 25 ? 250 : nil
        }))
        let h = try XCTUnwrap(s.hour(10))
        XCTAssertEqual(h.timeInRange, 7.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(h.shade, .high(strong: false))
        XCTAssertEqual(HourlyInRangeText.detail(h), "42% above, 14 days")
    }

    func testAnHourNeedsHalfItsBucketsOnADay() throws {
        // 9 am has readings for its first 25 minutes only (5 buckets): never counted. 11 am has 30
        // minutes (6 buckets): counted.
        let s = try XCTUnwrap(compute(history(skip: { t in
            let m = utc.component(.minute, from: t)
            switch self.hour(t) {
            case 9: return m >= 25
            case 11: return m >= 30
            default: return false
            }
        })))
        XCTAssertNil(s.hour(9))
        XCTAssertEqual(HourlyInRangeText.spokenCell(s.hour(9)), "Not enough readings.")
        XCTAssertEqual(HourlyInRangeText.help(9, nil), "9–10 am: not enough readings")
        XCTAssertEqual(s.hour(11)?.buckets, 14 * 6)
        XCTAssertEqual(s.counted.count, 23)
    }

    func testAnHourNeedsThreeDays() throws {
        // 5 pm only on the last two days.
        let cutoff = referenceNow.addingTimeInterval(-2 * 86_400)
        let s = try XCTUnwrap(compute(history(skip: { t in self.hour(t) == 17 && t < cutoff })))
        XCTAssertNil(s.hour(17))
        let three = try XCTUnwrap(compute(history(skip: { t in
            self.hour(t) == 17 && t < referenceNow.addingTimeInterval(-3 * 86_400)
        })))
        XCTAssertEqual(three.hour(17)?.days, 3)
    }

    func testTheCardNeedsThreeDays() {
        XCTAssertNil(compute([]))
        XCTAssertNil(compute(history(days: 1)))
        // Two days up to 2 pm touch three dates, but no hour has readings on three of them.
        XCTAssertNil(compute(history(days: 2)))
        XCTAssertNotNil(compute(history(days: 3)))
    }

    func testReadingsOutsideThePeriodAreLeftOut() throws {
        // Highs all day a fortnight and more ago don't touch the last 7 days.
        let s = try XCTUnwrap(compute(history { t in
            t < referenceNow.addingTimeInterval(-7 * 86_400) ? 250 : nil
        }, period: .week))
        XCTAssertEqual(s.timeInRange, 1)
        XCTAssertEqual(s.period, .week)
    }

    // MARK: Clock changes

    func testSpringForwardSkipsTheMissingHour() throws {
        // New York went from 2 am EST to 3 am EDT on 8 March 2026. 3 am is high every day; there's
        // no 2 am on the 8th, and its first hour after the change is 3 am, not a second 2 am.
        let ny = calendar("America/New_York")
        let end = date(ny, 2026, 3, 10, 12)
        let readings = history(end: end) { t in ny.component(.hour, from: t) == 3 ? 250 : nil }
        let s = try XCTUnwrap(compute(readings, calendar: ny))
        XCTAssertEqual(s.hour(2)?.days, 13)
        XCTAssertEqual(s.hour(2)?.timeInRange, 1)
        XCTAssertEqual(s.hour(3)?.days, 14)
        XCTAssertEqual(s.hour(3)?.buckets, 14 * 12)
        XCTAssertEqual(s.hour(3)?.timeAbove, 1)
        // The day itself is 23 hours long and still counts once.
        XCTAssertEqual(s.days, 15)
    }

    func testFallBackGivesTheRepeatedHourBothPasses() throws {
        // New York went from 2 am EDT back to 1 am EST on 1 November 2026: 1 am happened twice.
        let ny = calendar("America/New_York")
        let end = date(ny, 2026, 11, 3, 12)
        let readings = history(end: end) { t in ny.component(.hour, from: t) == 1 ? 250 : nil }
        let s = try XCTUnwrap(compute(readings, calendar: ny))
        XCTAssertEqual(s.hour(1)?.days, 14)
        XCTAssertEqual(s.hour(1)?.buckets, 14 * 12 + 12)
        XCTAssertEqual(s.hour(1)?.timeAbove, 1)
        // The second pass didn't spill into 2 am.
        XCTAssertEqual(s.hour(2)?.buckets, 14 * 12)
        XCTAssertEqual(s.hour(2)?.timeInRange, 1)
    }

    func testHalfHourZonesKeepBucketsInsideTheirHour() throws {
        // Adelaide is UTC+10:30 in November: 5-minute buckets still start on local 5 minutes.
        let adl = calendar("Australia/Adelaide")
        let end = date(adl, 2026, 11, 17, 12)
        let readings = history(end: end) { t in adl.component(.hour, from: t) == 6 ? 250 : nil }
        let s = try XCTUnwrap(compute(readings, calendar: adl))
        XCTAssertEqual(s.hour(6)?.timeAbove, 1)
        XCTAssertEqual(s.hour(5)?.timeInRange, 1)
        XCTAssertEqual(s.hour(7)?.timeInRange, 1)
    }

    // MARK: Words

    func testHourSpans() {
        XCTAssertEqual(HourlyInRangeText.span(0), "midnight–1 am")
        XCTAssertEqual(HourlyInRangeText.span(7), "7–8 am")
        XCTAssertEqual(HourlyInRangeText.span(11), "11 am–noon")
        XCTAssertEqual(HourlyInRangeText.span(12), "noon–1 pm")
        XCTAssertEqual(HourlyInRangeText.span(15), "3–4 pm")
        XCTAssertEqual(HourlyInRangeText.span(23), "11 pm–midnight")
        XCTAssertEqual(HourlyInRangeText.spanTitle(0), "Midnight–1 am")
        XCTAssertEqual(HourlyInRangeText.spokenSpan(0), "Midnight to 1 am")
        XCTAssertEqual(HourlyInRangeText.spokenSpan(7), "7 am to 8 am")
        XCTAssertEqual(HourlyInRangeText.spokenSpan(23), "11 pm to midnight")
        XCTAssertEqual([0, 6, 12, 18].map(HourlyInRangeText.tick), ["12a", "6a", "12p", "6p"])
        XCTAssertEqual(HourlyInRangeText.logbookHint(7, .fortnight),
                       "Opens the Logbook on what was logged between 7 am and 8 am over the last 14 days")
    }

    // MARK: Logbook

    func testHourLinkOpensOnThatHourAcrossTheDays() throws {
        let newest = referenceNow
        let link = LogbookLink.hour(7, .fortnight, newestReading: newest, now: newest.addingTimeInterval(600))
        XCTAssertEqual(link.filter, .hourOfDay)
        XCTAssertNil(link.kindChip, "the hour rides on the period chip, with no kind chip")
        XCTAssertNil(link.tag)
        XCTAssertEqual(link.period.hour, 7)
        XCTAssertEqual(link.period.label, "7–8 am · Last 14 days")
        XCTAssertEqual(link.period.phrase, "between 7 am and 8 am in the last 14 days")
        XCTAssertEqual(link.period.interval.start, newest.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(link.period.interval.end, newest.addingTimeInterval(600))
        XCTAssertEqual(link.sourceID, "logbook-hourOfDay")
        XCTAssertFalse(LogbookFilter.hourOfDay.isListed)
        XCTAssertEqual(LogbookFilter.hourOfDay.insightsCard, .hourOfDay)

        let day = utc.startOfDay(for: newest)
        let p = link.period
        XCTAssertTrue(p.contains(day.addingTimeInterval(7.5 * 3600), calendar: utc))
        XCTAssertTrue(p.contains(day.addingTimeInterval(-3 * 86_400 + 7 * 3600), calendar: utc))
        XCTAssertFalse(p.contains(day.addingTimeInterval(8 * 3600), calendar: utc))
        XCTAssertFalse(p.contains(day.addingTimeInterval(6.99 * 3600), calendar: utc))
        XCTAssertFalse(p.contains(day.addingTimeInterval(-20 * 86_400 + 7.5 * 3600), calendar: utc), "outside the days")
        // A period without an hour is just its interval.
        let plain = LogbookQuery.Period(label: "x", phrase: "x", interval: p.interval)
        XCTAssertTrue(plain.contains(day.addingTimeInterval(8 * 3600), calendar: utc))
    }

    func testLinkedHourNarrowsTheLogbookSearch() {
        let link = LogbookLink.hour(Calendar.autoupdatingCurrent.component(.hour, from: referenceNow), .week,
                                    newestReading: referenceNow, now: referenceNow)
        let query = LogbookQuery.parse("", now: referenceNow).linked(link.period)
        let inHour = LogEntry.meal(MealEntry(timestamp: referenceNow.addingTimeInterval(-86_400), carbs: 20))
        let otherHour = LogEntry.meal(MealEntry(timestamp: referenceNow.addingTimeInterval(-86_400 - 2 * 3600), carbs: 20))
        XCTAssertTrue(LogbookSearch.matches(inHour, query))
        XCTAssertFalse(LogbookSearch.matches(otherHour, query))
        XCTAssertTrue(LogbookFilter.hourOfDay.matches(otherHour, lowIDs: []), "the chip itself keeps everything")
    }

    func testRepeatedHourMatchesBothPassesInTheLogbook() {
        let ny = calendar("America/New_York")
        let first = date(utc, 2026, 11, 1, 5, 30)             // 1:30 am EDT
        let second = first.addingTimeInterval(3600)            // 1:30 am EST
        XCTAssertEqual(ny.component(.hour, from: second), 1)
        let period = LogbookQuery.Period(label: "1–2 am", phrase: "", interval: DateInterval(start: first.addingTimeInterval(-86_400), end: second.addingTimeInterval(86_400)), hour: 1)
        XCTAssertTrue(period.contains(first, calendar: ny))
        XCTAssertTrue(period.contains(second, calendar: ny))
        XCTAssertFalse(period.contains(second.addingTimeInterval(3600), calendar: ny))
    }

    // MARK: Compare

    func testCompareFindsTheHourThatMovedMost() throws {
        // 7 am was high in the fortnight before; this fortnight it's in range.
        let split = referenceNow.addingTimeInterval(-14 * 86_400)
        let readings = history { t in t <= split && self.hour(t) == 7 ? 250 : nil }
        let s = try XCTUnwrap(compute(readings))
        let before = try XCTUnwrap(InsightsCompare.previousHourly(readings: readings, low: 70, high: 180,
                                                                  current: s, calendar: utc))
        XCTAssertEqual(before.hour(7)?.timeInRange, 0)
        let d = try XCTUnwrap(InsightsCompare.hourRange(7, s, before))
        XCTAssertEqual(d.direction, .up)
        XCTAssertEqual(d.verdict, .better)
        XCTAssertEqual(InsightsCompare.hourRange(8, s, before)?.direction, .same)
        let biggest = try XCTUnwrap(InsightsCompare.biggestHourChange(s, before))
        XCTAssertEqual(biggest.hour, 7)
        XCTAssertEqual(HourlyInRangeText.changeLine(hour: biggest.hour, delta: biggest.delta,
                                                    previous: InsightsCompare.previousPhrase(days: 14)),
                       "Biggest change from the previous 14 days: 7–8 am, up 100 pts.")
        XCTAssertEqual(InsightsCompare.hourlyRange(s, before)?.direction, .up)
        XCTAssertNil(InsightsCompare.hourlyRange(s, nil))
        XCTAssertNil(InsightsCompare.biggestHourChange(s, s))
    }

    func testCompareNeedsThePreviousPeriod() throws {
        // Only 16 days kept: the fortnight before has 2 days, short of 4 in 7.
        let readings = history(days: 16)
        let s = try XCTUnwrap(compute(readings))
        XCTAssertNil(InsightsCompare.previousHourly(readings: readings, low: 70, high: 180, current: s, calendar: utc))
    }

    // MARK: Layout and share

    func testCardSitsAfterYourUsualDay() {
        XCTAssertEqual(InsightsCard(rawValue: "hourlyInRange"), .hourlyInRange)
        XCTAssertEqual(InsightsCard.hourlyInRange.title, "Time in range by hour")
        for defaults in [InsightsCard.phoneDefault, InsightsCard.macDefault] {
            let i = defaults.firstIndex(of: .dayPattern)!
            XCTAssertEqual(defaults[i + 1], .hourlyInRange)
        }
        // A layout saved before it shipped, Your usual day moved to the top: it lands right after.
        let saved = InsightsLayout(order: ["dayPattern", "weekInReview", "lows"], hidden: ["lows"])
        XCTAssertEqual(Array(saved.arranged(InsightsCard.macDefault).prefix(2)), [.dayPattern, .hourlyInRange])
        XCTAssertFalse(saved.isHidden(.hourlyInRange))
    }

    func testSharePeriodFollowsThePicker() {
        let d = UserDefaults(suiteName: "HourlyInRangeTests.\(UUID().uuidString)")!
        XCTAssertEqual(InsightsShare.period(for: .hourlyInRange, defaults: d, firstReading: nil), .days(14))
        d.set(30, forKey: InsightsShare.Key.hourly)
        XCTAssertEqual(InsightsShare.period(for: .hourlyInRange, defaults: d, firstReading: nil), .days(30))
    }
}
