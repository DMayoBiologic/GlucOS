import XCTest
@testable import GlucOSEngine

/// The menu bar hover preview: what the card holds, and when it opens and closes.
final class MenuBarHoverPreviewTests: XCTestCase {
    private func snapshot(mgdl: Double, trend: Trend = .rising, ageSeconds: TimeInterval,
                          history: [GlucoseReading] = []) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = GlucoseReading(timestamp: referenceNow.addingTimeInterval(-ageSeconds), mgdl: mgdl, trend: trend)
        s.history = history
        return s
    }

    /// One reading every five minutes over `minutes`, ending five minutes ago.
    private func readings(minutes: Int, from start: Double, step: Double = 0) -> [GlucoseReading] {
        stride(from: minutes, through: 5, by: -5).enumerated().map { i, m in
            GlucoseReading(timestamp: referenceNow.addingTimeInterval(-Double(m) * 60),
                           mgdl: start + Double(i) * step, trend: .flat)
        }
    }

    // MARK: Card

    func testLiveReadingShowsValueTrendAndAge() throws {
        let p = try XCTUnwrap(MenuBarHoverPreview.make(snapshot: snapshot(mgdl: 115, ageSeconds: 180),
                                                       recent: [], now: referenceNow))
        XCTAssertEqual(p.valueText, "6.4")
        XCTAssertEqual(p.unitText, "mmol/L")
        XCTAssertEqual(p.trend, .rising)
        XCTAssertEqual(p.trendText, "Rising")
        XCTAssertEqual(p.ageText, "3 min ago")
        XCTAssertFalse(p.isStale)
        XCTAssertEqual(p.range, .inRange)
    }

    func testStaleReadingLosesItsTrend() throws {
        let p = try XCTUnwrap(MenuBarHoverPreview.make(snapshot: snapshot(mgdl: 115, ageSeconds: 25 * 60),
                                                       recent: [], now: referenceNow))
        XCTAssertTrue(p.isStale)
        XCTAssertNil(p.trend)
        XCTAssertEqual(p.trendText, "No trend")
        XCTAssertEqual(p.ageText, "25 min ago")
    }

    func testNothingToPreviewWithoutAReading() {
        XCTAssertNil(MenuBarHoverPreview.make(snapshot: GlucoseSnapshot(), recent: [], now: referenceNow))
    }

    func testAgeText() {
        XCTAssertEqual(MenuBarHoverPreview.ageText(20), "Just now")
        XCTAssertEqual(MenuBarHoverPreview.ageText(60), "1 min ago")
        XCTAssertEqual(MenuBarHoverPreview.ageText(59 * 60), "59 min ago")
        XCTAssertEqual(MenuBarHoverPreview.ageText(3600), "1 h ago")
        XCTAssertEqual(MenuBarHoverPreview.ageText(3600 + 5 * 60), "1 h 5 min ago")
        XCTAssertEqual(MenuBarHoverPreview.ageText(2 * 86_400 + 60), "2 d ago")
    }

    func testChartCoversTwoHoursDeduplicatedAndInOrder() throws {
        let archive = readings(minutes: 180, from: 100)   // three hours: only the last two count
        let s = snapshot(mgdl: 110, ageSeconds: 60, history: Array(archive.suffix(6)))   // overlaps the archive
        let p = try XCTUnwrap(MenuBarHoverPreview.make(snapshot: s, recent: archive, now: referenceNow))
        // 120…5 minutes ago every 5 minutes = 24, plus the current reading.
        XCTAssertEqual(p.points.count, 25)
        XCTAssertEqual(p.points.map(\.x), p.points.map(\.x).sorted())
        XCTAssertGreaterThanOrEqual(p.points.first!.x, 0)
        XCTAssertLessThanOrEqual(p.points.last!.x, 1)
        XCTAssertTrue(p.points.allSatisfy { (0...1).contains($0.y) })
        XCTAssertEqual(p.points.filter(\.startsSegment).count, 1)
    }

    func testGapsLiftTheLine() throws {
        let early = readings(minutes: 110, from: 120).prefix(3)   // 110, 105, 100 min ago
        let late = readings(minutes: 30, from: 120)                // 30…5 min ago
        let p = try XCTUnwrap(MenuBarHoverPreview.make(snapshot: snapshot(mgdl: 120, ageSeconds: 60),
                                                       recent: Array(early) + late, now: referenceNow))
        XCTAssertEqual(p.points.filter(\.startsSegment).count, 2)
    }

    func testTargetBandSitsInsideTheChart() throws {
        let p = try XCTUnwrap(MenuBarHoverPreview.make(snapshot: snapshot(mgdl: 115, ageSeconds: 60),
                                                       recent: readings(minutes: 120, from: 110), now: referenceNow))
        XCTAssertGreaterThan(p.bandHigh, p.bandLow)
        XCTAssertGreaterThanOrEqual(p.bandLow, 0)
        XCTAssertLessThanOrEqual(p.bandHigh, 1)
    }

    func testMovementLine() {
        let rising = readings(minutes: 120, from: 100, step: 2)   // +46 mg/dL over the two hours
        XCTAssertEqual(MenuBarHoverPreview.movement(rising, unit: .mmol), "Up 2.6 over two hours")
        let level = readings(minutes: 120, from: 100)
        XCTAssertEqual(MenuBarHoverPreview.movement(level, unit: .mmol), "Level over two hours")
        XCTAssertNil(MenuBarHoverPreview.movement(readings(minutes: 30, from: 100), unit: .mmol))
    }

    // MARK: When it shows

    private typealias P = MenuBarHoverPreview

    func testRestingOpensAfterTheDelay() {
        var phase = P.next(.idle, on: .pointerEntered, allowed: true)
        XCTAssertEqual(phase, .pending)
        phase = P.next(phase, on: .delayElapsed, allowed: true)
        XCTAssertEqual(phase, .showing)
        XCTAssertEqual(P.next(phase, on: .pointerExited, allowed: true), .idle)
        XCTAssertEqual(P.hoverDelay, 0.6)
    }

    func testLeavingBeforeTheDelayNeverOpens() {
        let phase = P.next(.pending, on: .pointerExited, allowed: true)
        XCTAssertEqual(phase, .idle)
        XCTAssertEqual(P.next(phase, on: .delayElapsed, allowed: true), .idle)
    }

    func testAClickClosesItUntilThePointerLeaves() {
        let phase = P.next(.showing, on: .interaction, allowed: true)
        XCTAssertEqual(phase, .dismissed)
        // Still on the item as the popover closes: it doesn't come back.
        XCTAssertEqual(P.next(phase, on: .pointerEntered, allowed: true), .dismissed)
        XCTAssertEqual(P.next(phase, on: .delayElapsed, allowed: true), .dismissed)
        XCTAssertEqual(P.next(phase, on: .pointerExited, allowed: true), .idle)
        // A click while waiting stops it opening too.
        XCTAssertEqual(P.next(.pending, on: .interaction, allowed: true), .dismissed)
    }

    func testNeverOpensWhileNotAllowed() {
        // Popover open, setting off, or nothing to show.
        XCTAssertEqual(P.next(.idle, on: .pointerEntered, allowed: false), .idle)
        XCTAssertEqual(P.next(.pending, on: .delayElapsed, allowed: false), .idle)
    }

    func testReduceMotionShowsAStillImage() {
        XCTAssertTrue(P.fades(reduceMotion: false))
        XCTAssertFalse(P.fades(reduceMotion: true))
    }
}
