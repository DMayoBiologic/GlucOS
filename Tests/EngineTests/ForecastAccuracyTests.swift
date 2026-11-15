import XCTest
@testable import GlucOSEngine

/// The forecast log (what was shown, scored against what happened) and trend-timing tuning.
final class ForecastLedgerTests: XCTestCase {
    let now = referenceNow

    /// A trend forecast from readings rising 1 mg/dL a minute to 120 at `at`.
    func rising(at t: Date) throws -> GlucoseForecast {
        let r = readings(endingAt: t, minutes: 30) { 120 - $0 }
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: t)
        return try GlucoseForecaster.forecast(input).get()
    }

    func testKeepsOneForecastPerQuarterHourWithItsCheckedHorizons() throws {
        var ledger = ForecastLedger()
        XCTAssertTrue(ledger.note(try rising(at: now), device: "Mac", tuned: false, now: now))
        XCTAssertFalse(ledger.note(try rising(at: now.addingTimeInterval(5 * 60)), device: "Mac", tuned: false,
                                   now: now.addingTimeInterval(5 * 60)))
        XCTAssertTrue(ledger.note(try rising(at: now.addingTimeInterval(15 * 60)), device: "Mac", tuned: false,
                                  now: now.addingTimeInterval(15 * 60)))
        XCTAssertEqual(ledger.records.count, 2)
        // An uncalibrated trend forecast looks 30 minutes ahead: 15 and 30 are checked.
        XCTAssertEqual(ledger.records[0].points.map(\.minutes), [15, 30])
        XCTAssertEqual(ledger.records[0].startMgdl, 120)
        XCTAssertTrue(ledger.records[0].limitations.contains("uncalibrated"))
    }

    func testSkipsAForecastFromAnOldReading() throws {
        var ledger = ForecastLedger()
        XCTAssertFalse(ledger.note(try rising(at: now), device: "Mac", tuned: false, now: now.addingTimeInterval(3600)))
    }

    func testScoresAgainstLaterReadingsAndSettles() throws {
        var ledger = ForecastLedger()
        let f = try rising(at: now)
        ledger.note(f, device: "iPhone", tuned: false, now: now)
        let predicted30 = try XCTUnwrap(ledger.records[0].points.last?.mgdl)
        // Glucose levels off at 130 instead.
        let after = readings(endingAt: now.addingTimeInterval(60 * 60), minutes: 60) { m in m >= 50 ? 120 : 130 }
        let series = GlucoseSeries(after)

        ledger.score(readings: series, logTimes: [], now: now.addingTimeInterval(20 * 60))
        XCTAssertEqual(ledger.records[0].points[0].actual, 130)
        XCTAssertNil(ledger.records[0].points[1].actual, "30 minutes hasn't come yet")
        XCTAssertFalse(ledger.records[0].settled)

        ledger.score(readings: series, logTimes: [], now: now.addingTimeInterval(55 * 60))
        XCTAssertEqual(try XCTUnwrap(ledger.records[0].points[1].error), 130 - predicted30, accuracy: 0.001)
        XCTAssertTrue(ledger.records[0].settled, "Settled 20 minutes after its last point")
        XCTAssertEqual(ledger.pendingUpload().count, 1)
        ledger.markUploaded([ledger.records[0].id])
        XCTAssertTrue(ledger.pendingUpload().isEmpty)
    }

    func testPointsAfterALogAreReportedApart() throws {
        var ledger = ForecastLedger()
        ledger.note(try rising(at: now), device: "Mac", tuned: false, now: now)
        let series = GlucoseSeries(readings(endingAt: now.addingTimeInterval(40 * 60), minutes: 40) { _ in 140 })
        // A meal logged 20 minutes in: the 15-minute point is clean, the 30-minute one isn't.
        ledger.score(readings: series, logTimes: [now.addingTimeInterval(20 * 60)], now: now.addingTimeInterval(40 * 60))
        XCTAssertEqual(ledger.records[0].points.map(\.afterLog), [false, true])

        let acc = ledger.accuracy(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        XCTAssertEqual(acc.forecasts, 1)
        XCTAssertEqual(acc.clean.map(\.minutes), [15])
        XCTAssertEqual(acc.all.map(\.minutes), [15, 30])
        let h = try XCTUnwrap(acc.all(at: 15))
        XCTAssertEqual(h.naiveError, 20, accuracy: 0.001)
        XCTAssertEqual(h.checks, 1)
    }

    func testPrunesPastRetention() throws {
        var ledger = ForecastLedger()
        ledger.note(try rising(at: now), device: "Mac", tuned: false, now: now)
        XCTAssertFalse(ledger.prune(now: now.addingTimeInterval(30 * 86_400)))
        XCTAssertTrue(ledger.prune(now: now.addingTimeInterval(91 * 86_400)))
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        var ledger = ForecastLedger()
        ledger.note(try rising(at: now), device: "Mac", tuned: true, now: now)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(ForecastLedger.self, from: data), ledger)
    }

    func testUploadShape() throws {
        var ledger = ForecastLedger()
        ledger.note(try rising(at: now), device: "Mac", tuned: false, now: now)
        let up = ForecastUpload(ledger.records[0])
        XCTAssertEqual(up.issued, now.timeIntervalSince1970)
        XCTAssertEqual(up.basis, "trend")
        XCTAssertEqual(up.points.count, 2)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(up), encoding: .utf8))
        XCTAssertTrue(json.contains("\"start_mgdl\""))
        XCTAssertTrue(json.contains("\"after_log\""))
    }

    func testComparesThisWeekWithTheWeeksBefore() {
        func acc(_ error: Double, checks: Int) -> LiveAccuracy {
            let records = (0..<checks).map { i in
                ForecastRecord(id: UUID(), issuedAt: now.addingTimeInterval(Double(i) * 900), device: "Mac", basis: .trend,
                               startMgdl: 100, trendPerMinute: 0,
                               points: [.init(minutes: 30, mgdl: 100, lower: 80, upper: 120, actual: 100 + error)],
                               limitations: [], calibrated: true, tuned: false, morning: false)
            }
            return LiveAccuracy(records)
        }
        let line = ForecastAccuracyText.trendLine(lastWeek: acc(10, checks: 30), before: acc(20, checks: 30), unit: .mgdl)
        XCTAssertEqual(line?.hasSuffix("Getting better."), true)
        XCTAssertNil(ForecastAccuracyText.trendLine(lastWeek: acc(10, checks: 5), before: acc(20, checks: 30), unit: .mgdl))
        XCTAssertEqual(acc(10, checks: 30).clean(at: 30)?.insideRange, 1)
        XCTAssertEqual(acc(30, checks: 30).clean(at: 30)?.insideRange, 0)
    }
}

final class ForecastTunerTests: XCTestCase {
    let now = referenceNow

    /// Glucose swinging smoothly around 150, every 5 minutes for `days`.
    func wave(periodHours: Double, amplitude: Double, days: Int) -> [GlucoseReading] {
        readings(endingAt: now, minutes: days * 1440) { m in
            150 + amplitude * sin(2 * .pi * (Double(days * 1440) - m) / (periodHours * 60))
        }
    }

    func testStandardTimingKeepsLoopsValues() {
        XCTAssertEqual(ForecastTuning.standard.trendFade, 30 * 60)
        XCTAssertEqual(ForecastTuning.standard.trendWindow, 20 * 60)
        XCTAssertTrue(ForecastTuner.candidates.contains(.standard))
    }

    func testAShorterFadeFlattensTheForecastSooner() throws {
        let r = readings(endingAt: now, minutes: 30) { 120 - $0 }
        func at30(_ t: ForecastTuning) throws -> Double {
            let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty,
                                       tuning: t, now: now)
            return try XCTUnwrap(GlucoseForecaster.forecast(input).get().samples.last?.mgdl)
        }
        // Rising 1 mg/dL a minute: the standard fade adds 15 by 30 minutes, a 15-minute fade 7.5.
        XCTAssertEqual(try at30(.standard), 135, accuracy: 0.5)
        XCTAssertEqual(try at30(ForecastTuning(trendFade: 15 * 60, trendWindow: 20 * 60)), 127.5, accuracy: 0.5)
    }

    func testLongTrendsPickALongerFade() {
        let result = ForecastTuner.tune(readings: wave(periodHours: 6, amplitude: 80, days: 10), doses: [], meals: [],
                                        contexts: [], profile: .empty, days: 10, now: now)
        XCTAssertTrue(result.isTuned)
        XCTAssertEqual(result.tuning.trendFade, 45 * 60)
        XCTAssertLessThan(result.tunedError, result.standardError * ForecastTuner.requiredImprovement)
        XCTAssertGreaterThanOrEqual(result.checks, ForecastTuner.minimumChecks)
    }

    func testQuickSwingsCarryLessOfTheTrend() {
        let result = ForecastTuner.tune(readings: wave(periodHours: 1.5, amplitude: 40, days: 10), doses: [], meals: [],
                                        contexts: [], profile: .empty, days: 10, now: now)
        XCTAssertTrue(result.isTuned)
        // A trend that turns within the hour: less of it by fading sooner, counting it at part
        // strength, or both. How far the trend carries by 30 minutes, per mg/dL/min:
        let fade = result.tuning.trendFade / 60
        let carried = result.tuning.trendGain * (fade >= 30 ? 30 - 450 / fade : fade / 2)
        XCTAssertLessThan(carried, 15 * 0.8)
    }

    func testFitsHowMuchOfTheTrendCarriesOn() {
        // Glucose carries on at half the trend's strength, give or take.
        var rng = SeededRandom(seed: 7)
        var withTrend: [ForecastTuner.Key: Double] = [:], withoutTrend: [ForecastTuner.Key: Double] = [:]
        for i in 0..<300 {
            let key = ForecastTuner.Key(origin: now.addingTimeInterval(Double(i) * 900), minutes: 15)
            let trendPart = 20 * rng.normal()
            let actualChange = 0.5 * trendPart + 4 * rng.normal()
            withoutTrend[key] = actualChange
            withTrend[key] = actualChange - trendPart
        }
        let gain = ForecastTuner.fittedGain(withTrend: withTrend, withoutTrend: withoutTrend)
        XCTAssertEqual(gain ?? 0, 0.5, accuracy: 0.051)

        // When the trend carries on in full, it's left alone.
        let full = withTrend.mapValues { _ in 0.0 }
        XCTAssertNil(ForecastTuner.fittedGain(withTrend: full, withoutTrend: withoutTrend.mapValues { $0 * 2 }))
        // Too few points to say.
        XCTAssertNil(ForecastTuner.fittedGain(withTrend: withTrend.filter { $0.key.origin < now.addingTimeInterval(9000) },
                                              withoutTrend: withoutTrend))
    }

    func testANoisyTrendIsCountedAtPartStrength() {
        // Readings every minute: a slow wave plus sensor noise, so the 15-minute trend overstates
        // where glucose goes next and carrying it on in full forecasts worse than half.
        var rng = SeededRandom(seed: 11)
        var noise = 0.0
        let r = readings(endingAt: now, minutes: 6 * 1440, step: 1) { m in
            noise = 0.8 * noise + 3 * rng.normal()
            return 140 + 30 * sin(2 * .pi * m / (4 * 60)) + noise
        }
        let result = ForecastTuner.tune(readings: r, doses: [], meals: [], contexts: [], profile: .empty, days: 6, now: now)
        XCTAssertTrue(result.isTuned)
        XCTAssertLessThan(result.tuning.trendGain, 0.95)
        XCTAssertTrue(ForecastAccuracyText.tuningLine(result).contains("strength"))
    }

    func testStaysStandardWithoutEnoughHistory() {
        let result = ForecastTuner.tune(readings: wave(periodHours: 6, amplitude: 80, days: 1).suffix(12 * 12), doses: [],
                                        meals: [], contexts: [], profile: .empty, now: now)
        XCTAssertFalse(result.isTuned)
        XCTAssertLessThan(result.checks, ForecastTuner.minimumChecks)
    }

    func testTheModelUsesAndReportsTheTunedTiming() {
        let r = wave(periodHours: 6, amplitude: 80, days: 10)
        let model = OutlookEngine.learn(readings: r, doses: [], meals: [], contexts: [], low: 70, high: 180, now: now,
                                        calendar: utc)
        XCTAssertTrue(model.tuning.isTuned)
        XCTAssertEqual(model.calibration?.tuning, model.tuning.tuning)
        XCTAssertFalse(ForecastAccuracyText.tuningLine(model.tuning).isEmpty)
    }
}

/// The Insights card: 15, 30 and 60 minutes against no change, and how often the range held.
final class ForecastScorecardTests: XCTestCase {
    let now = referenceNow

    /// `count` forecasts from 100 mg/dL, each off by `error` at every horizon, glucose ending
    /// `moved` away from where it started. `inside` of them land inside a ±15 range.
    func records(count: Int, minutes: [Int] = [15, 30, 60], error: Double, moved: Double, inside: Int? = nil,
                 afterLog: Bool = false, device: String = "iPhone") -> [ForecastRecord] {
        (0..<count).map { i in
            let hit = i < (inside ?? count)
            return ForecastRecord(id: UUID(), issuedAt: now.addingTimeInterval(Double(i) * 900), device: device, basis: .trend,
                                  startMgdl: 100, trendPerMinute: 0,
                                  points: minutes.map { m in
                                      let actual = 100 + moved
                                      let forecast = actual - error
                                      let half = hit ? abs(error) + 5 : max(0, abs(error) - 5)
                                      return .init(minutes: m, mgdl: forecast, lower: forecast - half, upper: forecast + half,
                                                   actual: actual, afterLog: afterLog)
                                  },
                                  limitations: [], calibrated: true, tuned: false, morning: false)
        }
    }

    func testHiddenUntilFifteenMinutesHasEnoughCleanChecks() {
        XCTAssertNil(ForecastScorecard(LiveAccuracy(records(count: 29, error: 5, moved: 10))))
        XCTAssertNil(ForecastScorecard(LiveAccuracy(records(count: 60, error: 5, moved: 10, afterLog: true))),
                     "Points after a log don't count")
        XCTAssertNil(ForecastScorecard(LiveAccuracy(records(count: 60, minutes: [30, 60], error: 5, moved: 10))),
                     "Never shown without the 15-minute row")
        let card = ForecastScorecard(LiveAccuracy(records(count: 30, error: 5, moved: 10)))
        XCTAssertEqual(card?.rows.map(\.minutes), [15, 30, 60])
    }

    func testDropsAHorizonWithTooFewChecks() throws {
        let rs = records(count: 40, minutes: [15, 30], error: 5, moved: 10) + records(count: 10, minutes: [60], error: 5, moved: 10)
        let card = try XCTUnwrap(ForecastScorecard(LiveAccuracy(rs)))
        XCTAssertEqual(card.rows.map(\.minutes), [15, 30])
        XCTAssertNil(card.row(at: 60))
    }

    func testComparesWithNoChangeHonestly() throws {
        let better = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 6, moved: 18))))
        XCTAssertEqual(better.row(at: 15)?.error ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(better.row(at: 15)?.noChange ?? 0, 18, accuracy: 0.001)
        XCTAssertEqual(better.row(at: 15)?.comparison, .better)
        XCTAssertEqual(ForecastScorecardText.comparison(try XCTUnwrap(better.row(at: 15))), "Closer than no change")

        let same = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 10, moved: 10.2))))
        XCTAssertEqual(same.row(at: 15)?.comparison, .aboutTheSame)

        let worse = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 14, moved: 9))))
        XCTAssertEqual(worse.row(at: 15)?.comparison, .worse)
        XCTAssertEqual(ForecastScorecardText.comparison(try XCTUnwrap(worse.row(at: 15))), "Further off than no change")
    }

    func testRangeShareAndWording() throws {
        let short = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 10, moved: 10, inside: 24))))
        XCTAssertEqual(short.insidePercent, 60)
        XCTAssertTrue(ForecastScorecardText.rangeLine(short).contains("short of the aim"))
        let onTarget = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 10, moved: 10, inside: 32))))
        XCTAssertEqual(onTarget.insidePercent, 80)
        XCTAssertTrue(ForecastScorecardText.rangeLine(onTarget).hasSuffix("about 8 in 10."))
    }

    func testWordsInMmolAndNeverAboutDosing() throws {
        let card = try XCTUnwrap(ForecastScorecard(LiveAccuracy(records(count: 40, error: 10.8, moved: 18))))
        let row = try XCTUnwrap(card.row(at: 30))
        XCTAssertEqual(ForecastScorecardText.error(row.error, unit: .mmol), "±0.6 mmol/L")
        XCTAssertEqual(ForecastScorecardText.noChange(row, unit: .mmol), "No change ±1.0")
        XCTAssertTrue(ForecastScorecardText.spoken(row, unit: .mmol).hasPrefix("30 minutes ahead: typically 0.6 mmol/L off."))
        let footnote = ForecastScorecardText.footnote(device: "iPhone")
        XCTAssertTrue(footnote.contains("this iPhone"))
        XCTAssertTrue(footnote.contains("never a guide to dosing"))
        for text in [footnote, ForecastScorecardText.rangeLine(card), ForecastScorecardText.spoken(row, unit: .mmol)] {
            for word in ["take", "inject", "bolus", "correct"] {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(word)\" in: \(text)")
            }
        }
    }

    func testRelayForecastsStayApart() {
        var ledger = ForecastLedger()
        ledger.records = records(count: 40, error: 5, moved: 10) + records(count: 40, error: 30, moved: 10, device: ForecastRecord.relayDevice)
        let mine = ledger.accuracy(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(86_400), device: "iPhone")
        XCTAssertEqual(mine.clean(at: 15)?.checks, 40)
        XCTAssertEqual(mine.clean(at: 15)?.meanAbsoluteError ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(ledger.accuracy(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(86_400)).clean(at: 15)?.checks, 80)
        XCTAssertEqual(ForecastRecord.displayName(device: ForecastRecord.relayDevice), "Lock Screen")
        XCTAssertEqual(ForecastRecord.displayName(device: "Mac"), "Mac")
    }

    // MARK: Since the last update

    func versioned(_ rs: [ForecastRecord], _ version: String?, startingAt offset: TimeInterval = 0) -> [ForecastRecord] {
        rs.enumerated().map { i, r in
            var copy = ForecastRecord(id: r.id, issuedAt: now.addingTimeInterval(offset + Double(i) * 900), device: r.device,
                                      basis: r.basis, startMgdl: r.startMgdl, trendPerMinute: r.trendPerMinute,
                                      points: r.points, limitations: r.limitations, calibrated: r.calibrated,
                                      tuned: r.tuned, morning: r.morning)
            copy.appVersion = version
            return copy
        }
    }

    func testSinceUpdateKeepsOnlyTheInstalledVersion() throws {
        var ledger = ForecastLedger()
        ledger.records = versioned(records(count: 40, error: 20, moved: 10), "1.0.0")
            + versioned(records(count: 35, error: 4, moved: 10), "1.1.0", startingAt: 40 * 900)
        let end = now.addingTimeInterval(200 * 900)
        let first = ledger.firstRecord(device: "iPhone", appVersion: "1.1.0")
        XCTAssertEqual(first, now.addingTimeInterval(40 * 900))
        let week = ledger.accuracy(from: now, to: end, device: "iPhone")
        let mine = ledger.accuracy(from: now, to: end, device: "iPhone", appVersion: "1.1.0")
        XCTAssertEqual(week.clean(at: 15)?.checks, 75)
        XCTAssertEqual(mine.clean(at: 15)?.checks, 35)

        let u = try XCTUnwrap(ForecastSinceUpdate(accuracy: mine, version: "1.1.0", since: first, coversWeek: false))
        XCTAssertEqual(u.row(at: 15)?.error ?? 0, 4, accuracy: 0.001)
        let line = try XCTUnwrap(ForecastScorecardText.sinceUpdateRow(u, minutes: 15, unit: .mgdl))
        XCTAssertTrue(line.hasPrefix("On 1.1.0: ±4"), line)
        XCTAssertTrue(line.contains("Closer than no change"), line)
        XCTAssertNil(ForecastScorecardText.sinceUpdateCollecting(u))
        XCTAssertEqual(ForecastScorecardText.sinceUpdateTitle(u, now: first!.addingTimeInterval(9 * 3600 + 60)),
                       "Since you updated to 1.1.0, 9 hours ago")
    }

    func testSinceUpdateSaysItsStillCollecting() throws {
        var ledger = ForecastLedger()
        ledger.records = versioned(records(count: 40, error: 5, moved: 10), nil)
            + versioned(records(count: 12, error: 5, moved: 10), "1.1.0", startingAt: 40 * 900)
        let mine = ledger.accuracy(from: now, to: now.addingTimeInterval(100 * 900), device: "iPhone", appVersion: "1.1.0")
        let u = try XCTUnwrap(ForecastSinceUpdate(accuracy: mine, version: "1.1.0",
                                                  since: ledger.firstRecord(device: "iPhone", appVersion: "1.1.0"),
                                                  coversWeek: false))
        XCTAssertTrue(u.rows.isEmpty)
        XCTAssertNil(ForecastScorecardText.sinceUpdateRow(u, minutes: 15, unit: .mgdl))
        XCTAssertEqual(ForecastScorecardText.sinceUpdateCollecting(u)?.hasPrefix("1.1.0 has 12 of 30 checks"), true)
        XCTAssertNil(ForecastSinceUpdate(accuracy: .empty, version: "1.2.0", since: nil, coversWeek: false),
                     "Nothing to say before the version has recorded a forecast")
    }

    func testWholeWeekOnOneVersionIsNotSplit() throws {
        let mine = LiveAccuracy(versioned(records(count: 40, error: 5, moved: 10), "1.1.0"))
        let u = try XCTUnwrap(ForecastSinceUpdate(accuracy: mine, version: "1.1.0", since: now, coversWeek: true))
        XCTAssertNil(ForecastScorecardText.sinceUpdateRow(u, minutes: 15, unit: .mgdl))
        XCTAssertNil(ForecastScorecardText.sinceUpdateCollecting(u))
        XCTAssertTrue(ForecastScorecardText.sinceUpdateTitle(u).contains("1.1.0"))
    }

    func testNoteKeepsTheVersionAndUploadSendsIt() throws {
        var r = records(count: 1, error: 5, moved: 10)[0]
        r.appVersion = "1.1.0"
        let json = String(data: try JSONEncoder().encode(ForecastUpload(r)), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"app_version\":\"1.1.0\""), json)
        let old = String(data: try JSONEncoder().encode(ForecastUpload(records(count: 1, error: 5, moved: 10)[0])), encoding: .utf8)!
        XCTAssertFalse(old.contains("app_version"), "Records from before versions were kept send none")
        // Records saved before the field existed still load.
        let saved = try JSONEncoder().encode(records(count: 1, error: 5, moved: 10)[0])
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        obj.removeValue(forKey: "appVersion")
        let back = try JSONDecoder().decode(ForecastRecord.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.appVersion)
    }
}
