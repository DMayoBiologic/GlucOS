import XCTest
@testable import GlucOSEngine

/// Repeated meals, held-out profiles on short history, and widening the range from the forecasts
/// that were actually shown.
final class ForecastHonestyTests: XCTestCase {
    let now = referenceNow

    func meal(_ minutesAgo: Double, _ carbs: Double, _ food: String = "Toast", items: [String]? = nil) -> MealEntry {
        var m = MealEntry(timestamp: now.addingTimeInterval(-minutesAgo * 60), carbs: carbs, food: food)
        if let items {
            m.items = items.map { id in
                var item = MealItem(food: FoodItem(id: id, name: id, carbsPer100g: 50, source: .custom),
                                    grams: 100, portion: nil)
                item.carbs = carbs / Double(items.count)
                return item
            }
        }
        return m
    }

    // MARK: Repeated meals

    func testTheSameMealLoggedTwiceCountsOnce() {
        // The case from the logbook: one breakfast logged on the iPhone, then again on the Mac with
        // the time set 12 minutes earlier.
        let iphone = meal(60, 35.8, "Egg, chicken, whole, hard-boiled, Potato, hash brown")
        let mac = meal(72, 35.8, "egg, chicken, whole, hard-boiled,  potato, hash brown")
        let kept = LogCleanup.mealsWithoutRepeats([iphone, mac])
        XCTAssertEqual(kept.map(\.id), [mac.id], "The earliest entry is kept")
    }

    func testMatchesOnFoodsPickedFromTheList() {
        let a = meal(30, 54, "Big Brekkie Burger", items: ["custom:1"])
        let b = meal(10, 52, "Burger", items: ["custom:1"])
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([a, b]).count, 1)
    }

    func testDifferentMealsAreKept() {
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([meal(30, 40), meal(10, 20)]).count, 2, "Different carbs")
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([meal(30, 40, "Toast"), meal(10, 40, "Juice")]).count, 2,
                       "Different food")
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([meal(120, 40), meal(10, 40)]).count, 2, "Hours apart")
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([meal(30, 40, items: ["a"]), meal(10, 40, items: ["b"])]).count, 2,
                       "Different foods from the list")
        XCTAssertEqual(LogCleanup.mealsWithoutRepeats([meal(30, 0, "Salad"), meal(10, 0, "Salad")]).count, 2,
                       "Meals without carbs are never merged")
    }

    func testARepeatedMealDoesNotDoubleCarbsOnBoard() {
        let once = OnBoardNow(doses: [], meals: [meal(30, 40)], contexts: [], at: now)
        let twice = OnBoardNow(doses: [], meals: [meal(30, 40), meal(25, 40)], contexts: [], at: now)
        XCTAssertEqual(twice.carbs.onBoard, once.carbs.onBoard, accuracy: 0.01)
    }

    // MARK: Held-out profiles on short history

    func testHeldOutProfilesUseTheHistoryThereIs() {
        // 6 days of a simulated person: less than the 30-day backtest window. Each stretch's
        // profile must still be fitted on the other days, not on nothing.
        var person = SimulatedPerson()
        person.days = 6
        let sim = person.run(endingAt: now)
        let profile = EffectProfileLearner.learn(readings: sim.readings, doses: sim.doses, meals: sim.meals,
                                                 contexts: [], low: 70, now: now, calendar: utc)
        XCTAssertNotNil(profile.reliableInsulin)
        let heldOut = EffectProfileLearner.heldOut(readings: sim.readings, doses: sim.doses, meals: sim.meals,
                                                   contexts: [], profile: profile, low: 70, now: now, calendar: utc)
        for day in 0..<6 {
            let p = heldOut(now.addingTimeInterval(-Double(day) * 86_400 - 6 * 3600))
            XCTAssertNotNil(p.insulin, "Day \(day) back should have a held-out insulin figure")
            XCTAssertGreaterThan(p.intervals, 100)
        }
    }

    // MARK: Range from the forecasts shown

    /// A ledger of trend forecasts whose readings landed `miss` × the unwidened range's half-width
    /// (20 mg/dL) away. `shownScale` is how much wider the range was drawn.
    func ledger(points: Int, miss: Double, basis: ForecastBasis = .trend, shownScale: Double? = nil) -> ForecastLedger {
        var l = ForecastLedger()
        for i in 0..<points {
            let issued = now.addingTimeInterval(-Double(i + 1) * 3600)
            let half = 20.0 * (shownScale ?? 1)
            // Alternate above and below.
            let actual = 120 + (i % 2 == 0 ? 1 : -1) * miss * 20
            let p = ForecastRecord.Point(minutes: 30, mgdl: 120, lower: 120 - half, upper: 120 + half, actual: actual)
            l.records.append(ForecastRecord(id: UUID(), issuedAt: issued, device: "Mac", basis: basis, startMgdl: 120,
                                            trendPerMinute: 0, points: [p], limitations: [], calibrated: true,
                                            tuned: false, morning: false, rangeScale: shownScale, settled: true))
        }
        return l
    }

    func testRangeIsLeftAloneWithoutEnoughShownForecasts() {
        let s = ledger(points: 20, miss: 2).rangeScale(now: now)
        XCTAssertFalse(s.isWidened)
        XCTAssertEqual(s.factor(for: .trend), 1)
    }

    func testRangeWidensWhenReadingsLandOutsideIt() {
        // Every reading 1.6 half-widths out: the range held none of them.
        let s = ledger(points: 50, miss: 1.6).rangeScale(now: now)
        XCTAssertEqual(s.factor(for: .trend), 1.6, accuracy: 0.01)
        XCTAssertEqual(s.factor(for: .trendInsulinCarbs), 1.6, accuracy: 0.01, "Too few of a kind: uses all kinds")
        XCTAssertNotNil(ForecastAccuracyText.rangeLine(s))
    }

    func testRangeIsNeverNarrowedAndIsCapped() {
        XCTAssertEqual(ledger(points: 50, miss: 0.3).rangeScale(now: now).factor(for: .trend), 1)
        XCTAssertEqual(ledger(points: 50, miss: 9).rangeScale(now: now).factor(for: .trend), ForecastRangeScale.maximum)
    }

    func testWideningSettlesRatherThanCompounding() {
        // Shown 1.6× wide, and the readings landed 1.6 unwidened half-widths out (right at the
        // edge of what was shown): still 1.6, not 1.6 × 1.6.
        let s = ledger(points: 50, miss: 1.6, shownScale: 1.6).rangeScale(now: now)
        XCTAssertEqual(s.factor(for: .trend), 1.6, accuracy: 0.01)
    }

    func testEachHorizonGetsItsOwnWidening() {
        // Readings 1.6 half-widths out at 15 minutes, right on the edge at 45.
        var l = ForecastLedger()
        for i in 0..<40 {
            let sign: Double = i % 2 == 0 ? 1 : -1
            let points = [(15, 1.6), (45, 1.0)].map { m, miss in
                ForecastRecord.Point(minutes: m, mgdl: 120, lower: 100, upper: 140, actual: 120 + sign * miss * 20)
            }
            l.records.append(ForecastRecord(id: UUID(), issuedAt: now.addingTimeInterval(-Double(i + 1) * 3600), device: "Mac",
                                            basis: .trend, startMgdl: 120, trendPerMinute: 0, points: points,
                                            limitations: [], calibrated: true, tuned: false, morning: false, settled: true))
        }
        let s = l.rangeScale(now: now)
        XCTAssertEqual(s.factor(for: .trend, minutes: 15), 1.6, accuracy: 0.01)
        XCTAssertEqual(s.factor(for: .trend, minutes: 45), 1.0, accuracy: 0.01)
        XCTAssertEqual(s.factor(for: .trend, minutes: 30), 1.3, accuracy: 0.01, "Interpolated between horizons")
        XCTAssertEqual(s.factor(for: .trend, minutes: 5), 1.6, accuracy: 0.01, "Held before the first")
        XCTAssertEqual(s.largest, 1.6, accuracy: 0.01)

        // The forecast draws it point by point and records what each point was shown with.
        let r = readings(endingAt: now, minutes: 30) { 120 - $0 }
        var input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        let plain = try! GlucoseForecaster.forecast(input).get()
        input.rangeScale = s
        let wider = try! GlucoseForecaster.forecast(input).get()
        func half(_ f: GlucoseForecast, _ m: Int) -> Double {
            let p = f.samples.first { Int($0.date.timeIntervalSince(f.issuedAt) / 60) == m }!
            return p.upperMgdl - p.mgdl
        }
        XCTAssertEqual(half(wider, 15), half(plain, 15) * 1.6, accuracy: 0.01)
        XCTAssertEqual(half(wider, 30), half(plain, 30) * 1.3, accuracy: 0.01)
        var shown = ForecastLedger()
        shown.note(wider, device: "Mac", tuned: false, now: now)
        XCTAssertEqual(shown.records.first?.points.first { $0.minutes == 15 }?.scale ?? 0, 1.6, accuracy: 0.01)
        XCTAssertEqual(shown.records.first?.points.first { $0.minutes == 30 }?.scale ?? 0, 1.3, accuracy: 0.01)
    }

    func testOldRecordsWithoutAScaleStillDecode() throws {
        let json = """
        {"records":[{"id":"\(UUID().uuidString)","issuedAt":1789999200,"device":"Mac","basis":"trend","startMgdl":120,
        "trendPerMinute":0,"points":[],"limitations":[],"calibrated":false,"tuned":false,"morning":false,
        "settled":true,"uploaded":true}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let l = try decoder.decode(ForecastLedger.self, from: Data(json.utf8))
        XCTAssertNil(l.records.first?.rangeScale)
    }

    func testTheForecastDrawsTheWiderRange() throws {
        let r = readings(endingAt: now, minutes: 30) { 120 - $0 }
        var input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        let plain = try GlucoseForecaster.forecast(input).get()
        input.rangeScale = ForecastRangeScale(byBasis: [.trend: 1.5], checks: 60)
        let wider = try GlucoseForecaster.forecast(input).get()
        let a = try XCTUnwrap(plain.samples.last), b = try XCTUnwrap(wider.samples.last)
        XCTAssertEqual(a.mgdl, b.mgdl, "Widening never moves the forecast itself")
        XCTAssertEqual(b.upperMgdl - b.mgdl, (a.upperMgdl - a.mgdl) * 1.5, accuracy: 0.01)
        XCTAssertEqual(wider.rangeScale, 1.5)

        var ledger = ForecastLedger()
        ledger.note(wider, device: "Mac", tuned: false, now: now)
        XCTAssertEqual(ledger.records.first?.rangeScale, 1.5)
    }
}
