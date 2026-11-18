import XCTest
@testable import GlucOSEngine

/// The forecast details card's entrance and close (`ForecastCardEntrance`, round 74).
final class ForecastCardEntranceTests: XCTestCase {
    private let rising = ForecastDetails.Horizon(minutes: 30, mgdl: 150, lowerMgdl: 135, upperMgdl: 165, held: nil)
    private let falling = ForecastDetails.Horizon(minutes: 60, mgdl: 90, lowerMgdl: 70, upperMgdl: 110, held: nil)

    func testReduceMotionCrossFades() {
        XCTAssertEqual(ForecastCardEntrance.Style(reduceMotion: false), .widen)
        XCTAssertEqual(ForecastCardEntrance.Style(reduceMotion: true), .crossFade)
    }

    func testBandWidensFromTheLineIntoTheCard() {
        XCTAssertEqual(ForecastCardEntrance.bandHeight(open: false, full: 220, style: .widen), 2)
        XCTAssertEqual(ForecastCardEntrance.bandHeight(open: true, full: 220, style: .widen), 220)
        // Never taller than the card, even before it's been measured.
        XCTAssertEqual(ForecastCardEntrance.bandHeight(open: false, full: 0, style: .widen), 0)
        XCTAssertEqual(ForecastCardEntrance.bandHeight(open: false, full: -5, style: .widen), 0)
    }

    func testReduceMotionShowsTheWholeCardAndFadesOnly() {
        XCTAssertEqual(ForecastCardEntrance.bandHeight(open: false, full: 220, style: .crossFade), 220)
        XCTAssertEqual(ForecastCardEntrance.contentOpacity(open: false, style: .crossFade), 0)
        XCTAssertEqual(ForecastCardEntrance.contentOpacity(open: true, style: .crossFade), 1)
        XCTAssertEqual(ForecastCardEntrance.bandTint(open: false, style: .crossFade), ForecastCardEntrance.cardTint)
    }

    func testWidenRevealsByTheBandNotByFading() {
        XCTAssertEqual(ForecastCardEntrance.contentOpacity(open: false, style: .widen), 1)
        XCTAssertEqual(ForecastCardEntrance.bandTint(open: false, style: .widen), ForecastCardEntrance.lineTint)
        XCTAssertEqual(ForecastCardEntrance.bandTint(open: true, style: .widen), ForecastCardEntrance.cardTint)
        XCTAssertLessThan(ForecastCardEntrance.cardTint, ForecastCardEntrance.lineTint)
    }

    func testFiguresRollFromTheStartToTheirValue() {
        XCTAssertEqual(ForecastCardEntrance.figure(rising, start: 120, rolledIn: false, style: .widen), 120)
        XCTAssertEqual(ForecastCardEntrance.figure(rising, start: 120, rolledIn: true, style: .widen), 150)
        // Reduce Motion never shows anything but the forecast's own figure.
        XCTAssertEqual(ForecastCardEntrance.figure(rising, start: 120, rolledIn: false, style: .crossFade), 150)
    }

    func testRollDirectionFollowsTheForecastAndReversesOnClose() {
        XCTAssertFalse(ForecastCardEntrance.countsDown(rising, start: 120, rollingIn: true))
        XCTAssertTrue(ForecastCardEntrance.countsDown(rising, start: 120, rollingIn: false))
        XCTAssertTrue(ForecastCardEntrance.countsDown(falling, start: 120, rollingIn: true))
        XCTAssertFalse(ForecastCardEntrance.countsDown(falling, start: 120, rollingIn: false))
    }

    func testFiguresRollOneAfterTheOtherWhileTheBandOpens() {
        XCTAssertEqual(ForecastCardEntrance.figureDelay(index: 0), 0.14, accuracy: 1e-9)
        XCTAssertEqual(ForecastCardEntrance.figureDelay(index: 1), 0.22, accuracy: 1e-9)
        XCTAssertEqual(ForecastCardEntrance.figureDelay(index: -1), 0.14, accuracy: 1e-9)
        XCTAssertLessThan(ForecastCardEntrance.figureDelay(index: 1), ForecastCardEntrance.openDuration)
    }

    func testCloseIsQuickerThanOpenAndFadesFasterStill() {
        XCTAssertLessThan(ForecastCardEntrance.closeDuration(.widen), ForecastCardEntrance.openDuration)
        XCTAssertLessThan(ForecastCardEntrance.closeDuration(.crossFade), ForecastCardEntrance.closeDuration(.widen))
    }

    func testOpensFromTheEdgeNearestTheLine() {
        XCTAssertTrue(ForecastCardEntrance.opensFromTop(pointY: 40, plotMidY: 100))
        XCTAssertFalse(ForecastCardEntrance.opensFromTop(pointY: 160, plotMidY: 100))
    }
}
