import XCTest
@testable import GlucOSEngine

/// A forecast starting under 80 mg/dL draws its range's upper side wider, because glucose usually
/// comes back up from there (docs/ForecastAccuracy.md §40). The central line and lower side don't move.
final class LowStartRangeTests: XCTestCase {
    let now = referenceNow

    func forecast(from mgdl: Double, falling: Double = 0) throws -> GlucoseForecast {
        let r = readings(endingAt: now, minutes: 30) { m in mgdl + falling * m }
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        switch GlucoseForecaster.forecast(input) {
        case .success(let f): return f
        case .failure(let e): XCTFail("No forecast: \(e.reason)"); throw e
        }
    }

    func testFactorByMinutes() {
        func up(_ start: Double, _ m: Double, treated: Bool = false) -> Double {
            ForecastRangeScale.lowStartUpper(startMgdl: start, minutes: m, countsTreatment: treated)
        }
        XCTAssertEqual(up(70, 0), 1)
        XCTAssertEqual(up(70, 15), 2.8, accuracy: 1e-9)
        XCTAssertEqual(up(70, 30), 3.3, accuracy: 1e-9)
        XCTAssertEqual(up(70, 45), 3.45, accuracy: 1e-9)
        XCTAssertEqual(up(70, 60), 3.6, accuracy: 1e-9)
        XCTAssertEqual(up(70, 120), 3.6, accuracy: 1e-9)
        XCTAssertEqual(up(70, 5), 1 + 1.8 / 3, accuracy: 1e-9)
        // At or above 80, and when the logged treatment is already drawn, nothing changes.
        XCTAssertEqual(up(80, 30), 1)
        XCTAssertEqual(up(150, 30), 1)
        XCTAssertEqual(up(60, 30, treated: true), 1)
    }

    func testLowStartWidensOnlyTheUpperSide() throws {
        let low = try forecast(from: 72)
        let same = try forecast(from: 92)
        XCTAssertFalse(low.upperScales.isEmpty)
        XCTAssertTrue(same.upperScales.isEmpty)
        XCTAssertEqual(low.upperScale(atMinutes: 30), 3.3, accuracy: 1e-9)
        XCTAssertEqual(same.upperScale(atMinutes: 30), 1)
        // A flat line 20 mg/dL apart: same shape, so the sides can be compared directly.
        for (a, b) in zip(low.samples, same.samples).dropFirst() {
            XCTAssertEqual(a.mgdl + 20, b.mgdl, accuracy: 1e-6)
            XCTAssertEqual(a.mgdl - a.lowerMgdl, b.mgdl - b.lowerMgdl, accuracy: 1e-6, "lower side untouched")
            let m = Int(a.date.timeIntervalSince(now) / 60)
            XCTAssertEqual(a.upperMgdl - a.mgdl, (b.upperMgdl - b.mgdl) * low.upperScale(atMinutes: m), accuracy: 1e-6)
        }
    }

    func testPredictedLowsAreUnchanged() throws {
        // Falling 1.5 mg/dL a minute from 78: the warning comes from the central line alone.
        let f = try forecast(from: 78, falling: 1.5)
        XCTAssertFalse(f.upperScales.isEmpty)
        let flat = GlucoseForecast(issuedAt: f.issuedAt, startMgdl: f.startMgdl, basis: f.basis,
                                   trendPerMinute: f.trendPerMinute,
                                   samples: f.samples.map { ForecastSample(date: $0.date, mgdl: $0.mgdl, lowerMgdl: $0.lowerMgdl, upperMgdl: $0.mgdl) },
                                   limitations: f.limitations, calibrated: f.calibrated)
        let settings = PredictiveAlertSettings()
        let a = PredictiveAlertRules.evaluate(f, settings: settings, now: now)
        let b = PredictiveAlertRules.evaluate(flat, settings: settings, now: now)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(f.firstRangeBelow(70), flat.firstRangeBelow(70))
    }

    func testLedgerTakesTheWideningOutBeforeLearning() {
        // Landed 60 above a forecast whose upper side was 60 wide after a 3× low-start widening:
        // counted against the 20 it would have been, so the steady widening doesn't learn it away.
        let p = ForecastRecord.Point(minutes: 30, mgdl: 70, lower: 50, upper: 130, actual: 130, scale: 1, upperScale: 3)
        let r = ForecastRecord(id: UUID(), issuedAt: now, device: "Mac", basis: .trend, startMgdl: 72,
                               trendPerMinute: 0, points: [p], limitations: [], calibrated: true,
                               tuned: false, morning: false, settled: true)
        let miss = ForecastLedger.rangeMisses(r)
        XCTAssertEqual(miss.first?.ratio ?? 0, 3, accuracy: 1e-9)
        // Old records (no figure) read as before.
        var old = p
        old.upperScale = nil
        let r2 = ForecastRecord(id: UUID(), issuedAt: now, device: "Mac", basis: .trend, startMgdl: 72,
                                trendPerMinute: 0, points: [old], limitations: [], calibrated: true,
                                tuned: false, morning: false, settled: true)
        XCTAssertEqual(ForecastLedger.rangeMisses(r2).first?.ratio ?? 0, 1, accuracy: 1e-9)
    }
}
