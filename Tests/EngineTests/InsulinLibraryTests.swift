import XCTest
@testable import GlucOSEngine

final class InsulinLibraryTests: XCTestCase {

    private func dose(_ name: String, _ kind: InsulinKind = .rapid, at t: Double, pump: Bool = false) -> InsulinDose {
        InsulinDose(timestamp: Date(timeIntervalSince1970: t), units: 4, kind: kind, name: name, viaPump: pump)
    }

    func testSpellingsOfTheSameNameMatch() {
        XCTAssertEqual(InsulinLibrary.key("NovoRapid"), "novorapid")
        XCTAssertEqual(InsulinLibrary.key(" Novo-Rapid "), "novorapid")
        let library = [SavedInsulin(name: "NovoRapid", kind: .rapid), SavedInsulin(name: "Optisulin", kind: .long)]
        XCTAssertEqual(InsulinLibrary.match("novorapid", in: library)?.name, "NovoRapid")
        XCTAssertEqual(InsulinLibrary.match("Novo Rapid", in: library)?.name, "NovoRapid")
        XCTAssertNil(InsulinLibrary.match("Fiasp", in: library))
        XCTAssertNil(InsulinLibrary.match("  ", in: library))
    }

    func testIDsAreTheSameOnEveryDeviceForTheSameName() {
        XCTAssertEqual(SavedInsulin(name: "NovoRapid", kind: .rapid).id, SavedInsulin(name: "novorapid ", kind: .rapid).id)
        XCTAssertNotEqual(SavedInsulin(name: "NovoRapid", kind: .rapid).id, SavedInsulin(name: "Fiasp", kind: .ultraRapid).id)
        let id = InsulinLibrary.stableID(for: "NovoRapid")
        XCTAssertEqual(id.uuidString.dropFirst(14).first, "8", "version 8 UUID")
        XCTAssertEqual(UUID(uuidString: id.uuidString), id)
    }

    func testPreferredIsTheLastMealtimeInsulinLogged() {
        let library = [SavedInsulin(name: "Optisulin", kind: .long),
                       SavedInsulin(name: "NovoRapid", kind: .rapid),
                       SavedInsulin(name: "Fiasp", kind: .ultraRapid)]
        XCTAssertEqual(InsulinLibrary.preferred(in: library, doses: [], viaPump: false)?.name, "NovoRapid",
                       "first mealtime insulin when nothing's logged")
        let doses = [dose("fiasp", .ultraRapid, at: 100), dose("Optisulin", .long, at: 200)]
        XCTAssertEqual(InsulinLibrary.preferred(in: library, doses: doses, viaPump: false)?.name, "Fiasp",
                       "a long-acting dose since doesn't change the mealtime pick")
        XCTAssertNil(InsulinLibrary.preferred(in: [SavedInsulin(name: "Optisulin", kind: .long)], doses: [], viaPump: true),
                     "a pump never starts on long-acting insulin")
        XCTAssertEqual(InsulinLibrary.preferred(in: [SavedInsulin(name: "Optisulin", kind: .long)], doses: [], viaPump: false)?.name,
                       "Optisulin")
    }

    func testDiscoveredFromTheLogbookUsesTheCommonestSpelling() {
        let doses = [dose("Novorapid", at: 1), dose("NovoRapid", at: 2), dose("NovoRapid", at: 3),
                     dose("Optisulin", .long, at: 4), dose("", at: 5)]
        let found = InsulinLibrary.discovered(from: doses, excluding: [])
        XCTAssertEqual(found.map(\.name), ["NovoRapid", "Optisulin"])
        XCTAssertEqual(found.map(\.kind), [.rapid, .long])

        let fromSettings = InsulinLibrary.discovered(from: [], named: [("Lantus", .long), ("Humalog", .rapid)], excluding: [])
        XCTAssertEqual(fromSettings.map(\.name), ["Humalog", "Lantus"], "mealtime insulin first")

        let saved = [SavedInsulin(name: "NovoRapid", kind: .rapid)]
        XCTAssertEqual(InsulinLibrary.discovered(from: doses, excluding: saved).map(\.name), ["Optisulin"])
    }

    func testRespellingsOnlyTouchNamesThatMatch() {
        let library = [SavedInsulin(name: "NovoRapid", kind: .rapid)]
        let a = dose("Novorapid", at: 1), b = dose("NovoRapid", at: 2), c = dose("Fiasp", at: 3)
        XCTAssertEqual(InsulinLibrary.respellings([a, b, c], library: library), [a.id: "NovoRapid"])
        let p = LogPreset(name: "Breakfast", units: 4, kind: .rapid, insulinName: "novo rapid")
        XCTAssertEqual(InsulinLibrary.respellings([p], library: library), [p.id: "NovoRapid"])
    }

    func testDoseStep() {
        XCTAssertEqual(InsulinLibrary.step(for: nil, viaPump: false), 1)
        XCTAssertEqual(InsulinLibrary.step(for: nil, viaPump: true), 0.5)
        XCTAssertEqual(InsulinLibrary.step(for: SavedInsulin(name: "NovoRapid", kind: .rapid, doseStep: 0.5), viaPump: false), 0.5)
    }

    func testInsulinsSyncWithTheirOrder() throws {
        var mac = LogbookContents(), phone = LogbookContents()
        var macState = LogbookSyncState(userID: "u1"), phoneState = LogbookSyncState(userID: "u1")
        mac.insulins = [SavedInsulin(name: "NovoRapid", kind: .rapid, doseStep: 0.5), SavedInsulin(name: "Optisulin", kind: .long)]
        for i in mac.insulins {
            LogbookMerge.touch(i.id, kind: .insulin, deleted: false, now: Date(timeIntervalSince1970: 1000), state: &macState)
        }
        var rev: Int64 = 0
        func served(_ out: [LogbookRecord]) -> [LogbookRecord] {
            out.map { r in rev += 1; var s = r; s.rev = rev; return s }
        }
        let first = LogbookMerge.outgoing(mac, state: macState, device: "Mac")
        XCTAssertEqual(first.map(\.kind), ["insulin", "insulin"])
        LogbookMerge.apply(served(first), to: &phone, state: &phoneState)
        XCTAssertEqual(phone.insulins, mac.insulins)

        // Reordered on the Mac.
        mac.insulins.reverse()
        for i in mac.insulins {
            LogbookMerge.touch(i.id, kind: .insulin, deleted: false, now: Date(timeIntervalSince1970: 2000), state: &macState)
        }
        LogbookMerge.apply(served(LogbookMerge.outgoing(mac, state: macState, device: "Mac")), to: &phone, state: &phoneState)
        XCTAssertEqual(phone.insulins.map(\.name), ["Optisulin", "NovoRapid"])

        // Deleted on the Mac.
        let gone = mac.insulins.removeFirst()
        LogbookMerge.touch(gone.id, kind: .insulin, deleted: true, now: Date(timeIntervalSince1970: 3000), state: &macState)
        LogbookMerge.apply(served(LogbookMerge.outgoing(mac, state: macState, device: "Mac")), to: &phone, state: &phoneState)
        XCTAssertEqual(phone.insulins.map(\.name), ["NovoRapid"])
        XCTAssertEqual(phone.allIDs.map { $0.1 }, [.insulin])
    }

    func testFirstListFromOneDeviceLosesToADeleteFromAnother() {
        // Discovered insulins go up as `adoptedModified`, so a delete already on the server wins.
        var contents = LogbookContents(insulins: [SavedInsulin(name: "NovoRapid", kind: .rapid)])
        var state = LogbookSyncState(userID: "u1")
        let id = contents.insulins[0].id
        state.pending[id] = LogbookPendingChange(kind: "insulin", modified: LogbookMerge.adoptedModified, deleted: false)
        let tombstone = LogbookRecord(id: id, kind: "insulin", payload: nil, deleted: true, modified: 500, rev: 9)
        XCTAssertTrue(LogbookMerge.apply([tombstone], to: &contents, state: &state))
        XCTAssertTrue(contents.insulins.isEmpty)
        XCTAssertNil(state.pending[id])
    }

    func testTheSameInsulinUnderTwoIDsEndsUpOnceEverywhere() {
        let a = SavedInsulin(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Fiasp", kind: .ultraRapid)
        let b = SavedInsulin(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "fiasp", kind: .ultraRapid)
        func record(_ i: SavedInsulin, rev: Int64) -> LogbookRecord {
            LogbookRecord(id: i.id, kind: "insulin", payload: LogbookMerge.json(i), deleted: false, modified: 10, rev: rev)
        }
        var first = LogbookContents(insulins: [a]), second = LogbookContents(insulins: [b])
        var s1 = LogbookSyncState(userID: "u1"), s2 = LogbookSyncState(userID: "u1")
        LogbookMerge.apply([record(b, rev: 1)], to: &first, state: &s1)
        LogbookMerge.apply([record(a, rev: 2)], to: &second, state: &s2)
        XCTAssertEqual(first.insulins, [a])
        XCTAssertEqual(second.insulins, [a])
    }

    // MARK: Site rotation

    func testSuggestsTheSiteUsedLongestAgoInAreasInUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(SiteRotation.suggestion(lastUse: [:]))
        let last: [InjectionSite: Date] = [
            .abdomenLeft: now.addingTimeInterval(-3600),
            .abdomenRight: now.addingTimeInterval(-86_400),
            .thighLeft: now.addingTimeInterval(-5 * 86_400),
        ]
        XCTAssertEqual(SiteRotation.suggestion(lastUse: last), .thighRight, "never-used sites in a used area come first")
        var all = last
        all[.thighRight] = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(SiteRotation.suggestion(lastUse: all), .thighLeft)
    }

    func testFlagsASiteUsedInTheLastFewDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last: [InjectionSite: Date] = [.abdomenLeft: now.addingTimeInterval(-86_400), .armLeft: now.addingTimeInterval(-4 * 86_400)]
        XCTAssertNotNil(SiteRotation.recentUse(of: .abdomenLeft, lastUse: last, now: now))
        XCTAssertNil(SiteRotation.recentUse(of: .armLeft, lastUse: last, now: now))
        XCTAssertNil(SiteRotation.recentUse(of: .thighLeft, lastUse: last, now: now))
        XCTAssertNil(SiteRotation.recentUse(of: nil, lastUse: last, now: now))
    }
}
