import XCTest
@testable import GlucOSEngine

/// Each Insights screen's layout syncing as a logbook record (docs/InsightsLayout.md).
final class InsightsLayoutSyncTests: XCTestCase {
    typealias Server = LogbookSyncTests.FakeServer
    typealias Device = LogbookSyncTests.Device

    private func edit(_ device: inout Device, _ screen: InsightsScreen, at t: Double,
                      _ change: (inout InsightsLayout) -> Void) {
        var layout = device.contents.insightsLayouts[screen] ?? .standard
        change(&layout)
        device.contents.insightsLayouts[screen] = layout.isStandard ? nil : layout
        LogbookMerge.touch(screen.recordID, kind: .insightsLayout, deleted: layout.isStandard,
                           now: Date(timeIntervalSince1970: t), state: &device.state)
    }

    func testRecordIDsAreFixedAndDistinct() {
        XCTAssertEqual(InsightsScreen.phone.recordID.uuidString, "1A5E7C0D-0000-4C0B-8A1E-000000000001")
        XCTAssertEqual(InsightsScreen.mac.recordID.uuidString, "1A5E7C0D-0000-4C0B-8A1E-000000000002")
        XCTAssertNotEqual(InsightsScreen.phone.recordID, BolusSettings.recordID)
        for screen in InsightsScreen.allCases { XCTAssertEqual(InsightsScreen(recordID: screen.recordID), screen) }
        XCTAssertNil(InsightsScreen(recordID: UUID()))
        XCTAssertEqual(InsightsScreen.phone.defaults, InsightsCard.phoneDefault)
        XCTAssertEqual(InsightsScreen.mac.defaults, InsightsCard.macDefault)
        XCTAssertEqual(InsightsScreen.phone.legacyKey, InsightsLayout.phoneKey)
        XCTAssertEqual(InsightsScreen.mac.legacyKey, InsightsLayout.macKey)
    }

    func testAReorderAndAHiddenCardReachTheOtherDevice() {
        let server = Server()
        var first = Device(name: "iPhone"), second = Device(name: "iPhone")
        let phone = InsightsCard.phoneDefault
        edit(&first, .phone, at: 1_790_000_000) {
            $0.move(.lows, by: -1, defaults: phone)
            $0.hide(.mornings, defaults: phone)
        }
        first.sync(server)
        second.sync(server)

        let layout = second.contents.insightsLayouts[.phone]
        XCTAssertEqual(layout, first.contents.insightsLayouts[.phone])
        XCTAssertEqual(layout?.hiddenCards(phone), [.mornings])
        XCTAssertEqual(layout?.visible(phone).firstIndex(of: .lows), 2)
        XCTAssertNil(second.contents.insightsLayouts[.mac], "the Mac screen keeps its own layout")
    }

    func testHiddenCardRestoredOnOneDeviceComesBackOnTheOther() {
        let server = Server()
        var mac = Device(name: "Mac"), other = Device(name: "Mac")
        let defaults = InsightsCard.macDefault
        edit(&mac, .mac, at: 1_790_000_000) {
            $0.move(.forecastAccuracy, by: -1, defaults: defaults)
            $0.hide(.highs, defaults: defaults)
        }
        mac.sync(server)
        other.sync(server)
        edit(&other, .mac, at: 1_790_000_100) { $0.restore(.highs, defaults: defaults) }
        other.sync(server)
        mac.sync(server)

        XCTAssertEqual(mac.contents.insightsLayouts[.mac]?.hiddenCards(defaults), [])
        XCTAssertEqual(mac.contents.insightsLayouts[.mac]?.visible(defaults).firstIndex(of: .highs), 2,
                       "back in the slot it was hidden from")
        XCTAssertEqual(mac.contents, other.contents)
    }

    func testRestoreStandardOrderIsADeleteEverywhere() {
        let server = Server()
        var a = Device(name: "iPhone"), b = Device(name: "iPhone")
        edit(&a, .phone, at: 1_790_000_000) { $0.hide(.glance, defaults: InsightsCard.phoneDefault) }
        a.sync(server)
        b.sync(server)
        XCTAssertNotNil(b.contents.insightsLayouts[.phone])

        edit(&b, .phone, at: 1_790_000_100) { $0 = .standard }
        let out = LogbookMerge.outgoing(b.contents, state: b.state, device: "iPhone")
        XCTAssertEqual(out.map(\.deleted), [true])
        b.sync(server)
        a.sync(server)
        XCTAssertNil(a.contents.insightsLayouts[.phone])
        XCTAssertEqual(server.rows[InsightsScreen.phone.recordID]?.deleted, true)
    }

    func testLaterEditWins() {
        let server = Server()
        var a = Device(name: "iPhone"), b = Device(name: "iPhone")
        let phone = InsightsCard.phoneDefault
        edit(&a, .phone, at: 1_790_000_000) { $0.hide(.days, defaults: phone) }
        edit(&b, .phone, at: 1_790_000_050) { $0.hide(.overnight, defaults: phone) }
        a.sync(server)
        b.sync(server)
        a.sync(server)
        XCTAssertEqual(a.contents.insightsLayouts[.phone]?.hiddenCards(phone), [.overnight])
        XCTAssertEqual(a.contents, b.contents)
    }

    func testALayoutMovedFromAnOlderBuildLosesToOneAlreadySynced() {
        let server = Server()
        var synced = Device(name: "iPhone"), upgraded = Device(name: "iPhone")
        let phone = InsightsCard.phoneDefault
        edit(&synced, .phone, at: 1_790_000_000) { $0.hide(.mornings, defaults: phone) }
        synced.sync(server)

        // What LogbookStore does with a layout found in UserDefaults: older than anything synced.
        var legacy = InsightsLayout.standard
        legacy.hide(.forecastAccuracy, defaults: phone)
        upgraded.contents.insightsLayouts[.phone] = legacy
        upgraded.state = LogbookSyncState(userID: "u1")
        upgraded.state.pending[InsightsScreen.phone.recordID] = LogbookPendingChange(
            kind: LogbookRecordKind.insightsLayout.rawValue, modified: LogbookMerge.adoptedModified, deleted: false)
        upgraded.sync(server)

        XCTAssertEqual(upgraded.contents.insightsLayouts[.phone]?.hiddenCards(phone), [.mornings])
    }

    func testPayloadCarriesTheScreenAndSortedHiddenCards() throws {
        var contents = LogbookContents()
        contents.insightsLayouts[.mac] = InsightsLayout(order: ["lows", "weekInReview"], hidden: ["tags", "highs"])
        let payload = try XCTUnwrap(LogbookMerge.payload(for: InsightsScreen.mac.recordID, kind: "insightsLayout", in: contents))
        let synced = try XCTUnwrap(LogbookMerge.decode(SyncedInsightsLayout.self, from: payload))
        XCTAssertEqual(synced.screen, "mac")
        XCTAssertEqual(synced.hidden, ["highs", "tags"])
        XCTAssertEqual(synced.order, ["lows", "weekInReview"])
        XCTAssertNil(LogbookMerge.payload(for: InsightsScreen.phone.recordID, kind: "insightsLayout", in: contents))
        XCTAssertNil(LogbookMerge.payload(for: UUID(), kind: "insightsLayout", in: contents))
    }

    func testAScreenThisBuildDoesNotKnowIsLeftAlone() {
        var contents = LogbookContents()
        var state = LogbookSyncState()
        let record = LogbookRecord(id: UUID(), kind: "insightsLayout",
                                   payload: .object(["screen": .string("watch"), "order": .array([]),
                                                     "hidden": .array([.string("lows")])]),
                                   deleted: false, modified: 1_790_000_000, device: "Watch", rev: 1)
        XCTAssertFalse(LogbookMerge.apply([record], to: &contents, state: &state))
        XCTAssertTrue(contents.insightsLayouts.isEmpty)
    }

    func testUnknownCardNamesSurviveTheSync() {
        let server = Server()
        var a = Device(name: "Mac"), b = Device(name: "Mac")
        a.contents.insightsLayouts[.mac] = InsightsLayout(order: ["lows", "someFutureCard", "highs"], hidden: ["someFutureCard"])
        LogbookMerge.touch(InsightsScreen.mac.recordID, kind: .insightsLayout, deleted: false,
                           now: Date(timeIntervalSince1970: 1_790_000_000), state: &a.state)
        a.sync(server)
        b.sync(server)
        XCTAssertEqual(b.contents.insightsLayouts[.mac]?.order, ["lows", "someFutureCard", "highs"])
        XCTAssertTrue(b.contents.insightsLayouts[.mac]?.hidden.contains("someFutureCard") == true)
    }
}
