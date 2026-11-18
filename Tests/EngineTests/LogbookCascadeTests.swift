import XCTest
@testable import GlucOSEngine

/// Several Logbook rows leaving one after another and coming back the other way after Undo
/// (`LogbookCascade`), and the picked rows in order (`LogbookSelection.rows`).
final class LogbookCascadeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_795_000_000)
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: When it runs

    func testOnlyForTwoOrMoreRowsAndNeverUnderReduceMotion() {
        XCTAssertFalse(LogbookCascade.applies(rows: 0, reduceMotion: false))
        XCTAssertFalse(LogbookCascade.applies(rows: 1, reduceMotion: false))
        XCTAssertTrue(LogbookCascade.applies(rows: 2, reduceMotion: false))
        XCTAssertTrue(LogbookCascade.applies(rows: 30, reduceMotion: false))
        XCTAssertFalse(LogbookCascade.applies(rows: 2, reduceMotion: true))
        XCTAssertFalse(LogbookCascade.applies(rows: 30, reduceMotion: true))
    }

    // MARK: Timing

    func testLeavingRunsTopToBottomAStepApart() {
        let t = LogbookCascade.delays(rows: 3, direction: .leaving)
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0], 0, accuracy: 1e-9)
        XCTAssertEqual(t[1], LogbookCascade.step, accuracy: 1e-9)
        XCTAssertEqual(t[2], 2 * LogbookCascade.step, accuracy: 1e-9)
    }

    func testArrivingIsTheReverseSoTheBottomRowIsBackFirst() {
        let out = LogbookCascade.delays(rows: 4, direction: .leaving)
        let back = LogbookCascade.delays(rows: 4, direction: .arriving)
        XCTAssertEqual(back, out.reversed())
        XCTAssertEqual(back.last ?? -1, 0, accuracy: 1e-9)
    }

    func testALongSelectionStillStartsItsLastRowWithinTheSpread() {
        for n in [2, 5, 8, 20, 200] {
            let t = LogbookCascade.delays(rows: n, direction: .leaving)
            XCTAssertLessThanOrEqual(t.max() ?? 0, LogbookCascade.spread + 1e-9, "\(n) rows")
            XCTAssertLessThanOrEqual(LogbookCascade.total(rows: n), LogbookCascade.spread + LogbookCascade.rowDuration + 1e-9)
            // Still in order, each after the last.
            XCTAssertEqual(t, t.sorted())
        }
        XCTAssertLessThan(LogbookCascade.step(rows: 20), LogbookCascade.step)
        XCTAssertEqual(LogbookCascade.step(rows: 3), LogbookCascade.step, accuracy: 1e-9)
    }

    func testTotalIsTheLastRowsDelayPlusOneRow() {
        XCTAssertEqual(LogbookCascade.total(rows: 0), 0)
        XCTAssertEqual(LogbookCascade.total(rows: 1), LogbookCascade.rowDuration, accuracy: 1e-9)
        XCTAssertEqual(LogbookCascade.total(rows: 3), 2 * LogbookCascade.step + LogbookCascade.rowDuration, accuracy: 1e-9)
        let cascade = LogbookCascade(rows: [[a], [b], [c]], direction: .leaving)
        XCTAssertEqual(cascade.total, LogbookCascade.total(rows: 3), accuracy: 1e-9)
    }

    // MARK: Rows

    func testAGroupedRowMovesAsOne() {
        let cascade = LogbookCascade(rows: [[a], [b, c], [d]], direction: .leaving)
        XCTAssertEqual(cascade.rowCount, 3)
        XCTAssertEqual(cascade.delays[b], cascade.delays[c])
        XCTAssertEqual(cascade.delay([b, c]) ?? -1, LogbookCascade.step, accuracy: 1e-9)
        XCTAssertEqual(cascade.delay([d]) ?? -1, 2 * LogbookCascade.step, accuracy: 1e-9)
        XCTAssertEqual(cascade.ids, [a, b, c, d])
    }

    func testEmptyRowsAndRepeatsAreDropped() {
        let cascade = LogbookCascade(rows: [[a], [], [a, b]], direction: .leaving)
        XCTAssertEqual(cascade.rowCount, 2)
        XCTAssertEqual(cascade.ids, [a, b])
        XCTAssertEqual(cascade.delays[a] ?? -1, 0, accuracy: 1e-9)
    }

    func testLeavingRowsHideAtOnceAndOthersNever() {
        let cascade = LogbookCascade(rows: [[a], [b]], direction: .leaving)
        XCTAssertTrue(cascade.hides([a]))
        XCTAssertTrue(cascade.hides([b, UUID()]))
        XCTAssertFalse(cascade.hides([c]))
        XCTAssertNil(cascade.delay([c]))
    }

    func testArrivingRowsStayHiddenUntilRevealed() {
        let cascade = LogbookCascade(rows: [[a], [b]], direction: .arriving)
        XCTAssertTrue(cascade.hides([a]))
        let shown = cascade.revealed()
        XCTAssertFalse(shown.hides([a]))
        XCTAssertTrue(shown.holds([a]))
        XCTAssertNotEqual(cascade, shown)
        // Bottom row first.
        XCTAssertEqual(shown.delay([b]) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(shown.delay([a]) ?? -1, LogbookCascade.step, accuracy: 1e-9)
    }

    // MARK: Undo

    func testUndoOfTheCascadeComesBackInOrder() {
        let rows = [[a], [b, c], [d]]
        XCTAssertEqual(LogbookCascade.restoring(added: [a, b, c, d], deleted: rows), rows)
    }

    func testUndoKeepsWhatCameBackWhenSomeStayedDeleted() {
        // Deleted again on the other device before Undo: only the rest come back.
        XCTAssertEqual(LogbookCascade.restoring(added: [a, d], deleted: [[a], [b, c], [d]]), [[a], [d]])
    }

    func testOneRowBackOrSomethingElseArrivingIsNoCascade() {
        XCTAssertNil(LogbookCascade.restoring(added: [a], deleted: [[a], [b]]))
        XCTAssertNil(LogbookCascade.restoring(added: [], deleted: [[a], [b]]))
        // A sync bringing in another entry at the same moment arrives as usual.
        XCTAssertNil(LogbookCascade.restoring(added: [a, b, UUID()], deleted: [[a], [b]]))
        XCTAssertNil(LogbookCascade.restoring(added: [a, b], deleted: []))
    }

    func testVoiceOverLine() {
        XCTAssertEqual(LogbookCascadeText.restored(1), "Put back 1 entry")
        XCTAssertEqual(LogbookCascadeText.restored(4), "Put back 4 entries")
    }

    // MARK: Picked rows in order

    func testPickedRowsTopToBottomWithAGroupAsAllItsEntries() {
        let mealID = UUID(), doseID = UUID(), lone = UUID(), other = UUID()
        var dose = InsulinDose(timestamp: base.addingTimeInterval(60), units: 4, kind: .rapid, name: "NovoRapid")
        dose.id = doseID
        // Newest first, as both Logbooks list them.
        let rows: [LogEntry] = [
            .meal(MealEntry(id: lone, timestamp: base.addingTimeInterval(3 * 3600), carbs: 20, food: "Apple")),
            .meal(MealEntry(id: other, timestamp: base.addingTimeInterval(2 * 3600), carbs: 30, food: "Toast")),
            .dose(dose),
            .meal(MealEntry(id: mealID, timestamp: base, carbs: 45, food: "Pasta")),
        ]
        let runs = LogbookGrouping.runs(rows, entry: { Optional($0) })
        guard let groupID = runs.compactMap({ run -> UUID? in if case .group(let g) = run { return g.id } else { return nil } }).first else {
            return XCTFail("expected the meal and its insulin to group")
        }
        var selection = LogbookSelection()
        selection.set([groupID, lone])
        let picked = selection.rows(in: runs, entry: { Optional($0) })
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[0], [lone])
        XCTAssertEqual(Set(picked[1]), [mealID, doseID])
    }
}
