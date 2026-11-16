import XCTest
@testable import GlucOSEngine

final class WidgetGlanceTests: XCTestCase {
    private func snapshot(minutesOld: Double = 2, mgdl: Double = 110, trend: Trend = .rising) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.history = readings(endingAt: referenceNow.addingTimeInterval(-10 * 60), minutes: 120) { _ in 100 }
        s.current = reading(referenceNow.addingTimeInterval(-minutesOld * 60), mgdl, trend)
        s.sensor = SensorInfo(serial: "0M0001", activated: referenceNow.addingTimeInterval(-5 * 86_400), lifetimeDays: 15)
        s.fetchedAt = referenceNow
        return s
    }

    // MARK: Speech

    func testFreshReadingSaysRangeTrendAndAgeInWords() {
        let text = WidgetSpeech.reading(snapshot(), state: .fresh, at: referenceNow)
        XCTAssertTrue(text.hasPrefix("Glucose 6.1 "), text)
        XCTAssertTrue(text.contains("in range"), text)
        XCTAssertTrue(text.contains("rising"), text)
        XCTAssertTrue(text.contains("2 minutes ago"), text)
        XCTAssertFalse(text.contains("2m"), text)
    }

    func testStaleReadingNeverSaysItsRangeOrTrend() {
        let text = WidgetSpeech.reading(snapshot(minutesOld: 12, mgdl: 60, trend: .falling), state: .stale, at: referenceNow)
        XCTAssertTrue(text.hasPrefix("Stale."), text)
        XCTAssertTrue(text.contains("12 minutes ago"), text)
        XCTAssertFalse(text.lowercased().contains("low"), text)
        XCTAssertFalse(text.lowercased().contains("falling"), text)
    }

    func testExpiredReadingSaysWhenTheLastWasAndHowToFixIt() {
        var s = snapshot(minutesOld: 45)
        XCTAssertTrue(WidgetSpeech.reading(s, state: .expired, at: referenceNow).hasPrefix("No recent reading. The last was 6.1"))
        s.lastError = "offline"
        XCTAssertTrue(WidgetSpeech.reading(s, state: .expired, at: referenceNow).hasSuffix("Open GlucOS to reconnect."))
        XCTAssertEqual(WidgetSpeech.reading(.empty, state: .none, at: referenceNow), "No glucose reading yet. Waiting for GlucOS.")
    }

    func testAgeWords() {
        XCTAssertEqual(WidgetSpeech.age(20), "just now")
        XCTAssertEqual(WidgetSpeech.age(60), "1 minute ago")
        XCTAssertEqual(WidgetSpeech.age(3600), "1 hour ago")
        XCTAssertEqual(WidgetSpeech.age(2 * 3600 + 5 * 60), "2 hours 5 minutes ago")
    }

    // MARK: Reloads

    private func groups(_ old: GlucoseSnapshot, _ new: GlucoseSnapshot) -> Set<WidgetReload.Group> {
        WidgetReload.groups(from: WidgetReload.signature(old), to: WidgetReload.signature(new))
    }

    func testFirstPublishReloadsEverything() {
        XCTAssertEqual(WidgetReload.groups(from: nil, to: WidgetReload.signature(snapshot())), Set(WidgetReload.Group.allCases))
    }

    func testUnchangedSnapshotReloadsNothing() {
        // A logbook edit or relearn that leaves everything shown where it was.
        var b = snapshot()
        b.lastError = nil
        XCTAssertEqual(groups(snapshot(), b), [])
    }

    func testNewReadingInTheSameSlotReloadsOnlyTheGlucoseWidgets() {
        // referenceNow is on a 15-minute boundary, so 4 and 3 minutes old share the slot before it.
        XCTAssertEqual(groups(snapshot(minutesOld: 4), snapshot(minutesOld: 3, mgdl: 112)), [.glucose])
    }

    func testNewSlotReloadsTheSummariesToo() {
        XCTAssertEqual(groups(snapshot(minutesOld: 16), snapshot(minutesOld: 1)), [.glucose, .insights])
    }

    func testSettingsReloadEverything() {
        var b = snapshot()
        b.unit = .mgdl
        XCTAssertEqual(groups(snapshot(), b), [.glucose, .insights])
    }

    func testNewSensorReloadsOnlyTheSummaries() {
        var b = snapshot()
        b.sensor = SensorInfo(serial: "0M0002", activated: referenceNow, lifetimeDays: 15)
        XCTAssertEqual(groups(snapshot(), b), [.insights])
    }

    func testForecastOnlyCountsWhatsShown() {
        let sample = ForecastSample(date: referenceNow.addingTimeInterval(1800), mgdl: 130.2, lowerMgdl: 110, upperMgdl: 150)
        var a = snapshot()
        a.outlook = OutlookSnapshot(issuedAt: referenceNow, basis: .trend, forecast: [sample], insulinOnBoard: 1.23)
        var b = a
        // Under a mg/dL and under 0.05 U: nothing visible moved.
        b.outlook?.forecast = [ForecastSample(date: sample.date, mgdl: 130.4, lowerMgdl: 108, upperMgdl: 151)]
        b.outlook?.insulinOnBoard = 1.24
        XCTAssertEqual(groups(a, b), [])
        b.outlook?.insulinOnBoard = 1.4
        XCTAssertEqual(groups(a, b), [.glucose])
    }

    // MARK: Today so far

    func testTodayGlanceIsForItsDayOnly() {
        let g = TodayGlance(day: utc.startOfDay(for: referenceNow), period: "Midnight to 2 pm", headline: "",
                            timeInRange: 1, meanMgdl: 120, lows: 0, spoken: "")
        XCTAssertTrue(g.isCurrent(at: referenceNow, calendar: utc))
        XCTAssertFalse(g.isCurrent(at: referenceNow.addingTimeInterval(11 * 3600), calendar: utc))
    }

    func testTodaySoFarGlanceCarriesTheCardsWords() throws {
        let todayStart = utc.startOfDay(for: referenceNow)
        var rs: [GlucoseReading] = []
        var t = todayStart.addingTimeInterval(-14 * 86_400)
        while t <= referenceNow { rs.append(reading(t, 120)); t = t.addingTimeInterval(300) }
        let tsf = try XCTUnwrap(TodaySoFar.compute(readings: rs, window: .fortnight, low: 70, high: 180,
                                                   now: referenceNow, calendar: utc))
        let g = tsf.glance(unit: .mmol, now: referenceNow, calendar: utc)
        XCTAssertEqual(g.day, todayStart)
        XCTAssertEqual(g.period, "Midnight to 2 pm")
        XCTAssertEqual(g.headline, "About your usual day by now.")
        XCTAssertEqual(g.rangeCaption, "Usually 100%")
        XCTAssertEqual(g.lowsCaption, "Usually none by now")
        XCTAssertEqual(g.spoken, TodaySoFarText.spoken(tsf, unit: .mmol))

        // Written into the snapshot and read back by the widget.
        var s = GlucoseSnapshot()
        s.today = g
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(GlucoseSnapshot.self, from: data).today, g)
    }
}
