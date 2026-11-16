import XCTest
@testable import GlucOSEngine

/// Switching the Today / popover chart between 3, 6, 12 and 24 hours by pinch or keyboard.
final class ChartHoursTests: XCTestCase {
    func testStoredValuesOutsideTheChoicesFallBackToTwelve() {
        XCTAssertEqual(ChartHours.sanitized(nil), 12)
        XCTAssertEqual(ChartHours.sanitized(8), 12)
        XCTAssertEqual(ChartHours.sanitized(24), 24)
        XCTAssertEqual(ChartHours.sanitized(3), 3)
    }

    func testStepsStopAtTheEnds() {
        XCTAssertEqual(ChartHours.shorter(than: 12), 6)
        XCTAssertEqual(ChartHours.shorter(than: 3), 3)
        XCTAssertEqual(ChartHours.longer(than: 12), 24)
        XCTAssertEqual(ChartHours.longer(than: 24), 24)
        // Something not offered steps from 12.
        XCTAssertEqual(ChartHours.longer(than: 9), 24)
    }

    func testSpreadingZoomsInAndPinchingZoomsOut() {
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 1), 12)
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 1.2), 12)   // not far enough yet
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 1.4), 6)
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 1.4 * 1.4), 3)
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 5), 3)        // stays at the shortest
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: 1 / 1.4), 24)
        XCTAssertEqual(ChartHours.pinched(from: 3, scale: 1 / (1.4 * 1.4)), 12)
        XCTAssertEqual(ChartHours.pinched(from: 6, scale: 0.1), 24)
    }

    func testAStepLandsJustBeforeTheFullSpread() {
        // A tenth of a step early, so the chart moves while the fingers still are.
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: pow(1.4, 0.92)), 6)
        XCTAssertEqual(ChartHours.pinched(from: 12, scale: pow(1.4, 0.8)), 12)
    }

    func testNonsenseScalesChangeNothing() {
        XCTAssertEqual(ChartHours.pinched(from: 6, scale: 0), 6)
        XCTAssertEqual(ChartHours.pinched(from: 6, scale: .nan), 6)
        XCTAssertEqual(ChartHours.pinched(from: 6, scale: -2), 6)
    }

    func testChartsAreHandedTheLongestSpanAndMore() {
        XCTAssertGreaterThan(ChartHours.longestPlotted * 3600, 24 * 3600 + ChartSpan.lead)
    }
}
