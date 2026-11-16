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

    // MARK: Lock Screen accessories

    func testAccessoryStateUsesTheWidgetEdges() {
        XCTAssertEqual(AccessoryGlance.state(snapshot(minutesOld: 2), at: referenceNow), .fresh)
        XCTAssertEqual(AccessoryGlance.state(snapshot(minutesOld: 6), at: referenceNow), .fresh)
        XCTAssertEqual(AccessoryGlance.state(snapshot(minutesOld: 7), at: referenceNow), .stale)
        XCTAssertEqual(AccessoryGlance.state(snapshot(minutesOld: 30), at: referenceNow), .stale)
        XCTAssertEqual(AccessoryGlance.state(snapshot(minutesOld: 31), at: referenceNow), .expired)
        XCTAssertEqual(AccessoryGlance.state(.empty, at: referenceNow), .none)
    }

    func testAccessoryAgeIsShort() {
        XCTAssertEqual(AccessoryGlance.age(20), "now")
        XCTAssertEqual(AccessoryGlance.age(4 * 60), "4m")
        XCTAssertEqual(AccessoryGlance.age(65 * 60), "1h 5m")
        XCTAssertEqual(AccessoryGlance.age(65 * 60, compact: true), "1h")
        XCTAssertEqual(AccessoryGlance.age(3 * 3600), "3h")
        XCTAssertEqual(AccessoryGlance.age(50 * 3600), "2d")
    }

    func testInlineShowsTrendAndAgeOnlyWhileFresh() {
        XCTAssertEqual(AccessoryGlance.inline(snapshot(minutesOld: 2), at: referenceNow), "6.1 ↗ · 2m")
        XCTAssertEqual(AccessoryGlance.inline(snapshot(minutesOld: 2, trend: .unknown), at: referenceNow), "6.1 · 2m")
        let stale = AccessoryGlance.inline(snapshot(minutesOld: 12), at: referenceNow)
        XCTAssertEqual(stale, "Stale 6.1 · 12m")
        XCTAssertFalse(stale.contains("↗"))
    }

    func testInlineWithdrawsTheNumberOnceExpired() {
        var s = snapshot(minutesOld: 45)
        XCTAssertEqual(AccessoryGlance.inline(s, at: referenceNow), "No reading for 45m")
        s.lastError = "offline"
        XCTAssertEqual(AccessoryGlance.inline(s, at: referenceNow), "Can't connect · 45m")
        XCTAssertEqual(AccessoryGlance.inline(.empty, at: referenceNow), "No reading yet")
    }

    func testCircularCaptionIsTheAgeOnceNotFresh() {
        XCTAssertNil(AccessoryGlance.circularCaption(snapshot(minutesOld: 2), at: referenceNow))
        XCTAssertEqual(AccessoryGlance.circularCaption(snapshot(minutesOld: 12), at: referenceNow), "12m")
        XCTAssertEqual(AccessoryGlance.circularCaption(snapshot(minutesOld: 95), at: referenceNow), "1h")
        XCTAssertNil(AccessoryGlance.circularCaption(.empty, at: referenceNow))
    }

    func testRectangularWithdrawnLine() {
        XCTAssertNil(AccessoryGlance.withdrawnLine(snapshot(minutesOld: 2), at: referenceNow))
        XCTAssertNil(AccessoryGlance.withdrawnLine(snapshot(minutesOld: 12), at: referenceNow))
        XCTAssertEqual(AccessoryGlance.withdrawnLine(snapshot(minutesOld: 45), at: referenceNow), "No reading for 45m")
        XCTAssertEqual(AccessoryGlance.withdrawnLine(.empty, at: referenceNow), "Waiting for GlucOS")
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

    // MARK: Your usual

    private func usual(_ id: String, _ kind: UsualGlance.Kind, detail: String = "") -> UsualGlance {
        UsualGlance(id: id, kind: kind, title: id, detail: detail, systemImage: "fork.knife", spoken: id)
    }

    func testUsualEntriesReloadOnlyTheUsualWidget() {
        var b = snapshot()
        b.usuals = [usual("meal-lunch", .meal, detail: "Sandwich · 40 g")]
        XCTAssertEqual(groups(snapshot(), b), [.usual])
        var c = b
        c.usuals = [usual("meal-lunch", .meal, detail: "Sandwich · 45 g")]
        XCTAssertEqual(groups(b, c), [.usual])
    }

    func testANewReadingReloadsTheUsualWidgetOnlyWhileACorrectionShows() {
        var a = snapshot(minutesOld: 4), b = snapshot(minutesOld: 3, mgdl: 112)
        a.usuals = [usual("meal-lunch", .meal)]
        b.usuals = a.usuals
        XCTAssertEqual(groups(a, b), [.glucose])
        a.usuals = [usual("correction", .correction)]
        b.usuals = a.usuals
        XCTAssertEqual(groups(a, b), [.glucose, .usual])
    }

    func testAStaleReadingHidesTheUsualCorrection() {
        let all = [usual("low", .low), usual("correction", .correction), usual("meal-lunch", .meal), usual("x", .meal)]
        XCTAssertEqual(UsualGlance.visible(all, readingFresh: true, at: referenceNow).map(\.id), ["low", "correction", "meal-lunch"])
        XCTAssertEqual(UsualGlance.visible(all, readingFresh: false, at: referenceNow).map(\.id), ["low", "meal-lunch", "x"])
    }

    func testAMealGoesOnceItsPartOfTheDayIsOver() {
        var meal = usual("meal-breakfast", .meal)
        meal.until = referenceNow.addingTimeInterval(30 * 60)
        let all = [meal, usual("correction", .correction)]
        XCTAssertEqual(UsualGlance.visible(all, readingFresh: true, at: referenceNow).map(\.id), ["meal-breakfast", "correction"])
        XCTAssertEqual(UsualGlance.visible(all, readingFresh: true, at: meal.until!).map(\.id), ["correction"])
        let stale = referenceNow.addingTimeInterval(4 * 60)
        XCTAssertEqual(UsualGlance.changeDates(all, staleAt: stale, after: referenceNow), [stale, meal.until!])
        XCTAssertEqual(UsualGlance.changeDates([meal], staleAt: stale, after: referenceNow), [meal.until!])
    }

    func testMealSlotEnds() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func t(_ h: Int, _ m: Int = 0, day: Int = 16) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
        }
        XCTAssertEqual(MealSlot.breakfast.end(after: t(7, 30), calendar: cal), t(11))
        XCTAssertEqual(MealSlot.dinner.end(after: t(21, 59), calendar: cal), t(22))
        XCTAssertEqual(MealSlot.snack.end(after: t(23), calendar: cal), t(5, day: 17))
        XCTAssertNil(MealSlot.lunch.end(after: t(7), calendar: cal))
    }

    func testUsualGlanceCarriesTheEntrysWords() {
        let u = UsualEntry(kind: .correction, food: "", carbs: 0, items: nil, units: 2, insulinKind: .rapid,
                           insulinName: "NovoRapid", count: 4, lastLogged: referenceNow)
        let g = UsualGlance(u, now: referenceNow)
        XCTAssertNil(g.until)
        XCTAssertEqual(g.id, "correction")
        XCTAssertEqual(g.kind, .correction)
        XCTAssertEqual(g.title, "Usual correction")
        XCTAssertEqual(g.detail, u.detail)
        XCTAssertEqual(g.spoken, u.spokenLabel)
    }

    func testMacWidgetLinkRoundTrips() {
        for id in ["meal-breakfast", "correction", "low"] {
            let g = UsualGlance(id: id, kind: .meal, title: id, detail: "", systemImage: "fork.knife", spoken: id)
            XCTAssertEqual(g.openURL.absoluteString, "glucos://log/usual/\(id)")
            XCTAssertEqual(UsualGlance.usualID(from: g.openURL), id)
        }
        // Other links open the log window (or the popover) as before, never an entry.
        for s in ["glucos://log", "glucos://log/food", "glucos://open", "glucos://log/usual", "glucos://log/usual/", "other://log/usual/low"] {
            XCTAssertNil(UsualGlance.usualID(from: URL(string: s)!), s)
        }
    }
}
