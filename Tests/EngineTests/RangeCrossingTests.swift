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

    // MARK: Back-in-range moment (round 89)

    /// Feeds readings a minute apart and returns, for each, whether it marked the moment.
    private func moments(_ values: [Double], into tracker: inout RangeCrossing, from start: Int = 0,
                         follower: Bool = false) -> [Bool] {
        values.enumerated().map { i, v in
            let cue = tracker.observe(mgdl: v, at: t0.addingTimeInterval(Double(start + i) * 60),
                                      low: low, high: high, live: true)
            return RangeCrossing.marksMoment(cue, outFor: tracker.backAfter, follower: follower)
        }
    }

    func testMarksTheMomentAfterFifteenMinutesOutOnce() {
        var t = RangeCrossing()
        // In range, then low from minute 2 to minute 17 (the 16th reading out), back at minute 18.
        XCTAssertEqual(moments([100, 90], into: &t), [false, false])
        XCTAssertEqual(moments(Array(repeating: 60, count: 16), into: &t, from: 2), Array(repeating: false, count: 16))
        XCTAssertEqual(moments([76], into: &t, from: 18), [true])
        XCTAssertEqual(t.backAfter, 16 * 60)
        // Once per spell: settling in range says nothing more.
        XCTAssertEqual(moments([80, 90, 100], into: &t, from: 19), [false, false, false])
    }

    func testShortSpellsOnlyGetTheCrossingCue() {
        var t = RangeCrossing()
        _ = moments([100], into: &t)
        XCTAssertEqual(moments(Array(repeating: 190, count: 14), into: &t, from: 1), Array(repeating: false, count: 14))
        let cue = t.observe(mgdl: 170, at: t0.addingTimeInterval(15 * 60), low: low, high: high, live: true)
        XCTAssertEqual(cue, .backInRange)
        XCTAssertEqual(t.backAfter, 14 * 60)
        XCTAssertFalse(RangeCrossing.marksMoment(cue, outFor: t.backAfter, follower: false))
    }

    func testFifteenMinutesExactlyCounts() {
        XCTAssertTrue(RangeCrossing.marksMoment(.backInRange, outFor: 15 * 60, follower: false))
        XCTAssertFalse(RangeCrossing.marksMoment(.backInRange, outFor: 15 * 60 - 1, follower: false))
        XCTAssertFalse(RangeCrossing.marksMoment(.wentHigh, outFor: 60 * 60, follower: false))
        XCTAssertFalse(RangeCrossing.marksMoment(.backInRange, outFor: nil, follower: false))
    }

    func testNeverForFollowers() {
        var t = RangeCrossing()
        _ = moments([100], into: &t, follower: true)
        _ = moments(Array(repeating: 55, count: 20), into: &t, from: 1, follower: true)
        XCTAssertEqual(moments([80], into: &t, from: 21, follower: true), [false])
        XCTAssertEqual(t.backAfter, 20 * 60)
    }

    func testEachCrossingBackEndsTheSpell() {
        var t = RangeCrossing()
        _ = moments([100], into: &t)
        _ = moments(Array(repeating: 60, count: 10), into: &t, from: 1)   // low from minute 1
        // Back across at minute 11 after 10 minutes: the crossing cue only, and the spell ends.
        XCTAssertEqual(moments([72], into: &t, from: 11), [false])
        XCTAssertEqual(t.backAfter, 10 * 60)
        // A new spell starts at the next reading out, so the next crossing back counts from there.
        _ = moments([68], into: &t, from: 12)
        _ = moments(Array(repeating: 60, count: 15), into: &t, from: 13)
        XCTAssertEqual(moments([80], into: &t, from: 28), [true])
        XCTAssertEqual(t.backAfter, 16 * 60)
    }

    func testAShallowDipEndsQuietly() {
        var t = RangeCrossing()
        _ = moments([100], into: &t)
        // 68 is out but never 5 below the line, so coming back doesn't cue.
        XCTAssertEqual(moments(Array(repeating: 68, count: 20), into: &t, from: 1), Array(repeating: false, count: 20))
        XCTAssertEqual(moments([72, 80], into: &t, from: 21), [false, false])
        XCTAssertNil(t.outSince)
    }

    func testAStaleStretchMidLowKeepsTheSpellButALongGapEndsIt() {
        var t = RangeCrossing()
        _ = moments([100, 60, 60, 60], into: &t)    // low from minute 1
        _ = t.observe(mgdl: 60, at: t0.addingTimeInterval(4 * 60), low: low, high: high, live: false)
        // Ten minutes later, still low: the same spell, taken quietly.
        _ = moments([58, 58, 58, 58, 58, 58], into: &t, from: 14)
        XCTAssertEqual(moments([80], into: &t, from: 20), [true])
        XCTAssertEqual(t.backAfter, 19 * 60)

        var g = RangeCrossing()
        _ = moments([100, 60, 60], into: &g)
        // 40 minutes with nothing: the spell ends unseen; the low starts again at minute 42.
        _ = moments([58, 58, 58, 58, 58], into: &g, from: 42)
        let cue = g.observe(mgdl: 80, at: t0.addingTimeInterval(47 * 60), low: low, high: high, live: true)
        XCTAssertEqual(cue, .backInRange)
        XCTAssertEqual(g.backAfter, 5 * 60)
    }

    func testRingStaysStillUnderReduceMotion() {
        XCTAssertFalse(RangeCrossing.ringSweeps(reduceMotion: true))
        XCTAssertTrue(RangeCrossing.ringSweeps(reduceMotion: false))
        XCTAssertEqual(RangeCrossing.momentAnnouncement, "Back in range")
    }
}
