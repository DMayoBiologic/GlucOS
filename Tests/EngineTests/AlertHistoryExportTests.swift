import XCTest
@testable import GlucOSEngine

/// Alert History export (docs/AlertHistory.md, "Export").
final class AlertHistoryExportTests: XCTestCase {
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

    private func report(_ records: [AlertRecord], readings: [GlucoseReading] = [], notes: [ContextEvent] = [],
                        pick: AlertHistory.FilterPick = .all, unit: GlucoseUnit = .mmol,
                        device: LogbookExport.Device = .iPhone) -> AlertHistoryExport.Report {
        AlertHistoryExport.report(records: records, readings: readings, notes: notes, pick: pick, unit: unit,
                                  device: device, now: now, calendar: calendar)
    }

    // MARK: What's exported

    func testExportsWhatTheChipsShowOldestFirst() {
        let low = AlertRecord(kind: .low, firedAt: at(-120), response: .snoozed, respondedAt: at(-118), snoozeMinutes: 30)
        let high = AlertRecord(kind: .high, firedAt: at(-60))
        let predicted = AlertRecord(kind: .predictedLow, firedAt: at(-30), response: .dismissed, respondedAt: at(-29))
        let all = report([predicted, high, low])
        XCTAssertEqual(all.rows.map(\.item.id), [low.id, high.id, predicted.id])
        XCTAssertEqual(all.totalAlerts, 3)

        let lows = report([predicted, high, low], pick: .init(kind: .lows))
        XCTAssertEqual(lows.rows.map(\.item.id), [low.id])
        XCTAssertEqual(lows.totalAlerts, 3)

        let snoozed = report([predicted, high, low], pick: .init(outcome: .snoozed))
        XCTAssertEqual(snoozed.rows.map(\.item.id), [low.id])
        XCTAssertTrue(report([predicted, high, low], pick: .init(kind: .highs, outcome: .treated)).rows.isEmpty)
    }

    func testSameItemsAsTheHistory() {
        // The Mac's and the iPhone's copies are one row, and anything older than 7 days is left
        // out, exactly as on screen.
        let mac = AlertRecord(kind: .low, firedAt: at(-20))
        let phone = AlertRecord(kind: .low, firedAt: at(-19), response: .treating, respondedAt: at(-18))
        let old = AlertRecord(kind: .low, firedAt: at(-8 * 24 * 60))
        let r = report([mac, phone, old])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].item.outcome, .treating)
        let screen = AlertHistory.items(records: [mac, phone, old], readings: [], now: now, calendar: calendar)
        XCTAssertEqual(Set(r.rows.map(\.item)), Set(screen))
    }

    func testEachAlertCarriesItsNote() {
        let a = AlertRecord(kind: .low, firedAt: at(-90))
        let b = AlertRecord(kind: .high, firedAt: at(-30))
        let note = ContextEvent(timestamp: at(-90).addingTimeInterval(20), tags: [], note: "Ran for the bus")
        // A tagged entry is not an alert's note.
        let tagged = ContextEvent(timestamp: at(-30), tags: [.exercise], note: "Gym")
        let r = report([a, b], notes: [note, tagged])
        XCTAssertEqual(r.rows.map(\.note), ["Ran for the bus", ""])
    }

    func testOutcomeCountsInChipOrder() {
        let records = [
            AlertRecord(kind: .low, firedAt: at(-200), response: .snoozed, respondedAt: at(-199), snoozeMinutes: 15),
            AlertRecord(kind: .high, firedAt: at(-150)),
            AlertRecord(kind: .low, firedAt: at(-100), response: .treating, respondedAt: at(-99)),
            AlertRecord(kind: .high, firedAt: at(-50)),
        ]
        let r = report(records)
        XCTAssertEqual(r.outcomeCounts, [.init(outcome: .treated, count: 1), .init(outcome: .snoozed, count: 1),
                                         .init(outcome: .noResponse, count: 2)])
        XCTAssertEqual(AlertHistoryExport.outcomeLine(r), "Tapped Log treatment 1 · Snoozed 1 · No response 2")
        XCTAssertNil(AlertHistoryExport.outcomeLine(report([])))
    }

    // MARK: CSV

    func testCSVColumnsAndValues() {
        let low = AlertRecord(kind: .low, firedAt: at(-46), response: .snoozed, respondedAt: at(-44), snoozeMinutes: 30)
        let high = AlertRecord(kind: .predictedHigh, firedAt: at(-10))
        let readings = [GlucoseReading(timestamp: at(-48), mgdl: 61.3, trend: .flat)]
        let note = ContextEvent(timestamp: at(-46), tags: [], note: "Juice, then \"walk\"")
        let csv = AlertHistoryExport.csv(report([low, high], readings: readings, notes: [note]), calendar: calendar)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Date,Time,Alert,Type,Glucose (mmol/L),Outcome,Responded,Note")
        XCTAssertEqual(lines[1], "2026-11-18,14:14,Low alert,Low,3.4,Snoozed 30 min,14:16,\"Juice, then \"\"walk\"\"\"")
        XCTAssertEqual(lines[2], "2026-11-18,14:50,Predicted high alert,Predicted,,No response,,")
        XCTAssertEqual(lines.count, 4) // header, 2 rows, trailing CRLF
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testCSVInMgdlAndAResponseOnAnotherDay() {
        // Fired just before midnight, snoozed just after.
        let fired = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 23, minute: 58))!
        let r = AlertRecord(kind: .low, firedAt: fired, response: .snoozed,
                            respondedAt: fired.addingTimeInterval(4 * 60), snoozeMinutes: 15)
        let readings = [GlucoseReading(timestamp: fired.addingTimeInterval(-60), mgdl: 65, trend: .flat)]
        let csv = AlertHistoryExport.csv(report([r], readings: readings, unit: .mgdl), calendar: calendar)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Date,Time,Alert,Type,Glucose (mg/dL),Outcome,Responded,Note")
        XCTAssertEqual(lines[1], "2026-11-17,23:58,Low alert,Low,65,Snoozed 15 min,2026-11-18 00:02,")
    }

    func testCSVNeverRunsANoteAsAFormula() {
        let a = AlertRecord(kind: .low, firedAt: at(-30))
        let note = ContextEvent(timestamp: at(-30), tags: [], note: "=HYPERLINK(\"x\")")
        let csv = AlertHistoryExport.csv(report([a], notes: [note]), calendar: calendar)
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""))
    }

    // MARK: Words

    func testFileNameNamesTheDaysAndTheChips() {
        XCTAssertEqual(AlertHistoryExport.fileName(report([]), format: .pdf, calendar: calendar),
                       "GlucOS Alert History 2026-11-12 to 2026-11-18.pdf")
        XCTAssertEqual(AlertHistoryExport.fileName(report([], pick: .init(kind: .lows, outcome: .snoozed)),
                                                   format: .csv, calendar: calendar),
                       "GlucOS Alert History 2026-11-12 to 2026-11-18 (Snoozed low alerts).csv")
    }

    func testHeaderLinesSayThePeriodAndFilter() {
        let records = [AlertRecord(kind: .low, firedAt: at(-60)), AlertRecord(kind: .high, firedAt: at(-30))]
        XCTAssertEqual(LogbookExport.periodLine(report(records).period, calendar: calendar), "12 Nov – 18 Nov 2026 (7 days)")
        XCTAssertEqual(AlertHistoryExport.showingLine(report(records)), "Showing: All alerts · 2 alerts")
        XCTAssertEqual(AlertHistoryExport.showingLine(report(records, pick: .init(kind: .highs))),
                       "Showing: High alerts · 1 of 2 alerts")
        XCTAssertEqual(AlertHistoryExport.filterLine(.init(kind: .predicted, outcome: .noResponse)),
                       "Unanswered predicted alerts")
        XCTAssertEqual(AlertHistoryExport.emptyLine(.init(kind: .lows, outcome: .dismissed)),
                       "No dismissed low alerts in the last 7 days.")
    }

    func testFooterSaysWhichDeviceAndNoAdvice() {
        XCTAssertTrue(AlertHistoryExport.footnote(.mac).hasPrefix("Made on this Mac"))
        XCTAssertTrue(AlertHistoryExport.footnote(.iPhone).hasPrefix("Made on this iPhone"))
        XCTAssertTrue(AlertHistoryExport.footnote(.iPhone).contains("not advice"))
    }

    func testMenuWords() {
        XCTAssertEqual(AlertHistoryExportText.item(.pdf, device: .iPhone), "Share PDF")
        XCTAssertEqual(AlertHistoryExportText.item(.csv, device: .mac), "Save CSV…")
        XCTAssertEqual(AlertHistoryExportText.shown(12, of: 12), "12 alerts shown")
        XCTAssertEqual(AlertHistoryExportText.shown(3, of: 12), "3 of 12 alerts shown")
    }

    func testDaysGroupOldestFirst() {
        let y = AlertRecord(kind: .low, firedAt: at(-24 * 60))
        let t1 = AlertRecord(kind: .high, firedAt: at(-60))
        let t2 = AlertRecord(kind: .low, firedAt: at(-30))
        let days = AlertHistoryExport.days(report([t2, y, t1]).rows, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].rows.map(\.item.id), [y.id])
        XCTAssertEqual(days[1].rows.map(\.item.id), [t1.id, t2.id])
    }
}
