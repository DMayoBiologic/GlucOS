import XCTest
@testable import GlucOSEngine

/// The figures for a span picked out on the iPhone Today chart, telling a span from a pinch, and
/// VoiceOver's spans.
final class ChartSpanStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// One reading every 5 minutes with these values (mg/dL).
    private func readings(_ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(timestamp: at(Double($0.offset) * 5), mgdl: $0.element, trend: .flat) }
    }

    private func stats(_ r: [GlucoseReading], _ from: Double, _ to: Double) -> ChartSpanStats? {
        ChartSpanStats.compute(readings: r, from: at(from), to: at(to), lowMgdl: 70, highMgdl: 180)
    }

    // MARK: Figures

    func testAverageLowestHighestInRangeAndChange() throws {
        let r = readings([100, 120, 190, 60, 130])
        let s = try XCTUnwrap(stats(r, 0, 20))
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.averageMgdl, 120, accuracy: 1e-9)
        XCTAssertEqual(s.lowestMgdl, 60)
        XCTAssertEqual(s.highestMgdl, 190)
        XCTAssertEqual(s.inRange, 0.6, accuracy: 1e-9)
        XCTAssertEqual(s.changeMgdl, 30)
        XCTAssertEqual(s.inRangeText, "60%")
    }

    func testOnlyReadingsInsideTheSpanCountWithItsEndsIncluded() throws {
        let r = readings([300, 100, 110, 120, 40])
        let s = try XCTUnwrap(stats(r, 5, 15))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.lowestMgdl, 100)
        XCTAssertEqual(s.highestMgdl, 120)
        XCTAssertEqual(s.inRange, 1)
        XCTAssertEqual(s.changeMgdl, 20)
    }

    func testTheFingersCanBePlacedEitherWayRound() {
        let r = readings([100, 120, 140, 160])
        XCTAssertEqual(stats(r, 0, 15), stats(r, 15, 0))
        XCTAssertEqual(stats(r, 15, 0)?.start, at(0))
        XCTAssertEqual(stats(r, 15, 0)?.changeMgdl, 60)
    }

    func testTheTargetLinesCountAsInRange() throws {
        let s = try XCTUnwrap(stats(readings([70, 180, 69, 181]), 0, 15))
        XCTAssertEqual(s.inRange, 0.5, accuracy: 1e-9)
    }

    func testUnsortedReadingsGiveTheSameChange() {
        let r = readings([100, 110, 150])
        XCTAssertEqual(stats(Array(r.reversed()), 0, 10)?.changeMgdl, 50)
    }

    func testOneReadingHasNoChange() throws {
        let s = try XCTUnwrap(stats(readings([100, 120, 140]), 3, 8))
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s.changeMgdl)
        XCTAssertEqual(s.changeText(unit: .mmol), "–")
        XCTAssertNil(s.spokenChange(unit: .mmol))
    }

    func testAGapOrASpanSqueezedToNothingHasNoFigures() {
        let r = readings([100, 120])
        XCTAssertNil(stats(r, 6, 30), "a sensor gap: no reading inside")
        XCTAssertNil(stats(r, 0, 4), "shorter than the minimum span")
        XCTAssertNil(stats([], 0, 60))
        XCTAssertNotNil(stats(r, 0, 5))
    }

    func testChangeText() throws {
        XCTAssertEqual(try XCTUnwrap(stats(readings([100, 124]), 0, 5)).changeText(unit: .mmol), "+1.3")
        XCTAssertEqual(try XCTUnwrap(stats(readings([124, 100]), 0, 5)).changeText(unit: .mmol), "−1.3")
        XCTAssertEqual(try XCTUnwrap(stats(readings([124, 100]), 0, 5)).changeText(unit: .mgdl), "−24")
        // Rounds to nothing: no sign.
        XCTAssertEqual(try XCTUnwrap(stats(readings([100, 100.5]), 0, 5)).changeText(unit: .mmol), "0.0")
        XCTAssertEqual(try XCTUnwrap(stats(readings([100, 100.4]), 0, 5)).changeText(unit: .mgdl), "0")
    }

    func testSpokenChange() throws {
        XCTAssertEqual(try XCTUnwrap(stats(readings([100, 124]), 0, 5)).spokenChange(unit: .mmol), "Up 1.3")
        XCTAssertEqual(try XCTUnwrap(stats(readings([124, 100]), 0, 5)).spokenChange(unit: .mgdl), "Down 24")
        XCTAssertEqual(try XCTUnwrap(stats(readings([100, 100]), 0, 5)).spokenChange(unit: .mmol), "No change")
    }

    // MARK: Span or pinch

    func testFingersThatRestArmASpan() {
        XCTAssertTrue(ChartSpanHold.arms(held: 0.3, firstWidth: 3600, currentWidth: 3600, wasPinch: false))
        XCTAssertTrue(ChartSpanHold.arms(held: 0.5, firstWidth: 3600, currentWidth: 3600 * 1.1, wasPinch: false))
    }

    func testNotBeforeTheHoldIsUp() {
        XCTAssertFalse(ChartSpanHold.arms(held: 0.1, firstWidth: 3600, currentWidth: 3600, wasPinch: false))
    }

    func testAGapThatMovesIsAPinch() {
        XCTAssertTrue(ChartSpanHold.isPinch(firstWidth: 3600, currentWidth: 3600 * 1.2))
        XCTAssertTrue(ChartSpanHold.isPinch(firstWidth: 3600, currentWidth: 3600 * 0.8))
        XCTAssertFalse(ChartSpanHold.isPinch(firstWidth: 3600, currentWidth: 3600 * 1.15))
        XCTAssertFalse(ChartSpanHold.arms(held: 0.3, firstWidth: 3600, currentWidth: 3600 * 1.3, wasPinch: false))
    }

    func testOnceAPinchAlwaysAPinch() {
        // The fingers spread and came back before the hold was up.
        XCTAssertFalse(ChartSpanHold.arms(held: 1, firstWidth: 3600, currentWidth: 3600, wasPinch: true))
    }

    func testFingersLandingTogetherAreAPinchOnceTheyMove() {
        XCTAssertFalse(ChartSpanHold.isPinch(firstWidth: 0, currentWidth: 0))
        XCTAssertTrue(ChartSpanHold.isPinch(firstWidth: 0, currentWidth: 60))
    }

    // MARK: VoiceOver

    func testStepsFitTheChartsHours() {
        XCTAssertEqual(ChartSpanVoiceOver.steps(hours: 3), [30, 60, 120, 180])
        XCTAssertEqual(ChartSpanVoiceOver.steps(hours: 24), [30, 60, 120, 180, 360, 720, 1440])
        XCTAssertEqual(ChartSpanVoiceOver.steps(hours: 0.25), [30])
    }

    func testSwipingUpAndDown() {
        XCTAssertEqual(ChartSpanVoiceOver.step(nil, up: true, hours: 3), 30)
        XCTAssertEqual(ChartSpanVoiceOver.step(30, up: true, hours: 3), 60)
        XCTAssertEqual(ChartSpanVoiceOver.step(180, up: true, hours: 3), 180, "stays at the longest")
        XCTAssertEqual(ChartSpanVoiceOver.step(60, up: false, hours: 3), 30)
        XCTAssertNil(ChartSpanVoiceOver.step(30, up: false, hours: 3), "back to the chart's summary")
        XCTAssertNil(ChartSpanVoiceOver.step(nil, up: false, hours: 3))
    }

    func testFewerHoursClampTheSpan() {
        XCTAssertEqual(ChartSpanVoiceOver.clamped(720, hours: 3), 180)
        XCTAssertEqual(ChartSpanVoiceOver.clamped(60, hours: 3), 60)
        XCTAssertNil(ChartSpanVoiceOver.clamped(nil, hours: 3))
    }

    func testWords() {
        XCTAssertEqual(ChartSpanVoiceOver.words(minutes: 30), "30 minutes")
        XCTAssertEqual(ChartSpanVoiceOver.words(minutes: 60), "1 hour")
        XCTAssertEqual(ChartSpanVoiceOver.words(minutes: 720), "12 hours")
    }

    func testSpokenSentence() {
        let s = stats(readings([100, 120, 190, 60, 130]), 0, 20)
        XCTAssertEqual(ChartSpanVoiceOver.spoken(s, minutes: 30, unit: .mgdl),
                       "Last 30 minutes. Average 120, lowest 60, highest 190 milligrams per decilitre. "
                       + "60 percent in range. Up 30.")
        XCTAssertEqual(ChartSpanVoiceOver.spoken(nil, minutes: 60, unit: .mmol), "Last 1 hour. No readings.")
    }
}
