import XCTest
@testable import GlucOSEngine

/// Panning the chart back to earlier hours and back to now (`ChartPan`), and what `ChartSpan`
/// shows while panned.
final class ChartPanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One reading every 5 minutes for `hours`.
    private func readings(hours: Double) -> [GlucoseReading] {
        (0...Int(hours * 12)).map {
            GlucoseReading(timestamp: start.addingTimeInterval(Double($0) * 300), mgdl: 100 + Double($0 % 7), trend: .flat)
        }
    }

    private func hoursBefore(_ h: Double, _ d: Date) -> Date { d.addingTimeInterval(-h * 3600) }

    // MARK: Bounds

    func testNeverFurtherBackThanADay() {
        let r = readings(hours: 72)
        let newest = r.last!.timestamp
        let end = ChartPan.clamped(hoursBefore(40, newest), newest: newest, oldest: r[0].timestamp, hours: 3)
        XCTAssertEqual(end, hoursBefore(24, newest))
    }

    func testNeverPastTheOldestReading() {
        let r = readings(hours: 10)
        let newest = r.last!.timestamp
        let end = ChartPan.clamped(hoursBefore(20, newest), newest: newest, oldest: r[0].timestamp, hours: 6)
        // The left edge stops on the oldest reading: 10 h of history on a 6 h span pans 4 h.
        XCTAssertEqual(end, hoursBefore(4, newest))
    }

    func testShortHistoryCannotPan() {
        let r = readings(hours: 2)
        let newest = r.last!.timestamp
        XCTAssertNil(ChartPan.earliestEnd(newest: newest, oldest: r[0].timestamp, hours: 3))
        XCTAssertNil(ChartPan.clamped(hoursBefore(1, newest), newest: newest, oldest: r[0].timestamp, hours: 3))
        XCTAssertFalse(ChartPan.canGoEarlier(nil, newest: newest, oldest: r[0].timestamp, hours: 3))
    }

    func testNeverIntoTheFuture() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp
        XCTAssertNil(ChartPan.clamped(newest.addingTimeInterval(600), newest: newest, oldest: r[0].timestamp, hours: 3))
        XCTAssertNil(ChartPan.clamped(newest, newest: newest, oldest: r[0].timestamp, hours: 3))
    }

    // MARK: Dragging and scrolling

    func testTheTraceFollowsTheFingers() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp, oldest = r[0].timestamp
        // 60 s per point: dragging 30 points right shows 30 minutes earlier.
        let right = ChartPan.moved(from: nil, points: 30, secondsPerPoint: 60, newest: newest, oldest: oldest, hours: 3)
        XCTAssertEqual(right, newest.addingTimeInterval(-1800))
        // Then dragging back left past where it started comes back to now, not into the future.
        let back = ChartPan.moved(from: right, points: -90, secondsPerPoint: 60, newest: newest, oldest: oldest, hours: 3)
        XCTAssertNil(back)
    }

    func testNonsenseScalesLeaveThePanAlone() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp
        let end = hoursBefore(2, newest)
        XCTAssertEqual(ChartPan.moved(from: end, points: 10, secondsPerPoint: 0, newest: newest,
                                      oldest: r[0].timestamp, hours: 3), end)
        XCTAssertEqual(ChartPan.moved(from: end, points: .nan, secondsPerPoint: 60, newest: newest,
                                      oldest: r[0].timestamp, hours: 3), end)
    }

    func testLettingGoNearNowSpringsBackToNow() {
        let newest = start
        XCTAssertNil(ChartPan.released(newest.addingTimeInterval(-4 * 60), newest: newest))
        XCTAssertNil(ChartPan.released(newest.addingTimeInterval(-5 * 60), newest: newest))
        let far = newest.addingTimeInterval(-6 * 60)
        XCTAssertEqual(ChartPan.released(far, newest: newest), far)
        XCTAssertNil(ChartPan.released(nil, newest: newest))
    }

    // MARK: VoiceOver

    func testVoiceOverStepsAQuarterOfTheSpanAndAtLeastAnHour() {
        XCTAssertEqual(ChartPan.stepSeconds(hours: 3), 3600)
        XCTAssertEqual(ChartPan.stepSeconds(hours: 12), 3 * 3600)
        XCTAssertEqual(ChartPan.stepSeconds(hours: 24), 6 * 3600)
    }

    func testVoiceOverStepsBackAndUpToNow() {
        let r = readings(hours: 48)
        let newest = r.last!.timestamp, oldest = r[0].timestamp
        var end: Date? = nil
        end = ChartPan.stepped(end, earlier: true, newest: newest, oldest: oldest, hours: 12)
        XCTAssertEqual(end, hoursBefore(3, newest))
        for _ in 0..<20 { end = ChartPan.stepped(end, earlier: true, newest: newest, oldest: oldest, hours: 12) }
        XCTAssertEqual(end, hoursBefore(24, newest))
        XCTAssertFalse(ChartPan.canGoEarlier(end, newest: newest, oldest: oldest, hours: 12))
        for _ in 0..<8 { end = ChartPan.stepped(end, earlier: false, newest: newest, oldest: oldest, hours: 12) }
        XCTAssertNil(end)
    }

    func testSpokenSaysNowOrTheSpanAndHowFarBack() {
        let newest = start
        let clock: (Date) -> String = { String(Int($0.timeIntervalSince(newest) / 3600)) }
        XCTAssertEqual(ChartPan.spoken(end: nil, newest: newest, hours: 3, clock: clock), "Now")
        XCTAssertEqual(ChartPan.spoken(end: hoursBefore(2, newest), newest: newest, hours: 3, clock: clock),
                       "-5 to -2, 2 h earlier")
        XCTAssertEqual(ChartPan.behindLabel(newest.addingTimeInterval(-(3 * 3600 + 14 * 60)), newest: newest),
                       "3 h 15 min earlier")
        XCTAssertEqual(ChartPan.behindLabel(newest.addingTimeInterval(-60), newest: newest), "5 min earlier")
    }

    // MARK: What the chart shows while panned

    func testPannedSpanEndsAtTheEdgeWithoutTheForecast() throws {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp
        let edge = hoursBefore(6, newest)
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3,
                                        forecastEnd: newest.addingTimeInterval(3600), pannedTo: edge))
        XCTAssertEqual(w.domain.upperBound, edge)
        XCTAssertEqual(w.domain.lowerBound, hoursBefore(3, edge))
        XCTAssertEqual(w.visible.count, 37)
        XCTAssertTrue(w.visible.allSatisfy { w.domain.contains($0.timestamp) })
        // One lead past each edge stays plotted, so readings slide in and out of both.
        XCTAssertEqual(w.plotted.filter { $0.timestamp > edge }.count, 2)
        XCTAssertEqual(w.plotted.filter { $0.timestamp < w.domain.lowerBound }.count, 2)
    }

    func testUnpannedSpanIsUnchanged() throws {
        let r = readings(hours: 30)
        let a = try XCTUnwrap(ChartSpan(readings: r, domainHours: 6, dataHours: 6))
        let b = try XCTUnwrap(ChartSpan(readings: r, domainHours: 6, dataHours: 6, pannedTo: nil))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.visible.last, r.last)
    }

    func testGlidingBetweenPansKeepsBothStretchesPlotted() throws {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp
        let from = hoursBefore(10, newest)
        let to = hoursBefore(4, newest)
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3, pannedTo: to,
                                        keepPlotted: hoursBefore(3, from)...from))
        XCTAssertEqual(w.domain.upperBound, to)
        XCTAssertEqual(w.plotted.first?.timestamp, hoursBefore(3, from).addingTimeInterval(-ChartSpan.lead))
        XCTAssertEqual(w.plotted.last?.timestamp, to.addingTimeInterval(ChartSpan.lead))
        // Gliding from a pan back to now plots everything up to the newest reading.
        let home = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3,
                                           keepPlotted: hoursBefore(3, to)...to))
        XCTAssertEqual(home.plotted.first?.timestamp, hoursBefore(3, to).addingTimeInterval(-ChartSpan.lead))
        XCTAssertEqual(home.plotted.last, r.last)
        XCTAssertEqual(home.visible.count, 37)
    }

    func testTheHandedReadingsCoverTheLongestSpanPannedAllTheWayBack() {
        XCTAssertGreaterThanOrEqual(ChartPan.hoursHanded,
                                    Double(ChartHours.choices.max()!) + ChartPan.maxBackHours + ChartSpan.lead / 3600)
    }

    // MARK: Mac keys

    func testOptionArrowsMoveAnHourAndCommandRightGoesHome() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp, oldest = r[0].timestamp
        let back = ChartPan.keyed(nil, .earlier, newest: newest, oldest: oldest, hours: 3)
        XCTAssertEqual(back, hoursBefore(1, newest))
        let twice = ChartPan.keyed(back, .earlier, newest: newest, oldest: oldest, hours: 3)
        XCTAssertEqual(twice, hoursBefore(2, newest))
        XCTAssertEqual(ChartPan.keyed(twice, .later, newest: newest, oldest: oldest, hours: 3), back)
        XCTAssertNil(ChartPan.keyed(back, .later, newest: newest, oldest: oldest, hours: 3))
        XCTAssertNil(ChartPan.keyed(twice, .now, newest: newest, oldest: oldest, hours: 3))
        // Later at now stays at now; never into the future.
        XCTAssertNil(ChartPan.keyed(nil, .later, newest: newest, oldest: oldest, hours: 3))
    }

    func testOptionRightLandingNearNowSnapsHome() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp, oldest = r[0].timestamp
        // 63 minutes back, an hour later is 3 minutes back: close enough to go home.
        let near = newest.addingTimeInterval(-63 * 60)
        XCTAssertNil(ChartPan.keyed(near, .later, newest: newest, oldest: oldest, hours: 3))
        // 70 minutes back stays 10 minutes back.
        let far = newest.addingTimeInterval(-70 * 60)
        XCTAssertEqual(ChartPan.keyed(far, .later, newest: newest, oldest: oldest, hours: 3), newest.addingTimeInterval(-600))
    }

    func testOptionLeftStopsAtTheLimits() {
        let r = readings(hours: 30)
        let newest = r.last!.timestamp, oldest = r[0].timestamp
        let earliest = hoursBefore(24, newest)
        XCTAssertEqual(ChartPan.keyed(earliest, .earlier, newest: newest, oldest: oldest, hours: 3), earliest)
        let short = readings(hours: 2)
        XCTAssertNil(ChartPan.keyed(nil, .earlier, newest: short.last!.timestamp, oldest: short[0].timestamp, hours: 3))
    }

    // MARK: End-time label

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testEndLabelNamesTheWeekdayAndTime() throws {
        let locale = Locale(identifier: "en_AU")
        // 1_800_000_000 is a Friday, 8:00 am UTC.
        let label = try XCTUnwrap(ChartPan.endLabel(start, calendar: utc, locale: locale))
        XCTAssertEqual(label, "Fri " + ClockLabel.time(start, calendar: utc, locale: locale))
        XCTAssertNil(ChartPan.endLabel(nil, calendar: utc, locale: locale))
        let spoken = ChartPan.endSpoken(start, calendar: utc, locale: locale)
        XCTAssertEqual(spoken, "Chart ends Friday " + ClockLabel.time(start, calendar: utc, locale: locale))
    }

    func testTheLabelIsReadOncePerNewEnd() {
        let end = start
        XCTAssertTrue(ChartPan.announces(settled: end, lastSpoken: nil))
        XCTAssertFalse(ChartPan.announces(settled: end, lastSpoken: end))
        XCTAssertFalse(ChartPan.announces(settled: end.addingTimeInterval(20), lastSpoken: end))
        XCTAssertTrue(ChartPan.announces(settled: end.addingTimeInterval(-3600), lastSpoken: end))
        // Back at now the label fades and nothing is said.
        XCTAssertFalse(ChartPan.announces(settled: nil, lastSpoken: end))
    }
}
