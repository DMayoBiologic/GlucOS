import XCTest
@testable import GlucOSEngine

/// Cutting the drawn forecast back to the horizons that this device's own live checks show still
/// beat assuming no change, and bringing them back once they do again.
final class ForecastLiveHorizonTests: XCTestCase {
    let now = referenceNow

    /// `count` forecasts in the last few days, each `error` off at every horizon in `errors` while
    /// glucose moved `moved` from where it started (so no change is `moved` off). `shown` maps
    /// horizons to whether they were drawn.
    func records(count: Int = 40, errors: [Int: Double], moved: Double = 20, basis: ForecastBasis = .trendInsulinCarbs,
                 device: String = "iPhone", hidden: Set<Int> = [], hiddenInLatestOnly: Bool = false,
                 limitations: [String] = []) -> [ForecastRecord] {
        (0..<count).map { i in
            let latest = i == count - 1
            let points = errors.keys.sorted().map { m -> ForecastRecord.Point in
                let actual = 100 + moved
                let hide = hidden.contains(m) && (!hiddenInLatestOnly || latest)
                return .init(minutes: m, mgdl: actual - errors[m]!, lower: 0, upper: 400, actual: actual,
                             shown: hide ? false : nil)
            }
            return ForecastRecord(id: UUID(), issuedAt: now.addingTimeInterval(-Double(count - i) * 900), device: device,
                                  basis: basis, startMgdl: 100, trendPerMinute: 0, points: points, limitations: limitations,
                                  calibrated: true, tuned: false, morning: false, settled: true)
        }
    }

    func horizon(_ records: [ForecastRecord], device: String = "iPhone") -> ForecastLiveHorizon {
        ForecastLedger(records: records).liveHorizon(device: device, now: now)
    }

    // MARK: Ledger rule

    func testCutsTheFirstHorizonThatLosesToNoChange() {
        // The iPhone on 2026-11-15: 15 min level, 30 min better, 60 min clearly worse.
        let r = records(errors: [15: 20.3, 30: 15, 45: 18, 60: 24, 90: 10], moved: 20)
        let cut = horizon(r).cut(for: .trendInsulinCarbs)
        XCTAssertEqual(cut, .init(shownMinutes: 45, failedAt: 60), "90 goes with 60, even though it did well")
        XCTAssertNil(horizon(r).cut(for: .trend), "Other kinds are judged on their own")
    }

    func testInsulinOnlyForecastsAreJudgedApartFromThoseAfterAMeal() {
        // After meals: clearly better at an hour. Insulin alone: clearly worse from 45 minutes.
        let afterMeals = records(errors: [15: 10, 30: 12, 45: 14, 60: 15], moved: 20)
        let alone = records(errors: [15: 10, 30: 18, 45: 30, 60: 40], moved: 20, limitations: ["backgroundInsulin", "insulinOnly"])
        let h = horizon(afterMeals + alone)
        XCTAssertNil(h.cut(for: .trendInsulinCarbs), "The misses with insulin alone don't cost the meals their hour")
        XCTAssertEqual(h.insulinOnly, .init(shownMinutes: 30, failedAt: 45))
        XCTAssertEqual(h.cut(for: .trendInsulinCarbs, insulinOnly: true), .init(shownMinutes: 30, failedAt: 45))
        XCTAssertNil(h.cut(for: .trendInsulinCarbs, insulinOnly: false))
    }

    func testLevelWithNoChangeIsNotCut() {
        // 15 min: 14.8 against 14.4 (3% worse) is about the same, not clearly worse.
        XCTAssertNil(horizon(records(errors: [15: 14.8, 30: 10], moved: 14.4)).cut(for: .trendInsulinCarbs))
    }

    func testCutToNothingWhenFifteenMinutesLoses() {
        XCTAssertEqual(horizon(records(errors: [15: 25, 30: 10], moved: 20)).cut(for: .trendInsulinCarbs),
                       .init(shownMinutes: 0, failedAt: 15))
    }

    func testNeedsEnoughChecksBeforeCutting() {
        XCTAssertNil(horizon(records(count: 29, errors: [60: 40], moved: 20)).cut(for: .trendInsulinCarbs))
    }

    func testOnlyThisDevicesForecastsCount() {
        let mac = records(errors: [60: 40], moved: 20, device: "Mac")
        XCTAssertNil(horizon(mac).cut(for: .trendInsulinCarbs))
        XCTAssertNotNil(horizon(mac, device: "Mac").cut(for: .trendInsulinCarbs))
        XCTAssertNil(horizon(records(errors: [60: 40], moved: 20, device: ForecastRecord.relayDevice)).cut(for: .trendInsulinCarbs))
    }

    func testOnlyTheLastWeekCounts() {
        let old = records(errors: [60: 40], moved: 20).map { r in
            ForecastRecord(id: r.id, issuedAt: r.issuedAt.addingTimeInterval(-8 * 86_400), device: r.device, basis: r.basis,
                           startMgdl: r.startMgdl, trendPerMinute: 0, points: r.points, limitations: [],
                           calibrated: true, tuned: false, morning: false, settled: true)
        }
        XCTAssertNil(horizon(old).cut(for: .trendInsulinCarbs))
    }

    func testPointsAfterALogDoNotCount() {
        let r = records(errors: [60: 40], moved: 20).map { rec -> ForecastRecord in
            var rec = rec
            rec.points = rec.points.map { var p = $0; p.afterLog = true; return p }
            return rec
        }
        XCTAssertNil(horizon(r).cut(for: .trendInsulinCarbs))
    }

    func testACutHorizonComesBackOnlyOnceItIsClearlyBetter() {
        // Cut at 60 last time. Now level with no change (2% better): stays cut.
        let level = records(errors: [30: 10, 60: 19.6], moved: 20, hidden: [60], hiddenInLatestOnly: true)
        XCTAssertEqual(horizon(level).cut(for: .trendInsulinCarbs), .init(shownMinutes: 45, failedAt: 60))
        // The same figures while drawn: not cut (it's not clearly worse).
        XCTAssertNil(horizon(records(errors: [30: 10, 60: 19.6], moved: 20)).cut(for: .trendInsulinCarbs))
        // Clearly better (10% less error): back.
        let better = records(errors: [30: 10, 60: 18], moved: 20, hidden: [60], hiddenInLatestOnly: true)
        XCTAssertNil(horizon(better).cut(for: .trendInsulinCarbs))
    }

    func testACutHorizonStaysCutWhileItHasTooFewChecks() {
        let few = records(count: 10, errors: [30: 10, 60: 5], moved: 20, hidden: [60])
        XCTAssertEqual(horizon(few).cut(for: .trendInsulinCarbs), .init(shownMinutes: 45, failedAt: 60))
    }

    // MARK: Forecast

    /// A trend forecast from readings rising 1 mg/dL a minute to 120.
    func rising(_ live: ForecastLiveHorizon = .unlimited) -> Result<GlucoseForecast, ForecastFailure> {
        let r = readings(endingAt: now, minutes: 30) { 120 - $0 }
        var input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        input.liveHorizon = live
        return GlucoseForecaster.forecast(input)
    }

    func testTheForecastIsDrawnOnlyToTheLiveHorizonAndKeepsTheRest() throws {
        let full = try rising().get()
        XCTAssertEqual(full.horizon, 30 * 60)
        XCTAssertTrue(full.unshown.isEmpty)

        let cut = try rising(.init(byBasis: [.trend: .init(shownMinutes: 15, failedAt: 30)])).get()
        XCTAssertEqual(cut.horizon, 15 * 60, "Drawn to 15 minutes")
        XCTAssertEqual(cut.samples, Array(full.samples.prefix(4)))
        XCTAssertEqual(cut.unshown, Array(full.samples.dropFirst(4)), "The rest is the same forecast, kept back")
        XCTAssertTrue(cut.limitations.contains(.liveHorizon(shownMinutes: 15, failedAt: 30)))
        XCTAssertEqual(ForecastLimitation.liveHorizon(shownMinutes: 15, failedAt: 30).code, "liveHorizon:15")

        // Low and high warnings only look at what's drawn.
        XCTAssertNil(cut.firstAbove(full.samples[5].mgdl - 0.1))
    }

    func testACutPastTheForecastsReachChangesNothing() throws {
        // The trend forecast only reaches 30 minutes; a model cut at 60 doesn't touch it.
        let f = try rising(.init(byBasis: [.trend: .init(shownMinutes: 45, failedAt: 60),
                                           .trendInsulinCarbs: .init(shownMinutes: 0, failedAt: 15)])).get()
        XCTAssertEqual(f.horizon, 30 * 60)
        XCTAssertFalse(f.limitations.contains { if case .liveHorizon = $0 { return true } else { return false } })
    }

    func testCutToNothingShowsNoForecastButKeepsItForTheLog() throws {
        let result = rising(.init(byBasis: [.trend: .init(shownMinutes: 0, failedAt: 15)]))
        guard case .failure(let e) = result else { return XCTFail("Should not be drawn") }
        XCTAssertEqual(e.reason, .notAccurateEnough)
        XCTAssertTrue(e.limitations.contains(.liveHorizon(shownMinutes: 0, failedAt: 15)))
        let kept = try XCTUnwrap(e.unshown)
        XCTAssertEqual(kept.samples.count, 1, "Only the starting point")
        XCTAssertEqual(kept.unshown.count, 6)
    }

    func testTheLogKeepsScoringTheCutHorizons() throws {
        let cut = try rising(.init(byBasis: [.trend: .init(shownMinutes: 15, failedAt: 30)])).get()
        var ledger = ForecastLedger()
        XCTAssertTrue(ledger.note(cut, device: "iPhone", tuned: false, now: now))
        let points = ledger.records[0].points
        XCTAssertEqual(points.map(\.minutes), [15, 30])
        XCTAssertEqual(points.map(\.wasShown), [true, false])
        XCTAssertEqual(points[0].shown, nil, "Drawn points stay as before")

        // A forecast cut to nothing is still logged.
        guard case .failure(let e) = rising(.init(byBasis: [.trend: .init(shownMinutes: 0, failedAt: 15)])) else {
            return XCTFail()
        }
        var empty = ForecastLedger()
        XCTAssertTrue(empty.note(try XCTUnwrap(e.unshown), device: "iPhone", tuned: false, now: now))
        XCTAssertEqual(empty.records[0].points.map(\.wasShown), [false, false])
    }

    func testOutlookLogsTheUndrawnForecast() {
        var model = OutlookModel.empty
        model.liveHorizon = .init(byBasis: [.trend: .init(shownMinutes: 0, failedAt: 15)])
        let r = readings(endingAt: now, minutes: 30) { 120 - $0 }
        let o = OutlookEngine.outlook(readings: r, doses: [], meals: [], contexts: [], model: model, now: now)
        XCTAssertNil(o.glucoseForecast)
        XCTAssertNotNil(o.forecastToLog)
        XCTAssertTrue(o.snapshot(lowMgdl: 70).forecast.isEmpty)
    }

    func testUploadMarksOnlyUndrawnPoints() throws {
        let cut = try rising(.init(byBasis: [.trend: .init(shownMinutes: 15, failedAt: 30)])).get()
        var ledger = ForecastLedger()
        ledger.note(cut, device: "iPhone", tuned: false, now: now)
        let json = String(data: try JSONEncoder().encode(ForecastUpload(ledger.records[0])), encoding: .utf8)!
        XCTAssertEqual(json.components(separatedBy: "\"shown\":false").count - 1, 1)
        XCTAssertFalse(json.contains("\"shown\":true"))
    }

    func testOldRecordsDecodeAsDrawn() throws {
        let json = #"{"minutes":30,"mgdl":120,"lower":100,"upper":140,"afterLog":false}"#
        let p = try JSONDecoder().decode(ForecastRecord.Point.self, from: Data(json.utf8))
        XCTAssertTrue(p.wasShown)
    }

    func testExplanationNeverTalksAboutDosing() {
        for l in [ForecastLimitation.liveHorizon(shownMinutes: 45, failedAt: 60), .liveHorizon(shownMinutes: 0, failedAt: 15)] {
            XCTAssertFalse(l.message.lowercased().contains("dose"))
            XCTAssertFalse(l.forcesTrendOnly)
        }
    }
}
