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
        XCTAssertEqual(layout.visible(mac), [.lows, .weekInReview, .highs, .alerts, .overnight, .weekdayWeekend, .streaks, .bestDays, .tags, .dayPattern, .hourlyInRange, .forecastAccuracy])
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
                       [.dayPattern, .hourlyInRange, .weekInReview, .lows, .highs, .alerts, .overnight, .weekdayWeekend, .streaks, .bestDays, .tags, .forecastAccuracy])
        // New cards are never hidden.
        XCTAssertEqual(layout.visible(mac),
                       [.dayPattern, .hourlyInRange, .weekInReview, .lows, .alerts, .overnight, .weekdayWeekend, .streaks, .bestDays, .tags, .forecastAccuracy])
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

    func testBestDaysArriveAfterStreaksInASavedLayout() {
        // A layout saved before Best and toughest days shipped, with In-range streaks moved to the top
        // and Lows hidden: the new card shows, straight after streaks, and isn't hidden.
        let saved = ["streaks", "weekInReview", "lows", "highs", "overnight", "weekdayWeekend", "dayPattern",
                     "forecastAccuracy"]
        let layout = InsightsLayout(order: saved, hidden: ["lows"])
        XCTAssertEqual(Array(layout.arranged(mac).prefix(2)), [.streaks, .bestDays])
        XCTAssertFalse(layout.isHidden(.bestDays))
        XCTAssertEqual(InsightsCard.bestDays.title, "Best and toughest days")
        XCTAssertEqual(InsightsCard(rawValue: "bestDays"), .bestDays)
        let phoneLayout = InsightsLayout(order: InsightsCard.phoneDefault.filter { $0 != .bestDays }.map(\.rawValue),
                                         hidden: [])
        XCTAssertEqual(phoneLayout.visible(phone), phone)
    }

    func testTagsArriveAfterBestDaysInASavedLayout() {
        // A layout saved before the Tags card shipped, with Best and toughest days moved to the top:
        // Tags shows straight after it, not hidden.
        let saved = ["bestDays", "weekInReview", "lows", "highs", "overnight", "weekdayWeekend", "streaks",
                     "dayPattern", "forecastAccuracy"]
        let layout = InsightsLayout(order: saved, hidden: ["lows"])
        XCTAssertEqual(Array(layout.arranged(mac).prefix(2)), [.bestDays, .tags])
        XCTAssertFalse(layout.isHidden(.tags))
        XCTAssertEqual(InsightsCard(rawValue: "tags"), .tags)
        XCTAssertEqual(InsightsCard.tags.title, "Tags")
        let phoneLayout = InsightsLayout(order: InsightsCard.phoneDefault.filter { $0 != .tags }.map(\.rawValue),
                                         hidden: [])
        XCTAssertEqual(phoneLayout.visible(phone), phone)
    }

    func testAlertsArriveAfterHighsInASavedLayout() {
        // A layout saved before the Alerts card shipped, with Highs moved to the top and hidden:
        // Alerts shows straight after it, and isn't hidden.
        let saved = InsightsCard.macDefault.filter { $0 != .alerts && $0 != .highs }.map(\.rawValue)
        let layout = InsightsLayout(order: ["highs"] + saved, hidden: ["highs"])
        XCTAssertEqual(Array(layout.arranged(mac).prefix(2)), [.highs, .alerts])
        XCTAssertEqual(layout.visible(mac).first, .alerts)
        XCTAssertEqual(InsightsCard(rawValue: "alerts"), .alerts)
        XCTAssertEqual(InsightsCard.alerts.title, "Alerts")
        let phoneLayout = InsightsLayout(order: InsightsCard.phoneDefault.filter { $0 != .alerts }.map(\.rawValue),
                                         hidden: [])
        XCTAssertEqual(phoneLayout.visible(phone), phone)
    }

    func testMoveSkipsACardLeftOffTheScreen() {
        // Nothing tagged: Tags isn't drawn, so Move Up on Your usual day swaps it with Best and
        // toughest days, and Tags keeps its slot after Best and toughest days.
        var layout = InsightsLayout.standard
        let onScreen: (InsightsCard) -> Bool = { $0 != .tags }
        layout.move(.dayPattern, by: -1, defaults: mac, onScreen: onScreen)
        let shown = layout.visible(mac).filter(onScreen)
        XCTAssertEqual(Array(shown.suffix(5)), [.streaks, .dayPattern, .bestDays, .hourlyInRange, .forecastAccuracy])
        XCTAssertEqual(Array(layout.visible(mac).suffix(5)), [.dayPattern, .bestDays, .tags, .hourlyInRange, .forecastAccuracy])
        // And back down past the hidden slot.
        layout.move(.dayPattern, by: 1, defaults: mac, onScreen: onScreen)
        XCTAssertEqual(layout.visible(mac).filter(onScreen), mac.filter(onScreen))
        // Ends still stop.
        let before = layout
        layout.move(.forecastAccuracy, by: 1, defaults: mac, onScreen: onScreen)
        XCTAssertEqual(layout, before)
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
