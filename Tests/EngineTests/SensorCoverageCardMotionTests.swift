import XCTest
@testable import GlucOSEngine

final class SensorCoverageCardMotionTests: XCTestCase {
    func testBarsGrowTopToBottomAfterTheMeter() {
        let delays = (0..<SensorCoverage.longestShown).map(SensorCoverageCardMotion.growDelay(order:))
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertGreaterThan(delays[0], SensorCoverageCardMotion.meterStart)
        XCTAssertEqual(delays[1] - delays[0], SensorCoverageCardMotion.growStep, accuracy: 1e-9)
        // Out-of-range places never start before the first or wait forever.
        XCTAssertEqual(SensorCoverageCardMotion.growDelay(order: -3), delays[0])
        XCTAssertLessThan(SensorCoverageCardMotion.growDelay(order: 99), 1)
    }

    func testScaleIsTheLongestAndNeverBelowAMinute() {
        XCTAssertEqual(SensorCoverageCardMotion.scale(lengths: []), 60)
        XCTAssertEqual(SensorCoverageCardMotion.scale(lengths: [600, 3_600, 1_200]), 3_600)
    }

    func testCompareSharesTheScale() {
        let now = [3_600.0, 1_800]
        XCTAssertEqual(SensorCoverageCardMotion.scale(lengths: now, previous: [1_200]), 3_600)
        let wider = SensorCoverageCardMotion.scale(lengths: now, previous: [7_200, 600])
        XCTAssertEqual(wider, 7_200)
        XCTAssertEqual(SensorCoverageCardMotion.fraction(3_600, scale: wider), 0.5, accuracy: 1e-9)
    }

    func testFraction() {
        XCTAssertEqual(SensorCoverageCardMotion.fraction(0, scale: 600, minimum: 0.1), 0)
        XCTAssertEqual(SensorCoverageCardMotion.fraction(300, scale: 600), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SensorCoverageCardMotion.fraction(600, scale: 86_400, minimum: 0.04), 0.04, accuracy: 1e-9)
        XCTAssertEqual(SensorCoverageCardMotion.fraction(9_000, scale: 600), 1)
        XCTAssertEqual(SensorCoverageCardMotion.fraction(60, scale: 0), 0)
    }

    func testPreviousMarkOnlyWhereThePeriodBeforeHadAGap() {
        XCTAssertNil(SensorCoverageCardMotion.previousLength(at: 0, in: nil))
        XCTAssertEqual(SensorCoverageCardMotion.previousLength(at: 0, in: [900, 600]), 900)
        XCTAssertNil(SensorCoverageCardMotion.previousLength(at: 2, in: [900, 600]))
        XCTAssertNil(SensorCoverageCardMotion.previousLength(at: 0, in: [0]))
    }

    func testLengthsFollowTheListedOrder() throws {
        let start = referenceNow.addingTimeInterval(-14 * 86_400 + 300)
        let holes: [(TimeInterval, TimeInterval)] = [(2 * 86_400, 1_800), (5 * 86_400, 7_200), (9 * 86_400, 900)]
        var readings: [GlucoseReading] = []
        var t = start
        while t <= referenceNow {
            let skip = holes.contains { back, length in
                let s = referenceNow.addingTimeInterval(-back)
                return t > s && t < s.addingTimeInterval(length)
            }
            if !skip { readings.append(reading(t, 120)) }
            t = t.addingTimeInterval(300)
        }
        let context = ReadingGaps.Context(sensor: nil, polls: PollLog(), device: .mac)
        let s = try XCTUnwrap(SensorCoverage.compute(readings: readings, context: context, period: .fortnight))
        let lengths = SensorCoverageCardMotion.lengths(s)
        XCTAssertEqual(lengths, [7_200, 1_800, 900])
        XCTAssertEqual(SensorCoverageCardMotion.scale(lengths: lengths), 7_200)
    }
}
