import XCTest
@testable import GlucOSEngine

/// "Back in range in about X min": where the forecast comes back down to the high threshold, and
/// the device's own checks that decide whether it's shown (docs/ForecastAccuracy.md §24).
final class BackInRangeTests: XCTestCase {
    let now = referenceNow

    // MARK: Crossing

    func testCrossingIsLinearBetweenPoints() {
        // 198 → 183 at 15 → 175 at 30: crosses 180 at 15 + 3/8 × 15 (the iPhone, 12 Nov 22:15).
        let m = BackInRange.minutesBack(start: 198, points: [(15, 183), (30, 175)], high: 180)
        XCTAssertEqual(m!, 20.625, accuracy: 0.001)
        XCTAssertEqual(BackInRange.minutesBack(start: 192, points: [(15, 154)], high: 180)!, 15 * 12 / 38, accuracy: 0.001)
    }

    func testNothingWhenTheForecastStaysAboveOrStartsInRange() {
        XCTAssertNil(BackInRange.minutesBack(start: 250, points: [(15, 240), (30, 230)], high: 180),
                     "Nothing past the drawn forecast is guessed")
        XCTAssertNil(BackInRange.minutesBack(start: 150, points: [(15, 140)], high: 180))
        XCTAssertNil(BackInRange.minutesBack(start: 60, points: [(15, 80)], high: 180), "Lows get no time back")
    }

    // MARK: Actual return

    func testActualReturnNeedsTheNextReadingInRangeToo() {
        let start = now.addingTimeInterval(-7200)
        // Dips to 179 for one reading at 10 min, back up, then in range for good from 30 min.
        let values: [Int: Double] = [0: 200, 5: 190, 10: 179, 15: 185, 20: 184, 25: 182, 30: 178, 35: 170, 40: 160]
        let series = GlucoseSeries(values.map { reading(start.addingTimeInterval(Double($0.key) * 60), $0.value) })
        XCTAssertEqual(BackInRange.actualMinutesBack(readings: series, from: start, low: 70, high: 180), 30)
    }

    // MARK: Checks

    /// A settled forecast from `hoursAgo` that started at 200 and crossed 180 at `estimate` minutes,
    /// and readings that came back in range at `actual` minutes (nil: stayed at 220).
    func scenario(hoursAgo: Double, estimate: Double, actual: Double?, device: String = "iPhone")
        -> (ForecastRecord, [GlucoseReading]) {
        let issued = now.addingTimeInterval(-hoursAgo * 3600)
        // Linear from 200 down through 180 at `estimate`.
        let slope = 20 / estimate
        let points = [15, 30].map { m in
            ForecastRecord.Point(minutes: m, mgdl: 200 - slope * Double(m), lower: 0, upper: 400)
        }
        let record = ForecastRecord(id: UUID(), issuedAt: issued, device: device, basis: .trend, startMgdl: 200,
                                    trendPerMinute: -slope, points: points, limitations: [], calibrated: true,
                                    tuned: false, morning: false, settled: true)
        let readings = stride(from: 0, through: 7 * 60, by: 5).map { m -> GlucoseReading in
            let v: Double
            if let actual { v = Double(m) < actual ? 200 : 150 } else { v = 220 }
            return reading(issued.addingTimeInterval(Double(m) * 60), v)
        }
        return (record, readings)
    }

    func check(_ s: [(ForecastRecord, [GlucoseReading])], device: String = "iPhone") -> BackInRangeCheck {
        let readings = s.flatMap(\.1).sorted { $0.timestamp < $1.timestamp }
        return BackInRange.check(records: s.map(\.0), readings: GlucoseSeries(readings), device: device,
                                 low: 70, high: 180, now: now)
    }

    func testShownOnceFiveChecksMissByFifteenMinutesOrLessTypically() {
        // Days apart so each one's readings stand alone.
        let close = (1...5).map { scenario(hoursAgo: Double($0) * 24, estimate: 20, actual: 25 + Double($0)) }
        let c = check(close)
        XCTAssertEqual(c.checks, 5)
        // Readings every 5 minutes: each is first seen back in range at 30 minutes.
        XCTAssertEqual(c.medianMissMinutes!, 10, accuracy: 0.001)
        XCTAssertTrue(c.shows)
        XCTAssertFalse(check(Array(close.prefix(4))).shows, "Four checks aren't enough to say")
    }

    func testHiddenWhenTheTypicalMissIsOverFifteenMinutes() {
        let far = (1...6).map { scenario(hoursAgo: Double($0) * 24, estimate: 15, actual: $0 <= 3 ? 20 : 50) }
        // Misses 5, 5, 5 (rounded to the 5-minute readings), 35, 35, 35: median 20.
        XCTAssertFalse(check(far).shows)
        XCTAssertEqual(check(far).withinTolerance!, 0.5, accuracy: 0.001)
    }

    func testStillHighSixHoursLaterCountsAsAMiss() {
        let s = (1...5).map { scenario(hoursAgo: Double($0) * 24, estimate: 20, actual: nil) }
        let c = check(s)
        XCTAssertEqual(c.checks, 5)
        XCTAssertEqual(c.medianMissMinutes!, 340, accuracy: 0.001)
        XCTAssertFalse(c.shows)
    }

    func testOnlyThisDevicesForecastsCount() {
        let mac = (1...5).map { scenario(hoursAgo: Double($0) * 24, estimate: 20, actual: 22, device: "Mac") }
        XCTAssertEqual(check(mac, device: "iPhone"), .none)
        XCTAssertTrue(check(mac, device: "Mac").shows)
    }

    // MARK: Live estimate

    func forecast(start: Double, slope: Double) -> GlucoseForecast {
        let samples = stride(from: 0, through: 30, by: 5).map { m in
            ForecastSample(date: now.addingTimeInterval(Double(m) * 60), mgdl: start + slope * Double(m),
                           lowerMgdl: 0, upperMgdl: 400)
        }
        return GlucoseForecast(issuedAt: now, startMgdl: start, basis: .trend, trendPerMinute: slope,
                               samples: samples, limitations: [], calibrated: true)
    }

    func testEstimateOnlyWhileTheChecksAllowIt() {
        let open = BackInRangeCheck(checks: 5, medianMissMinutes: 6, withinTolerance: 0.8)
        let closed = BackInRangeCheck(checks: 5, medianMissMinutes: 18, withinTolerance: 0.4)
        let f = forecast(start: 200, slope: -1)
        XCTAssertEqual(BackInRange.estimate(f, high: 180, check: open), now.addingTimeInterval(20 * 60))
        XCTAssertNil(BackInRange.estimate(f, high: 180, check: closed))
        XCTAssertNil(BackInRange.estimate(f, high: 180, check: .none))
        XCTAssertNil(BackInRange.estimate(forecast(start: 200, slope: -0.5), high: 180, check: open),
                     "Still at 185 at the end of the drawn 30 minutes: nothing said")
        XCTAssertNil(BackInRange.estimate(forecast(start: 60, slope: 1), high: 180, check: open))
    }

    func testSnapshotCarriesTheEstimateOnlyWithAHighThreshold() {
        var model = OutlookModel.empty
        model.backInRange = BackInRangeCheck(checks: 6, medianMissMinutes: 5.8, withinTolerance: 0.7)
        let o = Outlook(at: now, forecast: .success(forecast(start: 200, slope: -1)), insulin: .compute(doses: [], at: now),
                        background: .compute(doses: [], at: now), carbs: .compute(meals: [], hypoTreatments: [], at: now),
                        model: model)
        XCTAssertEqual(o.snapshot(lowMgdl: 70, highMgdl: 180).backInRangeAt, now.addingTimeInterval(20 * 60))
        XCTAssertNil(o.snapshot(lowMgdl: 70).backInRangeAt)
    }
}
