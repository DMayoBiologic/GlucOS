import XCTest
@testable import GlucOSEngine

final class SpokenGlucoseTests: XCTestCase {
    private func snapshot(minutesOld: Double = 2, mgdl: Double = 110, trend: Trend = .rising,
                          caveat: String? = nil) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        let at = referenceNow.addingTimeInterval(-minutesOld * 60)
        s.history = readings(endingAt: at.addingTimeInterval(-5 * 60), minutes: 60) { _ in 100 }
        s.current = reading(at, mgdl, trend)
        s.fetchedAt = referenceNow
        if let caveat {
            var o = OutlookSnapshot(issuedAt: at, basis: .trend)
            o.caveat = ForecastCaveat(kind: .trendOnly, text: caveat, detail: nil, source: "freshLog")
            s.outlook = o
        }
        return s
    }

    func testFreshSaysReadingTrendAndAge() {
        let text = SpokenGlucose.answer(snapshot(), at: referenceNow)
        XCTAssertTrue(text.hasPrefix("Glucose 6.1 millimoles per litre"), text)
        XCTAssertTrue(text.contains("rising"), text)
        XCTAssertTrue(text.contains("2 minutes ago"), text)
        XCTAssertFalse(text.contains("forecast"), text)
    }

    func testFreshAddsTheForecastCaveat() {
        let text = SpokenGlucose.answer(snapshot(caveat: "Trend only for now: a meal or dose was logged in the last hour."),
                                        at: referenceNow)
        XCTAssertTrue(text.hasSuffix(" About the forecast: Trend only for now: a meal or dose was logged in the last hour."), text)
        let noStop = SpokenGlucose.answer(snapshot(caveat: "Less certain"), at: referenceNow)
        XCTAssertTrue(noStop.hasSuffix("About the forecast: Less certain."), noStop)
    }

    func testStaleIsNeverSpokenAsCurrent() {
        for minutes in [8.0, 12.0] {
            let text = SpokenGlucose.answer(snapshot(minutesOld: minutes, mgdl: 60, trend: .falling,
                                                     caveat: "Less certain: glucose is changing quickly."),
                                            at: referenceNow)
            if minutes < 10 {
                XCTAssertTrue(text.hasPrefix("Stale."), text)
                XCTAssertTrue(text.contains("8 minutes ago"), text)
            } else {
                // From 10 minutes, the widgets' no-readings words (WidgetGap).
                XCTAssertTrue(text.hasPrefix("No readings for 12 minutes"), text)
            }
            XCTAssertFalse(text.hasPrefix("Glucose"), text)
            XCTAssertFalse(text.lowercased().contains("falling"), text)
            XCTAssertFalse(text.lowercased().contains("low"), text)
            XCTAssertFalse(text.contains("forecast"), text)
        }
    }

    func testExpiredAndMissing() {
        XCTAssertTrue(SpokenGlucose.answer(snapshot(minutesOld: 45), at: referenceNow).hasPrefix("No readings for 45 minutes"))
        XCTAssertEqual(SpokenGlucose.answer(nil, at: referenceNow), "GlucOS has no reading yet. Open GlucOS to connect.")
        XCTAssertEqual(SpokenGlucose.answer(.empty, at: referenceNow), "No glucose reading yet. Waiting for GlucOS.")
    }

    func testOldForecastCaveatIsDropped() {
        // The caveat belongs to an earlier reading's forecast: not said with this one.
        var s = snapshot(caveat: "Less certain: glucose is changing quickly.")
        s.outlook?.issuedAt = referenceNow.addingTimeInterval(-20 * 60)
        XCTAssertNil(SpokenGlucose.caveat(s, at: referenceNow))
    }

    func testRefreshOnlyWhenNotFresh() {
        XCTAssertFalse(SpokenGlucose.wantsRefresh(snapshot(), at: referenceNow))
        XCTAssertTrue(SpokenGlucose.wantsRefresh(snapshot(minutesOld: 12), at: referenceNow))
        XCTAssertTrue(SpokenGlucose.wantsRefresh(nil, at: referenceNow))
    }
}
