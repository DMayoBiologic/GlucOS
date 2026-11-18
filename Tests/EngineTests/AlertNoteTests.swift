import XCTest
@testable import GlucOSEngine

/// Notes on low and high alerts (docs/AlertNotes.md): a plain Logbook note at the alert's time.
final class AlertNoteTests: XCTestCase {
    private let fired = Date(timeIntervalSince1970: 1_763_450_000)

    // MARK: Text

    func testCleanedTrimsAndJoinsLines() {
        XCTAssertEqual(AlertNote.cleaned("  went for a run \n\n after work "), "went for a run after work")
        XCTAssertNil(AlertNote.cleaned("   \n  "))
        XCTAssertNil(AlertNote.cleaned(""))
    }

    func testCleanedCapsLength() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(AlertNote.cleaned(long)?.count, AlertNote.maxLength)
    }

    // MARK: Which note belongs to an alert

    func testExistingFindsClosestPlainNoteInWindow() {
        let near = ContextEvent(timestamp: fired.addingTimeInterval(30), tags: [], note: "near")
        let nearer = ContextEvent(timestamp: fired.addingTimeInterval(-5), tags: [], note: "nearer")
        let far = ContextEvent(timestamp: fired.addingTimeInterval(AlertNote.window + 1), tags: [], note: "far")
        XCTAssertEqual(AlertNote.existing(near: fired, in: [near, far, nearer])?.note, "nearer")
        XCTAssertNil(AlertNote.existing(near: fired, in: [far]))
    }

    func testExistingIgnoresTaggedEventsAndEmptyNotes() {
        let exercise = ContextEvent(timestamp: fired, tags: [.exercise], note: "run")
        let empty = ContextEvent(timestamp: fired, tags: [], note: "")
        XCTAssertNil(AlertNote.existing(near: fired, in: [exercise, empty]))
        XCTAssertFalse(AlertNote.isNote(exercise))
        XCTAssertTrue(AlertNote.isNote(ContextEvent(timestamp: fired, tags: [], note: "x")))
    }

    // MARK: What saving does

    func testNewNoteIsAPlainEventAtTheAlertsTime() {
        let id = UUID()
        guard case .save(let c) = AlertNote.change(text: " skipped lunch ", firedAt: fired, existing: nil, id: id) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(c.id, id)
        XCTAssertEqual(c.timestamp, fired)
        XCTAssertTrue(c.tags.isEmpty, "never a treatment or any tag Insights or the forecast read")
        XCTAssertEqual(c.note, "skipped lunch")
        XCTAssertNil(c.labels)
    }

    func testEmptyTextWithNoNoteDoesNothing() {
        XCTAssertEqual(AlertNote.change(text: "  ", firedAt: fired, existing: nil), .none)
    }

    func testEditKeepsIdTimeAndLabels() {
        let old = ContextEvent(timestamp: fired.addingTimeInterval(20), tags: [], note: "old", labels: ["Work"])
        guard case .save(let c) = AlertNote.change(text: "new", firedAt: fired, existing: old) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(c.id, old.id)
        XCTAssertEqual(c.timestamp, old.timestamp)
        XCTAssertEqual(c.labels, ["Work"])
        XCTAssertEqual(c.note, "new")
    }

    func testSameTextIsNoChangeAndEmptyRemoves() {
        let old = ContextEvent(timestamp: fired, tags: [], note: "same")
        XCTAssertEqual(AlertNote.change(text: "same ", firedAt: fired, existing: old), .none)
        XCTAssertEqual(AlertNote.change(text: "", firedAt: fired, existing: old), .remove(old.id))
    }

    // MARK: How a plain note shows in the Logbook

    func testPlainNoteIsCalledANote() {
        let note = LogEntry.context(ContextEvent(timestamp: fired, tags: [], note: "x"))
        XCTAssertEqual(note.shortTitle, "Note")
        XCTAssertEqual(note.kindNoun, "note")
        let event = LogEntry.context(ContextEvent(timestamp: fired, tags: [.stress]))
        XCTAssertEqual(event.shortTitle, "Stress")
        XCTAssertEqual(event.kindNoun, "event")
        // No tags and no text is still nothing to name (LogbookUndo says "Entry deleted").
        let empty = LogEntry.context(ContextEvent(timestamp: fired, tags: []))
        XCTAssertEqual(empty.shortTitle, "")
        XCTAssertEqual(empty.kindNoun, "event")
    }

    // MARK: Undo of an added note

    func testAddUndoRemovesOnlyTheSameEntry() {
        let note = LogEntry.context(ContextEvent(timestamp: fired, tags: [], note: "x"))
        let add = LogbookAddUndo(entry: note, addedAt: 100)
        XCTAssertEqual(add.removal(current: note), note.id)
        XCTAssertNil(add.removal(current: nil), "already gone: nothing to delete")
        let other = LogEntry.meal(MealEntry(timestamp: fired, carbs: 10))
        XCTAssertNil(add.removal(current: other))
        XCTAssertEqual(add.title, "Added note")
    }

    func testAddUndoEndsOnlyOnANewerRemoteChange() {
        let note = LogEntry.context(ContextEvent(timestamp: fired, tags: [], note: "x"))
        let add = LogbookAddUndo(entry: note, addedAt: 100)
        let echo = LogbookRecord(id: note.id, kind: "context", payload: nil, deleted: false, modified: 100)
        let newer = LogbookRecord(id: note.id, kind: "context", payload: nil, deleted: false, modified: 105)
        let unrelated = LogbookRecord(id: UUID(), kind: "context", payload: nil, deleted: false, modified: 200)
        XCTAssertFalse(add.superseded(by: [echo, unrelated]))
        XCTAssertTrue(add.superseded(by: [newer]))
    }

    func testAddedOfferOnTheToast() {
        let note = LogEntry.context(ContextEvent(timestamp: fired, tags: [], note: "x"))
        let a = LogbookAddUndo(entry: note, addedAt: 1)
        let offer = LogbookUndoOffer.added(a)
        XCTAssertEqual(offer.title, "Added note")
        XCTAssertEqual(offer.ids, [a.token])
        XCTAssertEqual(offer.count, 1)
        XCTAssertFalse(offer.hint.isEmpty)
        XCTAssertNotEqual(offer.ids, LogbookUndoOffer.added(LogbookAddUndo(entry: note, addedAt: 1)).ids,
                          "a second add restarts the toast")
    }

    // MARK: Words

    func testWords() {
        XCTAssertEqual(AlertSnoozes.noteAction, "alert.note")
        XCTAssertEqual(AlertNoteText.buttonTitle(hasNote: false), "Add note")
        XCTAssertEqual(AlertNoteText.buttonTitle(hasNote: true), "Edit note")
        XCTAssertEqual(AlertNoteText.spoken("ran"), "Note: ran")
        XCTAssertNil(AlertNoteText.spoken(nil))
        XCTAssertNil(AlertNoteText.spoken(""))
        // The banner's buttons are unchanged: Add note is only on the notification and the history.
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .low), ["Log treatment", "Snooze 30 min"])
        let item = AlertHistory.Item(id: UUID(), kind: .low, firedAt: fired, readingMgdl: 62,
                                     outcome: .noResponse, respondedAt: nil)
        XCTAssertTrue(AlertNoteText.editorTitle(item).hasPrefix("Note on \(item.title) at "))
        // Never advice or dosing words.
        for w in [AlertNoteText.editorMessage, AlertNoteText.placeholder] {
            for banned in ["should", "take ", "units", "dose"] { XCTAssertFalse(w.lowercased().contains(banned), w) }
        }
    }
}
