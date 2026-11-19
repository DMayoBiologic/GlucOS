import XCTest
@testable import GlucOSEngine

/// Alert History rows coming and going (docs/AlertHistory.md, "Rows coming and going").
final class AlertHistoryRowMotionTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    /// Thu 19 Nov 2026, 3 pm in Perth.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15))!
    }

    private func item(_ minutes: Double, kind: AlertNotice.Kind = .low, id: UUID = UUID()) -> AlertHistory.Item {
        AlertHistory.Item(id: id, kind: kind, firedAt: now.addingTimeInterval(minutes * 60), readingMgdl: 60,
                          outcome: .noResponse, respondedAt: nil)
    }

    // MARK: Keys

    func testFirstListUsesEachItemsOwnID() {
        let a = item(-10), b = item(-90)
        let keys = AlertHistoryRowMotion.keys(for: [a, b], previous: [], previousKeys: [:])
        XCTAssertEqual(keys, [a.id: a.id, b.id: b.id])
    }

    func testKeptItemKeepsItsKey() {
        let a = item(-10)
        let first = AlertHistoryRowMotion.keys(for: [a], previous: [], previousKeys: [:])
        let fresh = item(-1)
        let next = AlertHistoryRowMotion.keys(for: [fresh, a], previous: [a], previousKeys: first)
        XCTAssertEqual(next[a.id], a.id)
        XCTAssertEqual(next[fresh.id], fresh.id, "a new alert is a new row")
    }

    func testOtherDevicesEarlierCopyKeepsTheRow() {
        let mac = item(-10)
        let first = AlertHistoryRowMotion.keys(for: [mac], previous: [], previousKeys: [:])
        // The iPhone's copy fired 40 s earlier syncs in: the merged item now carries its id.
        let merged = AlertHistory.Item(id: UUID(), kind: .low, firedAt: mac.firedAt.addingTimeInterval(-40),
                                       readingMgdl: 60, outcome: .noResponse, respondedAt: nil)
        let next = AlertHistoryRowMotion.keys(for: [merged], previous: [mac], previousKeys: first)
        XCTAssertEqual(next[merged.id], mac.id, "same alert, same row: nothing slides")
        // And again on the swap after that.
        let again = AlertHistory.Item(id: UUID(), kind: .low, firedAt: merged.firedAt.addingTimeInterval(-20),
                                      readingMgdl: 60, outcome: .treating, respondedAt: now)
        let third = AlertHistoryRowMotion.keys(for: [again], previous: [merged], previousKeys: next)
        XCTAssertEqual(third[again.id], mac.id)
    }

    func testDifferentKindOrTooFarApartIsANewRow() {
        let low = item(-10)
        let first = AlertHistoryRowMotion.keys(for: [low], previous: [], previousKeys: [:])
        let high = item(-10, kind: .high)
        XCTAssertEqual(AlertHistoryRowMotion.keys(for: [high], previous: [low], previousKeys: first)[high.id], high.id)
        let later = item(-10 + AlertHistory.sameAlert / 60 + 1)
        XCTAssertEqual(AlertHistoryRowMotion.keys(for: [later], previous: [low], previousKeys: first)[later.id], later.id)
    }

    func testOneDepartedRowIsTakenOverOnce() {
        let old = item(-10)
        let first = AlertHistoryRowMotion.keys(for: [old], previous: [], previousKeys: [:])
        let a = item(-11), b = item(-9)
        let keys = AlertHistoryRowMotion.keys(for: [b, a], previous: [old], previousKeys: first)
        XCTAssertEqual(Set(keys.values).count, 2, "no two rows share a key")
        XCTAssertTrue(keys.values.contains(old.id))
    }

    func testKeysNeverCollideWithAKeptRow() {
        // Row x was drawn under y's id (it took over y's row); a new item with id y turns up.
        let yID = UUID()
        let x = item(-30)
        let y = item(-5, id: yID)
        let keys = AlertHistoryRowMotion.keys(for: [y, x], previous: [x], previousKeys: [x.id: yID])
        XCTAssertEqual(keys[x.id], yID)
        XCTAssertNotEqual(keys[y.id], yID)
        XCTAssertEqual(Set(keys.values).count, 2)
    }

    // MARK: Ageing out

    func testOldestDayLeavesAtMidnight() {
        let start = AlertHistory.start(now: now, calendar: calendar)
        let oldest = AlertHistory.Item(id: UUID(), kind: .low, firedAt: start.addingTimeInterval(3600),
                                       readingMgdl: 60, outcome: .noResponse, respondedAt: nil)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        XCTAssertEqual(AlertHistoryRowMotion.nextAgeOut([item(-5), oldest], now: now, calendar: calendar), midnight)
    }

    func testNothingOnTheOldestDayMeansNoWake() {
        XCTAssertNil(AlertHistoryRowMotion.nextAgeOut([item(-5), item(-24 * 60)], now: now, calendar: calendar))
        XCTAssertNil(AlertHistoryRowMotion.nextAgeOut([], now: now, calendar: calendar))
    }

    func testTimings() {
        XCTAssertLessThanOrEqual(AlertHistoryRowMotion.reduceMotionFade, 0.3)
        XCTAssertLessThan(AlertHistoryRowMotion.removalScale, 1)
        XCTAssertGreaterThan(AlertHistoryRowMotion.removalScale, 0.9)
    }
}
