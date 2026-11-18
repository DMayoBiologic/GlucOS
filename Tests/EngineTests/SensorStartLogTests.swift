import XCTest
@testable import GlucOSEngine

/// "Sensor started" in the Logbook (docs/SensorStartLog.md): logged once per sensor, at its start,
/// with the same id on every device, and a delete made anywhere always wins.
final class SensorStartLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func sensor(_ serial: String = "0M0001ABCDE", startedAgo: TimeInterval = 3600, days: Int = 15) -> SensorInfo {
        SensorInfo(serial: serial, activated: now.addingTimeInterval(-startedAgo), lifetimeDays: days)
    }

    private func decide(_ s: SensorInfo?, enabled: Bool = true, follower: Bool = false, handled: Set<UUID> = [],
                        exists: Set<UUID> = [], loggedStarts: [Date] = []) -> SensorStartLog.Decision {
        SensorStartLog.decide(sensor: s, enabled: enabled, follower: follower, handled: handled,
                              exists: { exists.contains($0) }, loggedStarts: loggedStarts, now: now)
    }

    // MARK: Identity

    func testKeyIsTheSerialOrTheStartTime() {
        XCTAssertEqual(SensorStartLog.key(for: sensor(" 0m0001abcde ")), "sn:0M0001ABCDE")
        let noSerial = sensor("?")
        XCTAssertEqual(SensorStartLog.key(for: noSerial), "at:\(Int(noSerial.activated.timeIntervalSince1970))")
        XCTAssertEqual(SensorStartLog.key(for: sensor("")), SensorStartLog.key(for: sensor("?")))
    }

    func testIDIsTheSameOnEveryDeviceAndDiffersBetweenSensors() {
        let a = SensorStartLog.id(for: sensor())
        // The same sensor reported a moment later (another fetch, the other device) keeps its id.
        XCTAssertEqual(a, SensorStartLog.id(for: sensor(startedAgo: 3000)))
        XCTAssertNotEqual(a, SensorStartLog.id(for: sensor("0M0001ABCDF")))
        // Pinned, so a change to the hashing can't split one sensor into two events across versions.
        XCTAssertEqual(SensorStartLog.id(forKey: "sn:0M0001ABCDE"), SensorStartLog.id(forKey: "sn:0M0001ABCDE"))
        XCTAssertEqual(a.uuidString.prefix(8), "5E450557")
    }

    func testSensorStartIDsAreRecognisedWithoutAPayload() {
        XCTAssertTrue(SensorStartLog.isSensorStartID(SensorStartLog.id(for: sensor())))
        XCTAssertTrue(SensorStartLog.isSensorStartID(SensorStartLog.id(for: sensor("?"))))
        XCTAssertFalse(SensorStartLog.isSensorStartID(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!))
    }

    func testEventIsSensorStartedAtTheStart() {
        let s = sensor(startedAgo: 7200)
        let e = SensorStartLog.event(for: s)
        XCTAssertEqual(e.timestamp, s.activated)
        XCTAssertEqual(e.tags, [.sensorStarted])
        XCTAssertTrue(e.isSensorStart)
        XCTAssertEqual(LogEntry.context(e).shortTitle, "Sensor started")
        XCTAssertTrue(LogEntry.context(e).isSensorStart)
        XCTAssertEqual(SensorStartLog.modified(for: s), s.activated.timeIntervalSince1970)
    }

    // MARK: Deciding

    func testANewSensorIsLoggedWithUndo() {
        let s = sensor(startedAgo: 70 * 60)
        XCTAssertEqual(decide(s), .log(SensorStartLog.event(for: s), offersUndo: true))
    }

    func testAnOlderStartIsLoggedQuietly() {
        // Already being worn when GlucOS updated, or the device was off for the change.
        let s = sensor(startedAgo: 2 * 86_400)
        XCTAssertEqual(decide(s), .log(SensorStartLog.event(for: s), offersUndo: false))
        let edge = sensor(startedAgo: SensorStartLog.undoWindow)
        XCTAssertEqual(decide(edge), .log(SensorStartLog.event(for: edge), offersUndo: true))
    }

    func testNothingForFollowersTheSwitchOffOrNoSensor() {
        XCTAssertEqual(decide(sensor(), follower: true), .none)
        XCTAssertEqual(decide(sensor(), enabled: false), .none)
        XCTAssertEqual(decide(nil), .none)
    }

    func testNothingForAStartInTheFutureOrPastTheSensorsLife() {
        XCTAssertEqual(decide(sensor(startedAgo: -5 * 60)), .none, "clock problem")
        let skew = sensor(startedAgo: -30)
        XCTAssertEqual(decide(skew), .log(SensorStartLog.event(for: skew), offersUndo: true), "a little skew is fine")
        XCTAssertEqual(decide(sensor(startedAgo: 16 * 86_400)), .none, "an old sensor")
        XCTAssertEqual(decide(sensor(startedAgo: 15 * 86_400 + 60)), .none)
    }

    func testAHandledSensorIsNeverLoggedAgain() {
        let s = sensor()
        let id = SensorStartLog.id(for: s)
        // Logged before and deleted since: handled, gone from the logbook, stays gone.
        XCTAssertEqual(decide(s, handled: [id]), .none)
        // Synced in from the other device: remembered, not logged twice.
        XCTAssertEqual(decide(s, exists: [id]), .remember(id))
    }

    func testTheSameStartSeenAnotherWayIsNotLoggedTwice() {
        // An NFC scan's serial needn't read like LibreLinkUp's: same start, different id.
        let s = sensor("3MH00ABCDE")
        XCTAssertEqual(decide(s, loggedStarts: [s.activated.addingTimeInterval(120)]), .remember(SensorStartLog.id(for: s)))
        let far = s.activated.addingTimeInterval(SensorStartLog.sameStartTolerance + 60)
        XCTAssertEqual(decide(s, loggedStarts: [far]), .log(SensorStartLog.event(for: s), offersUndo: true))
    }

    func testRememberingKeepsTheLatestFew() {
        var list: [UUID] = []
        for i in 0..<50 { list = SensorStartLog.remembering(SensorStartLog.id(forKey: "sn:\(i)"), in: list) }
        XCTAssertEqual(list.count, SensorStartLog.rememberedLimit)
        XCTAssertEqual(list.last, SensorStartLog.id(forKey: "sn:49"))
        let again = SensorStartLog.remembering(SensorStartLog.id(forKey: "sn:20"), in: list)
        XCTAssertEqual(again.count, list.count)
        XCTAssertEqual(again.last, SensorStartLog.id(forKey: "sn:20"))
    }

    // MARK: Sync

    private final class Server {
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

    private struct Device {
        var contents = LogbookContents()
        var state = LogbookSyncState()
        let name: String

        mutating func sync(_ server: Server, fullPull: Bool = false) {
            LogbookMerge.adopt(userID: "u1", contents: contents, state: &state)
            LogbookMerge.apply(server.pull(since: fullPull ? 0 : state.cursor), to: &contents, state: &state)
            let out = LogbookMerge.outgoing(contents, state: state, device: name)
            server.push(out)
            LogbookMerge.pushed(out, state: &state)
        }

        /// What `LogbookStore.logSensorStart` does.
        mutating func logStart(_ s: SensorInfo) {
            let e = SensorStartLog.event(for: s)
            LogbookMerge.insertSorted(e, into: &contents.contexts)
            state.pending[e.id] = LogbookPendingChange(kind: LogbookRecordKind.context.rawValue,
                                                       modified: SensorStartLog.modified(for: s), deleted: false)
        }

        mutating func delete(_ id: UUID, at t: Date) {
            contents.contexts.removeAll { $0.id == id }
            LogbookMerge.touch(id, kind: .context, deleted: true, now: t, state: &state)
        }
    }

    func testBothDevicesLoggingTheSameSensorKeepOneEvent() {
        let server = Server()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        let s = sensor()
        mac.logStart(s)
        phone.logStart(s)
        mac.sync(server)
        phone.sync(server)
        mac.sync(server)
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(mac.contents.contexts.map(\.id), [SensorStartLog.id(for: s)])
        XCTAssertEqual(phone.contents.contexts.map(\.id), [SensorStartLog.id(for: s)])
    }

    func testADeleteAnywhereWinsOverALateLog() {
        let server = Server()
        var mac = Device(name: "Mac"), phone = Device(name: "iPhone")
        let s = sensor()
        let id = SensorStartLog.id(for: s)
        mac.logStart(s)
        mac.sync(server)
        // Undo on the Mac.
        mac.delete(id, at: now)
        mac.sync(server)
        // The iPhone sees the sensor only now: its log is older than the delete, so the server
        // keeps the delete, and the iPhone's copy goes on its next full pull.
        phone.logStart(s)
        phone.sync(server)
        XCTAssertTrue(server.rows[id]?.deleted ?? false)
        phone.sync(server, fullPull: true)
        XCTAssertTrue(phone.contents.contexts.isEmpty)
        XCTAssertTrue(mac.contents.contexts.isEmpty)
    }

    func testTheEventRoundTripsThroughSync() throws {
        let e = SensorStartLog.event(for: sensor())
        let json = try XCTUnwrap(LogbookMerge.json(e))
        XCTAssertEqual(LogbookMerge.decode(ContextEvent.self, from: json), e)
    }

    // MARK: Around the app

    func testSensorStartedOnlyMarksATime() {
        let tag = ContextTag.sensorStarted
        XCTAssertFalse(tag.affectsResponses)
        XCTAssertFalse(tag.isComparable)
        XCTAssertFalse(tag.isMoment)
        XCTAssertTrue(tag.isAutomatic)
        XCTAssertEqual(tag.reach, 0)
        XCTAssertFalse(ContextTag.allCases.filter { $0 != tag }.contains(where: \.isAutomatic))
    }

    func testUndoToastSaysWhatGlucOSLogged() {
        let entry = LogEntry.context(SensorStartLog.event(for: sensor()))
        XCTAssertEqual(entry.kindNoun, "sensor start")
        let add = LogbookAddUndo(entry: entry, addedAt: 1)
        XCTAssertTrue(add.isSensorStart)
        XCTAssertEqual(add.title, "Logged sensor start")
        let offer = LogbookUndoOffer.added(add)
        XCTAssertEqual(offer.hint, "Takes the sensor start off again, on all your devices")
        XCTAssertEqual(offer.symbol, ContextTag.sensorStarted.systemImage)
        XCTAssertTrue(offer.showsOutsideLogbook)
        // A note added from Alert History keeps its own words and stays where it was added.
        let note = LogbookAddUndo(entry: .context(ContextEvent(timestamp: now, tags: [], note: "run")), addedAt: 1)
        XCTAssertEqual(note.title, "Added note")
        XCTAssertEqual(LogbookUndoOffer.added(note).hint, "Takes the note off again, on all your devices")
        XCTAssertFalse(LogbookUndoOffer.added(note).showsOutsideLogbook)
    }

    func testChartMarkerOffersEditOnly() {
        XCTAssertEqual(MarkerActions.actions(for: .sensor), [.edit])
        XCTAssertEqual(MarkerPop.announcement(added: [.sensor], removed: []), "Sensor start added to chart")
    }

    func testLastLoggedSkipsSensorStarts() {
        let start = LogEntry.context(SensorStartLog.event(for: sensor(startedAgo: 600)))
        let meal = LogEntry.meal(MealEntry(timestamp: now.addingTimeInterval(-3600), carbs: 30))
        XCTAssertEqual(LastLogged.latest([start, meal], now: now)?.kind, .meal)
        XCTAssertNil(LastLogged.latest([start], now: now))
    }

    func testExportNamesIt() {
        let row = LogbookExport.row(.context(SensorStartLog.event(for: sensor())))
        XCTAssertEqual(row.type, "Sensor started")
        XCTAssertEqual(row.details, "")
    }
}
