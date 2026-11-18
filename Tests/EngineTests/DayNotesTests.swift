import XCTest
@testable import GlucOSEngine

/// Day notes (docs/LogbookSearch.md "Day notes"): their keys and record ids, how they sync as
/// logbook records, and how Logbook search reads them.
final class DayNotesTests: XCTestCase {
    typealias Server = LogbookSyncTests.FakeServer
    typealias Device = LogbookSyncTests.Device

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        c.locale = Locale(identifier: "en_AU")
        return c
    }()

    private func day(_ d: Int, hour: Int = 12, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
    }

    /// Writes (or with "" removes) a note the way `LogbookStore.saveDayNote` does.
    private func write(_ device: inout Device, _ key: String, _ text: String, at t: Double) {
        let kept = DayNotes.cleaned(text)
        device.contents.dayNotes[key] = kept.isEmpty ? nil : kept
        LogbookMerge.touch(DayNotes.recordID(for: key)!, kind: .dayNote, deleted: kept.isEmpty,
                           now: Date(timeIntervalSince1970: t), state: &device.state)
    }

    // MARK: Keys and ids

    func testKeyIsTheLocalCalendarDate() {
        XCTAssertEqual(DayNotes.key(for: day(18, hour: 0), calendar: cal), "2026-11-18")
        XCTAssertEqual(DayNotes.key(for: day(18, hour: 23), calendar: cal), "2026-11-18")
        XCTAssertEqual(DayNotes.key(for: day(3, month: 1), calendar: cal), "2026-01-03")
        XCTAssertEqual(DayNotes.start(of: "2026-11-18", calendar: cal), cal.startOfDay(for: day(18)))
    }

    func testOnlyRealDatesAreKeys() {
        XCTAssertTrue(DayNotes.isValid("2026-11-18"))
        XCTAssertTrue(DayNotes.isValid("2028-02-29"))
        for bad in ["2026-02-30", "2027-02-29", "2026-13-01", "2026-1-01", "20261118", "", "abcd-ef-gh", "2026-11-18x"] {
            XCTAssertFalse(DayNotes.isValid(bad), bad)
            XCTAssertNil(DayNotes.recordID(for: bad), bad)
        }
    }

    func testRecordIDIsFixedByTheDateAndReadsBack() {
        let id = DayNotes.recordID(for: "2026-11-18")
        XCTAssertEqual(id?.uuidString, "DA7E0000-0000-4000-8000-000020261118")
        XCTAssertEqual(id, DayNotes.recordID(for: "2026-11-18"), "every device works out the same id")
        XCTAssertNotEqual(id, DayNotes.recordID(for: "2026-11-19"))
        XCTAssertEqual(id.flatMap(DayNotes.key(recordID:)), "2026-11-18")
        XCTAssertNil(DayNotes.key(recordID: UUID()))
        XCTAssertNil(DayNotes.key(recordID: BolusSettings.recordID))
        XCTAssertNil(DayNotes.key(recordID: InsightsScreen.phone.recordID))
    }

    func testTypedNotesAreTidiedToOneShortLine() {
        XCTAssertEqual(DayNotes.cleaned("  sick   day \n with a cold "), "sick day with a cold")
        XCTAssertEqual(DayNotes.cleaned(" \n "), "")
        let long = String(repeating: "travel ", count: 20)
        XCTAssertLessThanOrEqual(DayNotes.cleaned(long).count, DayNotes.maxLength)
        XCTAssertFalse(DayNotes.cleaned(long).hasSuffix(" "))
    }

    func testNoteOnADate() {
        let notes = ["2026-11-18": "Sick day"]
        XCTAssertEqual(DayNotes.note(on: day(18, hour: 7), in: notes, calendar: cal), "Sick day")
        XCTAssertNil(DayNotes.note(on: day(17, hour: 23), in: notes, calendar: cal))
        XCTAssertNil(DayNotes.note(on: day(18), in: [:], calendar: cal))
    }

    // MARK: Sync

    func testANoteReachesTheOtherDevice() {
        let server = Server()
        var phone = Device(name: "iPhone"), mac = Device(name: "Mac")
        write(&phone, "2026-11-18", "Sick day", at: 1_790_000_000)
        let out = LogbookMerge.outgoing(phone.contents, state: phone.state, device: "iPhone")
        XCTAssertEqual(out.map(\.kind), ["dayNote"])
        XCTAssertEqual(out.first?.payload, LogbookMerge.json(DayNote(day: "2026-11-18", text: "Sick day")))
        phone.sync(server)
        mac.sync(server)
        XCTAssertEqual(mac.contents.dayNotes, ["2026-11-18": "Sick day"])
    }

    func testTheLaterEditWinsWhenBothDevicesWriteTheSameDay() {
        let server = Server()
        var phone = Device(name: "iPhone"), mac = Device(name: "Mac")
        // Both write a note for the same day before either syncs: one record, the later edit wins.
        write(&phone, "2026-11-18", "Travel", at: 1_790_000_000)
        write(&mac, "2026-11-18", "Travel to Sydney", at: 1_790_000_060)
        phone.sync(server)
        mac.sync(server)
        phone.sync(server)
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(phone.contents.dayNotes["2026-11-18"], "Travel to Sydney")
        XCTAssertEqual(phone.contents, mac.contents)
    }

    func testRemovingANoteIsADeleteEverywhere() {
        let server = Server()
        var phone = Device(name: "iPhone"), mac = Device(name: "Mac")
        write(&phone, "2026-11-18", "Sick day", at: 1_790_000_000)
        phone.sync(server)
        mac.sync(server)
        write(&mac, "2026-11-18", "   ", at: 1_790_000_100)
        XCTAssertEqual(LogbookMerge.outgoing(mac.contents, state: mac.state, device: "Mac").map(\.deleted), [true])
        mac.sync(server)
        phone.sync(server)
        XCTAssertTrue(phone.contents.dayNotes.isEmpty)
        // An older edit from a device that missed the delete can't bring it back.
        var stale = Device(name: "iPhone")
        write(&stale, "2026-11-18", "Sick day", at: 1_790_000_050)
        stale.sync(server)
        XCTAssertTrue(stale.contents.dayNotes.isEmpty)
    }

    func testExistingNotesUploadOnFirstSyncAndOtherDaysAreLeftAlone() {
        let server = Server()
        var phone = Device(name: "iPhone"), mac = Device(name: "Mac")
        phone.contents.dayNotes = ["2026-11-17": "Travel"]
        write(&mac, "2026-11-18", "Sick day", at: 1_790_000_000)
        phone.sync(server)
        mac.sync(server)
        phone.sync(server)
        XCTAssertEqual(phone.contents.dayNotes, ["2026-11-17": "Travel", "2026-11-18": "Sick day"])
        XCTAssertEqual(phone.contents, mac.contents)
        XCTAssertTrue(phone.contents.allIDs.contains { $0.0 == DayNotes.recordID(for: "2026-11-17") && $0.1 == .dayNote })
    }

    func testABadPayloadIsLeftForANewerApp() {
        var device = Device(name: "Mac")
        let id = DayNotes.recordID(for: "2026-11-18")!
        let records = [
            LogbookRecord(id: id, kind: "dayNote", payload: .object(["day": .string("2026-02-30"), "text": .string("x")]),
                          deleted: false, modified: 10, device: "iPhone", rev: 1),
            LogbookRecord(id: id, kind: "dayNote", payload: .string("nonsense"), deleted: false, modified: 11,
                          device: "iPhone", rev: 2),
        ]
        LogbookMerge.apply(records, to: &device.contents, state: &device.state)
        XCTAssertTrue(device.contents.dayNotes.isEmpty)
        XCTAssertEqual(device.state.cursor, 2)
    }

    func testAPulledNoteIsTidiedAndAnEmptyOneRemovesIt() {
        var device = Device(name: "Mac")
        device.contents.dayNotes = ["2026-11-18": "Sick day"]
        let id = DayNotes.recordID(for: "2026-11-18")!
        LogbookMerge.apply([LogbookRecord(id: id, kind: "dayNote",
                                          payload: LogbookMerge.json(DayNote(day: "2026-11-18", text: "  ")),
                                          deleted: false, modified: 10, device: "iPhone", rev: 1)],
                           to: &device.contents, state: &device.state)
        XCTAssertTrue(device.contents.dayNotes.isEmpty)
        LogbookMerge.apply([LogbookRecord(id: id, kind: "dayNote",
                                          payload: LogbookMerge.json(DayNote(day: "2026-11-18", text: " New \n sensor ")),
                                          deleted: false, modified: 11, device: "iPhone", rev: 2)],
                           to: &device.contents, state: &device.state)
        XCTAssertEqual(device.contents.dayNotes, ["2026-11-18": "New sensor"])
    }

    // MARK: Search

    private func meal(_ food: String, at date: Date) -> LogEntry {
        .meal(MealEntry(timestamp: date, carbs: 40, food: food, note: ""))
    }

    private func parse(_ text: String) -> LogbookQuery {
        LogbookQuery.parse(text, now: day(19, hour: 14), calendar: cal)
    }

    func testSearchFindsEverythingOnANotedDay() {
        let notes = ["2026-11-18": "Sick day"]
        let onSickDay = meal("Toast", at: day(18, hour: 8))
        let dayBefore = meal("Toast", at: day(17, hour: 8))
        let q = parse("sick")
        XCTAssertTrue(LogbookSearch.matches(onSickDay, q, dayNote: DayNotes.note(on: onSickDay.timestamp, in: notes, calendar: cal)))
        XCTAssertFalse(LogbookSearch.matches(dayBefore, q, dayNote: DayNotes.note(on: dayBefore.timestamp, in: notes, calendar: cal)))
        XCTAssertFalse(LogbookSearch.matches(onSickDay, q), "without the note, nothing in the entry says sick")
    }

    func testNoteWordsAndEntryWordsCombine() {
        let note = "Travel"
        XCTAssertTrue(LogbookSearch.matches(meal("Pizza", at: day(18)), parse("travel pizza"), dayNote: note))
        XCTAssertFalse(LogbookSearch.matches(meal("Salad", at: day(18)), parse("travel pizza"), dayNote: note))
        XCTAssertTrue(LogbookSearch.matches(meal("Pizza", at: day(18)), parse("TRAVELS"), dayNote: note),
                      "case and a plural don't matter")
    }

    func testANoteDoesNotWidenTheSearchPastItsDay() {
        // "sick yesterday" on the 19th: only the 18th, and only because of its note.
        let q = parse("sick yesterday")
        XCTAssertTrue(LogbookSearch.matches(meal("Toast", at: day(18, hour: 9)), q, dayNote: "Sick day"))
        XCTAssertFalse(LogbookSearch.matches(meal("Toast", at: day(16, hour: 9)), q, dayNote: "Sick day"))
    }

    func testAlertRowsOnANotedDayAreFoundToo() {
        let alert = AlertLog.rows([AlertRecord(kind: .low, firedAt: day(18, hour: 3))])[0]
        XCTAssertTrue(LogbookSearch.matches(alert, parse("sick"), dayNote: "Sick day"))
        XCTAssertFalse(LogbookSearch.matches(alert, parse("sick")))
    }

    // MARK: Words

    func testWhatVoiceOverHears() {
        XCTAssertEqual(DayNoteText.actionName(hasNote: false), "Add Note")
        XCTAssertEqual(DayNoteText.actionName(hasNote: true), "Edit Note")
        XCTAssertEqual(DayNoteText.spoken("Sick day"), "Note: Sick day")
        XCTAssertEqual(DayNoteText.withNote("Best day. Tuesday 17 November, 92% in range", "Travel"),
                       "Best day. Tuesday 17 November, 92% in range. Note: Travel")
        XCTAssertEqual(DayNoteText.withNote("Best day.", nil), "Best day.")
        XCTAssertEqual(DayNoteText.announcement(spokenDay: "Today", before: nil, after: "Sick day"), "Note added to Today")
        XCTAssertEqual(DayNoteText.announcement(spokenDay: "Today", before: "Sick day", after: nil), "Note removed from Today")
        XCTAssertEqual(DayNoteText.announcement(spokenDay: "Today", before: "Sick", after: "Sick day"), "Note changed for Today")
        XCTAssertNil(DayNoteText.announcement(spokenDay: "Today", before: "Sick", after: "Sick"))
        XCTAssertNil(DayNoteText.announcement(spokenDay: "Today", before: nil, after: ""))
    }
}
