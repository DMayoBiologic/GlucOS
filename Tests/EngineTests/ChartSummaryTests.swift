import XCTest
@testable import GlucOSEngine

/// The sentence VoiceOver reads for a glucose chart.
final class ChartSummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings(_ mgdl: [Double]) -> [GlucoseReading] {
        mgdl.enumerated().map { GlucoseReading(timestamp: start.addingTimeInterval(Double($0.offset) * 300), mgdl: $0.element, trend: .flat) }
    }

    func testDescribesNowExtremesTimeInRangeAndExcursions() {
        // 3.9–10 mmol/L target. Dips low once, goes high twice.
        let r = readings([120, 65, 60, 100, 200, 110, 190, 120])
        let s = ChartSummary.sentence(.init(readings: r, lowMgdl: 70, highMgdl: 180, unit: .mmol, hours: 6))
        XCTAssertEqual(s, "Last 6 hours. Now 6.7, in range. Lowest 3.3, highest 11.1. 50 percent in range. Went below range once and above range twice.")
    }

    func testStaleChartSaysSoAndLeavesOutTheForecast() {
        let r = readings([100, 102])
        let forecast = ForecastSample(date: r.last!.timestamp.addingTimeInterval(1800), mgdl: 120, lowerMgdl: 100, upperMgdl: 140)
        let s = ChartSummary.sentence(.init(readings: r, lowMgdl: 70, highMgdl: 180, unit: .mgdl, hours: 3,
                                            stale: true, forecastEnd: forecast))
        XCTAssertTrue(s.contains("Stale: the last reading was 102"), s)
        XCTAssertFalse(s.contains("Forecast"), s)
    }

    func testForecastIsMarkedAsNotAReadingAndRoundedToFiveMinutes() {
        let r = readings([100, 104, 108])
        let forecast = ForecastSample(date: r.last!.timestamp.addingTimeInterval(31 * 60), mgdl: 140, lowerMgdl: 120, upperMgdl: 160)
        let s = ChartSummary.sentence(.init(readings: r, lowMgdl: 70, highMgdl: 180, unit: .mgdl, hours: 12,
                                            forecastEnd: forecast, loggedCount: 2))
        XCTAssertTrue(s.hasSuffix("Forecast, not a reading: about 140 in 30 minutes. 2 entries logged."), s)
        XCTAssertTrue(s.hasPrefix("Last 12 hours. Now 108, in range."), s)
    }

    func testUrgentLowIsNamedAndEmptyChartIsSafe() {
        let s = ChartSummary.sentence(.init(readings: readings([60, 50]), lowMgdl: 70, highMgdl: 180, unit: .mgdl, hours: 24))
        XCTAssertTrue(s.contains("Now 50, urgent low"), s)
        XCTAssertTrue(s.contains("0 percent in range"), s)
        XCTAssertEqual(ChartSummary.sentence(.init(readings: [], lowMgdl: 70, highMgdl: 180, unit: .mgdl, hours: 48)),
                       "Last 2 days. No readings.")
    }
}
