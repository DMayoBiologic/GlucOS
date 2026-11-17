import XCTest
@testable import GlucOSEngine

final class AlertChartTests: XCTestCase {
    private let readingAt = 1_790_000_000.0

    private func chart(history: [Int?], forecast: [Int] = [], lower: Int? = nil, upper: Int? = nil) -> AlertChart {
        AlertChart(readingAt: readingAt, unit: "mmol", lowMgdl: 70, highMgdl: 180, history: history,
                   forecast: forecast, forecastLower: lower, forecastUpper: upper)
    }

    private func state(history: [Int?]) -> GlucoseActivityState {
        GlucoseActivityState(mgdl: Double(history.last!!), trend: 3, readingAt: readingAt, deltaMgdl: nil,
                             unit: "mmol", lowMgdl: 70, highMgdl: 180, history: history, source: "phone")
    }

    func testBuiltFromTheLiveActivityCard() {
        var s = state(history: [100, nil, 80, 62])
        s.forecast = [58, 55]
        s.forecastLower = 45
        s.forecastUpper = 66
        let c = AlertChart(state: s)
        XCTAssertEqual(c, chart(history: [100, nil, 80, 62], forecast: [58, 55], lower: 45, upper: 66))
    }

    func testNoChartWithTooFewReadingsOrDuringWarmUp() {
        XCTAssertNil(AlertChart(state: state(history: [nil, nil, 62])))
        var warming = state(history: [90, 80, 62])
        warming.warmUpEndsAt = readingAt + 600
        XCTAssertNil(AlertChart(state: warming))
    }

    func testOnlyLowAndHighAlertsGetOne() {
        let now = Date(timeIntervalSince1970: readingAt)
        let readings = (0..<12).map {
            GlucoseReading(timestamp: now.addingTimeInterval(Double($0 - 11) * 300), mgdl: 100 - Double($0) * 3, trend: .falling)
        }
        var snap = GlucoseSnapshot()
        snap.current = readings.last
        snap.history = Array(readings.dropLast())
        snap.fetchedAt = now
        for kind in AlertNotice.Kind.allCases {
            let chart = AlertChartSource.chart(for: kind, snapshot: snap, now: now)
            XCTAssertEqual(chart != nil, kind.treatment != nil, "\(kind)")
        }
        XCTAssertEqual(AlertChartSource.chart(for: .low, snapshot: snap, now: now)?.history.last, 67)
    }

    func testRoundTripsThroughUserInfoAsAPushCarriesIt() throws {
        let c = chart(history: [nil, 90, 80, 62], forecast: [58, 55], lower: 45, upper: 66)
        let value = try XCTUnwrap(c.userInfoValue)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
        // As APNs delivers it: JSON text parsed back into Foundation values.
        let push = try JSONSerialization.data(withJSONObject: ["kind": "low", "chart": value])
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: push) as? [AnyHashable: Any])
        XCTAssertEqual(AlertChart(userInfo: userInfo), c)
        // The relay's own payload shape (core.ts alertChart): no forecast range keys when absent.
        let relay = #"{"chart":{"readingAt":1790000000,"unit":"mgdl","lowMgdl":70,"highMgdl":180,"history":[null,90,62],"forecast":[]}}"#
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(relay.utf8)) as? [AnyHashable: Any])
        XCTAssertEqual(AlertChart(userInfo: decoded)?.glucoseUnit, .mgdl)
        XCTAssertEqual(AlertChart(userInfo: decoded)?.forecastEnd, nil)
    }

    func testMissingOrBrokenChartsAreIgnored() {
        XCTAssertNil(AlertChart(userInfo: ["kind": "low"]))
        XCTAssertNil(AlertChart(userInfo: ["chart": "nonsense"]))
        XCTAssertNil(AlertChart(userInfo: ["chart": ["readingAt": 1]]))
        var c = chart(history: [90, 62])
        c.lowMgdl = 200
        XCTAssertNil(AlertChart(userInfo: ["chart": c.userInfoValue!]))
    }

    func testLayoutPutsTheReadingThreeQuartersAlongWithAnHourOfForecast() {
        let history: [Int?] = Array(repeating: 100, count: 37)
        let l = chart(history: history, forecast: Array(repeating: 90, count: 12), lower: 70, upper: 110).layout
        XCTAssertEqual(l.now.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(l.runs.count, 1)
        XCTAssertEqual(l.runs[0].first!.x, 0)
        XCTAssertEqual(l.forecast.first, l.now)
        XCTAssertEqual(l.forecast.last!.x, 1, accuracy: 1e-9)
        XCTAssertEqual(l.forecast.count, 13)
        XCTAssertNotNil(l.cone)
        XCTAssertGreaterThan(l.cone!.top.y, l.cone!.bottom.y)
    }

    func testLayoutWithoutAForecastEndsAtTheReading() {
        let l = chart(history: [100, 90, 80]).layout
        XCTAssertEqual(l.now.x, 1)
        XCTAssertTrue(l.forecast.isEmpty)
        XCTAssertNil(l.cone)
    }

    func testGapsSplitTheLine() {
        let l = chart(history: [100, 95, nil, nil, 80, nil, 62]).layout
        XCTAssertEqual(l.runs.map(\.count), [2, 1, 1])
    }

    func testTargetBandAndValuesAlwaysFit() {
        let l = chart(history: [300, 350, 390], forecast: [420], lower: 380, upper: 460).layout
        XCTAssertEqual(l.maxMgdl, AlertChart.ceilingMgdl)
        XCTAssertLessThanOrEqual(l.minMgdl, 70 - AlertChart.padding)
        XCTAssertEqual(l.lowY, (70 - l.minMgdl) / (l.maxMgdl - l.minMgdl), accuracy: 1e-9)
        for p in l.runs.flatMap({ $0 }) + l.forecast { XCTAssert((0...1).contains(p.y)) }
    }

    func testAFlatLineKeepsAMinimumSpan() {
        // Target band 100–120 and readings of 110: the y range still spans 90 mg/dL.
        let c = AlertChart(readingAt: readingAt, unit: "mgdl", lowMgdl: 100, highMgdl: 120, history: [110, 110, 110])
        let l = c.layout
        XCTAssertEqual(l.maxMgdl - l.minMgdl, AlertChart.minimumSpan, accuracy: 1e-9)
        XCTAssertEqual(l.now.y, 0.5, accuracy: 0.01)
    }

    func testVoiceOverSummary() {
        let c = chart(history: [nil, 90, 80, 62], forecast: Array(repeating: 55, count: 6), lower: 45, upper: 66)
        XCTAssertEqual(c.spokenSummary,
                       "Last 3 hours. Now 3.4, low. Lowest 3.4, highest 5.0. 67 percent in range. "
                           + "Went below range once. Forecast, not a reading: about 3.1 in 30 minutes.")
    }

    func testReduceMotionDrawsTheChartAtOnce() {
        XCTAssertEqual(AlertChart.drawInSeconds(reduceMotion: true), 0)
        XCTAssertGreaterThan(AlertChart.drawInSeconds(reduceMotion: false), 0)
    }

    func testPayloadStaysSmall() throws {
        let c = chart(history: Array(repeating: 288, count: 37), forecast: Array(repeating: 288, count: 12), lower: 250, upper: 330)
        let data = try JSONSerialization.data(withJSONObject: c.userInfoValue!)
        XCTAssertLessThan(data.count, 600)
    }
}
