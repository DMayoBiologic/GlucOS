import XCTest
@testable import GlucOSEngine

final class TodaySoFarTests: XCTestCase {
    // referenceNow is 14:00 UTC, so "today so far" is midnight to 2 pm.

    /// Readings every `step` minutes from `days` days before today's midnight up to `referenceNow`,
    /// following `value` (minute of the UTC day, days before today: 0 = today) -> mg/dL.
    private func history(days: Int, step: Int = 5, value: (Int, Int) -> Double?) -> [GlucoseReading] {
        let todayStart = utc.startOfDay(for: referenceNow)
        var out: [GlucoseReading] = []
        var t = todayStart.addingTimeInterval(-Double(days) * 86_400)
        while t <= referenceNow {
            let minute = Int(t.timeIntervalSince(utc.startOfDay(for: t)) / 60)
            let ago = Int((todayStart.timeIntervalSince(utc.startOfDay(for: t)) / 86_400).rounded())
            if let v = value(minute, ago) { out.append(reading(t, v)) }
            t = t.addingTimeInterval(Double(step) * 60)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], window: DayPattern.Window = .fortnight) -> TodaySoFar? {
        TodaySoFar.compute(readings: readings, window: window, low: 70, high: 180, now: referenceNow, calendar: utc)
    }

    func testSameAsUsual() throws {
        let t = try XCTUnwrap(compute(history(days: 14) { _, _ in 120 }))
        XCTAssertEqual(t.minute, 14 * 60)
        XCTAssertEqual(t.today.timeInRange, 1, accuracy: 0.001)
        XCTAssertEqual(t.today.meanMgdl, 120, accuracy: 0.001)
        XCTAssertEqual(t.today.lows, 0)
        let u = try XCTUnwrap(t.usual)
        XCTAssertEqual(u.days, 14)
        XCTAssertEqual(u.daysWithLows, 0)
        XCTAssertEqual(t.rangeChange, .same)
        XCTAssertEqual(TodaySoFarText.headline(t), "About your usual day by now.")
        XCTAssertEqual(TodaySoFarText.period(t), "Midnight to 2 pm")
        XCTAssertEqual(TodaySoFarText.lowsCaption(t), "Usually none by now")
    }

    func testUsualOnlyCountsTheSameHours() throws {
        // Earlier days are high only after 2 pm, which today hasn't reached: usual stays in range.
        let t = try XCTUnwrap(compute(history(days: 14) { m, ago in ago > 0 && m > 14 * 60 ? 250 : 120 }))
        XCTAssertEqual(try XCTUnwrap(t.usual).timeInRange, 1, accuracy: 0.001)
        XCTAssertEqual(t.rangeChange, .same)
    }

    func testBetterAndWorseThanUsual() throws {
        // Earlier days are above range every morning until 6 am (25% of the hours to 2 pm).
        let better = try XCTUnwrap(compute(history(days: 14) { m, ago in ago > 0 && m < 6 * 60 ? 220 : 120 }))
        XCTAssertEqual(try XCTUnwrap(better.usual).timeInRange, 0.57, accuracy: 0.02)
        XCTAssertEqual(better.rangeChange, .better)
        XCTAssertTrue(TodaySoFarText.headline(better).hasPrefix("More time in range"))
        XCTAssertEqual(TodaySoFarText.meanCaption(better, unit: .mgdl), "Usually 163")

        let worse = try XCTUnwrap(compute(history(days: 14) { m, ago in ago == 0 && m < 6 * 60 ? 220 : 120 }))
        XCTAssertEqual(worse.rangeChange, .worse)
        XCTAssertTrue(TodaySoFarText.headline(worse).hasPrefix("Less time in range"))
    }

    func testUsualIsTheMedianDay() throws {
        // One terrible day out of 14 doesn't move the usual day.
        let t = try XCTUnwrap(compute(history(days: 14) { _, ago in ago == 3 ? 300 : 120 }))
        let u = try XCTUnwrap(t.usual)
        XCTAssertEqual(u.timeInRange, 1, accuracy: 0.001)
        XCTAssertEqual(u.meanMgdl, 120, accuracy: 0.001)
    }

    func testLowsCountRunsOfFifteenMinutes() throws {
        // Today: a 30-minute low at 3 am and a 10-minute dip at 9 am (too short to count).
        // Earlier: 4 of the 14 days had a 20-minute low at 4 am.
        let t = try XCTUnwrap(compute(history(days: 14) { m, ago in
            if ago == 0 { return (180..<210).contains(m) || (540..<550).contains(m) ? 60 : 120 }
            return ago <= 4 && (240..<260).contains(m) ? 62 : 120
        }))
        XCTAssertEqual(t.today.lows, 1)
        let u = try XCTUnwrap(t.usual)
        XCTAssertEqual(u.daysWithLows, 4)
        XCTAssertEqual(TodaySoFarText.lowsCaption(t), "4 of 14 days by now")
        XCTAssertTrue(TodaySoFarText.spoken(t, unit: .mgdl).contains("1 low. 4 of the last 14 days had one by this time"))
    }

    func testOneMinuteReadingsCountLikeFifteen() throws {
        // Today on 1-minute Bluetooth readings, high from 1 pm; earlier days on 15-minute history.
        let earlier = history(days: 14, step: 15) { _, ago in ago > 0 ? 120 : nil }
        let today = history(days: 0, step: 1) { m, _ in m >= 13 * 60 ? 220 : 120 }
        let t = try XCTUnwrap(compute(earlier + today))
        XCTAssertEqual(t.today.timeInRange, 13.0 / 14.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(t.usual).days, 14)
    }

    func testNeedsAnHourAndHalfTheReadings() {
        // Nothing today after 12:30 am.
        XCTAssertNil(compute(history(days: 14) { m, ago in ago == 0 && m > 30 ? nil : 120 }))
        // Today has readings only from noon: under half of midnight to 2 pm.
        XCTAssertNil(compute(history(days: 14) { m, ago in ago == 0 && m < 12 * 60 ? nil : 120 }))
        // The newest reading is yesterday's.
        XCTAssertNil(compute(history(days: 14) { _, ago in ago == 0 ? nil : 120 }))
    }

    func testTodayAloneUntilFiveUsualDays() throws {
        let t = try XCTUnwrap(compute(history(days: 3) { _, _ in 120 }))
        XCTAssertNil(t.usual)
        XCTAssertNil(t.rangeChange)
        XCTAssertEqual(TodaySoFarText.headline(t), "100% of today in range so far.")
        XCTAssertTrue(TodaySoFarText.footnote(t).hasPrefix("Your usual day joins in"))
        XCTAssertFalse(TodaySoFarText.spoken(t, unit: .mmol).contains("usually"))
    }

    func testLowRunStillGoingCountsOnceLongEnough() {
        let start = referenceNow
        let pts = (0..<3).map { (start.addingTimeInterval(Double($0) * 300), 60.0) }
        XCTAssertEqual(TodaySoFar.lowRuns(pts, low: 70), 1)
        XCTAssertEqual(TodaySoFar.lowRuns(Array(pts.prefix(2)), low: 70), 0)
    }

    func testCacheKeyMovesEveryFiveMinutesAndOnNewDay() {
        let a = history(days: 1) { _, _ in 120 }
        let k1 = TodaySoFarCache.key(readings: a, window: .fortnight, low: 70, high: 180, now: referenceNow, calendar: utc)
        let k2 = TodaySoFarCache.key(readings: a + [reading(referenceNow.addingTimeInterval(60), 120)],
                                     window: .fortnight, low: 70, high: 180, now: referenceNow, calendar: utc)
        XCTAssertEqual(k1.newest, k2.newest)
        let k3 = TodaySoFarCache.key(readings: a, window: .fortnight, low: 70, high: 180,
                                     now: referenceNow.addingTimeInterval(11 * 3600), calendar: utc)
        XCTAssertNotEqual(k1, k3)
    }
}
