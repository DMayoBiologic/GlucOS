import XCTest
@testable import GlucOSEngine

/// Reordering and hiding Insights cards (`InsightsLayout`, docs/InsightsLayout.md).
final class InsightsLayoutTests: XCTestCase {
    private let mac = InsightsCard.macDefault
    private let phone = InsightsCard.phoneDefault

    func testStandardIsTheShippedOrder() {
        XCTAssertEqual(InsightsLayout.standard.visible(phone), phone)
        XCTAssertEqual(InsightsLayout.standard.visible(mac), mac)
        XCTAssertTrue(InsightsLayout.standard.hiddenCards(phone).isEmpty)
        XCTAssertEqual(InsightsLayout.standard.stored, "")
    }

    func testDragMovesLikeOnMove() {
        var layout = InsightsLayout.standard
        // Drag Lows (index 1) to the top.
        layout.moveVisible(fromOffsets: IndexSet(integer: 1), toOffset: 0, defaults: mac)
        XCTAssertEqual(layout.visible(mac), [.lows, .weekInReview, .highs, .overnight, .weekdayWeekend, .streaks, .dayPattern, .forecastAccuracy])
        // Drag Week in review (now index 1) to the end: onMove reports the count as the destination.
        layout.moveVisible(fromOffsets: IndexSet(integer: 1), toOffset: mac.count, defaults: mac)
        XCTAssertEqual(layout.visible(mac).last, .weekInReview)
        XCTAssertEqual(layout.visible(mac).first, .lows)
    }

    func testMoveDownOnePlaceLandsAfterItsNeighbour() {
        var layout = InsightsLayout.standard
        layout.moveVisible(fromOffsets: IndexSet(integer: 0), toOffset: 2, defaults: mac)
        XCTAssertEqual(Array(layout.visible(mac).prefix(3)), [.lows, .weekInReview, .highs])
    }

    func testStepMovesAndStopsAtTheEnds() {
        var layout = InsightsLayout.standard
        layout.move(.highs, by: -1, defaults: mac)
        XCTAssertEqual(Array(layout.visible(mac).prefix(3)), [.weekInReview, .highs, .lows])
        layout.move(.highs, by: 1, defaults: mac)
        XCTAssertEqual(layout.visible(mac), mac)
        let before = layout
        layout.move(.weekInReview, by: -1, defaults: mac)
        layout.move(.forecastAccuracy, by: 1, defaults: mac)
        XCTAssertEqual(layout.visible(mac), before.visible(mac))
    }

    func testHideAndRestoreKeepsItsPlace() {
        var layout = InsightsLayout.standard
        layout.hide(.highs, defaults: mac)
        XCTAssertFalse(layout.visible(mac).contains(.highs))
        XCTAssertEqual(layout.hiddenCards(mac), [.highs])
        layout.restore(.highs, defaults: mac)
        XCTAssertEqual(layout.visible(mac), mac)
        XCTAssertTrue(layout.hiddenCards(mac).isEmpty)
    }

    func testDraggingPastAHiddenCardLeavesItInItsSlot() {
        var layout = InsightsLayout.standard
        layout.hide(.lows, defaults: mac)
        // Showing: weekInReview, highs, overnight, ... Drag Highs above Week in review.
        layout.moveVisible(fromOffsets: IndexSet(integer: 1), toOffset: 0, defaults: mac)
        XCTAssertEqual(Array(layout.visible(mac).prefix(2)), [.highs, .weekInReview])
        // Lows still sits second in the full order, so restoring it puts it back there.
        XCTAssertEqual(layout.arranged(mac)[1], .lows)
        layout.restore(.lows, defaults: mac)
        XCTAssertEqual(Array(layout.visible(mac).prefix(3)), [.highs, .lows, .weekInReview])
    }

    func testNewCardShowsNextToItsShippedNeighbour() {
        // Someone who placed their cards before Overnight and Weekdays and weekends shipped, with
        // Day pattern moved to the top and Highs hidden.
        let layout = InsightsLayout(order: ["dayPattern", "weekInReview", "lows", "highs", "forecastAccuracy"],
                                    hidden: ["highs"])
        XCTAssertEqual(layout.arranged(mac),
                       [.dayPattern, .weekInReview, .lows, .highs, .overnight, .weekdayWeekend, .streaks, .forecastAccuracy])
        // New cards are never hidden.
        XCTAssertEqual(layout.visible(mac),
                       [.dayPattern, .weekInReview, .lows, .overnight, .weekdayWeekend, .streaks, .forecastAccuracy])
    }

    func testStreaksArriveAfterWeekdaysAndWeekendsInASavedLayout() {
        // A layout saved before In-range streaks shipped, with Weekdays and weekends moved up and
        // hidden: the new card still shows, after it.
        let saved = ["weekdayWeekend", "weekInReview", "lows", "highs", "overnight", "dayPattern", "forecastAccuracy"]
        let layout = InsightsLayout(order: saved, hidden: ["weekdayWeekend"])
        XCTAssertEqual(Array(layout.arranged(mac).prefix(2)), [.weekdayWeekend, .streaks])
        XCTAssertEqual(layout.visible(mac).first, .streaks)
        let phoneLayout = InsightsLayout(order: InsightsCard.phoneDefault.filter { $0 != .streaks }.map(\.rawValue),
                                         hidden: [])
        XCTAssertEqual(phoneLayout.visible(phone), phone)
    }

    func testNewCardFirstInShippedOrderGoesToTheTop() {
        let layout = InsightsLayout(order: ["days", "weekInReview"], hidden: [])
        XCTAssertEqual(layout.arranged(phone).first, .glance)
    }

    func testUnknownAndDuplicateNamesAreIgnoredButKept() {
        var layout = InsightsLayout(order: ["lows", "someFutureCard", "lows", "glance"], hidden: ["someFutureCard"])
        // Glance isn't a Mac card; the future card isn't known; Lows counts once.
        XCTAssertEqual(layout.arranged(mac).filter { $0 == .lows }.count, 1)
        XCTAssertEqual(Set(layout.arranged(mac)), Set(mac))
        XCTAssertEqual(layout.arranged(mac).count, mac.count)
        layout.hide(.highs, defaults: mac)
        XCTAssertTrue(layout.order.contains("someFutureCard"))
        XCTAssertTrue(layout.hidden.contains("someFutureCard"))
    }

    func testStoredRoundTrip() {
        var layout = InsightsLayout.standard
        layout.move(.dayPattern, by: -1, defaults: phone)
        layout.hide(.mornings, defaults: phone)
        let back = InsightsLayout(stored: layout.stored)
        XCTAssertEqual(back, layout)
        XCTAssertEqual(back.visible(phone), layout.visible(phone))
        XCTAssertEqual(InsightsLayout(stored: ""), .standard)
        XCTAssertEqual(InsightsLayout(stored: "not json"), .standard)
    }

    func testEveryCardHasATitleAndSymbol() {
        for card in InsightsCard.allCases {
            XCTAssertFalse(card.title.isEmpty)
            XCTAssertFalse(card.systemImage.isEmpty)
        }
        XCTAssertEqual(Set(phone).count, phone.count)
        XCTAssertEqual(Set(mac).count, mac.count)
    }
}
