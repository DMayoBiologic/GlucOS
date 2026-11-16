import XCTest
@testable import GlucOSEngine

/// The soft cue when the live reading crosses into or out of the target range (improvement
/// round 43): once per crossing, never again while the reading hovers at the edge, and never on
/// readings that aren't news.
final class RangeCrossingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let low = 70.0
    private let high = 180.0

    /// Feeds one reading a minute and returns the cue each one gave.
    private func run(_ values: [Double], live: Bool = true,
                     into tracker: inout RangeCrossing, from start: Int = 0) -> [RangeCrossing.Cue?] {
        values.enumerated().map { i, v in
            tracker.observe(mgdl: v, at: t0.addingTimeInterval(Double(start + i) * 60),
                            low: low, high: high, live: live)
        }
    }

    func testCuesOnceOnTheReadingThatCrossesEachWay() {
        var t = RangeCrossing()
        XCTAssertEqual(run([100, 90, 80, 69, 62, 60], into: &t), [nil, nil, nil, .wentLow, nil, nil])
        XCTAssertEqual(run([65, 72, 90], into: &t, from: 6), [nil, .backInRange, nil])
        XCTAssertEqual(run([170, 181, 200], into: &t, from: 9), [nil, .wentHigh, nil])
        XCTAssertEqual(run([185, 175, 150], into: &t, from: 12), [nil, .backInRange, nil])
    }

    func testHoveringAtTheEdgeNeverRepeats() {
        var t = RangeCrossing()
        // In range, then a reading that wanders back and forth over the low line.
        let cues = run([95, 71, 69, 71, 68, 72, 69, 70, 69, 73], into: &t)
        XCTAssertEqual(cues.compactMap { $0 }, [.wentLow])
        // Settling clearly low re-arms, so coming back in cues once more.
        XCTAssertEqual(run([62, 76], into: &t, from: 10), [nil, .backInRange])
    }

    func testHoveringAtTheHighLineNeverRepeats() {
        var t = RangeCrossing()
        let cues = run([150, 179, 182, 178, 181, 180, 183, 179], into: &t)
        XCTAssertEqual(cues.compactMap { $0 }, [.wentHigh])
    }

    func testFirstReadingIsQuietWhereverItIs() {
        var t = RangeCrossing()
        XCTAssertNil(t.observe(mgdl: 55, at: t0, low: low, high: high, live: true))
        XCTAssertEqual(t.side, .below)
        var u = RangeCrossing()
        XCTAssertNil(u.observe(mgdl: 220, at: t0, low: low, high: high, live: true))
        XCTAssertEqual(u.side, .above)
    }

    func testSeededRightAtTheEdgeWaitsToSettle() {
        var t = RangeCrossing()
        // First seen 2 mg/dL inside: the next step out isn't a cue until it has clearly settled.
        XCTAssertEqual(run([72, 68, 60, 80], into: &t), [nil, nil, nil, .backInRange])
    }

    func testStaleOrSavedReadingsNeverCueAndStartOverQuietly() {
        var t = RangeCrossing()
        _ = run([100, 100], into: &t)
        // The saved reading from before launch, or a stale one, is not news.
        XCTAssertNil(t.observe(mgdl: 60, at: t0.addingTimeInterval(120), low: low, high: high, live: false))
        XCTAssertNil(t.side)
        // The first live reading after takes its side without a cue.
        XCTAssertNil(t.observe(mgdl: 60, at: t0.addingTimeInterval(180), low: low, high: high, live: true))
        XCTAssertEqual(t.side, .below)
        XCTAssertEqual(t.observe(mgdl: 90, at: t0.addingTimeInterval(240), low: low, high: high, live: true), .backInRange)
    }

    func testTheSameReadingDrawnAgainSaysNothing() {
        var t = RangeCrossing()
        _ = run([100], into: &t)
        XCTAssertEqual(t.observe(mgdl: 60, at: t0.addingTimeInterval(60), low: low, high: high, live: true), .wentLow)
        XCTAssertNil(t.observe(mgdl: 60, at: t0.addingTimeInterval(60), low: low, high: high, live: true))
    }

    func testMovingTheTargetRangeIsNotACrossing() {
        var t = RangeCrossing()
        _ = run([100, 100], into: &t)
        // Raising the low line to 110 puts 100 below it, but the reading didn't move.
        XCTAssertNil(t.observe(mgdl: 100, at: t0.addingTimeInterval(120), low: 110, high: high, live: true))
        XCTAssertEqual(t.side, .below)
    }

    func testLowToUrgentLowIsNotACrossing() {
        var t = RangeCrossing()
        XCTAssertEqual(run([100, 65, 58, 50, 45], into: &t).compactMap { $0 }, [.wentLow])
    }

    func testStraightFromHighToLowCuesLow() {
        var t = RangeCrossing()
        XCTAssertEqual(run([200, 60], into: &t), [nil, .wentLow])
    }

    func testALowKeepsItsWarningAndTheRestAreOneLightTap() {
        XCTAssertEqual(RangeCrossing.Cue.wentLow.haptic, .enteredLow)
        XCTAssertEqual(RangeCrossing.Cue.wentHigh.haptic, .rangeCrossed)
        XCTAssertEqual(RangeCrossing.Cue.backInRange.haptic, .rangeCrossed)
        if case .lightImpact = HapticEvent.rangeCrossed.feel {} else { XCTFail("not a light tap") }
    }

    func testWashIsBriefAndSkippedUnderReduceMotion() {
        XCTAssertLessThan(RangeCrossing.washDuration, 1)
        XCTAssertLessThanOrEqual(RangeCrossing.washPeakOpacity, 0.25)
        XCTAssertTrue(RangeCrossing.washes(reduceMotion: false))
        XCTAssertFalse(RangeCrossing.washes(reduceMotion: true))
    }
}
