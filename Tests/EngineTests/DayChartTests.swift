import XCTest
@testable import GlucOSEngine

final class DayChartTests: XCTestCase {
    private var day: Date { utc.startOfDay(for: referenceNow).addingTimeInterval(-86_400) }
    private var dayEnd: Date { DayChart.end(of: day, calendar: utc) }

    private func every(_ step: Int, from start: Date, to end: Date, _ mgdl: Double = 120) -> [GlucoseReading] {
        stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Double(step) * 60)
            .map { reading(Date(timeIntervalSince1970: $0), mgdl) }
    }

    func testEndIsNextMidnight() {
        XCTAssertEqual(DayChart.end(of: day, calendar: utc), day.addingTimeInterval(86_400))
        XCTAssertEqual(DayChart.end(of: day.addingTimeInterval(3600), calendar: utc), day.addingTimeInterval(86_400))
    }

    func testOneMinuteReadingsBecomeFiveMinutePoints() throws {
        let r = every(1, from: day, to: day.addingTimeInterval(3600))
        let s = DayChart.segments(r, from: day, to: dayEnd)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].count, 12)
        // Each point sits at its readings' mean time: minutes 0–4 → 2.
        XCTAssertEqual(try XCTUnwrap(s[0].first).date, day.addingTimeInterval(120))
    }

    func testWholeDayNeverPassesBucketCount() {
        let r = every(1, from: day, to: dayEnd)
        XCTAssertEqual(DayChart.segments(r, from: day, to: dayEnd).joined().count, 288)
    }

    func testOnlyTheDaysReadings() {
        let r = every(5, from: day.addingTimeInterval(-3600), to: dayEnd.addingTimeInterval(3600))
        let points = DayChart.segments(r, from: day, to: dayEnd).joined()
        XCTAssertTrue(points.allSatisfy { $0.date >= day && $0.date < dayEnd })
        XCTAssertEqual(points.count, 288)
    }

    func testGapBreaksTheLine() {
        let morning = every(5, from: day, to: day.addingTimeInterval(2 * 3600))
        let evening = every(5, from: day.addingTimeInterval(6 * 3600), to: day.addingTimeInterval(8 * 3600))
        let s = DayChart.segments(evening + morning, from: day, to: dayEnd)
        XCTAssertEqual(s.count, 2)
        XCTAssertLessThan(s[0].last!.date, s[1].first!.date)
    }

    func testFifteenMinuteHistoryStaysOneLine() {
        let r = every(15, from: day, to: dayEnd)
        XCTAssertEqual(DayChart.segments(r, from: day, to: dayEnd).count, 1)
    }

    func testZeroReadingsSkipped() {
        let r = [reading(day.addingTimeInterval(60), 0), reading(day.addingTimeInterval(120), 100)]
        let s = DayChart.segments(r, from: day, to: dayEnd)
        XCTAssertEqual(s.joined().map(\.mgdl), [100])
    }

    func testExtremes() throws {
        let r = [reading(day.addingTimeInterval(3600), 60), reading(day.addingTimeInterval(7200), 220),
                 reading(day.addingTimeInterval(7500), 120)]
        let e = try XCTUnwrap(DayChart.extremes(DayChart.segments(r, from: day, to: dayEnd)))
        XCTAssertEqual(e.lowest.mgdl, 60)
        XCTAssertEqual(e.highest.mgdl, 220)
        XCTAssertNil(DayChart.extremes([]))
    }

    func testToggleOneAtATime() {
        XCTAssertEqual(DayChart.toggled(open: nil, tapped: "a"), "a")
        XCTAssertNil(DayChart.toggled(open: "a", tapped: "a"))
        XCTAssertEqual(DayChart.toggled(open: "a", tapped: "b"), "b")
        XCTAssertEqual(DayChart.stillOpen("a", among: ["a", "b"]), "a")
        XCTAssertNil(DayChart.stillOpen("c", among: ["a", "b"]))
        XCTAssertNil(DayChart.stillOpen(nil, among: ["a"]))
    }

    func testSpokenSummary() {
        let r = [reading(day.addingTimeInterval(3600), 60), reading(day.addingTimeInterval(7200), 220),
                 reading(day.addingTimeInterval(8 * 3600), 120)]
        let s = DayChart.segments(r, from: day, to: dayEnd)
        let text = DayChartText.spoken(day: .yesterday, figures: DayInRange(below: 0.04, inRange: 0.78, above: 0.18),
                                       segments: s, unit: .mgdl, low: 70, high: 180, logged: 3,
                                       calendar: utc, locale: Locale(identifier: "en_AU"))
        XCTAssertTrue(text.hasPrefix("Yesterday, chart. 78% in range, 4% below, 18% above. Lowest 60 mg/dL at "), text)
        XCTAssertTrue(text.contains("highest 220 mg/dL at "), text)
        XCTAssertTrue(text.contains("Target 70 to 180."), text)
        XCTAssertTrue(text.contains("2 gaps in readings."), text)
        XCTAssertTrue(text.hasSuffix("3 entries logged."), text)
    }

    func testSpokenWithoutReadings() {
        let text = DayChartText.spoken(day: .today, figures: nil, segments: [], unit: .mgdl, low: 70, high: 180,
                                       logged: 1, calendar: utc)
        XCTAssertEqual(text, "Today, chart. No readings. Target 70 to 180. 1 entry logged.")
        XCTAssertNil(DayChartText.caption([], unit: .mgdl, calendar: utc))
    }

    func testCacheOnlyRecomputesOnChange() {
        let cache = DayChartCache()
        let r = every(5, from: day, to: dayEnd)
        _ = cache.segments(readings: r, from: day, to: dayEnd)
        _ = cache.segments(readings: r, from: day, to: dayEnd)
        XCTAssertEqual(cache.computeCount, 1)
        _ = cache.segments(readings: r + [reading(dayEnd, 100)], from: day, to: dayEnd)
        XCTAssertEqual(cache.computeCount, 2)
        _ = cache.segments(readings: r, from: day.addingTimeInterval(-86_400), to: day)
        XCTAssertEqual(cache.computeCount, 3)
    }
}
