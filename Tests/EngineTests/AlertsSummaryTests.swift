import XCTest
@testable import GlucOSEngine

/// The Insights Alerts card (docs/InsightsAlerts.md).
final class AlertsSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    /// Wed 18 Nov 2026, 3 pm in Perth.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
    }

    private func at(days: Double = 0, minutes: Double = 0) -> Date {
        now.addingTimeInterval(days * 86_400 + minutes * 60)
    }

    private func summary(_ records: [AlertRecord], period: AlertsSummary.Period = .week,
                         end: Date? = nil) -> AlertsSummary {
        AlertsSummary.compute(records: records, period: period, end: end ?? now, calendar: calendar)
    }

    /// A reading every 15 minutes from `from` days ago to `to` days ago.
    private func readings(from: Double, to: Double) -> [GlucoseReading] {
        stride(from: -from * 86_400, through: -to * 86_400, by: 900).map {
            GlucoseReading(timestamp: now.addingTimeInterval($0), mgdl: 120, trend: .flat)
        }
    }

    // MARK: Counting

    func testCountsByKindAndEnding() {
        let records = [
            AlertRecord(kind: .urgentLow, firedAt: at(days: -1), response: .treating, respondedAt: at(days: -1, minutes: 1)),
            AlertRecord(kind: .low, firedAt: at(days: -2), response: .snoozed, respondedAt: at(days: -2, minutes: 2), snoozeMinutes: 30),
            AlertRecord(kind: .predictedLow, firedAt: at(days: -3), response: .dismissed, respondedAt: at(days: -3, minutes: 1)),
            AlertRecord(kind: .high, firedAt: at(days: -4)),
            AlertRecord(kind: .veryHigh, firedAt: at(days: -5), response: .snoozed, respondedAt: at(days: -5, minutes: 1), snoozeMinutes: 60),
            AlertRecord(kind: .predictedHigh, firedAt: at(days: -6)),
            AlertRecord(kind: .predictedVeryHigh, firedAt: at(days: -6, minutes: 30), response: .other),
        ]
        let s = summary(records)
        XCTAssertEqual(s.count, 7)
        XCTAssertEqual(s.lows, 3)
        XCTAssertEqual(s.highs, 4)
        XCTAssertEqual(s.count(.low), 2)
        XCTAssertEqual(s.count(.predictedLow), 1)
        XCTAssertEqual(s.count(.high), 2)
        XCTAssertEqual(s.count(.predictedHigh), 2)
        XCTAssertEqual(s.count(.treating), 1)
        XCTAssertEqual(s.count(.snoozed), 2)
        XCTAssertEqual(s.count(.dismissed), 1)
        XCTAssertEqual(s.count(.noResponse), 3, "a response a newer build wrote reads as no response")
        XCTAssertEqual(s.answered, 4)
        XCTAssertEqual(s.groups.map(\.group), [.low, .predictedLow, .high, .predictedHigh])
        XCTAssertEqual(s.endings.map(\.count), [1, 2, 1, 3])
    }

    func testOtherKindsAreNeverCounted() {
        let records = [AlertRecord(kind: .stale, firedAt: at(days: -1)),
                       AlertRecord(kind: .rapidChange, firedAt: at(days: -1)),
                       AlertRecord(kind: .apiBroken, firedAt: at(days: -2))]
        XCTAssertEqual(summary(records).count, 0)
        XCTAssertFalse(AlertsSummary.shows(records))
        XCTAssertFalse(AlertsSummary.shows([]))
        XCTAssertTrue(AlertsSummary.shows(records + [AlertRecord(kind: .high, firedAt: at(days: -80))]))
    }

    func testTheMacAndIPhoneCopiesCountOnceWithTheBestOutcome() {
        let mac = AlertRecord(kind: .low, firedAt: at(days: -1))
        let phone = AlertRecord(kind: .low, firedAt: at(days: -1, minutes: 1), response: .snoozed,
                                respondedAt: at(days: -1, minutes: 2), snoozeMinutes: 30)
        let s = summary([mac, phone])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.count(.snoozed), 1)
        XCTAssertEqual(s.count(.noResponse), 0)
    }

    func testThePeriodRunsBackItsCalendarDaysFromTheEnd() {
        let start = calendar.date(byAdding: .day, value: -7, to: now)!
        let onStart = AlertRecord(kind: .low, firedAt: start)
        let justInside = AlertRecord(kind: .high, firedAt: start.addingTimeInterval(60))
        let later = AlertRecord(kind: .high, firedAt: now.addingTimeInterval(60))
        let s = summary([onStart, justInside, later])
        XCTAssertEqual(s.start, start)
        XCTAssertEqual(s.items.map(\.id), [justInside.id], "the start belongs to the period before; after the end isn't counted")
        // 30 days reaches back further than the Alert History's 7.
        let old = AlertRecord(kind: .low, firedAt: at(days: -20))
        XCTAssertEqual(summary([old], period: .month).count, 1)
        XCTAssertEqual(summary([old], period: .fortnight).count, 0)
    }

    func testSteppedBackEndsEarlier() {
        let recent = AlertRecord(kind: .low, firedAt: at(days: -2))
        let earlier = AlertRecord(kind: .low, firedAt: at(days: -9))
        let s = summary([recent, earlier], end: calendar.date(byAdding: .day, value: -7, to: now)!)
        XCTAssertEqual(s.items.map(\.id), [earlier.id])
    }

    func testAlertHistoryStillListsSevenDaysByDefault() {
        let old = AlertRecord(kind: .low, firedAt: at(days: -9))
        XCTAssertTrue(AlertHistory.items(records: [old], readings: [], now: now, calendar: calendar).isEmpty)
        XCTAssertEqual(AlertHistory.items(records: [old], readings: [], now: now,
                                          since: at(days: -10), calendar: calendar).count, 1)
    }

    // MARK: Compare

    func testPreviousPeriodComparesCounts() {
        let records = [
            AlertRecord(kind: .low, firedAt: at(days: -1)),
            AlertRecord(kind: .high, firedAt: at(days: -2)),
            AlertRecord(kind: .low, firedAt: at(days: -8)),
            AlertRecord(kind: .low, firedAt: at(days: -9)),
            AlertRecord(kind: .high, firedAt: at(days: -10)),
            AlertRecord(kind: .low, firedAt: at(days: -13.9)),
        ]
        let current = summary(records)
        let prev = AlertsSummary.previous(records: records, readings: readings(from: 14, to: 0),
                                          current: current, calendar: calendar)
        XCTAssertEqual(prev?.count, 4)
        XCTAssertEqual(prev?.end, current.start)
        XCTAssertNil(prev?.countedSince)
        let total = InsightsCompare.alerts(current, prev)
        XCTAssertEqual(total?.direction, .down)
        XCTAssertEqual(total?.verdict, .better, "fewer alerts is better")
        XCTAssertEqual(total?.badge, "2")
        XCTAssertEqual(InsightsCompare.lowAlerts(current, prev)?.direction, .down)
        XCTAssertEqual(InsightsCompare.highAlerts(current, prev)?.direction, .same)
        XCTAssertNil(InsightsCompare.alerts(current, nil))
    }

    func testNoCompareBeforeAlertsWereKept() {
        // The first alert on record is 3 days ago: the week before would read as none only because
        // nothing was recorded yet.
        let records = [AlertRecord(kind: .low, firedAt: at(days: -3))]
        let current = summary(records)
        XCTAssertNil(AlertsSummary.previous(records: records, readings: readings(from: 14, to: 0),
                                            current: current, calendar: calendar))
        // An alert recorded on the first day of the week before is enough.
        let reaching = records + [AlertRecord(kind: .high, firedAt: at(days: -13.5))]
        XCTAssertNotNil(AlertsSummary.previous(records: reaching, readings: readings(from: 14, to: 0),
                                               current: summary(reaching), calendar: calendar))
    }

    func testNoCompareWithoutEnoughReadingsBefore() {
        let records = [AlertRecord(kind: .low, firedAt: at(days: -13.5)), AlertRecord(kind: .low, firedAt: at(days: -1))]
        let current = summary(records)
        // Readings on only the last 3 days of the week before: under 4 of 7.
        XCTAssertNil(AlertsSummary.previous(records: records, readings: readings(from: 9, to: 0),
                                            current: current, calendar: calendar))
        XCTAssertNotNil(AlertsSummary.previous(records: records, readings: readings(from: 11.9, to: 0),
                                               current: current, calendar: calendar))
    }

    // MARK: Empty state

    func testLongerWithAlerts() {
        let records = [AlertRecord(kind: .low, firedAt: at(days: -20))]
        XCTAssertEqual(AlertsSummary.longerWithAlerts(records: records, than: .week, end: now, calendar: calendar), .month)
        XCTAssertNil(AlertsSummary.longerWithAlerts(records: records, than: .month, end: now, calendar: calendar))
        let near = [AlertRecord(kind: .low, firedAt: at(days: -10))]
        XCTAssertEqual(AlertsSummary.longerWithAlerts(records: near, than: .week, end: now, calendar: calendar), .fortnight)
    }

    func testEmptyStateOffersALongerPeriodOrSaysWhy() {
        let longer = InsightsEmptyState.alerts(currentDays: 7, longerWithAlerts: 30)
        XCTAssertEqual(longer.reason, .tryLonger(days: 30))
        XCTAssertEqual(longer.actionTitle, "Show 30 Days")
        XCTAssertEqual(longer.title, "No alerts in 7 days")
        let none = InsightsEmptyState.alerts(currentDays: 30, longerWithAlerts: nil)
        XCTAssertEqual(none.reason, .noAlerts(days: 30))
        XCTAssertNil(none.action)
        XCTAssertEqual(none.systemImage, "bell.slash")
        XCTAssertTrue(none.message.contains("Test alerts aren't counted"))
    }

    // MARK: Words

    func testWords() {
        let records = [
            AlertRecord(kind: .low, firedAt: at(days: -1), response: .treating, respondedAt: at(days: -1)),
            AlertRecord(kind: .high, firedAt: at(days: -2)),
        ]
        let s = summary(records)
        XCTAssertEqual(AlertsSummaryText.headline(s), "2 alerts in the last 7 days.")
        XCTAssertEqual(AlertsSummaryText.headline(summary([])), "No alerts in the last 7 days.")
        XCTAssertEqual(AlertsSummaryText.answeredLine(s), "1 of 2 got a response.")
        XCTAssertNil(AlertsSummaryText.answeredLine(summary([])))
        XCTAssertEqual(AlertsSummaryText.ending(.treating), "Tapped Log treatment")
        XCTAssertEqual(AlertsSummaryText.spoken(s),
                       "Alerts, the last 7 days. 2 alerts: 1 low, 1 high. By kind: Low and urgent low 1, High and very high 1. How they ended: Tapped Log treatment 1, No response 1.")
        XCTAssertEqual(AlertsSummaryText.spoken(summary([])), "Alerts, the last 7 days. No alerts.")
    }

    func testFootnoteSaysWhenAlertsWereFirstKept() {
        let records = [AlertRecord(kind: .low, firedAt: at(days: -3))]
        let s = summary(records, period: .fortnight)
        XCTAssertNotNil(s.countedSince)
        XCTAssertTrue(AlertsSummaryText.footnote(s, calendar: calendar, locale: Locale(identifier: "en_AU"))
            .contains("GlucOS has kept alerts since 15 Nov 2026."))
        // Kept from before the period started: nothing to say.
        let old = records + [AlertRecord(kind: .high, firedAt: at(days: -40))]
        XCTAssertNil(summary(old, period: .fortnight).countedSince)
    }

    func testNoAdviceWords() {
        let records = [AlertRecord(kind: .low, firedAt: at(days: -1)), AlertRecord(kind: .high, firedAt: at(days: -2))]
        let s = summary(records)
        let all = [AlertsSummaryText.headline(s), AlertsSummaryText.answeredLine(s) ?? "",
                   AlertsSummaryText.footnote(s), AlertsSummaryText.spoken(s), AlertsSummaryText.historyHint]
            .joined(separator: " ").lowercased()
        for word in ["should", "try ", "increase", "decrease", "reduce", "dose more", "adjust"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }
}
