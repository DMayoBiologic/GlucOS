import XCTest
@testable import GlucOSEngine

/// Two devices and a server, simulated, to check the logbook converges whatever order things
/// happen in. The server below follows the same rules as `logbook_push` / `logbook_pull`.
final class LogbookSyncTests: XCTestCase {

    /// The SQL functions' rules: keep the newer edit, a new change counter on every write.
    final class FakeServer {
        var rows: [UUID: LogbookRecord] = [:]
        var rev: Int64 = 0

        func push(_ records: [LogbookRecord]) {
            for r in records {
                if let old = rows[r.id], old.modified >= r.modified { continue }
                rev += 1
                var stored = r
                stored.rev = rev
                if r.deleted { stored.payload = nil }
                rows[r.id] = stored
            }
        }

        func pull(since: Int64) -> [LogbookRecord] {
            rows.values.filter { ($0.rev ?? 0) > since }.sorted { ($0.rev ?? 0) < ($1.rev ?? 0) }
        }
    }

    struct Device {
        var contents = LogbookContents()
        var state = LogbookSyncState()
        let name: String

        mutating func sync(_ server: FakeServer, user: String = "u1") {
            LogbookMerge.adopt(userID: user, contents: contents, state: &state)
            LogbookMerge.apply(server.pull(since: state.cursor), to: &contents, state: &state)
            let out = LogbookMerge.outgoing(contents, state: state, device: name)
            server.push(out)
            LogbookMerge.pushed(out, state: &state)
        }

        mutating func add(_ dose: InsulinDose, at t: Double) {
            LogbookMerge.insertSorted(dose, into: &contents.doses)
            LogbookMerge.touch(dose.id, kind: .dose, deleted: false, now: Date(timeIntervalSince1970: t), state: &state)
        }

        mutating func delete(_ id: UUID, at t: Double) {
            contents.doses.removeAll { $0.id == id }
            LogbookMerge.touch(id, kind: .dose, deleted: true, now: Date(timeIntervalSince1970: t), state: &state)
        }
    }

    func dose(_ units: Double, id: UUID = UUID(), at t: Double = 1_790_000_000) -> InsulinDose {
        InsulinDose(id: id, timestamp: Date(timeIntervalSince1970: t), units: units, kind: .rapid, name: "NovoRapid",
                    site: .abdomenLeft, viaPump: false, note: "")
    }

    func testExistingEntriesFromBothDevicesAreMergedOnFirstSync() {
        let server = FakeServer()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        mac.contents.doses = [dose(4, at: 100), dose(2, at: 300)]
        mac.contents.meals = [MealEntry(timestamp: Date(timeIntervalSince1970: 120), carbs: 45, food: "Toast")]
        mac.contents.presets = [LogPreset(name: "Breakfast", units: 4, carbs: 45), LogPreset(name: "Hypo", carbs: 15, tags: [.hypoTreatment])]
        phone.contents.doses = [dose(6, at: 200)]

        mac.sync(server)
        phone.sync(server)
        mac.sync(server)

        XCTAssertEqual(mac.contents, phone.contents)
        XCTAssertEqual(mac.contents.doses.map(\.units), [4, 6, 2], "kept in time order")
        XCTAssertEqual(phone.contents.presets.map(\.name), ["Breakfast", "Hypo"], "preset order carries over")
        XCTAssertTrue(mac.state.pending.isEmpty)
        XCTAssertTrue(phone.state.pending.isEmpty)
        XCTAssertEqual(server.rows.count, 6)
    }

    func testLaterEditWinsAndAnOfflineDeviceCatchesUp() {
        let server = FakeServer()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        let d = dose(4)
        mac.add(d, at: 1000)
        mac.sync(server)
        phone.sync(server)
        XCTAssertEqual(phone.contents.doses.first?.units, 4)

        // Both edit while apart; the phone's edit is later.
        var m = d; m.units = 5
        mac.add(m, at: 2000)
        var p = d; p.units = 6
        phone.add(p, at: 3000)
        mac.sync(server)
        phone.sync(server)
        mac.sync(server)
        XCTAssertEqual(mac.contents.doses.map(\.units), [6])
        XCTAssertEqual(phone.contents.doses.map(\.units), [6])

        // The other order: the earlier edit is pushed last, and still loses.
        var m2 = d; m2.units = 7
        mac.add(m2, at: 4000)
        var p2 = d; p2.units = 8
        phone.add(p2, at: 5000)
        phone.sync(server)
        mac.sync(server)
        XCTAssertEqual(mac.contents.doses.map(\.units), [8])
        XCTAssertTrue(mac.state.pending.isEmpty, "a losing local edit is dropped, not retried forever")
    }

    func testDeletesReachOtherDevicesAndAreNotUndoneByOldCopies() {
        let server = FakeServer()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        let d = dose(4)
        mac.add(d, at: 1000)
        mac.sync(server)
        phone.sync(server)

        phone.delete(d.id, at: 2000)
        phone.sync(server)
        mac.sync(server)
        XCTAssertTrue(mac.contents.doses.isEmpty)

        // A third device restored from an old backup still has it: its copy is older, so it goes.
        var old = Device(name: "Mac")
        old.contents.doses = [d]
        old.sync(server)
        XCTAssertTrue(old.contents.doses.isEmpty)
        XCTAssertEqual(server.rows[d.id]?.deleted, true)
    }

    func testEditAfterDeleteOnAnotherDeviceBringsItBack() {
        let server = FakeServer()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        let d = dose(4)
        mac.add(d, at: 1000)
        mac.sync(server)
        phone.sync(server)
        phone.delete(d.id, at: 2000)
        var edited = d; edited.units = 3
        mac.add(edited, at: 3000)
        phone.sync(server)
        mac.sync(server)
        phone.sync(server)
        XCTAssertEqual(phone.contents.doses.map(\.units), [3])
        XCTAssertEqual(mac.contents.doses.map(\.units), [3])
    }

    func testEditMadeWhilePushingStaysPending() {
        var device = Device(name: "Mac")
        let d = dose(4)
        device.add(d, at: 1000)
        let sent = LogbookMerge.outgoing(device.contents, state: device.state, device: "Mac")
        var again = d; again.units = 5
        device.add(again, at: 1000.5)
        LogbookMerge.pushed(sent, state: &device.state)
        XCTAssertNotNil(device.state.pending[d.id])
    }

    func testClockGoingBackwardsStillMovesEditsForward() {
        var state = LogbookSyncState()
        let id = UUID()
        LogbookMerge.touch(id, kind: .dose, deleted: false, now: Date(timeIntervalSince1970: 2000), state: &state)
        LogbookMerge.touch(id, kind: .dose, deleted: false, now: Date(timeIntervalSince1970: 1000), state: &state)
        XCTAssertGreaterThan(state.pending[id]!.modified, 2000)
    }

    func testUnknownKindsAndUnreadablePayloadsAreLeftAlone() {
        var contents = LogbookContents()
        var state = LogbookSyncState(userID: "u1")
        let records = [
            LogbookRecord(id: UUID(), kind: "glucoseNote", payload: .object(["text": .string("hi")]), deleted: false, modified: 10, rev: 1),
            LogbookRecord(id: UUID(), kind: "dose", payload: .object(["units": .string("lots")]), deleted: false, modified: 10, rev: 2),
        ]
        XCTAssertFalse(LogbookMerge.apply(records, to: &contents, state: &state))
        XCTAssertEqual(contents, LogbookContents())
        XCTAssertEqual(state.cursor, 2, "still moves past them")
    }

    func testPayloadsRoundTripAndMatchTheLogbookFile() throws {
        let c = ContextEvent(timestamp: Date(timeIntervalSince1970: 1_790_000_123.5), tags: [.exercise, .alcohol], note: "run")
        let json = try XCTUnwrap(LogbookMerge.json(c))
        XCTAssertEqual(json["timestamp"]?.number, 1_790_000_123.5, "dates as Unix seconds, like logbook.json")
        XCTAssertEqual(LogbookMerge.decode(ContextEvent.self, from: json), c)

        let record = LogbookRecord(id: c.id, kind: "context", payload: json, deleted: false, modified: 5, device: "Mac")
        let wire = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(LogbookRecord.self, from: wire)
        XCTAssertEqual(back, record)
        let text = String(decoding: wire, as: UTF8.self)
        XCTAssertFalse(text.contains("\"rev\""), "pushes don't send a change counter")
    }

    func testSwitchingAccountStartsOverAndKeepsLocalEdits() {
        var state = LogbookSyncState(userID: "u1", cursor: 40, lastFullPull: 1, pending: [:])
        let contents = LogbookContents(doses: [dose(4)])
        let edited = UUID()
        LogbookMerge.touch(edited, kind: .meal, deleted: false, now: Date(timeIntervalSince1970: 1000), state: &state)
        XCTAssertFalse(LogbookMerge.adopt(userID: "u1", contents: contents, state: &state))
        XCTAssertTrue(LogbookMerge.adopt(userID: "u2", contents: contents, state: &state))
        XCTAssertEqual(state.cursor, 0)
        XCTAssertNil(state.lastFullPull)
        XCTAssertEqual(state.pending[contents.doses[0].id]?.modified, LogbookMerge.adoptedModified)
        XCTAssertEqual(state.pending[edited]?.modified, 1000)
    }
}
