import XCTest
@testable import GlucOSEngine

/// A forecast starting over 180 mg/dL draws its range's lower side wider around an hour out,
/// because glucose usually comes down faster than the model draws from there
/// (docs/ForecastAccuracy.md §41). The central line and upper side don't move, and possible lows
/// read the lower side from before the widening.
final class HighStartRangeTests: XCTestCase {
    let now = referenceNow
    let learned = EffectProfile(insulin: LearnedEffect(value: 50, standardError: 3, examples: 20),
                                carbs: LearnedEffect(value: 3, standardError: 0.3, examples: 20),
                                driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: referenceNow)

    /// A model forecast (a meal 90 minutes ago, so not a fresh log) from `mgdl`, moving `slope` a minute.
    func forecast(from mgdl: Double, slope: Double = 0, carbs: Double = 40) throws -> GlucoseForecast {
        let r = readings(endingAt: now, minutes: 30) { m in mgdl + slope * m }
        let meal = MealEntry(timestamp: now.addingTimeInterval(-90 * 60), carbs: carbs)
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [meal], contexts: [], profile: learned, now: now)
        switch GlucoseForecaster.forecast(input) {
        case .success(let f): return f
        case .failure(let e): XCTFail("No forecast: \(e.reason)"); throw e
        }
    }

    func sample(_ f: GlucoseForecast, _ minutes: Double) throws -> ForecastSample {
        try XCTUnwrap(f.samples.first { $0.date == now.addingTimeInterval(minutes * 60) })
    }

    func testFactorByMinutes() {
        func down(_ start: Double, _ m: Double) -> Double { ForecastRangeScale.highStartLower(startMgdl: start, minutes: m) }
        XCTAssertEqual(down(220, 0), 1)
        XCTAssertEqual(down(220, 15), 1)
        XCTAssertEqual(down(220, 30), 1)
        XCTAssertEqual(down(220, 45), 1.35, accuracy: 1e-9)
        XCTAssertEqual(down(220, 60), 1.7, accuracy: 1e-9)
        XCTAssertEqual(down(220, 75), 1.35, accuracy: 1e-9)
        XCTAssertEqual(down(220, 90), 1, accuracy: 1e-9)
        XCTAssertEqual(down(220, 180), 1)
        // At or under 180 nothing changes.
        XCTAssertEqual(down(180, 60), 1)
        XCTAssertEqual(down(120, 60), 1)
        XCTAssertEqual(down(70, 60), 1)
    }

    func testHighStartWidensOnlyTheLowerSideAnHourOut() throws {
        let high = try forecast(from: 230)
        let same = try forecast(from: 160)
        XCTAssertEqual(high.basis, .trendInsulinCarbs)
        XCTAssertGreaterThanOrEqual(high.horizon, 60 * 60)
        XCTAssertFalse(high.lowerScales.isEmpty)
        XCTAssertTrue(same.lowerScales.isEmpty)
        XCTAssertEqual(high.lowerScale(atMinutes: 60), 1.7, accuracy: 1e-9)
        XCTAssertEqual(high.lowerScale(atMinutes: 30), 1)
        // The same shape 70 mg/dL apart, so the sides can be compared directly.
        for (a, b) in zip(high.samples, same.samples).dropFirst() {
            XCTAssertEqual(a.mgdl - 70, b.mgdl, accuracy: 1e-6, "central line untouched")
            XCTAssertEqual(a.upperMgdl - a.mgdl, b.upperMgdl - b.mgdl, accuracy: 1e-6, "upper side untouched")
            let m = Int((a.date.timeIntervalSince(now) / 60).rounded())
            guard a.lowerMgdl > GlucoseForecaster.sensorRange.lowerBound - 0.5 else { continue }
            XCTAssertEqual(a.mgdl - a.lowerMgdl, (b.mgdl - b.lowerMgdl) * high.lowerScale(atMinutes: m), accuracy: 1e-6)
        }
        XCTAssertEqual(try sample(high, 30).lowerMgdl - 70, try sample(same, 30).lowerMgdl, accuracy: 1e-6)
    }

    func testPossibleAndPredictedLowsAreUnchanged() throws {
        // Falling from 200: the widened lower side an hour out reaches well down, but a possible
        // low is shown exactly where the range without the widening would have put it.
        let f = try forecast(from: 200, slope: -1.2)
        XCTAssertFalse(f.lowerScales.isEmpty)
        var plain = GlucoseForecast(issuedAt: f.issuedAt, startMgdl: f.startMgdl, basis: f.basis,
                                    trendPerMinute: f.trendPerMinute,
                                    samples: f.samples.map { s in
                                        let m = Int((s.date.timeIntervalSince(now) / 60).rounded())
                                        return ForecastSample(date: s.date, mgdl: s.mgdl, lowerMgdl: f.warningLowers[m] ?? s.lowerMgdl,
                                                              upperMgdl: s.upperMgdl)
                                    },
                                    limitations: f.limitations, calibrated: f.calibrated)
        plain.lowLookahead = f.lowLookahead
        plain.unshown = f.unshown
        var moved = false
        for low in stride(from: 40.0, through: 220, by: 5) {
            XCTAssertEqual(f.firstRangeBelow(low), plain.firstRangeBelow(low), "possible low at \(low)")
            // Read off the drawn lower side instead, some of these would have come sooner.
            if let drawn = f.samples.first(where: { $0.lowerMgdl < low })?.date,
               drawn != plain.firstRangeBelow(low) { moved = true }
        }
        XCTAssertTrue(moved, "the test should cover a threshold the widening crosses")
        let settings = PredictiveAlertSettings()
        XCTAssertEqual(PredictiveAlertRules.evaluate(f, settings: settings, now: now),
                       PredictiveAlertRules.evaluate(plain, settings: settings, now: now))
    }

    func testLedgerTakesTheWideningOutBeforeLearning() {
        // Landed 60 below a forecast whose lower side was 60 wide after a 1.5× high-start widening:
        // counted against the 40 it would have been.
        let p = ForecastRecord.Point(minutes: 60, mgdl: 220, lower: 160, upper: 260, actual: 160, scale: 1, lowerScale: 1.5)
        let r = ForecastRecord(id: UUID(), issuedAt: now, device: "Mac", basis: .trendInsulinCarbs, startMgdl: 230,
                               trendPerMinute: 0, points: [p], limitations: [], calibrated: true,
                               tuned: false, morning: false, settled: true)
        XCTAssertEqual(ForecastLedger.rangeMisses(r).first?.ratio ?? 0, 1.5, accuracy: 1e-9)
        var old = p
        old.lowerScale = nil
        let r2 = ForecastRecord(id: UUID(), issuedAt: now, device: "Mac", basis: .trendInsulinCarbs, startMgdl: 230,
                                trendPerMinute: 0, points: [old], limitations: [], calibrated: true,
                                tuned: false, morning: false, settled: true)
        XCTAssertEqual(ForecastLedger.rangeMisses(r2).first?.ratio ?? 0, 1, accuracy: 1e-9)
    }
}
