import XCTest
@testable import GlucOSEngine

/// What the glucose chart shows and plots while its span changes and readings arrive.
final class ChartSpanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One reading every 5 minutes for `hours`.
    private func readings(hours: Double) -> [GlucoseReading] {
        (0...Int(hours * 12)).map {
            GlucoseReading(timestamp: start.addingTimeInterval(Double($0) * 300), mgdl: 100 + Double($0 % 7), trend: .flat)
        }
    }

    func testAxisCoversTheSpanBackFromTheNewestReading() throws {
        let r = readings(hours: 24)
        let last = r.last!.timestamp
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3))
        XCTAssertEqual(w.domain.lowerBound, last.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(w.domain.upperBound, last)
        XCTAssertEqual(w.visible.count, 37)          // 3 h of 5-minute readings, both ends included
        XCTAssertTrue(w.visible.allSatisfy { w.domain.contains($0.timestamp) })
    }

    func testOneLeadOfReadingsStaysPlottedPastTheLeftEdge() throws {
        let r = readings(hours: 24)
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3))
        let past = w.plotted.filter { $0.timestamp < w.domain.lowerBound }
        XCTAssertEqual(past.count, 2)                // 10 minutes of lead
        let still = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3, lead: 0))
        XCTAssertEqual(Array(still.plotted), Array(still.visible))
    }

    func testShortHistoryStartsAtTheFirstReadingAsBefore() throws {
        let r = readings(hours: 2)
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 12, dataHours: 12))
        XCTAssertEqual(w.domain.lowerBound, r.first!.timestamp)
        XCTAssertEqual(w.visible.count, r.count)
    }

    func testAxisReachesTheForecastEnd() throws {
        let r = readings(hours: 6)
        let end = r.last!.timestamp.addingTimeInterval(3600)
        let w = try XCTUnwrap(ChartSpan(readings: r, domainHours: 3, dataHours: 3, forecastEnd: end))
        XCTAssertEqual(w.domain.upperBound, end)
    }

    func testNoReadingsNoWindow() {
        XCTAssertNil(ChartSpan(readings: [], domainHours: 3, dataHours: 3))
    }

    func testWideningPlotsTheWiderDataBeforeTheAxisMoves() throws {
        let r = readings(hours: 24)
        var t = ChartSpanTransition(hours: 3)
        t.prepare(for: 24)
        XCTAssertEqual(t.domainHours, 3)
        XCTAssertEqual(t.dataHours, 24)
        let before = try XCTUnwrap(ChartSpan(readings: r, domainHours: t.domainHours, dataHours: t.dataHours))
        XCTAssertEqual(before.visible.count, 37)     // nothing new on screen yet
        XCTAssertEqual(before.plotted.count, r.count) // but already plotted, off the left edge
        t.move(to: 24)
        t.settle(generation: t.generation)
        XCTAssertEqual(t.domainHours, 24)
        XCTAssertEqual(t.dataHours, 24)
    }

    func testNarrowingKeepsTheDataUntilTheAxisHasMoved() {
        var t = ChartSpanTransition(hours: 24)
        t.prepare(for: 3)
        let g = t.generation
        t.move(to: 3)
        XCTAssertEqual(t.domainHours, 3)
        XCTAssertEqual(t.dataHours, 24)              // still sliding off the left
        t.settle(generation: g)
        XCTAssertEqual(t.dataHours, 3)
    }

    func testAnOverlappingChangeIsNotTrimmedByTheEarlierOnesEnd() {
        var t = ChartSpanTransition(hours: 24)
        t.prepare(for: 3)
        let first = t.generation
        t.move(to: 3)
        t.prepare(for: 12)                           // picked again before the first move ended
        t.move(to: 12)
        t.settle(generation: first)
        XCTAssertEqual(t.dataHours, 24)              // the first move's end changes nothing
        t.settle(generation: t.generation)
        XCTAssertEqual(t.dataHours, 12)
    }

    func testReduceMotionJumps() {
        var t = ChartSpanTransition(hours: 3)
        t.jump(to: 24)
        XCTAssertEqual(t.domainHours, 24)
        XCTAssertEqual(t.dataHours, 24)
    }

    // MARK: Detail kept through a move (Mac dashboard)

    func testDetailStaysAtTheStartingSpanUntilTheMoveSettles() {
        var t = ChartSpanTransition(hours: 3)
        XCTAssertFalse(t.isChanging)
        t.prepare(for: 720)                          // 3 hours to 30 days
        XCTAssertTrue(t.isChanging)
        XCTAssertEqual(t.detailHours, 3)
        t.move(to: 720)
        XCTAssertEqual(t.detailHours, 3)             // still drawn at 3-hour detail while gliding
        t.settle(generation: t.generation)
        XCTAssertEqual(t.detailHours, 720)
        XCTAssertFalse(t.isChanging)
    }

    func testNarrowingKeepsTheWideDetailUntilItSettles() {
        var t = ChartSpanTransition(hours: 720)
        t.prepare(for: 3)
        t.move(to: 3)
        XCTAssertEqual(t.detailHours, 720)
        XCTAssertTrue(t.isChanging)
        t.settle(generation: t.generation)
        XCTAssertEqual(t.detailHours, 3)
    }

    func testJumpClearsDetail() {
        var t = ChartSpanTransition(hours: 3)
        t.prepare(for: 24)
        t.jump(to: 168)
        XCTAssertEqual(t.detailHours, 168)
        XCTAssertFalse(t.isChanging)
    }

    // MARK: PeriodSpan (Mac dashboard)

    func testPeriodSpanEndsAtThePeriodEndNotTheNewestReading() {
        let r = readings(hours: 48)
        let end = start.addingTimeInterval(24 * 3600)          // a past period
        let p = PeriodSpan(readings: r, end: end, transition: ChartSpanTransition(hours: 3))
        XCTAssertEqual(p.domain, end.addingTimeInterval(-3 * 3600)...end)
        XCTAssertEqual(p.visible.count, 37)
        XCTAssertTrue(p.visible.allSatisfy { p.domain.contains($0.timestamp) })
        XCTAssertTrue(p.plotted.allSatisfy { $0.timestamp <= end })
        XCTAssertEqual(p.plotted.filter { $0.timestamp < p.domain.lowerBound }.count, 2)   // the lead
        XCTAssertNil(p.detailStart)
    }

    func testPeriodSpanPlotsTheWiderEndWhileWidening() {
        let r = readings(hours: 48)
        let end = r.last!.timestamp
        var t = ChartSpanTransition(hours: 3)
        t.prepare(for: 24)
        let p = PeriodSpan(readings: r, end: end, transition: t, lead: 0)
        XCTAssertEqual(p.visible.count, 37)                    // the axis hasn't moved yet
        XCTAssertEqual(p.plotted.count, 24 * 12 + 1)           // but 24 hours are drawn
        XCTAssertEqual(p.detailStart, end.addingTimeInterval(-3 * 3600))
    }

    func testPeriodSpanWithNoReadingsInThePeriod() {
        let r = readings(hours: 2)
        let p = PeriodSpan(readings: r, end: start.addingTimeInterval(-3600), transition: ChartSpanTransition(hours: 3))
        XCTAssertTrue(p.visible.isEmpty)
        XCTAssertTrue(p.plotted.isEmpty)
        XCTAssertTrue(PeriodSpan(readings: [], end: start, transition: ChartSpanTransition(hours: 3)).plotted.isEmpty)
    }
}
