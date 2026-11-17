import XCTest
@testable import GlucOSEngine

/// Where a scrub along the glucose chart snaps: logged markers and each day's lowest and highest.
final class ScrubSnapTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let locale = Locale(identifier: "en_AU")
    /// A midnight, UTC.
    private let midnight = Date(timeIntervalSince1970: 1_799_971_200)

    private func at(_ minutes: Double) -> Date { midnight.addingTimeInterval(minutes * 60) }

    /// One reading every 5 minutes from `start` minutes, with these values (mg/dL).
    private func readings(from start: Double = 0, _ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(timestamp: at(start + Double($0.offset) * 5), mgdl: $0.element, trend: .flat) }
    }

    private func everything(_ r: [GlucoseReading]) -> ClosedRange<Date> { r.first!.timestamp...r.last!.timestamp }

    // MARK: Extremes

    func testEachDayHasItsLowestAndHighest() {
        let r = readings([120, 95, 150, 180, 110])
        let e = ScrubSnap.extremes(readings: r, visible: everything(r), calendar: utc)
        XCTAssertEqual(e, [ScrubSnap.Target(date: at(5), kind: .lowest(mgdl: 95)),
                           ScrubSnap.Target(date: at(15), kind: .highest(mgdl: 180))])
    }

    func testTheWholeDayCountsButOnlyWhatsOnScreenSnaps() {
        // The day's low at 00:05 is off screen; "highest" is still the day's own, not the screen's.
        let r = readings([120, 60, 150, 180, 110])
        let e = ScrubSnap.extremes(readings: r, visible: at(10)...at(20), calendar: utc)
        XCTAssertEqual(e, [ScrubSnap.Target(date: at(15), kind: .highest(mgdl: 180))])
        // The on-screen lowest (110 at 00:20) isn't the day's, so it isn't a target.
        XCTAssertFalse(e.contains { if case .lowest = $0.kind { return true } else { return false } })
    }

    func testTwoDaysOnScreenEachHaveTheirOwn() {
        // 23:50 to 00:15: yesterday's last two readings, then today's first four.
        let r = readings(from: -10, [100, 80, 140, 200, 90, 120])
        let e = ScrubSnap.extremes(readings: r, visible: everything(r), calendar: utc)
        XCTAssertEqual(e.map(\.kind), [.highest(mgdl: 100), .lowest(mgdl: 80), .highest(mgdl: 200), .lowest(mgdl: 90)])
        XCTAssertEqual(e.map(\.date), [at(-10), at(-5), at(5), at(10)])
    }

    func testATieKeepsTheEarliestReading() {
        let r = readings([100, 70, 150, 70, 150])
        let e = ScrubSnap.extremes(readings: r, visible: everything(r), calendar: utc)
        XCTAssertEqual(e.map(\.date), [at(5), at(10)])
    }

    func testAFlatDayHasNothingToSnapTo() {
        let r = readings([110, 110, 110])
        XCTAssertTrue(ScrubSnap.extremes(readings: r, visible: everything(r), calendar: utc).isEmpty)
        XCTAssertTrue(ScrubSnap.extremes(readings: [], visible: at(0)...at(10), calendar: utc).isEmpty)
    }

    func testMarkersComeFirstAndOnlyOnScreen() {
        let r = readings([120, 95, 150])
        let a = UUID(), b = UUID()
        let t = ScrubSnap.targets(logged: [.init(id: a, date: at(6), label: "Meal at 12:06 am"),
                                           .init(id: b, date: at(-30), label: "Off screen")],
                                  readings: r, visible: everything(r), calendar: utc)
        XCTAssertEqual(t.first, ScrubSnap.Target(date: at(6), kind: .logged(id: a, label: "Meal at 12:06 am")))
        XCTAssertEqual(t.count, 3)
    }

    // MARK: Snapping

    /// 30 seconds per point: 8 points is 4 minutes, 14 points is 7 minutes.
    private let spp: Double = 30

    func testSnapsOnlyWithinReach() {
        let low = ScrubSnap.Target(date: at(60), kind: .lowest(mgdl: 60))
        XCTAssertEqual(ScrubSnap.snap(finger: at(57), targets: [low], current: nil, secondsPerPoint: spp), low)
        XCTAssertEqual(ScrubSnap.snap(finger: at(64), targets: [low], current: nil, secondsPerPoint: spp), low)
        XCTAssertNil(ScrubSnap.snap(finger: at(55), targets: [low], current: nil, secondsPerPoint: spp))
        XCTAssertNil(ScrubSnap.snap(finger: at(66), targets: [low], current: nil, secondsPerPoint: spp))
    }

    func testHoldsOnUntilTheFingerMovesFurtherAway() {
        let low = ScrubSnap.Target(date: at(60), kind: .lowest(mgdl: 60))
        // Past reach but within let-go: still snapped, so it never flickers at the edge.
        XCTAssertEqual(ScrubSnap.snap(finger: at(66), targets: [low], current: low, secondsPerPoint: spp), low)
        XCTAssertEqual(ScrubSnap.snap(finger: at(53), targets: [low], current: low, secondsPerPoint: spp), low)
        XCTAssertNil(ScrubSnap.snap(finger: at(68), targets: [low], current: low, secondsPerPoint: spp))
        // Gone from the chart (a marker deleted mid-scrub): lets go.
        XCTAssertNil(ScrubSnap.snap(finger: at(60), targets: [], current: low, secondsPerPoint: spp))
    }

    func testMovesToACloserTargetWithinReach() {
        let low = ScrubSnap.Target(date: at(60), kind: .lowest(mgdl: 60))
        let meal = ScrubSnap.Target(date: at(70), kind: .logged(id: UUID(), label: "Meal"))
        XCTAssertEqual(ScrubSnap.snap(finger: at(66), targets: [meal, low], current: low, secondsPerPoint: spp), meal)
        // Halfway: the current one holds.
        XCTAssertEqual(ScrubSnap.snap(finger: at(65), targets: [meal, low], current: low, secondsPerPoint: spp), low)
    }

    func testAMarkerWinsATie() {
        let high = ScrubSnap.Target(date: at(64), kind: .highest(mgdl: 220))
        let dose = ScrubSnap.Target(date: at(56), kind: .logged(id: UUID(), label: "Dose"))
        XCTAssertEqual(ScrubSnap.snap(finger: at(60), targets: [dose, high], current: nil, secondsPerPoint: spp), dose)
    }

    func testNoScaleNoSnap() {
        let low = ScrubSnap.Target(date: at(60), kind: .lowest(mgdl: 60))
        XCTAssertNil(ScrubSnap.snap(finger: at(60), targets: [low], current: nil, secondsPerPoint: 0))
        XCTAssertNil(ScrubSnap.snap(finger: at(60), targets: [low], current: nil, secondsPerPoint: .infinity))
    }

    func testOnlyArmsOnceTheFingerHasMovedPastAHold() {
        // 10 points at 30 s a point is 5 minutes.
        XCTAssertFalse(ScrubSnap.arms(start: at(60), finger: at(60), secondsPerPoint: spp))
        XCTAssertFalse(ScrubSnap.arms(start: at(60), finger: at(64), secondsPerPoint: spp))
        XCTAssertTrue(ScrubSnap.arms(start: at(60), finger: at(66), secondsPerPoint: spp))
        XCTAssertTrue(ScrubSnap.arms(start: at(60), finger: at(54), secondsPerPoint: spp))
        XCTAssertFalse(ScrubSnap.arms(start: at(60), finger: at(90), secondsPerPoint: 0))
    }

    // MARK: VoiceOver

    func testSpokenLines() {
        let now = at(14 * 60)
        let low = ScrubSnap.Target(date: at(2 * 60 + 15), kind: .lowest(mgdl: 70.2))
        XCTAssertEqual(ScrubSnap.spoken(low, unit: .mmol, now: now, calendar: utc, locale: locale),
                       "Lowest today, 3.9 mmol/L at \(ClockLabel.time(low.date, calendar: utc, locale: locale))")
        let high = ScrubSnap.Target(date: at(-60), kind: .highest(mgdl: 250))
        XCTAssertTrue(ScrubSnap.spoken(high, unit: .mgdl, now: now, calendar: utc, locale: locale)
            .hasPrefix("Highest yesterday, 250 mg/dL at "))
        let meal = ScrubSnap.Target(date: at(60), kind: .logged(id: UUID(), label: "Meal, 40 g carbs at 1:00 am"))
        XCTAssertEqual(ScrubSnap.spoken(meal, unit: .mmol, now: now, calendar: utc), "Meal, 40 g carbs at 1:00 am")
    }
}
