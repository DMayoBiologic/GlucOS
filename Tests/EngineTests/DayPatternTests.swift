import XCTest
@testable import GlucOSEngine

final class DayPatternTests: XCTestCase {
    /// Readings every `step` minutes for `days` days ending at `referenceNow`, following `value`
    /// (minute of the UTC day, day index) -> mg/dL.
    private func history(days: Int, step: Int = 5, value: (Int, Int) -> Double) -> [GlucoseReading] {
        let start = referenceNow.addingTimeInterval(-Double(days) * 86_400 + 60)
        var out: [GlucoseReading] = []
        var t = start
        var i = 0
        while t <= referenceNow {
            let c = utc.dateComponents([.hour, .minute], from: t)
            let minute = c.hour! * 60 + c.minute!
            out.append(reading(t, value(minute, i * step / 1440)))
            t = t.addingTimeInterval(Double(step) * 60)
            i += 1
        }
        return out
    }

    func testFlatDayGivesFlatBands() throws {
        let p = try XCTUnwrap(DayPattern.compute(readings: history(days: 14) { _, _ in 120 },
                                                 window: .fortnight, now: referenceNow, calendar: utc))
        XCTAssertEqual(p.slots.count, 48)
        XCTAssertEqual(p.filled.count, 48)
        for s in p.filled {
            XCTAssertEqual(s.p10, 120, accuracy: 0.001)
            XCTAssertEqual(s.p50, 120, accuracy: 0.001)
            XCTAssertEqual(s.p90, 120, accuracy: 0.001)
        }
        let h = try XCTUnwrap(p.highlights(low: 70, high: 180))
        XCTAssertTrue(h.middleHalfInRange)
        XCTAssertNil(h.lowDip)
        XCTAssertNil(h.medianAbove)
    }

    func testPeakFollowsTheTimeOfDay() throws {
        // Rises to 230 around 2 pm every day, 100 otherwise.
        let p = try XCTUnwrap(DayPattern.compute(readings: history(days: 14) { m, _ in
            abs(m - 14 * 60) < 90 ? 230 : 100
        }, window: .fortnight, now: referenceNow, calendar: utc))
        let h = try XCTUnwrap(p.highlights(low: 70, high: 180))
        XCTAssertEqual(Double(h.peak.minute), 14 * 60, accuracy: 60)
        let run = try XCTUnwrap(h.medianAbove)
        XCTAssertLessThanOrEqual(run.first * 30, 13 * 60)
        XCTAssertGreaterThanOrEqual((run.last + 1) * 30, 15 * 60)
        XCTAssertFalse(h.middleHalfInRange)
        let lines = DayPatternText.lines(p, unit: .mgdl, low: 70, high: 180)
        XCTAssertTrue(lines[0].hasPrefix("Highest around"))
        XCTAssertTrue(lines.contains { $0.contains("above range from") })
    }

    func testPercentilesSpreadAcrossDays() throws {
        // Each day sits at its own level, 80...210 over 14 days: the bands spread and stay ordered.
        let p = try XCTUnwrap(DayPattern.compute(readings: history(days: 14) { _, day in 80 + Double(day) * 10 },
                                                 window: .fortnight, now: referenceNow, calendar: utc))
        for s in p.filled {
            XCTAssertLessThanOrEqual(s.p10, s.p25)
            XCTAssertLessThanOrEqual(s.p25, s.p50)
            XCTAssertLessThanOrEqual(s.p50, s.p75)
            XCTAssertLessThanOrEqual(s.p75, s.p90)
            XCTAssertGreaterThan(s.p90 - s.p10, 80)
        }
        let h = try XCTUnwrap(p.highlights(low: 100, high: 180))
        XCTAssertNotNil(h.lowDip)
        XCTAssertTrue(DayPatternText.lines(p, unit: .mgdl, low: 100, high: 180).contains { $0.contains("dips below range") })
    }

    func testDenseReadingsDontOutweighOtherDays() throws {
        // 13 days of 15-minute history at 100, one day of 1-minute readings at 200. Averaging into
        // 5-minute buckets counts that day's readings 5 to a bucket, so the median stays at 100.
        var rs = history(days: 13, step: 15) { _, _ in 100 }
        let lastDayStart = referenceNow.addingTimeInterval(-13 * 86_400)
        rs = rs.filter { $0.timestamp > lastDayStart }
        var t = lastDayStart.addingTimeInterval(-86_400 + 60)
        while t <= lastDayStart { rs.append(reading(t, 200)); t = t.addingTimeInterval(60) }
        rs.sort { $0.timestamp < $1.timestamp }
        let p = try XCTUnwrap(DayPattern.compute(readings: rs, window: .fortnight, now: referenceNow, calendar: utc))
        for s in p.filled { XCTAssertEqual(s.p50, 100, accuracy: 0.001) }
    }

    func testTooFewDaysOrTooManyGapsShowsNothing() {
        XCTAssertNil(DayPattern.compute(readings: history(days: 3) { _, _ in 120 },
                                        window: .fortnight, now: referenceNow, calendar: utc))
        // Only mornings: most of the day is missing.
        let mornings = history(days: 14) { _, _ in 120 }.filter {
            utc.component(.hour, from: $0.timestamp) < 8
        }
        XCTAssertNil(DayPattern.compute(readings: mornings, window: .fortnight, now: referenceNow, calendar: utc))
    }

    func testWindowLeavesOutOlderReadings() throws {
        // 30 days: the first 16 at 250, the last 14 at 100.
        let rs = history(days: 30) { _, day in day < 16 ? 250 : 100 }
        let fortnight = try XCTUnwrap(DayPattern.compute(readings: rs, window: .fortnight, now: referenceNow, calendar: utc))
        let month = try XCTUnwrap(DayPattern.compute(readings: rs, window: .month, now: referenceNow, calendar: utc))
        XCTAssertEqual(fortnight.filled.map(\.p90).max() ?? 0, 100, accuracy: 0.001)
        XCTAssertGreaterThan(month.filled.map(\.p50).max() ?? 0, 150)
    }

    func testPercentileInterpolates() {
        XCTAssertEqual(DayPattern.percentile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(DayPattern.percentile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(DayPattern.percentile([10], 0.9), 10)
        XCTAssertEqual(DayPattern.percentile([0, 10], 0.25), 2.5)
    }

    func testClockReadsLikePeopleSayIt() {
        XCTAssertEqual(DayPatternText.clock(0), "midnight")
        XCTAssertEqual(DayPatternText.clock(720), "noon")
        XCTAssertEqual(DayPatternText.clock(180), "3 am")
        XCTAssertEqual(DayPatternText.clock(870), "2:30 pm")
        XCTAssertEqual(DayPatternText.clock(1440), "midnight")
        XCTAssertEqual(DayPatternText.span(.init(first: 24, last: 29)), "from noon to 3 pm")
    }

    func testSpokenSummaryNamesThePeriodAndTarget() throws {
        let p = try XCTUnwrap(DayPattern.compute(readings: history(days: 14) { _, _ in 120 },
                                                 window: .fortnight, now: referenceNow, calendar: utc))
        let s = DayPatternText.spoken(p, unit: .mmol, low: 70, high: 180)
        XCTAssertTrue(s.hasPrefix("Usual day over the last 14 days, from 14 days of readings."), s)
        XCTAssertTrue(s.contains("Target 3.9 to 10.0 mmol/L"), s)
        XCTAssertTrue(s.contains("stays in range all day"), s)
        XCTAssertTrue(s.contains("Steady through the day, around 6.7"), s)
        XCTAssertFalse(s.contains(".."), s)
    }

    func testCacheKeyMovesEvery15Minutes() {
        let rs = history(days: 1) { _, _ in 100 }
        let a = DayPatternCache.key(readings: rs, window: .fortnight)
        let b = DayPatternCache.key(readings: rs + [reading(referenceNow.addingTimeInterval(-120), 100)], window: .fortnight)
        let c = DayPatternCache.key(readings: rs + [reading(referenceNow.addingTimeInterval(16 * 60), 100)], window: .fortnight)
        XCTAssertEqual(a.newest, b.newest)
        XCTAssertNotEqual(a.newest, c.newest)
        XCTAssertNotEqual(a, DayPatternCache.key(readings: rs, window: .month))
    }
}
