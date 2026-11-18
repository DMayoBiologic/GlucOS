import XCTest
@testable import GlucOSEngine

/// Settings › Alerts › History (docs/AlertHistory.md).
final class AlertHistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    /// Wed 18 Nov 2026, 3 pm in Perth.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func reading(_ minutes: Double, _ mgdl: Double) -> GlucoseReading {
        GlucoseReading(timestamp: at(minutes), mgdl: mgdl, trend: .flat)
    }

    private func items(_ records: [AlertRecord], readings: [GlucoseReading] = []) -> [AlertHistory.Item] {
        AlertHistory.items(records: records, readings: readings, now: now, calendar: calendar)
    }

    // MARK: What's listed

    func testOnlyTheLastSevenCalendarDays() {
        let start = AlertHistory.start(now: now, calendar: calendar)
        // Midnight on Thu 12 Nov: today and the 6 days before it.
        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!)
        let inside = AlertRecord(kind: .low, firedAt: start.addingTimeInterval(60))
        let outside = AlertRecord(kind: .low, firedAt: start.addingTimeInterval(-60))
        XCTAssertEqual(items([inside, outside]).map(\.id), [inside.id])
    }

    func testOnlyLowAndHighAlertsNewestFirst() {
        let a = AlertRecord(kind: .low, firedAt: at(-120))
        let b = AlertRecord(kind: .predictedHigh, firedAt: at(-30))
        let stale = AlertRecord(kind: .stale, firedAt: at(-10))
        var future = AlertRecord(kind: .low, firedAt: at(-5))
        future.kind = "somethingNewer"
        XCTAssertEqual(items([a, b, stale, future]).map(\.id), [b.id, a.id])
    }

    func testEveryRepeatIsItsOwnRow() {
        // Unlike the Logbook, which folds a spell into one row: the history lists each alert.
        let records = (0..<3).map { AlertRecord(kind: .low, firedAt: at(Double(-60 + $0 * 15))) }
        XCTAssertEqual(items(records).count, 3)
    }

    func testTheMacAndIPhoneCopiesAreOneRowWithTheBestOutcome() {
        let mac = AlertRecord(kind: .low, firedAt: at(-20))
        let phone = AlertRecord(kind: .low, firedAt: at(-19), response: .snoozed, respondedAt: at(-18), snoozeMinutes: 30)
        let list = items([mac, phone])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, mac.id)
        XCTAssertEqual(list[0].outcome, .snoozed(minutes: 30))
        XCTAssertEqual(list[0].respondedAt, at(-18))
        // A different kind at the same moment is its own alert.
        XCTAssertEqual(items([mac, AlertRecord(kind: .predictedLow, firedAt: at(-20))]).count, 2)
    }

    func testAButtonBeatsADismissal() {
        let dismissed = AlertRecord(kind: .high, firedAt: at(-20), response: .dismissed, respondedAt: at(-19))
        let treated = AlertRecord(kind: .high, firedAt: at(-20), response: .treating, respondedAt: at(-15), snoozeMinutes: 30)
        XCTAssertEqual(items([dismissed, treated])[0].outcome, .treating)
        XCTAssertEqual(items([treated, dismissed])[0].outcome, .treating)
        XCTAssertEqual(items([dismissed])[0].outcome, .dismissed)
        XCTAssertEqual(items([AlertRecord(kind: .high, firedAt: at(-20))])[0].outcome, .noResponse)
        XCTAssertNil(items([AlertRecord(kind: .high, firedAt: at(-20))])[0].respondedAt)
    }

    func testTestAlertsAreNeverRecorded() {
        // A test alert carries no kind, so there's never a record of one to list (docs/TestAlert.md).
        var info: [AnyHashable: Any] = [:]
        for (k, v) in TestAlert.userInfo(chart: nil) { info[k] = v }
        XCTAssertNil(TestAlert.ownKind(info))
        // Even dressed up as a low, a test alert isn't one of the user's own.
        info["kind"] = AlertNotice.Kind.low.rawValue
        XCTAssertNil(TestAlert.ownKind(info))
    }

    // MARK: Dismissals

    func testADismissalIsRecordedOnlyWhenNothingWasTapped() {
        let shown = AlertRecord(kind: .low, firedAt: at(-10))
        let d = AlertLog.dismissed(.low, firedAt: at(-10), at: at(-9), in: [shown])!
        XCTAssertEqual(d.id, shown.id)
        XCTAssertEqual(d.response, .dismissed)
        XCTAssertEqual(d.respondedAt, at(-9))
        XCTAssertNil(d.snoozeMinutes)
        // A snooze stands: the banner goes away after its button too.
        let snoozed = AlertRecord(kind: .low, firedAt: at(-10), response: .snoozed, respondedAt: at(-9), snoozeMinutes: 30)
        XCTAssertNil(AlertLog.dismissed(.low, firedAt: at(-10), at: at(-8), in: [snoozed]))
        // A button after a dismissal still counts.
        let tapped = AlertLog.responded(.low, .treating, snoozeMinutes: 15, firedAt: at(-10), at: at(-5), in: [d])!
        XCTAssertEqual(tapped.response, .treating)
        // A push not seen yet gets a record; alerts that aren't logged get none.
        XCTAssertEqual(AlertLog.dismissed(.high, firedAt: at(-3), at: at(-2), in: [])?.response, .dismissed)
        XCTAssertNil(AlertLog.dismissed(.stale, firedAt: at(-3), at: at(-2), in: []))
    }

    func testTheLogbookRowSaysDismissedLast() {
        let records = [
            AlertRecord(kind: .low, firedAt: at(-30), response: .dismissed, respondedAt: at(-29)),
            AlertRecord(kind: .low, firedAt: at(-15)),
        ]
        XCTAssertEqual(AlertLog.rows(records)[0].responseText, "Dismissed")
        let withSnooze = records + [AlertRecord(kind: .low, firedAt: at(-5), response: .snoozed, respondedAt: at(-4), snoozeMinutes: 30)]
        XCTAssertEqual(AlertLog.rows(withSnooze)[0].responseText, "Snoozed 30 min")
    }

    func testAnOlderVersionReadsDismissedAsNoResponse() throws {
        // What an older build does with a value it doesn't know: `.other`, shown as no response.
        let data = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"low","firedAt":0,"response":"somethingNewer"}"#.utf8)
        let r = try JSONDecoder().decode(AlertRecord.self, from: data)
        XCTAssertEqual(r.response, .other)
        let round = try JSONDecoder().decode(AlertRecord.self, from: JSONEncoder().encode(AlertRecord(kind: .low, firedAt: now, response: .dismissed)))
        XCTAssertEqual(round.response, .dismissed)
    }

    // MARK: The reading

    func testTheReadingAtTheTime() {
        let readings = [reading(-25, 80), reading(-20, 70), reading(-15, 62), reading(-10, 60)]
        let r = AlertRecord(kind: .low, firedAt: at(-14))
        XCTAssertEqual(items([r], readings: readings.shuffled())[0].readingMgdl, 62)
    }

    func testAReadingJustAfterWhenNoneBefore() {
        let r = AlertRecord(kind: .low, firedAt: at(-14))
        XCTAssertEqual(items([r], readings: [reading(-11, 65)])[0].readingMgdl, 65)
        // Too far either side: none.
        XCTAssertNil(items([r], readings: [reading(-30, 65), reading(-5, 60)])[0].readingMgdl)
    }

    // MARK: Days

    func testGroupedByLocalDayNewestFirst() {
        let today = AlertRecord(kind: .low, firedAt: at(-60))
        let lateYesterday = AlertRecord(kind: .high, firedAt: calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 23, minute: 50))!)
        let earlyYesterday = AlertRecord(kind: .low, firedAt: calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 2))!)
        let days = AlertHistory.days(items([earlyYesterday, today, lateYesterday]), calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].start, calendar.startOfDay(for: now))
        XCTAssertEqual(days[0].items.map(\.id), [today.id])
        XCTAssertEqual(days[1].items.map(\.id), [lateYesterday.id, earlyYesterday.id])
        XCTAssertTrue(AlertHistory.days([], calendar: calendar).isEmpty)
    }

    // MARK: Opening the Logbook

    func testARowOpensTheLogbookAroundIt() {
        let first = AlertRecord(kind: .predictedLow, firedAt: at(-90))
        let second = AlertRecord(kind: .low, firedAt: at(-60))
        let records = [first, second]
        let item = items(records).first { $0.id == second.id }!
        let link = AlertHistory.link(for: item, records: records, now: now, calendar: calendar)
        XCTAssertEqual(link.filter, .aroundAlert)
        XCTAssertNil(link.kindChip, "everything around it, not one kind")
        // From before the Logbook row it folds into (which starts at the forecast low) to 2 h after.
        XCTAssertEqual(link.period.interval.start, at(-90 - 15))
        XCTAssertEqual(link.period.interval.end, at(-60 + 120))
        XCTAssertTrue(link.period.contains(first.firedAt, calendar: calendar))
        XCTAssertTrue(link.period.label.hasPrefix("Around "))
        XCTAssertFalse(LogbookFilter.aroundAlert.isListed)
        XCTAssertTrue(LogbookFilter.aroundAlert.matches(AlertLog.rows(records)[0]))
    }

    // MARK: Words

    func testWords() {
        let r = AlertRecord(kind: .urgentLow, firedAt: at(-30), response: .treating, respondedAt: at(-29))
        let item = items([r], readings: [reading(-31, 50)])[0]
        XCTAssertEqual(item.title, "Urgent low alert")
        XCTAssertEqual(AlertHistoryText.reading(50, unit: .mgdl), "50 mg/dL")
        XCTAssertEqual(AlertHistoryText.reading(nil, unit: .mgdl), "No reading")
        XCTAssertTrue(AlertHistoryText.outcome(item, calendar: calendar).hasPrefix("Tapped Log treatment at "))
        let spoken = AlertHistoryText.spoken(item, unit: .mmol, calendar: calendar)
        XCTAssertTrue(spoken.hasPrefix("Urgent low alert, "), spoken)
        XCTAssertTrue(spoken.contains("reading 2.8 mmol/L"), spoken)
        XCTAssertTrue(spoken.contains("Tapped Log treatment"), spoken)
        XCTAssertEqual(AlertHistory.Outcome.snoozed(minutes: 30).text, "Snoozed 30 min")
        XCTAssertEqual(AlertHistory.Outcome.dismissed.text, "Dismissed")
        XCTAssertEqual(AlertHistory.Outcome.noResponse.text, "No response")
        XCTAssertEqual(AlertHistoryText.count(1), "1 alert")
        XCTAssertEqual(AlertHistoryText.count(4), "4 alerts")
        XCTAssertNotEqual(AlertHistoryText.emptyMessage(alertsOn: true), AlertHistoryText.emptyMessage(alertsOn: false))
    }

    // MARK: Live while open

    func testANewAlertArrivingIsOneChange() {
        let high = AlertRecord(kind: .high, firedAt: at(-120))
        let fresh = AlertRecord(kind: .low, firedAt: at(-1))
        let old = items([high], readings: [reading(-2, 65)])
        let new = items([high, fresh], readings: [reading(-2, 65)])
        let changes = AlertHistory.changes(from: old, to: new, now: now)
        XCTAssertEqual(changes.count, 1)
        guard case .arrived(let item) = changes.first else { return XCTFail("\(changes)") }
        XCTAssertEqual(item.id, fresh.id)
        let text = AlertHistoryText.announcement(changes, unit: .mgdl, calendar: calendar)!
        XCTAssertTrue(text.hasPrefix("New low alert, "), text)
        XCTAssertTrue(text.hasSuffix("reading 65 mg/dL"), text)
    }

    func testAnOutcomeMovingOnIsOneChange() {
        let fired = AlertRecord(kind: .low, firedAt: at(-10))
        var snoozed = fired
        snoozed.response = .snoozed
        snoozed.snoozeMinutes = 30
        snoozed.respondedAt = at(-8)
        let changes = AlertHistory.changes(from: items([fired]), to: items([snoozed]), now: now)
        XCTAssertEqual(changes.map(\.item.id), [fired.id])
        guard case .outcome(let item) = changes.first else { return XCTFail("\(changes)") }
        XCTAssertEqual(item.outcome, .snoozed(minutes: 30))
        let text = AlertHistoryText.announcement(changes, unit: .mgdl, calendar: calendar)!
        XCTAssertTrue(text.hasPrefix("Low alert at "), text)
        XCTAssertTrue(text.hasSuffix(": Snoozed 30 min"), text)
        // Nothing changed: nothing to say.
        XCTAssertTrue(AlertHistory.changes(from: items([snoozed]), to: items([snoozed]), now: now).isEmpty)
        XCTAssertNil(AlertHistoryText.announcement([], unit: .mgdl))
    }

    func testTheOtherDevicesCopyIsNotANewAlert() {
        // The Mac's copy, fired a minute earlier, syncs in after the iPhone's and takes over the
        // row's id. It's the same alert, and its dismissal is the only change.
        let phone = AlertRecord(kind: .low, firedAt: at(-5))
        let mac = AlertRecord(kind: .low, firedAt: at(-6), response: .dismissed, respondedAt: at(-4))
        let old = items([phone])
        let new = items([phone, mac])
        XCTAssertEqual(new.map(\.id), [mac.id])
        let changes = AlertHistory.changes(from: old, to: new, now: now)
        XCTAssertEqual(changes.count, 1)
        guard case .outcome = changes.first else { return XCTFail("\(changes)") }
        // A copy with nothing new says nothing.
        let quiet = AlertRecord(kind: .low, firedAt: at(-6))
        XCTAssertTrue(AlertHistory.changes(from: old, to: items([phone, quiet]), now: now).isEmpty)
    }

    func testOldAlertsSyncingInAreListedQuietly() {
        let late = AlertRecord(kind: .high, firedAt: at(-AlertHistory.freshArrival / 60 - 1))
        XCTAssertTrue(AlertHistory.changes(from: [], to: items([late]), now: now).isEmpty)
        // And one ageing out of the 7 days isn't a change either.
        XCTAssertTrue(AlertHistory.changes(from: items([late]), to: [], now: now).isEmpty)
    }

    func testSeveralChangesAreCountedInOneAnnouncement() {
        let a = AlertRecord(kind: .low, firedAt: at(-40))
        var aTreated = a
        aTreated.response = .treating
        aTreated.respondedAt = at(-39)
        let b = AlertRecord(kind: .high, firedAt: at(-3))
        let c = AlertRecord(kind: .urgentLow, firedAt: at(-1))
        let changes = AlertHistory.changes(from: items([a]), to: items([aTreated, b, c]), now: now)
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(AlertHistoryText.announcement(changes, unit: .mgdl, calendar: calendar),
                       "Alert history: 2 new alerts, 1 updated")
        XCTAssertEqual(AlertHistoryText.announcement(Array(changes.prefix(2)), unit: .mgdl, calendar: calendar),
                       "Alert history: 2 new alerts")
    }
}
