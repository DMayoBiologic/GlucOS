import XCTest
@testable import GlucOSEngine

/// Picking several Logbook rows (`LogbookSelection`), tagging them together (`LogbookBulkTag`) and
/// undoing that in one go (`LogbookBatchEditUndo`).
final class LogbookSelectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_795_000_000)

    private func meal(_ m: Double, id: UUID = UUID(), labels: [String]? = nil) -> LogEntry {
        .meal(MealEntry(id: id, timestamp: base.addingTimeInterval(m * 60), carbs: 45, food: "Toast", labels: labels))
    }

    private func dose(_ m: Double, units: Double = 4, id: UUID = UUID(), labels: [String]? = nil) -> LogEntry {
        var d = InsulinDose(timestamp: base.addingTimeInterval(m * 60), units: units, kind: .rapid, name: "NovoRapid")
        d.id = id
        d.labels = labels
        return .dose(d)
    }

    private func site(_ m: Double) -> LogEntry {
        .siteChange(SiteChange(timestamp: base.addingTimeInterval(m * 60), site: .abdomenLeft))
    }

    /// The rows newest first, as both Logbooks list them; nil stands for an alert row.
    private func runs(_ rows: [LogEntry?]) -> [LogbookRun<LogEntry?>] {
        LogbookGrouping.runs(rows, entry: { $0 })
    }

    // MARK: Selection

    func testAGroupIsPickedAsOneRowAndActsOnAllItsEntries() {
        let m = meal(0), d = dose(5), s = site(-60)
        let r = runs([d, m, nil, s])
        let pickable = LogbookSelection.pickable(r, entry: { $0 })
        guard case .group(let g)? = r.first else { return XCTFail("no group") }
        // The group's own id and the lone site change; never the group's entries, never the alert.
        XCTAssertEqual(pickable, [g.id, s.id])
        var sel = LogbookSelection()
        sel.toggle(g.id)
        XCTAssertEqual(sel.entries(in: r, entry: { $0 }).map(\.id), [d.id, m.id])
        sel.toggle(s.id)
        XCTAssertEqual(sel.entries(in: r, entry: { $0 }).count, 3)
        XCTAssertTrue(LogbookSelection.allPicked(sel, of: pickable))
        sel.toggle(g.id)
        XCTAssertEqual(sel.entries(in: r, entry: { $0 }).map(\.id), [s.id])
        XCTAssertFalse(LogbookSelection.allPicked(sel, of: pickable))
    }

    func testHiddenRowsNeverCount() {
        let a = dose(0), b = site(30)
        var sel = LogbookSelection()
        sel.set([a.id, b.id])
        // A search left only `b` showing: `a` counts for nothing, and keep(only:) lets it go.
        let shown = runs([b])
        XCTAssertEqual(sel.entries(in: shown, entry: { $0 }).map(\.id), [b.id])
        sel.keep(only: Set(LogbookSelection.pickable(shown, entry: { $0 })))
        XCTAssertEqual(sel.picked, [b.id])
        sel.clear()
        XCTAssertTrue(sel.isEmpty)
        XCTAssertFalse(LogbookSelection.allPicked(sel, of: []))
    }

    func testSelectionText() {
        XCTAssertEqual(LogbookSelectionText.title(0), "Select Entries")
        XCTAssertEqual(LogbookSelectionText.title(3), "3 Selected")
        XCTAssertEqual(LogbookSelectionText.spoken(0), "None selected")
        XCTAssertEqual(LogbookSelectionText.spoken(1), "1 entry selected")
        XCTAssertEqual(LogbookSelectionText.spoken(4), "4 entries selected")
        XCTAssertEqual(LogbookSelectionText.deleteName(1), "Delete")
        XCTAssertEqual(LogbookSelectionText.deleteName(2), "Delete 2")
    }

    // MARK: Tagging several

    func testAddingATagChangesOnlyTagsAndSkipsEntriesThatHaveIt() {
        let a = dose(0, units: 4.35), b = meal(5, labels: ["exercise"]), c = site(10)
        let full = dose(20, labels: (1...LogbookTags.maxPerEntry).map { "T\($0)" })
        let out = LogbookBulkTag.adding("  Exercise ", to: [a, b, c, full])
        // `b` already has it (any spelling) and `full` has no room: neither is saved again.
        XCTAssertEqual(out.map(\.id), [a.id, c.id])
        guard case .dose(let d)? = out.first, case .dose(let old) = a else { return XCTFail() }
        XCTAssertEqual(d.labels, ["Exercise"])
        // Nothing but the tags changes: never an amount.
        var stripped = d
        stripped.labels = nil
        XCTAssertEqual(stripped, old)
        XCTAssertEqual(d.units, 4.35)
        // A moment whose "What else is going on?" choice is Exercise already shows under it.
        let moment = LogEntry.context(ContextEvent(timestamp: base, tags: [.exercise]))
        XCTAssertTrue(LogbookBulkTag.adding("Exercise", to: [moment]).isEmpty)
        XCTAssertTrue(LogbookBulkTag.adding("   ", to: [a]).isEmpty)
    }

    func testRemovingATagLeavesOtherTagsAndMomentChoices() {
        let a = dose(0, labels: ["Travel", "Exercise"]), b = meal(5), c = meal(9, labels: ["exercise"])
        let out = LogbookBulkTag.removing("Exercise", from: [a, b, c])
        XCTAssertEqual(out.map(\.id), [a.id, c.id])
        XCTAssertEqual(out[0].labels, ["Travel"])
        XCTAssertEqual(out[1].labels, [])
        // A moment's choice isn't a label, so there's nothing to take off.
        let moment = LogEntry.context(ContextEvent(timestamp: base, tags: [.exercise]))
        XCTAssertTrue(LogbookBulkTag.removing("Exercise", from: [moment]).isEmpty)
        XCTAssertEqual(LogbookBulkTag.removable([a, b, c]), ["Exercise", "Travel"])
        XCTAssertTrue(LogbookBulkTag.allHave("exercise", [a, c]))
        XCTAssertFalse(LogbookBulkTag.allHave("Exercise", [a, b]))
        XCTAssertTrue(LogbookBulkTag.allHave("Exercise", [moment]))
    }

    func testTagTitles() {
        let a = dose(0), b = meal(5)
        XCTAssertEqual(LogbookBulkTag.title("Exercise", adding: true, changed: [a, b]), "Added Exercise to 2 entries")
        XCTAssertEqual(LogbookBulkTag.title("Exercise", adding: true, changed: [a]), "Added Exercise to 4 u NovoRapid")
        XCTAssertEqual(LogbookBulkTag.title("Sick", adding: false, changed: [a, b]), "Removed Sick from 2 entries")
        XCTAssertEqual(LogbookBulkTag.nothingToDo("Sick", adding: true), "Already tagged Sick")
    }

    // MARK: Undo for several

    func testBatchUndoRestoresEveryEntryExactlyUnderItsId() {
        let a = dose(0, units: 4.35), b = meal(5), untouched = site(9)
        let after = LogbookBulkTag.adding("Travel", to: [a, b, untouched])
        let offer = LogbookBatchEditUndo.offer(before: [a, b, untouched], after: after,
                                               editedAt: [a.id: 2000, b.id: 2000, untouched.id: 2000],
                                               title: "Added Travel to 3 entries")!
        XCTAssertEqual(offer.count, 3)
        XCTAssertEqual(Set(offer.ids), [a.id, b.id, untouched.id])
        let now = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let back = offer.restore(current: { now[$0] })
        XCTAssertEqual(back, [a, b, untouched])
        guard case .dose(let d) = back[0] else { return XCTFail() }
        XCTAssertEqual(d.units, 4.35)
        XCTAssertNil(d.labels)
        // One deleted since stays deleted; the others still come back.
        XCTAssertEqual(offer.restore(current: { $0 == b.id ? nil : now[$0] }).map(\.id), [a.id, untouched.id])
        // Nothing really changed: no Undo.
        XCTAssertNil(LogbookBatchEditUndo.offer(before: [a], after: [a], editedAt: [:], title: "x"))
        XCTAssertNil(LogbookBatchEditUndo.offer(before: [a], after: [], editedAt: [:], title: "x"))
        // Only entries that changed are kept.
        let partial = LogbookBatchEditUndo.offer(before: [a, b], after: [after[0], b], editedAt: [a.id: 1, b.id: 1], title: "x")!
        XCTAssertEqual(partial.ids, [a.id])
    }

    func testBatchUndoSurvivesItsOwnEchoAndDropsEntriesChangedElsewhere() {
        let a = dose(0), b = meal(5)
        let after = LogbookBulkTag.adding("Sick", to: [a, b])
        let offer = LogbookBatchEditUndo.offer(before: [a, b], after: after, editedAt: [a.id: 2000, b.id: 2000],
                                               title: "Added Sick to 2 entries")!
        func record(_ id: UUID, _ t: Double) -> LogbookRecord {
            LogbookRecord(id: id, kind: "dose", payload: nil, deleted: false, modified: t, device: "Mac", rev: 1)
        }
        // This device's own change coming back from the server keeps Undo.
        XCTAssertTrue(offer.superseded(by: [record(a.id, 2000.0004), record(b.id, 2000)]).isEmpty)
        // A newer change on the Mac to `b` ends Undo for `b` only.
        let gone = offer.superseded(by: [record(b.id, 2005)])
        XCTAssertEqual(gone, [b.id])
        let rest = offer.dropping(gone)
        XCTAssertEqual(rest?.ids, [a.id])
        XCTAssertEqual(rest?.token, offer.token)
        XCTAssertNil(rest?.dropping([a.id]))
        XCTAssertEqual(offer.dropping([]), offer)
    }

    func testTheToastOffersTheBatch() {
        let a = dose(0), b = meal(5)
        let after = LogbookBulkTag.adding("Sick", to: [a, b])
        let batch = LogbookBatchEditUndo.offer(before: [a, b], after: after, editedAt: [:], title: "Added Sick to 2 entries")!
        let offer = LogbookUndoOffer.batch(batch)
        XCTAssertEqual(offer.title, "Added Sick to 2 entries")
        XCTAssertEqual(offer.symbol, "tag")
        XCTAssertEqual(offer.ids, [batch.token])
        XCTAssertEqual(offer.count, 2)
        XCTAssertFalse(offer.hint.isEmpty)
        // Deleting several already reads as one: "2 entries deleted".
        XCTAssertEqual(LogbookUndoOffer.deleted([a, b]).title, "2 entries deleted")
    }
}
