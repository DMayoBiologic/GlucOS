import XCTest
@testable import GlucOSEngine

final class DayInRangeTests: XCTestCase {
    // referenceNow is 14:00 UTC.
    private var today: Date { utc.startOfDay(for: referenceNow) }
    private var yesterday: Date { today.addingTimeInterval(-86_400) }

    /// Readings every `step` minutes from `start` until `end`, following `value(minute of day)`.
    private func readings(from start: Date, to end: Date, step: Int = 5,
                          _ value: (Int) -> Double?) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = start
        while t < end {
            let minute = Int(t.timeIntervalSince(utc.startOfDay(for: t)) / 60)
            if let v = value(minute) { out.append(reading(t, v)) }
            t = t.addingTimeInterval(Double(step) * 60)
        }
        return out
    }

    private func compute(_ r: [GlucoseReading], days: [Date]) -> [Date: DayInRange] {
        DayInRange.compute(readings: r, days: days, low: 70, high: 180, now: referenceNow, calendar: utc)
    }

    func testWholeDayInRange() throws {
        let r = readings(from: yesterday, to: today) { _ in 120 }
        let d = try XCTUnwrap(compute(r, days: [yesterday])[yesterday])
        XCTAssertEqual(d.inRange, 1, accuracy: 0.001)
        XCTAssertEqual(d.below, 0, accuracy: 0.001)
        XCTAssertEqual(d.above, 0, accuracy: 0.001)
    }

    func testSharesCountFiveMinuteBucketsNotReadings() throws {
        // Low midnight–3 am in 1-minute readings, high 3–9 am in 15-minute ones, in range after.
        let low = readings(from: yesterday, to: yesterday.addingTimeInterval(3 * 3600), step: 1) { _ in 60 }
        let high = readings(from: yesterday.addingTimeInterval(3 * 3600), to: yesterday.addingTimeInterval(9 * 3600),
                            step: 15) { _ in 220 }
        let rest = readings(from: yesterday.addingTimeInterval(9 * 3600), to: today) { _ in 120 }
        let d = try XCTUnwrap(compute(low + high + rest, days: [yesterday])[yesterday])
        // 36 low buckets (1-minute readings averaged), 24 high (one per 15-minute reading), 180 in range.
        XCTAssertEqual(d.below, 36.0 / 240, accuracy: 0.001)
        XCTAssertEqual(d.above, 24.0 / 240, accuracy: 0.001)
        XCTAssertEqual(d.inRange, 180.0 / 240, accuracy: 0.001)
        XCTAssertEqual(d.below + d.inRange + d.above, 1, accuracy: 0.0001)
    }

    func testLinkUpHistoryCountsAsComplete() {
        let r = readings(from: yesterday, to: today, step: 15) { _ in 120 }
        XCTAssertNotNil(compute(r, days: [yesterday])[yesterday])
    }

    func testDayWithASensorGapHasNoBar() {
        // Readings only until 10 am: under half the day.
        let r = readings(from: yesterday, to: yesterday.addingTimeInterval(10 * 3600)) { _ in 120 }
        XCTAssertNil(compute(r, days: [yesterday])[yesterday])
    }

    func testTodayRunsToNow() throws {
        // Midnight to 2 pm: in range until noon, then high.
        let r = readings(from: today, to: referenceNow) { $0 < 12 * 60 ? 120 : 200 }
        let d = try XCTUnwrap(compute(r, days: [today])[today])
        XCTAssertEqual(d.inRange, 12.0 / 14, accuracy: 0.001)
        XCTAssertEqual(d.above, 2.0 / 14, accuracy: 0.001)
    }

    func testTodayNeedsAnHour() {
        let early = today.addingTimeInterval(40 * 60)
        let r = readings(from: today, to: early) { _ in 120 }
        XCTAssertTrue(DayInRange.compute(readings: r, days: [today], low: 70, high: 180,
                                         now: early, calendar: utc).isEmpty)
    }

    func testUnsortedReadingsAndManyDays() throws {
        let r = readings(from: yesterday.addingTimeInterval(-86_400), to: referenceNow) { _ in 150 }
        let out = compute(r.shuffled(), days: [today, yesterday, yesterday.addingTimeInterval(-86_400)])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(try XCTUnwrap(out[yesterday]).inRange, 1, accuracy: 0.001)
    }

    func testEdgesCountAsInRange() throws {
        let r = readings(from: yesterday, to: today) { $0 < 720 ? 70 : 180 }
        XCTAssertEqual(try XCTUnwrap(compute(r, days: [yesterday])[yesterday]).inRange, 1, accuracy: 0.001)
    }

    func testSpoken() {
        let d = DayInRange(below: 0.04, inRange: 0.78, above: 0.18)
        XCTAssertEqual(DayInRangeText.spoken(.today, d, calendar: utc), "Today, 78% in range, 4% below, 18% above")
        XCTAssertEqual(DayInRangeText.spoken(.yesterday, DayInRange(below: 0, inRange: 1, above: 0), calendar: utc),
                       "Yesterday, 100% in range")
        XCTAssertEqual(DayInRangeText.spoken(.today, nil, calendar: utc), "Today")
        XCTAssertEqual(DayInRangeText.percent(d), "78%")
        let tuesday = DayInRangeText.spokenDay(.other(yesterday), calendar: utc, locale: Locale(identifier: "en_AU"))
        XCTAssertFalse(tuesday.isEmpty)
        XCTAssertTrue(DayInRangeText.spoken(.other(yesterday), d, calendar: utc, locale: Locale(identifier: "en_AU"))
            .hasPrefix(tuesday + ", 78% in range"))
    }

    func testCacheOnlyRecomputesOnChange() {
        let cache = DayInRangeCache()
        let r = readings(from: yesterday, to: referenceNow) { _ in 120 }
        _ = cache.figures(readings: r, days: [yesterday, today], low: 70, high: 180, now: referenceNow, calendar: utc)
        _ = cache.figures(readings: r, days: [yesterday, today], low: 70, high: 180,
                          now: referenceNow.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(cache.computeCount, 1)
        _ = cache.figures(readings: r + [reading(referenceNow, 120)], days: [yesterday, today], low: 70, high: 180,
                          now: referenceNow.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(cache.computeCount, 2)
        _ = cache.figures(readings: r, days: [yesterday, today], low: 80, high: 180, now: referenceNow, calendar: utc)
        XCTAssertEqual(cache.computeCount, 3)
    }

    func testDrawnOnce() {
        let drawn = DrawnOnce()
        XCTAssertFalse(drawn.has("a"))
        XCTAssertTrue(drawn.first("a"))
        XCTAssertFalse(drawn.first("a"))
        XCTAssertTrue(drawn.has("a"))
        XCTAssertTrue(drawn.first("b"))
    }

    func testFirstRowsPerDay() {
        let ids = (0..<5).map { _ in UUID() }
        let times = [referenceNow, referenceNow.addingTimeInterval(-3600),
                     yesterday.addingTimeInterval(20 * 3600), yesterday.addingTimeInterval(3600),
                     yesterday.addingTimeInterval(-3600)]
        let firsts = LogbookDays.firstRows(zip(ids, times).map { (id: $0, timestamp: $1) }, calendar: utc)
        XCTAssertEqual(firsts, [ids[0]: today, ids[2]: yesterday, ids[4]: yesterday.addingTimeInterval(-86_400)])
    }

    // MARK: Breakdown

    func testBreakdownSpreadsTheDayByShare() throws {
        // Low midnight–1 am, high 6–10 am, in range the rest, in 15-minute LinkUp history.
        let r = readings(from: yesterday, to: today, step: 15) { m in
            m < 60 ? 60 : (m >= 360 && m < 600 ? 220 : 120)
        }
        let d = try XCTUnwrap(compute(r, days: [yesterday])[yesterday])
        XCTAssertEqual(d.spanMinutes, 1440)
        let parts = d.parts
        XCTAssertEqual(parts.map(\.band), [.below, .inRange, .above])
        XCTAssertEqual(parts[0].minutes, 60)
        XCTAssertEqual(parts[2].minutes, 240)
        XCTAssertEqual(parts[1].minutes, 1140)
        XCTAssertEqual(parts.map(\.minutes).reduce(0, +), 1440)
    }

    func testTodaysBreakdownRunsToNow() throws {
        let r = readings(from: today, to: referenceNow) { _ in 120 }
        let d = try XCTUnwrap(compute(r, days: [today])[today])
        XCTAssertEqual(d.spanMinutes, 14 * 60)
        XCTAssertEqual(d.parts[1].minutes, 14 * 60)
        XCTAssertEqual(d.parts[0].minutes, 0)
    }

    func testBreakdownNeverRoundsAShareAway() {
        let d = DayInRange(below: 0.001, inRange: 0.999, above: 0, spanMinutes: 1440)
        XCTAssertEqual(d.parts[0].minutes, 5)
        XCTAssertEqual(d.parts[1].minutes, 1435)
        XCTAssertEqual(d.parts[2].minutes, 0)
    }

    func testBreakdownWords() {
        let d = DayInRange(below: 0.04, inRange: 0.78, above: 0.18, spanMinutes: 1440)
        // 57.6 → 60 min below, 259.2 → 260 min above, the rest in range.
        XCTAssertEqual(DayInRangeBreakdownText.figure(d.parts[0], hasTimes: true), "4% · 1 h")
        XCTAssertEqual(DayInRangeBreakdownText.figure(d.parts[1], hasTimes: true), "78% · 18 h 40 min")
        XCTAssertEqual(DayInRangeBreakdownText.figure(d.parts[2], hasTimes: true), "18% · 4 h 20 min")
        XCTAssertEqual(DayInRangeBreakdownText.help(d),
                       "In range 78% · 18 h 40 min, below 4% · 1 h, above 18% · 4 h 20 min. Click to show the day's chart.")
        XCTAssertEqual(DayInRangeBreakdownText.spoken(d),
                       "78% in range, 18 hours 40 minutes. 4% below, 1 hour. 18% above, 4 hours 20 minutes")
        XCTAssertEqual(DayInRangeBreakdownText.duration(25), "25 min")
        XCTAssertEqual(DayInRangeBreakdownText.spokenDuration(61), "1 hour 1 minute")
        // Shares only (no span known): just the percents.
        let bare = DayInRange(below: 0, inRange: 1, above: 0)
        XCTAssertEqual(DayInRangeBreakdownText.spoken(bare), "100% in range")
        XCTAssertEqual(DayInRangeBreakdownText.figure(bare.parts[1], hasTimes: false), "100%")
    }
}
