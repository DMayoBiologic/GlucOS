import XCTest
@testable import GlucOSEngine

final class InsightsDeltaTests: XCTestCase {
    // MARK: Delta maths

    func testTimeInRangeUpIsBetterInPoints() {
        let d = InsightsDelta.timeInRange(0.72, 0.68)
        XCTAssertEqual(d.direction, .up)
        XCTAssertEqual(d.verdict, .better)
        XCTAssertEqual(d.points, 4)
        XCTAssertEqual(d.badge, "4 pts")
        XCTAssertEqual(d.spoken(label: "Time in range", previous: "the previous 14 days"),
                       "Time in range up 4 points on the previous 14 days, better.")
    }

    func testTimeInRangeDownIsWorse() {
        let d = InsightsDelta.timeInRange(0.60, 0.61)
        XCTAssertEqual(d.direction, .down)
        XCTAssertEqual(d.verdict, .worse)
        XCTAssertEqual(d.spoken(label: "Time in range", previous: "the previous 7 days"),
                       "Time in range down 1 point on the previous 7 days, worse.")
    }

    func testTimeAboveUpIsWorse() {
        let d = InsightsDelta.timeAbove(0.30, 0.22)
        XCTAssertEqual(d.direction, .up)
        XCTAssertEqual(d.verdict, .worse)
        XCTAssertEqual(InsightsDelta.timeAbove(0.10, 0.22).verdict, .better)
    }

    func testShareWithinHalfAPointReadsAsSame() {
        let d = InsightsDelta.timeInRange(0.703, 0.700)
        XCTAssertEqual(d.direction, .same)
        XCTAssertEqual(d.verdict, .neutral)
        XCTAssertEqual(d.badge, "Same")
        XCTAssertEqual(d.spoken(label: "Time in range", previous: "the previous 14 days"),
                       "Time in range the same as the previous 14 days.")
    }

    func testFewerLowsIsBetterAndEqualIsSame() {
        let fewer = InsightsDelta.count(3, 5)
        XCTAssertEqual(fewer.direction, .down)
        XCTAssertEqual(fewer.verdict, .better)
        XCTAssertEqual(fewer.badge, "2")
        XCTAssertEqual(fewer.spoken(label: "Lows", previous: "the previous 14 days"),
                       "Lows down 2 on the previous 14 days, better.")
        XCTAssertEqual(InsightsDelta.count(6, 4).verdict, .worse)
        let same = InsightsDelta.count(4, 4)
        XCTAssertEqual(same.direction, .same)
        XCTAssertEqual(same.verdict, .neutral)
    }

    func testAverageCloserToTheMiddleOfRangeIsBetter() {
        // Range 70–180, middle 125.
        let d = InsightsDelta.average(140, 160, unit: .mgdl, low: 70, high: 180)
        XCTAssertEqual(d.direction, .down)
        XCTAssertEqual(d.verdict, .better)
        XCTAssertEqual(d.badge, "20")
        XCTAssertEqual(d.spoken(label: "Average", previous: "the previous 24 hours"),
                       "Average down 20 mg/dL on the previous 24 hours, better.")
        XCTAssertEqual(InsightsDelta.average(170, 150, unit: .mgdl, low: 70, high: 180).verdict, .worse)
        // Falling from above the middle to as far below it: moved, but neither closer nor further.
        let across = InsightsDelta.average(100, 150, unit: .mgdl, low: 70, high: 180)
        XCTAssertEqual(across.direction, .down)
        XCTAssertEqual(across.verdict, .neutral)
    }

    func testAverageSameWithinTheWrittenStep() {
        // 0.5 mg/dL is under 0.05 mmol/L, so it reads as no change in mmol/L.
        XCTAssertEqual(InsightsDelta.average(150.5, 150, unit: .mmol, low: 70, high: 180).direction, .same)
        XCTAssertEqual(InsightsDelta.average(152, 150, unit: .mmol, low: 70, high: 180).direction, .up)
        XCTAssertEqual(InsightsDelta.average(152, 150, unit: .mmol, low: 70, high: 180).badge, "0.1")
        XCTAssertEqual(InsightsDelta.average(150.4, 150, unit: .mgdl, low: 70, high: 180).direction, .same)
        XCTAssertEqual(InsightsDelta.average(151, 150, unit: .mgdl, low: 70, high: 180).direction, .up)
    }

    func testSpokenJoinsOnlyTheDeltasThatExist() {
        let text = InsightsCompare.spoken([("Lows", .count(1, 2)), ("Highs", nil)], previous: "the previous 7 days")
        XCTAssertEqual(text, "Lows down 1 on the previous 7 days, better.")
        XCTAssertNil(InsightsCompare.spoken([("Lows", nil)], previous: "the previous 7 days"))
    }

    func testPreviousPhrase() {
        XCTAssertEqual(InsightsCompare.previousPhrase(days: 14), "the previous 14 days")
        XCTAssertEqual(InsightsCompare.previousPhrase(hours: 24), "the previous 24 hours")
        XCTAssertEqual(InsightsCompare.previousPhrase(hours: 168), "the previous 7 days")
    }

    // MARK: Enough data

    func testNeedsFourOfEverySevenDays() {
        XCTAssertTrue(InsightsCompare.hasEnough(covered: 4, of: 7))
        XCTAssertFalse(InsightsCompare.hasEnough(covered: 3, of: 7))
        XCTAssertTrue(InsightsCompare.hasEnough(covered: 8, of: 14))
        XCTAssertFalse(InsightsCompare.hasEnough(covered: 7, of: 14))
        XCTAssertTrue(InsightsCompare.hasEnough(covered: 18, of: 30))
        XCTAssertFalse(InsightsCompare.hasEnough(covered: 17, of: 30))
        XCTAssertFalse(InsightsCompare.hasEnough(covered: 0, of: 0))
    }

    func testPreviousSliceIsTheLengthBeforeTheLength() {
        let rs = readings(endingAt: referenceNow, minutes: 3 * 24 * 60, step: 60) { _ in 120 }
        let slice = InsightsCompare.previousSlice(rs, end: referenceNow, seconds: 86_400)
        XCTAssertEqual(slice.first?.timestamp, referenceNow.addingTimeInterval(-2 * 86_400 + 3600))
        XCTAssertEqual(slice.last?.timestamp, referenceNow.addingTimeInterval(-86_400))
        XCTAssertEqual(slice.count, 24)
    }

    func testAlignmentAllowsADayOfDrift() {
        let length = 7.0 * 86_400
        let start = referenceNow.addingTimeInterval(-length)
        XCTAssertTrue(InsightsCompare.isAligned(previousEnd: start, currentEnd: referenceNow, seconds: length))
        XCTAssertTrue(InsightsCompare.isAligned(previousEnd: start.addingTimeInterval(-20 * 3600),
                                                currentEnd: referenceNow, seconds: length))
        XCTAssertFalse(InsightsCompare.isAligned(previousEnd: start.addingTimeInterval(-2 * 86_400),
                                                 currentEnd: referenceNow, seconds: length))
    }

    // MARK: Cards

    /// Readings every 5 minutes over `days` up to referenceNow, at 120 except 55 for 30 minutes
    /// from 03:00 UTC on each of `lowDaysAgo`, and 220 for 2 hours from 18:00 on each of `highDaysAgo`.
    private func history(days: Int, lowDaysAgo: [Int] = [], highDaysAgo: [Int] = []) -> [GlucoseReading] {
        let today = utc.startOfDay(for: referenceNow)
        let lows = lowDaysAgo.map { today.addingTimeInterval(Double(-$0) * 86_400 + 3 * 3600) }
        let highs = highDaysAgo.map { today.addingTimeInterval(Double(-$0) * 86_400 + 18 * 3600) }
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-Double(days) * 86_400 + 300)
        while t <= referenceNow {
            let low = lows.contains { t >= $0 && t < $0.addingTimeInterval(1800) }
            let high = highs.contains { t >= $0 && t < $0.addingTimeInterval(7200) }
            out.append(reading(t, low ? 55 : (high ? 220 : 120)))
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func lows(_ rs: [GlucoseReading], _ period: LowsSummary.Period = .fortnight) -> LowsSummary? {
        LowsSummary.compute(readings: rs, meals: [], contexts: [], answers: [], low: 70, period: period, calendar: utc)
    }

    private func previousLows(_ rs: [GlucoseReading], _ current: LowsSummary) -> LowsSummary? {
        InsightsCompare.previousLows(readings: rs, meals: [], contexts: [], answers: [], low: 70,
                                     current: current, calendar: utc)
    }

    func testLowsCompareWithTheFortnightBefore() throws {
        let rs = history(days: 30, lowDaysAgo: [3, 18, 20])
        let current = try XCTUnwrap(lows(rs))
        XCTAssertEqual(current.count, 1)
        let previous = try XCTUnwrap(previousLows(rs, current))
        XCTAssertEqual(previous.count, 2)
        let delta = try XCTUnwrap(InsightsCompare.lows(current, previous))
        XCTAssertEqual(delta.direction, .down)
        XCTAssertEqual(delta.verdict, .better)
    }

    func testNoComparisonWithoutAPreviousPeriod() throws {
        let rs = history(days: 14, lowDaysAgo: [3])
        let current = try XCTUnwrap(lows(rs))
        XCTAssertNil(previousLows(rs, current))
        XCTAssertNil(InsightsCompare.lows(current, nil))
    }

    func testNoComparisonWhenThePreviousPeriodIsMostlyEmpty() throws {
        // 18 days: the fortnight before holds only 4 days of readings.
        let rs = history(days: 18, lowDaysAgo: [3, 16])
        let current = try XCTUnwrap(lows(rs))
        XCTAssertNil(previousLows(rs, current))
    }

    func testHighsCompareTimeAboveAndCount() throws {
        let rs = history(days: 14, highDaysAgo: [1, 2, 9])
        let current = try XCTUnwrap(HighsSummary.compute(readings: rs, high: 180, period: .week, calendar: utc))
        let previous = try XCTUnwrap(InsightsCompare.previousHighs(readings: rs, high: 180, current: current, calendar: utc))
        XCTAssertEqual(current.count, 2)
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(InsightsCompare.highs(current, previous)?.verdict, .worse)
        XCTAssertEqual(InsightsCompare.timeAbove(current, previous)?.direction, .up)
        XCTAssertEqual(InsightsCompare.timeAbove(current, previous)?.verdict, .worse)
    }

    func testGlanceComparesTheWindowBefore() throws {
        let rs = readings(endingAt: referenceNow, minutes: 48 * 60) { m in m < 24 * 60 ? 120 : 200 }
        let current = try XCTUnwrap(GlucoseStats.compute(rs.filter { $0.timestamp > referenceNow.addingTimeInterval(-86_400) },
                                                         low: 70, high: 180))
        let previous = try XCTUnwrap(InsightsCompare.previousGlance(readings: rs, hours: 24, now: referenceNow,
                                                                    low: 70, high: 180))
        XCTAssertEqual(InsightsCompare.glanceRange(current, previous)?.verdict, .better)
        XCTAssertEqual(InsightsCompare.glanceAverage(current, previous, unit: .mgdl, low: 70, high: 180)?.verdict, .better)
    }

    func testGlanceNeedsMostOfThePreviousWindow() {
        // 30 hours: the 24 before the last 24 hold only 6 hours of readings.
        let rs = readings(endingAt: referenceNow, minutes: 30 * 60) { _ in 120 }
        XCTAssertNil(InsightsCompare.previousGlance(readings: rs, hours: 24, now: referenceNow, low: 70, high: 180))
    }
}
