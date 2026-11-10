import XCTest
@testable import GlucOSEngine

final class PredictiveAlertTests: XCTestCase {
    let now = referenceNow
    let settings = PredictiveAlertSettings(lows: true, highs: true, leadTime: 30 * 60, lowMgdl: 70, highMgdl: 180, highAlertsOn: true)

    func forecast(endingAt mgdl: Double, slope: Double) -> GlucoseForecast {
        let r = readings(endingAt: now, minutes: 20) { m in mgdl - slope * m }
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [], profile: .empty, now: now)
        guard case .success(let f) = GlucoseForecaster.forecast(input) else { fatalError("no forecast") }
        return f
    }

    func testFallingTowardsLowAlerts() {
        // 90 falling 2/min: reaches 70 at about 13 minutes.
        let d = PredictiveAlertRules.evaluate(forecast(endingAt: 90, slope: -2), settings: settings, now: now)
        XCTAssertEqual(d?.kind, .low)
        XCTAssertEqual(d?.thresholdMgdl, 70)
        XCTAssertLessThanOrEqual(d?.minutesAway(from: now) ?? 99, 20)
    }

    func testFallingFastTowardsUrgentLowAlertsUrgent() {
        let d = PredictiveAlertRules.evaluate(forecast(endingAt: 80, slope: -3), settings: settings, now: now)
        XCTAssertEqual(d?.kind, .urgentLow)
    }

    func testSteadyOrSlowDriftDoesNotAlert() {
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 75, slope: 0), settings: settings, now: now))
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 75, slope: -0.2), settings: settings, now: now))
        // Falling but nowhere near low within the lead time.
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 160, slope: -1), settings: settings, now: now))
    }

    func testAlreadyLowLeavesItToTheReadingAlert() {
        let d = PredictiveAlertRules.evaluate(forecast(endingAt: 65, slope: -1), settings: settings, now: now)
        // Below 70 already, so no "predicted low", but still heading for urgent low.
        XCTAssertNotEqual(d?.kind, .low)
    }

    func testRisingTowardsHighAlerts() {
        let d = PredictiveAlertRules.evaluate(forecast(endingAt: 165, slope: 2), settings: settings, now: now)
        XCTAssertEqual(d?.kind, .high)
        var off = settings
        off.highAlertsOn = false
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 165, slope: 2), settings: off, now: now))
        off.highs = false
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 240, slope: 3), settings: off, now: now))
    }

    func testRisingTowardsVeryHighAlertsEvenWithoutHighAlerts() {
        var s = settings
        s.highAlertsOn = false
        let d = PredictiveAlertRules.evaluate(forecast(endingAt: 235, slope: 2), settings: s, now: now)
        XCTAssertEqual(d?.kind, .veryHigh)
    }

    func testModelledFallWithoutAFallingTrendDoesNotAlert() throws {
        // Flat at 90 with insulin acting and its effect learnt: the forecast's line crosses 70,
        // but the trend isn't falling yet, so there's no heads-up (by design: the trend has to agree).
        let r = readings(endingAt: now, minutes: 20) { _ in 90 }
        let profile = EffectProfile(insulin: LearnedEffect(value: 80, standardError: 4, examples: 20), carbs: nil,
                                    driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: now)
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-45 * 60), units: 4, kind: .rapid)
        let input = ForecastInputs(readings: GlucoseSeries(r), doses: [dose], meals: [], contexts: [], profile: profile, now: now)
        guard case .success(let f) = GlucoseForecaster.forecast(input) else { return XCTFail("no forecast") }
        XCTAssertEqual(f.basis, .trendInsulinCarbs)
        // The crossing is inside the lead time, so only the trend gate can be holding the alert back.
        let crossing = try XCTUnwrap(f.firstBelow(70))
        XCTAssertLessThanOrEqual(crossing.timeIntervalSince(now), settings.leadTime)
        XCTAssertNil(PredictiveAlertRules.evaluate(f, settings: settings, now: now))
    }

    func testOldForecastNeverAlerts() {
        let f = forecast(endingAt: 90, slope: -2)
        XCTAssertNil(PredictiveAlertRules.evaluate(f, settings: settings, now: now.addingTimeInterval(10 * 60)))
    }

    func testLowsCanBeTurnedOff() {
        var s = settings
        s.lows = false
        XCTAssertNil(PredictiveAlertRules.evaluate(forecast(endingAt: 90, slope: -2), settings: s, now: now))
    }
}

final class RecurringPatternTests: XCTestCase {
    /// 14 days of readings every 15 minutes at `base`, with `override(day, hour)` replacing values.
    func history(base: Double = 120, override: (Int, Int) -> Double? = { _, _ in nil }) -> [GlucoseReading] {
        let end = utc.startOfDay(for: referenceNow)
        let start = end.addingTimeInterval(-14 * 86_400)
        var out: [GlucoseReading] = []
        var t = start
        var day = 0
        while t < end {
            let hour = utc.component(.hour, from: t)
            day = Int(t.timeIntervalSince(start) / 86_400)
            out.append(reading(t, override(day, hour) ?? base))
            t = t.addingTimeInterval(15 * 60)
        }
        return out
    }

    func testNoPatternsInSteadyData() {
        XCTAssertTrue(RecurringPatternFinder.find(readings: history(), low: 70, high: 180, now: referenceNow, calendar: utc).isEmpty)
    }

    func testFindsRecurringNightLows() {
        // Lows from 2 to 4 am on 6 of 14 days.
        let r = history { day, hour in (day % 2 == 0 && day < 12 && (2..<4).contains(hour)) ? 60 : nil }
        let p = RecurringPatternFinder.find(readings: r, low: 70, high: 180, now: referenceNow, calendar: utc)
        let low = try? XCTUnwrap(p.first { $0.kind == .low })
        XCTAssertEqual(low?.startHour, 2)
        XCTAssertEqual(low?.endHour, 4)
        XCTAssertEqual(low?.days, 6)
        XCTAssertEqual(low?.hours, 2)
        XCTAssertFalse(p.contains { $0.kind == .high })
    }

    func testOccasionalLowsAreNotAPattern() {
        // Only twice.
        let r = history { day, hour in (day < 2 && hour == 3) ? 60 : nil }
        XCTAssertTrue(RecurringPatternFinder.find(readings: r, low: 70, high: 180, now: referenceNow, calendar: utc).isEmpty)
    }

    func testHighsAcrossMidnightAreOneWindow() {
        // High from 10 pm to 1 am most days.
        let r = history { day, hour in (day % 3 != 0 && (hour >= 22 || hour < 1)) ? 220 : nil }
        let p = RecurringPatternFinder.find(readings: r, low: 70, high: 180, now: referenceNow, calendar: utc)
        let highs = p.filter { $0.kind == .high }
        XCTAssertEqual(highs.count, 1)
        XCTAssertEqual(highs.first?.startHour, 22)
        XCTAssertEqual(highs.first?.endHour, 1)
        XCTAssertEqual(highs.first?.hours, 3)
    }

    func testHistoryIsEnoughOnlyWithACoveredHourOnSevenDays() {
        let end = utc.startOfDay(for: referenceNow)
        // One reading a day for ten days: plenty of days, but no hour is ever covered.
        var sparse: [GlucoseReading] = []
        for d in 1...10 {
            let day: TimeInterval = -Double(d) * 86_400
            sparse.append(reading(end.addingTimeInterval(day + 3 * 3600), 120))
        }
        XCTAssertFalse(RecurringPatternFinder.hasEnoughHistory(readings: sparse, now: referenceNow, calendar: utc))
        // 3 am covered (every 15 minutes) on seven days.
        var covered: [GlucoseReading] = []
        for d in 1...7 {
            for q in 0..<4 {
                let offset: TimeInterval = -Double(d) * 86_400 + 3 * 3600 + Double(q) * 900
                covered.append(reading(end.addingTimeInterval(offset), 120))
            }
        }
        XCTAssertTrue(RecurringPatternFinder.hasEnoughHistory(readings: covered, now: referenceNow, calendar: utc))
        // …but six days isn't enough.
        let sixDaysAgo = end.addingTimeInterval(-6.5 * 86_400)
        let six = covered.filter { $0.timestamp > sixDaysAgo }
        XCTAssertFalse(RecurringPatternFinder.hasEnoughHistory(readings: six, now: referenceNow, calendar: utc))
        XCTAssertTrue(RecurringPatternFinder.hasEnoughHistory(readings: history(), now: referenceNow, calendar: utc))
    }

    func testNotEnoughDaysIsNotAPattern() {
        let all = history { _, hour in hour == 3 ? 60 : nil }
        let recent = all.filter { $0.timestamp >= referenceNow.addingTimeInterval(-5 * 86_400) }
        XCTAssertTrue(RecurringPatternFinder.find(readings: recent, low: 70, high: 180, now: referenceNow, calendar: utc).isEmpty)
    }
}

final class OutlookTests: XCTestCase {
    func testSnapshotCarriesTheEssentials() {
        let now = referenceNow
        let r = readings(endingAt: now, minutes: 20) { m in 90 + 2 * m }   // falling 2/min to 90
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-3600), units: 2, kind: .rapid)
        let outlook = OutlookEngine.outlook(readings: r, doses: [dose], meals: [], contexts: [], model: .empty, now: now)
        let s = outlook.snapshot(lowMgdl: 70)
        XCTAssertEqual(s.issuedAt, now)
        XCTAssertEqual(s.basis, .trend)   // insulin not learnt
        XCTAssertFalse(s.forecast.isEmpty)
        XCTAssertEqual(s.insulinOnBoard ?? 0, 2 * InsulinActionCurve.rapid.fractionRemaining(after: 3600), accuracy: 1e-9)
        XCTAssertNotNil(s.insulinMostlyDoneAt)
        XCTAssertNil(s.carbsOnBoard)
        XCTAssertNotNil(s.lowExpectedAt)
        XCTAssertTrue(s.isCurrent(at: now))
        XCTAssertFalse(s.isCurrent(at: now.addingTimeInterval(10 * 60)))
        XCTAssertEqual(s.sample(minutesAhead: 30)?.date, now.addingTimeInterval(30 * 60))
        XCTAssertNil(s.sample(minutesAhead: 90))
        XCTAssertTrue(outlook.limitations.contains(.insulinNotLearned))
    }

    func testUnavailableForecastExplainsWhy() {
        let now = referenceNow
        let outlook = OutlookEngine.outlook(readings: [reading(now.addingTimeInterval(-3600), 100)], doses: [], meals: [],
                                            contexts: [], model: .empty, now: now)
        let s = outlook.snapshot(lowMgdl: 70)
        XCTAssertTrue(s.forecast.isEmpty)
        XCTAssertNotNil(s.unavailableReason)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let now = referenceNow
        var snap = GlucoseSnapshot()
        snap.outlook = OutlookSnapshot(issuedAt: now, basis: .trendInsulinCarbs,
                                       forecast: [ForecastSample(date: now, mgdl: 100, lowerMgdl: 100, upperMgdl: 100)],
                                       insulinOnBoard: 1.5)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(GlucoseSnapshot.self, from: enc.encode(snap))
        XCTAssertEqual(back.outlook, snap.outlook)
        // A snapshot written before the outlook existed still reads.
        let old = #"{"history":[],"unit":"mmol","lowMgdl":70,"highMgdl":180,"fetchedAt":"2026-01-01T00:00:00Z"}"#
        let legacy = try dec.decode(GlucoseSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(legacy.outlook)
    }
}
