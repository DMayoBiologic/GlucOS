import XCTest
@testable import GlucOSEngine

/// Which steps of a scrub along the glucose chart give a haptic tick.
final class ChartScrubTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// One reading every 5 minutes with these values (mg/dL).
    private func readings(_ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(timestamp: at(Double($0.offset) * 5), mgdl: $0.element, trend: .flat) }
    }

    private func tick(_ from: Double, _ to: Double, _ r: [GlucoseReading], logged: [Double] = []) -> ChartScrub.Tick? {
        ChartScrub.tick(from: at(from), to: at(to), readings: r, lowMgdl: 70, highMgdl: 180, logged: logged.map(at))
    }

    func testMovingWithinOneBandDoesNotTick() {
        let r = readings([100, 110, 120, 130])
        XCTAssertNil(tick(0, 5, r))
        XCTAssertNil(tick(0, 15, r))
        XCTAssertNil(tick(15, 0, r))
        XCTAssertNil(tick(5, 5, r))
    }

    func testCrossingTheHighOrLowLineTicksBothWays() {
        let r = readings([160, 175, 190, 200, 65])
        XCTAssertEqual(tick(5, 10, r), .rangeEdge)
        XCTAssertEqual(tick(10, 5, r), .rangeEdge)
        XCTAssertNil(tick(10, 15, r))
        XCTAssertEqual(tick(15, 20, r), .rangeEdge)       // high straight to low
    }

    func testTheLinesThemselvesCountAsInRange() {
        let r = readings([70, 180, 69, 181])
        XCTAssertNil(tick(0, 5, r))
        XCTAssertEqual(tick(0, 10, r), .rangeEdge)
        XCTAssertEqual(tick(5, 15, r), .rangeEdge)
    }

    func testUrgentLowAndVeryHighAreNotExtraEdges() {
        let r = readings([60, 50, 240, 260])
        XCTAssertNil(tick(0, 5, r))
        XCTAssertNil(tick(10, 15, r))
    }

    func testAFastDragThatSkipsAShortLowStillTicks() {
        // In, low for one reading, back in: the two ends agree but the trace crossed twice.
        let r = readings([100, 90, 62, 95, 110])
        XCTAssertEqual(tick(0, 20, r), .rangeEdge)
        XCTAssertEqual(tick(20, 0, r), .rangeEdge)
    }

    func testPassingSomethingLoggedTicks() {
        let r = readings([100, 105, 110, 115])
        XCTAssertEqual(tick(0, 5, r, logged: [2]), .logged)
        XCTAssertEqual(tick(5, 0, r, logged: [2]), .logged)
        XCTAssertEqual(tick(0, 15, r, logged: [12]), .logged)
        XCTAssertNil(tick(5, 10, r, logged: [2]))
        XCTAssertNil(tick(0, 5, r, logged: [20]))
    }

    func testAMarkerOnAReadingTicksOnArrivalNotOnLeaving() {
        let r = readings([100, 105, 110])
        XCTAssertEqual(tick(0, 5, r, logged: [5]), .logged)
        XCTAssertNil(tick(5, 10, r, logged: [5]))
        XCTAssertEqual(tick(10, 5, r, logged: [5]), .logged)
        XCTAssertNil(tick(5, 0, r, logged: [5]))
    }

    func testARangeEdgeWinsOverAMarkerInTheSameStep() {
        let r = readings([170, 190])
        XCTAssertEqual(tick(0, 5, r, logged: [3]), .rangeEdge)
    }

    func testAGapInTheDataComparesTheReadingsEitherSide() {
        // The finger crossed a gap (no hovered reading), so the step is from 0 to 60 minutes.
        let r = [GlucoseReading(timestamp: at(0), mgdl: 100, trend: .flat),
                 GlucoseReading(timestamp: at(60), mgdl: 200, trend: .flat)]
        XCTAssertEqual(tick(0, 60, r), .rangeEdge)
    }
}
