import XCTest
@testable import GlucOSEngine

/// Insights figures pulse once when new data changes them, and only then (`InsightsFigurePulse`).
final class InsightsFigurePulseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func revision(_ minutes: Double, readings: Int = 100, logged: Int = 4) -> InsightsFigurePulse.Revision {
        .init(newestReading: t0.addingTimeInterval(minutes * 60), readingCount: readings, loggedCount: logged)
    }

    private func shown(_ text: String, _ revision: InsightsFigurePulse.Revision, back: Int = 0) -> InsightsFigurePulse.Shown {
        .init(text: text, revision: revision, periodBack: back)
    }

    private func pulses(_ old: InsightsFigurePulse.Shown, _ new: InsightsFigurePulse.Shown,
                        reduceMotion: Bool = false, countingUp: Bool = false) -> Bool {
        InsightsFigurePulse.pulses(from: old, to: new, reduceMotion: reduceMotion, countingUp: countingUp)
    }

    func testNewReadingThatChangesTheFigurePulses() {
        XCTAssertTrue(pulses(shown("72%", revision(0)), shown("73%", revision(5, readings: 101))))
    }

    func testSyncedEntryThatChangesTheFigurePulses() {
        XCTAssertTrue(pulses(shown("3", revision(0)), shown("4", revision(0, logged: 5))))
    }

    func testNewReadingThatLeavesTheFigureAloneDoesNotPulse() {
        XCTAssertFalse(pulses(shown("72%", revision(0)), shown("72%", revision(5, readings: 101))))
    }

    func testPickerChangeOnlyRolls() {
        // A 7 → 14 day picker: new figure, same data.
        XCTAssertFalse(pulses(shown("72%", revision(0)), shown("68%", revision(0))))
    }

    func testPeriodStepOnlyRolls() {
        XCTAssertFalse(pulses(shown("72%", revision(0)), shown("65%", revision(0), back: 1)))
        // Even if a reading lands in the same moment.
        XCTAssertFalse(pulses(shown("72%", revision(0)), shown("65%", revision(5, readings: 101), back: 1)))
    }

    func testNeverOutsideInsights() {
        let none = InsightsFigurePulse.Revision.none
        XCTAssertFalse(pulses(shown("72%", none), shown("73%", none)))
        XCTAssertFalse(pulses(shown("72%", none), shown("73%", revision(5))))
        XCTAssertFalse(pulses(shown("72%", revision(0)), shown("73%", none)))
    }

    func testNeverUnderReduceMotionOrWhileCountingUp() {
        let old = shown("72%", revision(0)), new = shown("73%", revision(5, readings: 101))
        XCTAssertFalse(pulses(old, new, reduceMotion: true))
        XCTAssertFalse(pulses(old, new, countingUp: true))
    }

    func testPulseIsShortAndSmall() {
        XCTAssertGreaterThan(InsightsFigurePulse.peakScale, 1)
        XCTAssertLessThanOrEqual(InsightsFigurePulse.peakScale, 1.1)
        XCTAssertLessThan(InsightsFigurePulse.totalDuration, 0.8)
        XCTAssertLessThan(InsightsFigurePulse.riseDuration, InsightsFigurePulse.settleDuration)
    }
}
