import XCTest
@testable import GlucOSEngine

/// The small per-day line under Insights figures (`InsightsSparkline`).
final class InsightsSparklineTests: XCTestCase {
    private func series(_ values: [Double?], threshold: Double = 0.05, span: Double = 0.2) -> InsightsSparkline {
        InsightsSparkline(values: values, threshold: threshold, minimumSpan: span)
    }

    private func day(_ daysAgo: Int, hour: Int = 12) -> Date {
        utc.startOfDay(for: referenceNow).addingTimeInterval(Double(-daysAgo) * 86_400 + Double(hour) * 3600)
    }

    // MARK: Direction

    func testDirection() {
        XCTAssertEqual(series([0.5, 0.55, 0.6, 0.65, 0.7]).direction, .rising)
        XCTAssertEqual(series([0.7, 0.65, 0.6, 0.55, 0.5]).direction, .falling)
        XCTAssertEqual(series([0.6, 0.62, 0.59, 0.61, 0.6]).direction, .steady)
        XCTAssertEqual(series([0.5, 0.55, 0.6, 0.65, 0.7]).summary, "rising over 5 days")
    }

    func testTooFewDaysHasNoDirection() {
        let s = series([nil, 0.5, nil, 0.9, 0.9, nil])
        XCTAssertNil(s.direction)
        XCTAssertNil(s.summary)
        XCTAssertTrue(s.drawable)
        XCTAssertFalse(series([nil, nil, 0.5]).drawable)
    }

    func testGapsDontCountTowardsDirection() {
        // Four known days rising, the rest empty.
        let s = series([0.4, nil, 0.5, nil, nil, 0.6, nil, 0.7])
        XCTAssertEqual(s.direction, .rising)
        XCTAssertEqual(s.summary, "rising over 8 days")
    }

    // MARK: Heights

    func testHeightsSpanZeroToOne() {
        let h = series([0.2, 0.8, 0.5]).heights(count: 5)
        XCTAssertEqual(h.count, 5)
        XCTAssertEqual(h.first!, 0, accuracy: 1e-9)
        XCTAssertEqual(h[2], 1, accuracy: 1e-9)
        XCTAssertEqual(h.last!, 0.5, accuracy: 1e-9)
    }

    func testSmallSpreadIsDrawnFlatter() {
        // 0.70 to 0.72 inside a 0.2 span: close to the middle, not filling the height.
        let h = series([0.70, 0.72]).heights(count: 2)
        XCTAssertEqual(h[0], 0.45, accuracy: 1e-9)
        XCTAssertEqual(h[1], 0.55, accuracy: 1e-9)
    }

    func testAllZerosSitOnTheFloor() {
        let h = series([0, 0, 0, 0], threshold: 0.5, span: 2).heights(count: 4)
        XCTAssertEqual(h, [0, 0, 0, 0])
    }

    func testFillJoinsGapsAndHoldsEnds() {
        XCTAssertEqual(InsightsSparkline.fill([nil, 1, nil, 3, nil]), [1, 1, 2, 3, 3])
        XCTAssertEqual(InsightsSparkline.fill([nil, nil]), [])
        XCTAssertTrue(series([nil, nil]).heights(count: 5).isEmpty)
    }

    // MARK: Days

    func testDayIndex() {
        let end = referenceNow
        XCTAssertEqual(InsightsSparkline.dayIndex(day(0, hour: 1), end: end, days: 14, calendar: utc), 13)
        XCTAssertEqual(InsightsSparkline.dayIndex(day(13), end: end, days: 14, calendar: utc), 0)
        XCTAssertNil(InsightsSparkline.dayIndex(day(14), end: end, days: 14, calendar: utc))
        XCTAssertNil(InsightsSparkline.dayIndex(end.addingTimeInterval(86_400), end: end, days: 14, calendar: utc))
    }

    // MARK: Builders

    func testTimeInRangeByDay() {
        // 14 days every 5 minutes: out of range (250) for the older week, in range (120) for the
        // newer one, and nothing at all 3 days ago.
        let all = readings(endingAt: referenceNow, minutes: 14 * 1_440) { m in m > 7 * 1_440 ? 250 : 120 }
        let gapStart = utc.startOfDay(for: day(3)), gapEnd = gapStart.addingTimeInterval(86_400)
        let rs = all.filter { $0.timestamp < gapStart || $0.timestamp >= gapEnd }
        let s = InsightsSparkline.timeInRange(readings: rs, low: 70, high: 180, days: 14, calendar: utc)
        XCTAssertEqual(s.days, 14)
        XCTAssertNil(s.values[10])
        XCTAssertEqual(s.values[13]!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.values[2]!, 0, accuracy: 1e-9)
        XCTAssertEqual(s.direction, .rising)
        XCTAssertEqual(s.summary, "rising over 14 days")
    }

    func testTimeInRangeWithoutReadings() {
        let s = InsightsSparkline.timeInRange(readings: [], low: 70, high: 180, calendar: utc)
        XCTAssertEqual(s.days, 14)
        XCTAssertFalse(s.drawable)
    }

    func testLowsByDay() {
        let lows = (0..<3).map { i in
            LowsSummary.Low(start: day(0, hour: 2 + i), end: day(0, hour: 2 + i).addingTimeInterval(1_200),
                            status: .unknown, part: .overnight)
        } + [LowsSummary.Low(start: day(1), end: day(1).addingTimeInterval(1_200), status: .treated, part: .afternoon)]
        let summary = LowsSummary(period: .week, end: referenceNow, lows: lows, days: 7)
        let s = InsightsSparkline.lows(summary, calendar: utc)
        XCTAssertEqual(s.values, [0, 0, 0, 0, 0, 1, 3])
        XCTAssertEqual(s.direction, .rising)
        XCTAssertEqual(InsightsSparkline.lows(LowsSummary(period: .fortnight, end: referenceNow, lows: [], days: 14),
                                              calendar: utc).summary, "steady over 14 days")
    }

    func testHighsByDay() throws {
        // Every 5 minutes for 30 days at 120, with the last three days at 220 from noon on.
        let rs = readings(endingAt: referenceNow, minutes: 30 * 1_440) { m in
            let t = referenceNow.addingTimeInterval(-m * 60)
            let recent = t >= utc.startOfDay(for: self.day(2))
            return recent && utc.component(.hour, from: t) >= 12 ? 220 : 120
        }
        let summary = try XCTUnwrap(HighsSummary.compute(readings: rs, high: 180, period: .fortnight, calendar: utc))
        XCTAssertEqual(summary.daily.count, 14)
        XCTAssertEqual(summary.daily[0]!, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.daily[12]!, 0.5, accuracy: 0.01)
        let s = InsightsSparkline.highs(summary)
        XCTAssertEqual(s.direction, .rising)
    }

    func testOvernightByNight() {
        let nights = [5, 4, 2, 1].map { back in
            OvernightSummary.Night(start: utc.startOfDay(for: day(back)), timeInRange: 1 - Double(back) * 0.1,
                                   lows: 0, changeMgdl: nil)
        }
        let summary = OvernightSummary(period: .week, end: referenceNow, nights: nights, timeInRange: 0.7, timeBelow: 0)
        let s = InsightsSparkline.overnight(summary, calendar: utc)
        XCTAssertEqual(s.values.count, 7)
        XCTAssertNil(s.values[3])
        XCTAssertNil(s.values[6])
        XCTAssertEqual(s.values[1]!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.direction, .rising)
        XCTAssertEqual(s.spokenLine(label: OvernightSummaryText.sparklineLabel),
                       "In range each night: rising over 7 days.")
    }
}
