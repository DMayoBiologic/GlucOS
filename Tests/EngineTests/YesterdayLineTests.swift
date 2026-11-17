import XCTest
@testable import GlucOSEngine

/// Yesterday's faint line on the chart: the same clock time a day earlier, including on the days
/// the clocks change.
final class YesterdayLineTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// One reading every `step` seconds from `start` to `end`, wobbling so each is distinguishable.
    private func readings(from start: Date, to end: Date, step: TimeInterval = 300) -> [GlucoseReading] {
        stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: step).enumerated().map { i, t in
            GlucoseReading(timestamp: Date(timeIntervalSince1970: t), mgdl: 100 + Double(i % 40), trend: .flat)
        }
    }

    private func clock(_ d: Date, _ c: Calendar) -> [Int] {
        let parts = c.dateComponents([.hour, .minute], from: d)
        return [parts.hour!, parts.minute!]
    }

    // MARK: An ordinary day

    func testAnOrdinaryDayIsExactly24HoursBack() {
        let now = referenceNow
        let r = readings(from: now.addingTimeInterval(-49 * 3600), to: now)
        let p = YesterdayLine.points(readings: r, from: now.addingTimeInterval(-3 * 3600), to: now, calendar: utc)
        XCTAssertEqual(p.count, 37)            // 3 h of 5-minute readings, both ends
        XCTAssertTrue(p.allSatisfy { $0.date.timeIntervalSince($0.readAt) == 86_400 })
        XCTAssertEqual(Set(p.map(\.segment)), [0])
        XCTAssertEqual(p.first?.date, now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(p.last?.date, now)
    }

    func testTodaysOwnReadingsNeverShowAsYesterday() {
        let now = referenceNow
        let r = readings(from: now.addingTimeInterval(-12 * 3600), to: now)
        XCTAssertTrue(YesterdayLine.points(readings: r, from: now.addingTimeInterval(-3 * 3600), to: now, calendar: utc).isEmpty)
    }

    func testTheLineCanRunOnPastNowUnderTheForecast() {
        let now = referenceNow
        let r = readings(from: now.addingTimeInterval(-49 * 3600), to: now)
        let p = YesterdayLine.points(readings: r, from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600), calendar: utc)
        XCTAssertEqual(p.last?.date, now.addingTimeInterval(3600))
    }

    func testAGapInYesterdaysReadingsBreaksTheLine() {
        let now = referenceNow
        var r = readings(from: now.addingTimeInterval(-27 * 3600), to: now.addingTimeInterval(-26 * 3600))
        r += readings(from: now.addingTimeInterval(-25 * 3600), to: now.addingTimeInterval(-24 * 3600))
        let p = YesterdayLine.points(readings: r, from: now.addingTimeInterval(-3 * 3600), to: now, calendar: utc)
        XCTAssertEqual(Set(p.map(\.segment)), [0, 1])
        let firstOfSecond = p.first { $0.segment == 1 }
        XCTAssertEqual(firstOfSecond?.readAt, now.addingTimeInterval(-25 * 3600))
    }

    func testOncePerMinuteReadingsAreThinned() {
        let now = referenceNow
        let r = readings(from: now.addingTimeInterval(-27 * 3600), to: now.addingTimeInterval(-24 * 3600), step: 60)
        let p = YesterdayLine.points(readings: r, from: now.addingTimeInterval(-3 * 3600), to: now, calendar: utc)
        XCTAssertLessThanOrEqual(p.count, 37)
        XCTAssertGreaterThanOrEqual(p.count, 30)
        for (a, b) in zip(p, p.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.date.timeIntervalSince(a.date), YesterdayLine.spacing)
        }
        XCTAssertEqual(Set(p.map(\.segment)), [0])
    }

    // MARK: Days the clocks change

    /// Every point sits at the same clock time as it was read, one calendar day on, always moving
    /// forward, and the hour the clocks skipped today brings nothing in.
    private func assertLinesUpByClock(_ zone: String, today: (Int, Int, Int), file: StaticString = #filePath, line: UInt = #line) {
        let c = calendar(zone)
        let start = date(c, today.0, today.1, today.2, 0)
        let end = date(c, today.0, today.1, today.2, 12)
        let r = readings(from: start.addingTimeInterval(-30 * 3600), to: end)
        XCTAssertTrue(YesterdayLine.clocksChange(between: start, and: end, calendar: c), file: file, line: line)
        let p = YesterdayLine.points(readings: r, from: start, to: end, calendar: c)
        XCTAssertGreaterThan(p.count, 100, file: file, line: line)
        for point in p {
            XCTAssertEqual(clock(point.date, c), clock(point.readAt, c), file: file, line: line)
            XCTAssertEqual(c.dateComponents([.day], from: c.startOfDay(for: point.readAt), to: c.startOfDay(for: point.date)).day, 1,
                           file: file, line: line)
        }
        for (a, b) in zip(p, p.dropFirst()) {
            XCTAssertLessThan(a.date, b.date, file: file, line: line)
        }
        XCTAssertEqual(Set(p.map(\.readAt)).count, p.count, file: file, line: line)
    }

    func testClocksGoingForwardLineUpByClockTime() {
        assertLinesUpByClock("America/New_York", today: (2026, 3, 8))
        assertLinesUpByClock("Europe/London", today: (2026, 3, 29))
        assertLinesUpByClock("Australia/Sydney", today: (2026, 10, 4))
    }

    func testClocksGoingBackLineUpByClockTime() {
        assertLinesUpByClock("America/New_York", today: (2026, 11, 1))
        assertLinesUpByClock("Europe/London", today: (2026, 10, 25))
        assertLinesUpByClock("Australia/Sydney", today: (2026, 4, 5))
    }

    func testSpringForwardMorningIs23HoursAfterYesterdaysAndSkippedHourIsLeftOut() {
        let c = calendar("America/New_York")
        let start = date(c, 2026, 3, 8, 0), end = date(c, 2026, 3, 8, 12)
        let r = readings(from: start.addingTimeInterval(-30 * 3600), to: end)
        let p = YesterdayLine.points(readings: r, from: start, to: end, calendar: c)
        let eight = p.first { $0.readAt == date(c, 2026, 3, 7, 8) }
        XCTAssertEqual(eight?.date, date(c, 2026, 3, 8, 8))
        XCTAssertEqual(eight.map { $0.date.timeIntervalSince($0.readAt) }, 23 * 3600)
        // 2 am to 3 am didn't happen today, so yesterday's readings from then have nowhere to go.
        XCTAssertFalse(p.contains { c.component(.hour, from: $0.readAt) == 2 })
    }

    func testFallBackMorningIs25HoursAfterYesterdays() {
        let c = calendar("America/New_York")
        let start = date(c, 2026, 11, 1, 0), end = date(c, 2026, 11, 1, 12)
        let r = readings(from: start.addingTimeInterval(-30 * 3600), to: end)
        let p = YesterdayLine.points(readings: r, from: start, to: end, calendar: c)
        let eight = p.first { $0.readAt == date(c, 2026, 10, 31, 8) }
        XCTAssertEqual(eight?.date, date(c, 2026, 11, 1, 8))
        XCTAssertEqual(eight.map { $0.date.timeIntervalSince($0.readAt) }, 25 * 3600)
        // The repeated hour: yesterday's 1 am readings are drawn once, not twice.
        XCTAssertEqual(p.filter { c.component(.hour, from: $0.readAt) == 1 }.count, 12)
    }

    func testOrdinaryDaysNeedNoCalendarSums() {
        let now = referenceNow
        XCTAssertFalse(YesterdayLine.clocksChange(between: now.addingTimeInterval(-86_400), and: now, calendar: utc))
        let c = calendar("Australia/Perth")
        XCTAssertFalse(YesterdayLine.clocksChange(between: now.addingTimeInterval(-86_400), and: now, calendar: c))
        let ny = calendar("America/New_York")
        let mid = date(ny, 2026, 6, 15, 12)
        XCTAssertFalse(YesterdayLine.clocksChange(between: mid.addingTimeInterval(-86_400), and: mid, calendar: ny))
    }

    // MARK: "Yesterday at this time"

    func testYesterdayAtThisTimeFollowsTheClockAcrossDaylightSaving() {
        let c = calendar("America/New_York")
        let r = readings(from: date(c, 2026, 3, 6, 0), to: date(c, 2026, 3, 8, 12))
            + readings(from: date(c, 2026, 10, 30, 0), to: date(c, 2026, 11, 1, 12))
        XCTAssertEqual(YesterdayLine.reading(at: date(c, 2026, 3, 8, 9), in: r, calendar: c)?.timestamp, date(c, 2026, 3, 7, 9))
        XCTAssertEqual(YesterdayLine.reading(at: date(c, 2026, 11, 1, 9), in: r, calendar: c)?.timestamp, date(c, 2026, 10, 31, 9))
        XCTAssertEqual(YesterdayLine.reading(at: date(c, 2026, 3, 8, 9, 2), in: r, calendar: c)?.timestamp, date(c, 2026, 3, 7, 9))
    }

    func testNothingCloseYesterdaySaysNothing() {
        let now = referenceNow
        let r = readings(from: now.addingTimeInterval(-30 * 3600), to: now.addingTimeInterval(-25 * 3600))
        XCTAssertNil(YesterdayLine.reading(at: now, in: r, calendar: utc))
        XCTAssertNil(YesterdayLine.spoken(nil, unit: .mmol))
        let found = YesterdayLine.reading(at: now.addingTimeInterval(-3600), in: r, calendar: utc)
        XCTAssertNotNil(found)
        let line = YesterdayLine.spoken(found, unit: .mmol)
        XCTAssertEqual(line?.hasPrefix("Yesterday at this time: "), true)
        XCTAssertEqual(line?.hasSuffix("."), true)
    }

    func testMenuTitleAndHoursNeeded() {
        XCTAssertEqual(YesterdayLine.menuTitle(showing: false), "Show Yesterday's Line")
        XCTAssertEqual(YesterdayLine.menuTitle(showing: true), "Hide Yesterday's Line")
        XCTAssertEqual(YesterdayLine.hoursNeeded(forSpan: 24.25), 49.25)
    }
}
