import XCTest
@testable import GlucOSEngine

/// "Logged twice?" (docs/DoubleLog.md): a meal or dose saved within 5 minutes of one that looks the
/// same is offered for Undo, never blocked or deleted on its own.
final class DoubleLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_763_450_000)

    private func dose(_ units: Double, at offset: TimeInterval = 0, kind: InsulinKind = .rapid,
                      name: String = "NovoRapid") -> LogEntry {
        .dose(InsulinDose(timestamp: t0.addingTimeInterval(offset), units: units, kind: kind, name: name))
    }

    private func meal(_ carbs: Double, at offset: TimeInterval = 0, food: String = "Toast") -> LogEntry {
        .meal(MealEntry(timestamp: t0.addingTimeInterval(offset), carbs: carbs, food: food))
    }

    private func record(_ id: UUID, modified: Double, deleted: Bool = false) -> LogbookRecord {
        LogbookRecord(id: id, kind: "dose", payload: nil, deleted: deleted, modified: modified)
    }

    // MARK: What counts as the same

    func testSameDoseWithinFiveMinutesIsTwice() {
        let earlier = dose(4)
        let new = dose(4, at: 120)
        XCTAssertEqual(DoubleLog.earlier(for: new, in: [earlier, new])?.id, earlier.id)
    }

    func testOutsideWindowIsNot() {
        let earlier = dose(4)
        XCTAssertNil(DoubleLog.earlier(for: dose(4, at: DoubleLog.window + 1), in: [earlier]))
        XCTAssertNotNil(DoubleLog.earlier(for: dose(4, at: DoubleLog.window), in: [earlier]))
        // Either side: a new entry backdated before the earlier one still counts.
        XCTAssertNotNil(DoubleLog.earlier(for: dose(4, at: -60), in: [earlier]))
    }

    func testDifferentAmountIsNot() {
        let earlier = dose(4)
        XCTAssertNil(DoubleLog.earlier(for: dose(5, at: 60), in: [earlier]))
        XCTAssertNil(DoubleLog.earlier(for: dose(4.5, at: 60), in: [earlier]))
        // Within the slack (0.1 u, or 5% of a big dose) is the same.
        XCTAssertNotNil(DoubleLog.earlier(for: dose(4.05, at: 60), in: [earlier]))
        XCTAssertNotNil(DoubleLog.earlier(for: dose(20.8, at: 60), in: [dose(20)]))
    }

    func testDifferentInsulinIsNot() {
        let earlier = dose(4)
        XCTAssertNil(DoubleLog.earlier(for: dose(4, at: 60, kind: .long), in: [earlier]))
        XCTAssertNil(DoubleLog.earlier(for: dose(4, at: 60, name: "Fiasp"), in: [earlier]))
        // Spelling doesn't matter, and an unnamed dose matches by kind.
        XCTAssertNotNil(DoubleLog.earlier(for: dose(4, at: 60, name: "novo rapid"), in: [earlier]))
        XCTAssertNotNil(DoubleLog.earlier(for: dose(4, at: 60, name: ""), in: [earlier]))
    }

    func testMeals() {
        let earlier = meal(30)
        XCTAssertNotNil(DoubleLog.earlier(for: meal(30, at: 90, food: " toast "), in: [earlier]))
        XCTAssertNotNil(DoubleLog.earlier(for: meal(31, at: 90), in: [earlier]))
        XCTAssertNotNil(DoubleLog.earlier(for: meal(30, at: 90, food: ""), in: [earlier]))
        XCTAssertNil(DoubleLog.earlier(for: meal(45, at: 90), in: [earlier]))
        XCTAssertNil(DoubleLog.earlier(for: meal(30, at: 90, food: "Apple"), in: [earlier]))
    }

    func testMealNeverMatchesDose() {
        XCTAssertNil(DoubleLog.earlier(for: meal(4, at: 30, food: ""), in: [dose(4)]))
        XCTAssertNil(DoubleLog.earlier(for: dose(4, at: 30), in: [meal(4, food: "")]))
    }

    func testNeverForNotesEventsOrSites() {
        let note = LogEntry.context(ContextEvent(timestamp: t0, tags: [], note: "ran"))
        let note2 = LogEntry.context(ContextEvent(timestamp: t0.addingTimeInterval(30), tags: [], note: "ran"))
        XCTAssertNil(DoubleLog.earlier(for: note2, in: [note]))
        let site = LogEntry.siteChange(SiteChange(timestamp: t0, site: .abdomenLeft))
        let site2 = LogEntry.siteChange(SiteChange(timestamp: t0.addingTimeInterval(30), site: .abdomenLeft))
        XCTAssertNil(DoubleLog.earlier(for: site2, in: [site]))
    }

    func testClosestInTimeWins() {
        let far = dose(4, at: -240)
        let near = dose(4, at: -30)
        XCTAssertEqual(DoubleLog.earlier(for: dose(4), in: [far, near])?.id, near.id)
    }

    func testEntriesSavedTogetherAreNotTwins() {
        let a = dose(4), b = dose(4, at: 1)
        XCTAssertNil(DoubleLog.earlier(for: b, in: [a, b], excluding: [a.id, b.id]))
        XCTAssertNil(LogbookRepeatUndo.offer(saved: [a, b], in: [a, b], addedAt: [:]))
    }

    // MARK: The offer

    func testOfferPairsEachNewEntryWithItsTwin() {
        let oldDose = dose(4), oldMeal = meal(30)
        let newDose = dose(4, at: 60), newMeal = meal(30, at: 60)
        let all = [oldDose, oldMeal, newDose, newMeal]
        let offer = LogbookRepeatUndo.offer(saved: [newDose, newMeal], in: all,
                                            addedAt: [newDose.id: 10, newMeal.id: 10])
        XCTAssertEqual(offer?.pairs.map(\.earlier.id), [oldDose.id, oldMeal.id])
        XCTAssertEqual(offer?.ids, [newDose.id, newMeal.id])
        XCTAssertEqual(offer?.title, "Logged twice? 2 entries")
        XCTAssertEqual(LogbookUndoOffer.repeated(offer!).count, 2)
    }

    func testOfferOnlyForTheRepeatedOne() {
        let oldDose = dose(4)
        let newDose = dose(4, at: 60), newMeal = meal(30, at: 60)
        let offer = LogbookRepeatUndo.offer(saved: [newDose, newMeal], in: [oldDose, newDose, newMeal], addedAt: [:])
        XCTAssertEqual(offer?.ids, [newDose.id])
        XCTAssertEqual(offer?.title, "Logged twice? 4 u NovoRapid")
        XCTAssertNil(LogbookRepeatUndo.offer(saved: [newMeal], in: [oldDose, newMeal], addedAt: [:]))
    }

    func testToastWording() {
        let old = dose(4), new = dose(4, at: 60)
        let offer = LogbookRepeatUndo.offer(saved: [new], in: [old, new], addedAt: [:])!
        let shown = LogbookUndoOffer.repeated(offer)
        XCTAssertTrue(shown.isRepeat)
        XCTAssertFalse(LogbookUndoOffer.deleted([old]).isRepeat)
        XCTAssertEqual(shown.symbol, "square.on.square")
        XCTAssertTrue(shown.hint.hasPrefix("Takes the new entry off again"))
        XCTAssertTrue(shown.hint.contains("stays"))
        XCTAssertLessThanOrEqual(shown.title.count, 40)
        // A fresh token per offer restarts the countdown.
        let again = LogbookRepeatUndo.offer(saved: [new], in: [old, new], addedAt: [:])!
        XCTAssertNotEqual(shown.ids, LogbookUndoOffer.repeated(again).ids)
    }

    // MARK: Undo

    func testUndoRemovesOnlyNewEntriesWhileTwinRemains() {
        let old = dose(4), new = dose(4, at: 60)
        let offer = LogbookRepeatUndo.offer(saved: [new], in: [old, new], addedAt: [:])!
        let both: [UUID: LogEntry] = [old.id: old, new.id: new]
        XCTAssertEqual(offer.removals(current: { both[$0] }), [new.id])
        // The earlier one deleted since: Undo leaves the new one, so the dose is still logged once.
        XCTAssertEqual(offer.removals(current: { $0 == new.id ? new : nil }), [])
        // The new one gone already: nothing to do.
        XCTAssertEqual(offer.removals(current: { $0 == old.id ? old : nil }), [])
    }

    func testSupersededBySync() {
        let old = dose(4), new = dose(4, at: 60)
        let offer = LogbookRepeatUndo.offer(saved: [new], in: [old, new], addedAt: [new.id: 100])!
        // Our own add echoing back keeps Undo.
        XCTAssertFalse(offer.superseded(by: [record(new.id, modified: 100)]))
        // A later edit or delete of the new one elsewhere ends it.
        XCTAssertTrue(offer.superseded(by: [record(new.id, modified: 105)]))
        // Any change to the earlier twin elsewhere ends it too.
        XCTAssertTrue(offer.superseded(by: [record(old.id, modified: 1, deleted: true)]))
        XCTAssertFalse(offer.superseded(by: [record(UUID(), modified: 999)]))
    }
}
