import XCTest
@testable import GlucOSEngine

/// Hiding an Insights card from its menu and bringing it back with Undo (round 102).
final class InsightsHideUndoTests: XCTestCase {
    private let defaults = InsightsScreen.phone.defaults

    func testUndoShowsTheCardInItsOldSlot() {
        var moved = InsightsLayout.standard
        moved.move(.lows, by: -1, defaults: defaults)
        var hidden = moved
        hidden.hide(.lows, defaults: defaults)
        XCTAssertFalse(hidden.visible(defaults).contains(.lows))
        let undo = InsightsHideUndo(card: .lows, screen: .phone, hiddenAt: 100)
        let back = undo.restoring(into: hidden)
        XCTAssertEqual(back?.visible(defaults), moved.visible(defaults), "same place as before the hide")
        XCTAssertEqual(back?.hidden, [])
    }

    func testOtherHiddenCardsStayHidden() {
        var layout = InsightsLayout.standard
        layout.hide(.highs, defaults: defaults)
        layout.hide(.lows, defaults: defaults)
        let back = InsightsHideUndo(card: .lows, screen: .phone, hiddenAt: 100).restoring(into: layout)
        XCTAssertEqual(back?.hidden, [InsightsCard.highs.rawValue])
    }

    func testNothingToDoWhenTheCardIsShowingAlready() {
        let undo = InsightsHideUndo(card: .lows, screen: .phone, hiddenAt: 100)
        XCTAssertNil(undo.restoring(into: .standard))
    }

    func testUndoEndsOnlyOnANewerLayoutFromElsewhere() {
        let undo = InsightsHideUndo(card: .lows, screen: .phone, hiddenAt: 100)
        let id = InsightsScreen.phone.recordID
        let echo = LogbookRecord(id: id, kind: "insightsLayout", payload: nil, deleted: false, modified: 100)
        let newer = LogbookRecord(id: id, kind: "insightsLayout", payload: nil, deleted: false, modified: 105)
        let mac = LogbookRecord(id: InsightsScreen.mac.recordID, kind: "insightsLayout", payload: nil,
                                deleted: false, modified: 105)
        XCTAssertFalse(undo.superseded(by: [echo]), "our own layout coming back")
        XCTAssertFalse(undo.superseded(by: [mac]), "the Mac's layout is separate")
        XCTAssertTrue(undo.superseded(by: [newer]))
    }

    func testOffer() {
        let undo = InsightsHideUndo(card: .hourlyInRange, screen: .phone, hiddenAt: nil)
        let offer = LogbookUndoOffer.cardHidden(undo)
        XCTAssertEqual(offer.title, "Hid Time in range by hour")
        XCTAssertEqual(offer.symbol, "eye.slash")
        XCTAssertEqual(offer.ids, [undo.token])
        XCTAssertEqual(offer.count, 1)
        XCTAssertFalse(offer.showsOutsideLogbook)
        XCTAssertNotEqual(undo, InsightsHideUndo(card: .hourlyInRange, screen: .phone, hiddenAt: nil),
                          "a second hide restarts the countdown")
        XCTAssertFalse(undo.superseded(by: []))
    }
}
