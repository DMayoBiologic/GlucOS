import XCTest
@testable import GlucOSEngine

/// Which marker a hold or hover lands on, and what the peek card says about it.
final class MarkerPeekTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHitTakesTheNearestMarkerWithinReach() {
        let spots = [MarkerPeek.Spot(id: a, x: 100, y: 200), MarkerPeek.Spot(id: b, x: 100, y: 180)]
        XCTAssertEqual(MarkerPeek.hit(x: 102, y: 198, in: spots), a)
        XCTAssertEqual(MarkerPeek.hit(x: 101, y: 183, in: spots), b)
        // Off every marker: the chart's own touches (scrub, the yesterday menu) carry on.
        XCTAssertNil(MarkerPeek.hit(x: 160, y: 200, in: spots))
        XCTAssertNil(MarkerPeek.hit(x: 100, y: 100, in: []))
    }

    func testHitRadiusEdgeAndTies() {
        let spots = [MarkerPeek.Spot(id: a, x: 0, y: 0), MarkerPeek.Spot(id: b, x: 0, y: 40)]
        XCTAssertEqual(MarkerPeek.hit(x: MarkerPeek.hitRadius, y: 0, in: spots), a)
        XCTAssertNil(MarkerPeek.hit(x: MarkerPeek.hitRadius + 0.5, y: 0, in: spots))
        // Exactly between two: the first listed, so it never flips.
        XCTAssertEqual(MarkerPeek.hit(x: 0, y: 20, in: spots), a)
    }

    func testHoldingStillVersusScrubbing() {
        XCTAssertTrue(MarkerPeek.isHolding(dx: 0, dy: 0))
        XCTAssertTrue(MarkerPeek.isHolding(dx: 6, dy: 8))
        XCTAssertFalse(MarkerPeek.isHolding(dx: 8, dy: 8))
    }

    func testHoldComesBeforeTheSystemMenu() {
        // The system's touch-and-hold menu fires at about 0.5 s; the peek must win on a marker.
        XCTAssertLessThan(MarkerPeek.holdDuration, 0.5)
    }

    func testAgo() {
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(-20), now: now), "Just now")
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(-25 * 60), now: now), "25 min ago")
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(-120 * 60), now: now), "2 h ago")
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(-125 * 60), now: now), "2 h 5 min ago")
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(30), now: now), "Just now")
        XCTAssertEqual(MarkerPeek.ago(now.addingTimeInterval(5 * 60), now: now), "Soon")
    }

    func testDetailNamesTheReadingNearestThen() {
        let logged = now.addingTimeInterval(-25 * 60)
        let readings = [GlucoseReading(timestamp: logged.addingTimeInterval(-4 * 60), mgdl: 126, trend: .flat),
                        GlucoseReading(timestamp: logged.addingTimeInterval(2 * 60), mgdl: 130, trend: .flat)]
        XCTAssertEqual(MarkerPeek.reading(near: logged, in: readings)?.mgdl, 130)
        XCTAssertEqual(MarkerPeek.detail(date: logged, now: now, readings: readings, unit: .mmol),
                       "25 min ago · 7.2 mmol/L then")
        XCTAssertEqual(MarkerPeek.detail(date: logged, now: now, readings: readings, unit: .mgdl),
                       "25 min ago · 130 mg/dL then")
    }

    func testNoReadingNearbySaysOnlyWhen() {
        let logged = now.addingTimeInterval(-60 * 60)
        let far = [GlucoseReading(timestamp: logged.addingTimeInterval(-11 * 60), mgdl: 100, trend: .flat)]
        XCTAssertNil(MarkerPeek.reading(near: logged, in: far))
        XCTAssertEqual(MarkerPeek.detail(date: logged, now: now, readings: far, unit: .mmol), "1 h ago")
    }
}
