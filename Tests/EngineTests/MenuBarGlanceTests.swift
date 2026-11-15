import XCTest
@testable import GlucOSEngine

/// The Mac menu bar item redraws only when its glance changes, so these pin down what a glance
/// holds: stale readings lose their trend and colour, and nothing changes between readings except
/// at the stale moment and each minute of a stale reading's age.
final class MenuBarGlanceTests: XCTestCase {
    private func snapshot(mgdl: Double, trend: Trend = .flat, ageSeconds: TimeInterval,
                          history: [GlucoseReading] = []) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = GlucoseReading(timestamp: referenceNow.addingTimeInterval(-ageSeconds), mgdl: mgdl, trend: trend)
        s.history = history
        return s
    }

    private func glance(_ s: GlucoseSnapshot, recent: [GlucoseReading] = [], delta: Bool = false,
                        sparkline: Bool = false, colour: Bool = true, now: Date = referenceNow) -> MenuBarGlance {
        MenuBarGlance.make(snapshot: s, recent: recent, hasCredentials: true, showDelta: delta,
                           showSparkline: sparkline, colorByRange: colour, now: now)
    }

    func testLiveReadingShowsValueTrendAndRangeColour() {
        let g = glance(snapshot(mgdl: 115, trend: .rising, ageSeconds: 60))
        XCTAssertEqual(g.state, .live)
        XCTAssertEqual(g.valueText, "6.4")
        XCTAssertEqual(g.trend, .rising)
        XCTAssertEqual(g.range, .inRange)
        XCTAssertTrue(g.colored)
        XCTAssertEqual(g.text, "6.4 ↗")
    }

    func testStaleReadingDropsTrendAndColourAndShowsAge() {
        let g = glance(snapshot(mgdl: 50, trend: .falling, ageSeconds: 12 * 60 + 30))
        XCTAssertEqual(g.state, .stale)
        XCTAssertNil(g.trend)
        XCTAssertFalse(g.colored, "an old reading must never look like a live one, even an urgent low")
        XCTAssertEqual(g.ageText, "12m")
        XCTAssertEqual(g.text, "2.8 · 12m")
    }

    func testUrgentLowIsColouredEvenWithColourOff() {
        XCTAssertTrue(glance(snapshot(mgdl: 50, ageSeconds: 60), colour: false).colored)
        XCTAssertFalse(glance(snapshot(mgdl: 115, ageSeconds: 60), colour: false).colored)
    }

    func testNoReading() {
        let waiting = MenuBarGlance.make(snapshot: GlucoseSnapshot(), recent: [], hasCredentials: true,
                                         showDelta: true, showSparkline: true, colorByRange: true, now: referenceNow)
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertEqual(waiting.text, "––")
        let off = MenuBarGlance.make(snapshot: GlucoseSnapshot(), recent: [], hasCredentials: false,
                                     showDelta: true, showSparkline: true, colorByRange: true, now: referenceNow)
        XCTAssertEqual(off.state, .notConnected)
    }

    func testGlanceDoesNotChangeBetweenReadingsWhileLive() {
        let s = snapshot(mgdl: 115, ageSeconds: 30)
        XCTAssertEqual(glance(s), glance(s, now: referenceNow.addingTimeInterval(4 * 60)),
                       "a live glance holds no clock, so the item isn't redrawn as the reading ages")
    }

    func testNextChangeIsTheStaleMomentThenEachMinute() {
        let live = snapshot(mgdl: 115, ageSeconds: 60)
        let readingTime = live.current!.timestamp
        let stalesAt = MenuBarGlance.nextChange(snapshot: live, now: referenceNow)!
        XCTAssertEqual(stalesAt, readingTime.addingTimeInterval(GlucoseSnapshot.staleAfter + 1))
        XCTAssertTrue(live.isStale(at: stalesAt))
        XCTAssertFalse(live.isStale(at: stalesAt.addingTimeInterval(-1.5)))

        let stale = snapshot(mgdl: 115, ageSeconds: 7 * 60 + 20)
        let next = MenuBarGlance.nextChange(snapshot: stale, now: referenceNow)!
        XCTAssertEqual(next.timeIntervalSince(stale.current!.timestamp), 8 * 60, accuracy: 0.001)
        XCTAssertNotEqual(glance(stale).ageText, glance(stale, now: next).ageText)
        XCTAssertNil(MenuBarGlance.nextChange(snapshot: GlucoseSnapshot(), now: referenceNow))
    }

    func testSparklineCoversTheLastHourAndKeepsFlatHoursFlat() {
        // A rise from 100 to 155 over the hour, one reading a minute.
        let readings = (0..<60).map { i in
            GlucoseReading(timestamp: referenceNow.addingTimeInterval(Double(i - 59) * 60), mgdl: 100 + Double(i), trend: .rising)
        }
        let line = MenuBarGlance.sparkline(readings, endingAt: referenceNow)
        XCTAssertEqual(line.count, MenuBarGlance.sparklineBuckets)
        XCTAssertEqual(line.first, 0)
        XCTAssertEqual(line.last, 1)
        XCTAssertEqual(line, line.sorted())

        // Flat with a 2 mg/dL wobble: stays near the middle instead of spanning the full height.
        let flat = (0..<60).map { i in
            GlucoseReading(timestamp: referenceNow.addingTimeInterval(Double(i - 59) * 60),
                           mgdl: 110 + Double(i % 3), trend: .flat)
        }
        let flatLine = MenuBarGlance.sparkline(flat, endingAt: referenceNow)
        XCTAssertFalse(flatLine.isEmpty)
        XCTAssertTrue(flatLine.allSatisfy { abs($0 - 0.5) < 0.1 })

        // Too little history draws nothing, and readings older than an hour are ignored.
        let old = readings.map { GlucoseReading(timestamp: $0.timestamp.addingTimeInterval(-7200), mgdl: $0.mgdl, trend: $0.trend) }
        XCTAssertEqual(MenuBarGlance.sparkline(old, endingAt: referenceNow), [])
    }

    func testSparklineOnlyWhenTurnedOn() {
        let recent = (0..<30).map { i in
            GlucoseReading(timestamp: referenceNow.addingTimeInterval(Double(i - 30) * 120), mgdl: 120, trend: .flat)
        }
        let s = snapshot(mgdl: 120, ageSeconds: 0)
        XCTAssertTrue(glance(s, recent: recent).sparkline.isEmpty)
        XCTAssertFalse(glance(s, recent: recent, sparkline: true).sparkline.isEmpty)
    }

    func testDeltaOnlyWhenLiveAndTurnedOn() {
        let prev = GlucoseReading(timestamp: referenceNow.addingTimeInterval(-6 * 60), mgdl: 110, trend: .flat)
        let s = snapshot(mgdl: 115, ageSeconds: 60, history: [prev])
        XCTAssertEqual(glance(s, delta: true).deltaText, "+0.3")
        XCTAssertNil(glance(s).deltaText)
    }
}
