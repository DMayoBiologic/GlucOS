import XCTest
@testable import GlucOSEngine

final class AlertPlannerTests: XCTestCase {
    let now = referenceNow

    func snapshot(_ mgdl: Double, trend: Trend = .flat, age: TimeInterval = 60) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = reading(now.addingTimeInterval(-age), mgdl, trend)
        s.history = readings(endingAt: now.addingTimeInterval(-age - 300), minutes: 60) { _ in mgdl }
        return s
    }

    func testLowAlertsOnceThenWaitsForTheCooldown() {
        var p = AlertPlanner()
        let prefs = AlertPreferences()
        let first = p.evaluate(snapshot(65), prefs: prefs, now: now)
        XCTAssertEqual(first.map(\.kind), [.low])
        XCTAssertEqual(first.first?.title, "Low glucose — 3.6 mmol/L")
        XCTAssertEqual(first.first?.identifier, "glucos.low")
        XCTAssertTrue(p.evaluate(snapshot(64), prefs: prefs, now: now.addingTimeInterval(60)).isEmpty)
        // After the 15-minute cooldown it repeats.
        let later = now.addingTimeInterval(16 * 60)
        var s = snapshot(64)
        s.current = reading(later.addingTimeInterval(-60), 64)
        XCTAssertEqual(p.evaluate(s, prefs: prefs, now: later).map(\.kind), [.low])
    }

    func testUrgentLowIsCriticalAndRepeatsEveryFiveMinutes() {
        var p = AlertPlanner()
        let n = p.evaluate(snapshot(50), prefs: AlertPreferences(), now: now)
        XCTAssertEqual(n.map(\.kind), [.urgentLow])
        XCTAssertTrue(n[0].critical)
        let later = now.addingTimeInterval(5 * 60 + 1)
        var s = snapshot(50)
        s.current = reading(later.addingTimeInterval(-30), 50)
        XCTAssertEqual(p.evaluate(s, prefs: AlertPreferences(), now: later).map(\.kind), [.urgentLow])
    }

    func testBackInRangeResetsSoTheNextLowAlertsAtOnce() {
        var p = AlertPlanner()
        _ = p.evaluate(snapshot(65), prefs: AlertPreferences(), now: now)
        _ = p.evaluate(snapshot(100), prefs: AlertPreferences(), now: now.addingTimeInterval(60))
        XCTAssertEqual(p.evaluate(snapshot(66), prefs: AlertPreferences(), now: now.addingTimeInterval(120)).map(\.kind), [.low])
    }

    func testHighNeedsItsSwitchButVeryHighDoesNot() {
        var prefs = AlertPreferences()
        prefs.high = false
        var p = AlertPlanner()
        XCTAssertTrue(p.evaluate(snapshot(200), prefs: prefs, now: now).isEmpty)
        XCTAssertEqual(p.evaluate(snapshot(260), prefs: prefs, now: now).map(\.kind), [.veryHigh])
    }

    func testStaleReadingRaisesNoDataInsteadOfARangeAlert() {
        var p = AlertPlanner()
        let n = p.evaluate(snapshot(60, age: 20 * 60), prefs: AlertPreferences(), now: now)
        XCTAssertEqual(n.map(\.kind), [.stale])
    }

    func testAlertsOffMeansNothing() {
        var prefs = AlertPreferences()
        prefs.enabled = false
        var p = AlertPlanner()
        XCTAssertTrue(p.evaluate(snapshot(40), prefs: prefs, now: now).isEmpty)
    }

    func testPredictedLowIsWordedAsAForecast() {
        var s = snapshot(90, trend: .falling, age: 0)
        let r = readings(endingAt: now, minutes: 20) { m in 90 + 2 * m }
        s.current = r.last
        s.history = Array(r.dropLast())
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        guard case .success(let f) = GlucoseForecaster.forecast(input) else { return XCTFail("no forecast") }
        var p = AlertPlanner()
        let n = p.evaluatePrediction(s, forecast: f, prefs: AlertPreferences(), now: now)
        XCTAssertEqual(n?.kind, .predictedLow)
        XCTAssertTrue(n?.body.contains("Forecast, not a reading") ?? false)
        // Held back while it's recent.
        XCTAssertNil(p.evaluatePrediction(s, forecast: f, prefs: AlertPreferences(), now: now.addingTimeInterval(60)))
    }
}

final class GlucoseActivityStateTests: XCTestCase {
    let now = referenceNow

    func testHistoryIsOnAFiveMinuteGridEndingAtTheReading() throws {
        var s = GlucoseSnapshot()
        let r = readings(endingAt: now, minutes: 240) { m in 100 + m / 10 }
        s.current = r.last
        // Leave a gap 60–90 minutes ago.
        s.history = r.dropLast().filter {
            let age = now.timeIntervalSince($0.timestamp)
            return !(age > 60 * 60 && age < 90 * 60)
        }
        let state = try XCTUnwrap(GlucoseActivityState.make(from: s, now: now))
        XCTAssertEqual(state.history.count, 37)
        XCTAssertEqual(state.history.last!, 100)
        XCTAssertEqual(state.history.first!, 118)
        XCTAssertTrue(state.history.contains { $0 == nil })
        XCTAssertEqual(state.historyReadings.last?.timestamp, now)
        XCTAssertTrue(state.forecast.isEmpty)
    }

    func testForecastOnlyWhileCurrent() throws {
        var s = GlucoseSnapshot()
        s.current = reading(now, 120, .falling)
        var o = OutlookSnapshot(issuedAt: now, basis: .trend)
        o.forecast = (1...6).map { ForecastSample(date: now.addingTimeInterval(Double($0) * 300), mgdl: 120 - Double($0) * 5,
                                                  lowerMgdl: 100, upperMgdl: 130) }
        s.outlook = o
        let fresh = try XCTUnwrap(GlucoseActivityState.make(from: s, now: now.addingTimeInterval(30)))
        XCTAssertEqual(fresh.forecast, [115, 110, 105, 100, 95, 90])
        XCTAssertEqual(fresh.forecastHeadline?.minutes, 30)
        let stale = try XCTUnwrap(GlucoseActivityState.make(from: s, now: now.addingTimeInterval(10 * 60)))
        XCTAssertTrue(stale.forecast.isEmpty)
        XCTAssertTrue(stale.isStale(at: now.addingTimeInterval(10 * 60)))
    }

    func testEncodesWithoutDatesAndStaysSmall() throws {
        var s = GlucoseSnapshot()
        let r = readings(endingAt: now, minutes: 180) { m in 100 + m }
        s.current = r.last
        s.history = Array(r.dropLast())
        let state = try XCTUnwrap(GlucoseActivityState.make(from: s, now: now))
        let data = try JSONEncoder().encode(state)
        XCTAssertLessThan(data.count, 1500)
        let back = try JSONDecoder().decode(GlucoseActivityState.self, from: data)
        XCTAssertEqual(back, state)
    }
}
