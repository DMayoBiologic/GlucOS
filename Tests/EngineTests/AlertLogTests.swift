import XCTest
@testable import GlucOSEngine

/// Low and high alerts in the Logbook (docs/AlertLog.md).
final class AlertLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: Recording

    func testOnlyLowAndHighAlertsAreKept() {
        for kind in AlertNotice.Kind.allCases {
            let kept = AlertLog.fired(kind, at: t0, in: []) != nil
            XCTAssertEqual(kept, kind.treatment != nil, "\(kind)")
        }
        XCTAssertNil(AlertLog.fired(.rapidChange, at: t0, in: []))
        XCTAssertNil(AlertLog.fired(.stale, at: t0, in: []))
        XCTAssertNil(AlertLog.fired(.sensorExpiring, at: t0, in: []))
        XCTAssertNil(AlertLog.fired(.apiBroken, at: t0, in: []))
    }

    func testTheSameNotificationSeenTwiceIsOneRecord() {
        let first = AlertLog.fired(.low, at: at(0), in: [])!
        // Shown while open, then found again in Notification Center.
        XCTAssertNil(AlertLog.fired(.low, at: at(0.5), in: [first]))
        // A different alert at the same time is its own record.
        XCTAssertNotNil(AlertLog.fired(.predictedLow, at: at(0.5), in: [first]))
        // The 15-minute repeat is a new one.
        XCTAssertNotNil(AlertLog.fired(.low, at: at(15), in: [first]))
    }

    func testATapUpdatesTheAlertItAnswers() {
        let first = AlertLog.fired(.high, at: at(0), in: [])!
        let tapped = AlertLog.responded(.high, .snoozed, snoozeMinutes: 30, firedAt: at(0), at: at(2), in: [first])!
        XCTAssertEqual(tapped.id, first.id)
        XCTAssertEqual(tapped.response, .snoozed)
        XCTAssertEqual(tapped.respondedAt, at(2))
        XCTAssertEqual(tapped.snoozeMinutes, 30)
    }

    func testATapOnAPushNotSeenYetAddsIt() {
        let tapped = AlertLog.responded(.urgentLow, .treating, snoozeMinutes: nil, firedAt: at(0), at: at(1), in: [])!
        XCTAssertEqual(tapped.kind, "urgentLow")
        XCTAssertEqual(tapped.firedAt, at(0))
        XCTAssertEqual(tapped.response, .treating)
        XCTAssertNil(tapped.snoozeMinutes)
        XCTAssertNil(AlertLog.responded(.stale, .snoozed, snoozeMinutes: 30, firedAt: at(0), at: at(1), in: []))
    }

    func testOldRecordsExpire() {
        let old = AlertRecord(kind: .low, firedAt: at(0))
        let recent = AlertRecord(kind: .low, firedAt: at(89 * 1440))
        XCTAssertEqual(AlertLog.expired([old, recent], now: at(91 * 1440)).map(\.id), [old.id])
    }

    // MARK: Rows

    func testRepeatsOfOneLowAreOneRow() {
        let records = [
            AlertRecord(kind: .predictedLow, firedAt: at(0)),
            AlertRecord(kind: .low, firedAt: at(20)),
            AlertRecord(kind: .low, firedAt: at(35), response: .snoozed, respondedAt: at(36), snoozeMinutes: 30),
            AlertRecord(kind: .low, firedAt: at(70)),
        ]
        let rows = AlertLog.rows(records)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.id, records[0].id)
        // A real low over the forecast that came first.
        XCTAssertEqual(row.kind, .low)
        XCTAssertEqual(row.title, "Low alert")
        XCTAssertEqual(row.first, at(0))
        XCTAssertEqual(row.last, at(70))
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row.responseText, "Snoozed 30 min")
        XCTAssertEqual(row.repeatText, "Went off 4 times")
    }

    func testALowAndAHighAreSeparateRows() {
        let rows = AlertLog.rows([
            AlertRecord(kind: .high, firedAt: at(0)),
            AlertRecord(kind: .low, firedAt: at(10)),
        ])
        XCTAssertEqual(rows.map(\.kind), [.low, .high])
        XCTAssertEqual(rows.map(\.responseText), ["No response", "No response"])
        XCTAssertNil(rows[0].repeatText)
    }

    func testALongGapStartsANewRow() {
        let rows = AlertLog.rows([
            AlertRecord(kind: .low, firedAt: at(0)),
            AlertRecord(kind: .low, firedAt: at(0) + AlertLog.rowGap + 60),
        ])
        XCTAssertEqual(rows.count, 2)
        // Newest first.
        XCTAssertGreaterThan(rows[0].timestamp, rows[1].timestamp)
    }

    func testTheMacAndIPhoneShowingOneAlertCountOnce() {
        let rows = AlertLog.rows([
            AlertRecord(kind: .veryHigh, firedAt: at(0)),
            AlertRecord(kind: .veryHigh, firedAt: at(0.3)),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 1)
        XCTAssertEqual(rows[0].title, "Very high alert")
    }

    func testAForecastAndTheRealLowMomentsLaterAreTwoAlerts() {
        let rows = AlertLog.rows([
            AlertRecord(kind: .predictedLow, firedAt: at(0)),
            AlertRecord(kind: .low, firedAt: at(0.5)),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0].repeatText, "Went off 2 times")
    }

    func testTreatingWinsOverASnooze() {
        let rows = AlertLog.rows([
            AlertRecord(kind: .urgentLow, firedAt: at(0), response: .treating, respondedAt: at(1)),
            AlertRecord(kind: .low, firedAt: at(15), response: .snoozed, respondedAt: at(16), snoozeMinutes: 15),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .urgentLow)
        XCTAssertEqual(rows[0].responseText, "Tapped Log treatment")
        XCTAssertEqual(rows[0].respondedAt, at(1))
    }

    func testRecordsFromANewerVersionStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"somethingNew","firedAt":1800000000,"response":"dismissedLater"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let r = try d.decode(AlertRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.response, .other)
        XCTAssertNil(r.alertKind)
        // A kind this version doesn't know gets no row.
        XCTAssertTrue(AlertLog.rows([r]).isEmpty)
    }

    // MARK: Sync and safety

    func testAlertsSyncBetweenDevicesAndAreNeverEntries() {
        var mac = LogbookContents(), phone = LogbookContents()
        var macState = LogbookSyncState(), phoneState = LogbookSyncState()
        let r = AlertRecord(kind: .low, firedAt: at(0), response: .treating, respondedAt: at(1), snoozeMinutes: 15)
        mac.alerts.append(r)
        LogbookMerge.touch(r.id, kind: .alert, deleted: false, now: at(1), state: &macState)
        let pushed = LogbookMerge.outgoing(mac, state: macState, device: "Mac")
        XCTAssertEqual(pushed.map(\.kind), ["alert"])
        let remote = pushed.enumerated().map { i, r in var r = r; r.rev = Int64(i + 1); return r }
        XCTAssertTrue(LogbookMerge.apply(remote, to: &phone, state: &phoneState))
        XCTAssertEqual(phone.alerts, [r])
        // "Log treatment" is not a treatment: no food, dose or hypo treatment tag appears.
        XCTAssertTrue(phone.doses.isEmpty)
        XCTAssertTrue(phone.meals.isEmpty)
        XCTAssertTrue(phone.contexts.isEmpty)

        // Expired on the Mac: gone everywhere.
        mac.alerts = []
        LogbookMerge.touch(r.id, kind: .alert, deleted: true, now: at(2), state: &macState)
        let gone = LogbookMerge.outgoing(mac, state: macState, device: "Mac").map { r in var r = r; r.rev = 10; return r }
        XCTAssertTrue(LogbookMerge.apply(gone, to: &phone, state: &phoneState))
        XCTAssertTrue(phone.alerts.isEmpty)
    }

    func testAlertsAreUploadedOnFirstSync() {
        var c = LogbookContents()
        c.alerts = [AlertRecord(kind: .high, firedAt: at(0))]
        var state = LogbookSyncState()
        LogbookMerge.adopt(userID: "u", contents: c, state: &state)
        XCTAssertEqual(state.pending[c.alerts[0].id]?.kind, "alert")
    }
}
