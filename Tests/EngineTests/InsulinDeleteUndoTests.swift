import XCTest
@testable import GlucOSEngine

/// Deleting a saved insulin in Settings and putting it back with Undo (round 101).
final class InsulinDeleteUndoTests: XCTestCase {
    private let novo = SavedInsulin(name: "NovoRapid", kind: .rapid)
    private let fiasp = SavedInsulin(name: "Fiasp", kind: .ultraRapid)
    private let lantus = SavedInsulin(name: "Lantus", kind: .long)

    func testUndoPutsItBackInItsOldPlace() {
        let undo = LogbookInsulinUndo(insulin: fiasp, index: 1, deletedAt: 100)
        XCTAssertEqual(undo.restoring(into: [novo, lantus])?.map(\.name), ["NovoRapid", "Fiasp", "Lantus"])
        let first = LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: 100)
        XCTAssertEqual(first.restoring(into: [fiasp, lantus])?.map(\.name), ["NovoRapid", "Fiasp", "Lantus"])
    }

    func testUndoKeepsTheInsulinExactlyAsSaved() {
        var stepped = novo
        stepped.doseStep = 0.5
        let undo = LogbookInsulinUndo(insulin: stepped, index: 0, deletedAt: 100)
        XCTAssertEqual(undo.restoring(into: [lantus])?.first, stepped, "same id, kind and dose step")
    }

    func testAShorterListPutsItAtTheEnd() {
        let undo = LogbookInsulinUndo(insulin: lantus, index: 2, deletedAt: 100)
        XCTAssertEqual(undo.restoring(into: [novo])?.map(\.name), ["NovoRapid", "Lantus"])
        XCTAssertEqual(undo.restoring(into: [])?.map(\.name), ["Lantus"])
    }

    func testNothingToPutBackWhenItIsThereAlready() {
        let undo = LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: 100)
        XCTAssertNil(undo.restoring(into: [novo, lantus]), "same id")
        let retyped = SavedInsulin(id: UUID(), name: "novo rapid", kind: .rapid)
        XCTAssertNil(undo.restoring(into: [retyped]), "same name saved again")
    }

    func testUndoEndsOnlyOnANewerRemoteChange() {
        let undo = LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: 100)
        let echo = LogbookRecord(id: novo.id, kind: "insulin", payload: nil, deleted: true, modified: 100)
        let newer = LogbookRecord(id: novo.id, kind: "insulin", payload: nil, deleted: false, modified: 105)
        let other = LogbookRecord(id: lantus.id, kind: "insulin", payload: nil, deleted: false, modified: 200)
        XCTAssertFalse(undo.superseded(by: [echo, other]), "our own tombstone and another insulin's move")
        XCTAssertTrue(undo.superseded(by: [newer]))
        XCTAssertFalse(LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: nil).superseded(by: [newer]))
    }

    func testOfferOnTheToast() {
        let undo = LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: 100)
        let offer = LogbookUndoOffer.insulinDeleted(undo)
        XCTAssertEqual(offer.title, "Deleted NovoRapid")
        XCTAssertEqual(offer.symbol, "trash")
        XCTAssertEqual(offer.ids, [undo.token])
        XCTAssertEqual(offer.count, 1)
        XCTAssertTrue(offer.hint.contains("NovoRapid"))
        XCTAssertFalse(offer.isRepeat)
        XCTAssertFalse(offer.showsOutsideLogbook, "only in the Logbook and Settings")
        XCTAssertNotEqual(offer.ids, LogbookUndoOffer.insulinDeleted(LogbookInsulinUndo(insulin: novo, index: 0, deletedAt: 100)).ids,
                          "a second delete restarts the toast")
    }

    // MARK: Motion

    func testRowShrinksAndFadesWithItsHeight() {
        XCTAssertEqual(RowRemoval.scale(fraction: 1), 1)
        XCTAssertEqual(RowRemoval.scale(fraction: 0), RowRemoval.shrunkScale)
        XCTAssertEqual(RowRemoval.scale(fraction: -1), RowRemoval.shrunkScale, "clamped")
        XCTAssertEqual(RowRemoval.opacity(fraction: 1), 1)
        XCTAssertEqual(RowRemoval.opacity(fraction: 0), 0)
        XCTAssertGreaterThan(RowRemoval.opacity(fraction: 0.5), 0.5, "the text fades ahead of the shrink")
        XCTAssertLessThanOrEqual(RowRemoval.duration, 0.35)
        XCTAssertLessThanOrEqual(RowRemoval.fadeDuration, RowRemoval.duration)
    }

    func testArrivalsAreOnlyNewRows() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(RowRemoval.arrivals(from: [a, b], to: [a, c, b]), [c])
        XCTAssertTrue(RowRemoval.arrivals(from: [a, b], to: [b, a]).isEmpty, "a reorder brings none")
        XCTAssertTrue(RowRemoval.arrivals(from: [a, b], to: [a]).isEmpty)
    }
}
