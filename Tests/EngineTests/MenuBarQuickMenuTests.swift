import XCTest
@testable import GlucOSEngine

/// The menu bar item's right-click menu: which clicks open it and what it holds.
final class MenuBarQuickMenuTests: XCTestCase {
    private func meal(_ food: String, carbs: Double, slot: MealSlot = .breakfast) -> UsualEntry {
        UsualEntry(kind: .meal(slot), food: food, carbs: carbs, items: nil, units: 4, insulinKind: .rapid,
                   insulinName: "NovoRapid", count: 5, lastLogged: referenceNow)
    }

    private func correction(_ units: Double) -> UsualEntry {
        UsualEntry(kind: .correction, food: "", carbs: 0, items: nil, units: units, insulinKind: .rapid,
                   insulinName: "NovoRapid", count: 4, lastLogged: referenceNow)
    }

    private func low() -> UsualEntry {
        UsualEntry(kind: .lowTreatment, food: "Jelly beans", carbs: 15, items: nil, units: nil, insulinKind: nil,
                   insulinName: "", count: 3, lastLogged: referenceNow)
    }

    private func items(_ rows: [MenuBarQuickMenu.Row]) -> [MenuBarQuickMenu.Item] {
        rows.compactMap { if case .item(let i) = $0 { return i } else { return nil } }
    }

    // MARK: Clicks

    func testRightClickAndControlClickOpenTheMenu() {
        XCTAssertTrue(MenuBarQuickMenu.opensMenu(.secondary, control: false))
        XCTAssertTrue(MenuBarQuickMenu.opensMenu(.secondary, control: true))
        XCTAssertTrue(MenuBarQuickMenu.opensMenu(.primary, control: true))
    }

    func testPlainClickStillOpensThePopover() {
        XCTAssertFalse(MenuBarQuickMenu.opensMenu(.primary, control: false))
    }

    // MARK: Rows

    func testWithoutUsualsTheMenuIsJustTheActions() {
        let rows = MenuBarQuickMenu.rows(usuals: [])
        XCTAssertFalse(rows.contains(.header(MenuBarQuickMenu.usualHeader)))
        XCTAssertEqual(items(rows).map(\.action), [.newEntry, .openLogbook, .settings])
        XCTAssertNotEqual(rows.first, .separator)
    }

    func testUsualsComeFirstUnderAHeaderWithOptionCommandKeys() {
        let rows = MenuBarQuickMenu.rows(usuals: [low(), meal("Toast", carbs: 30)])
        XCTAssertEqual(rows.first, .header("Your usual"))
        let list = items(rows)
        XCTAssertEqual(list.map(\.action), [.usual(id: "low"), .usual(id: "meal-breakfast"),
                                            .newEntry, .openLogbook, .settings])
        XCTAssertEqual(list[0].key, "1")
        XCTAssertEqual(list[1].key, "2")
        XCTAssertTrue(list[0].withOption)
        XCTAssertEqual(list[0].symbol, low().systemImage)
        // A separator between the usuals and the rest.
        XCTAssertEqual(rows[3], .separator)
    }

    func testOnlyTheFirstThreeUsualsAreShown() {
        let usuals = [low(), meal("Toast", carbs: 30), correction(2), meal("Apple", carbs: 15, slot: .snack)]
        let shown = items(MenuBarQuickMenu.rows(usuals: usuals)).filter {
            if case .usual = $0.action { return true } else { return false }
        }
        XCTAssertEqual(shown.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(shown.last?.action, .usual(id: "correction"))
    }

    func testSettingsKeepsCommandComma() {
        let settings = items(MenuBarQuickMenu.rows(usuals: [])).last
        XCTAssertEqual(settings?.action, .settings)
        XCTAssertEqual(settings?.key, ",")
        XCTAssertEqual(settings?.withOption, false)
    }

    func testUsualToolTipSaysNothingIsLoggedYet() {
        let usual = items(MenuBarQuickMenu.rows(usuals: [low()]))[0]
        XCTAssertTrue(usual.toolTip?.contains("Nothing is logged until you do") == true)
    }

    // MARK: Titles

    func testTitlesSayWhatFillsIn() {
        XCTAssertEqual(MenuBarQuickMenu.title(for: meal("Toast and banana", carbs: 45)),
                       "Usual breakfast: Toast and banana · 45 g")
        XCTAssertEqual(MenuBarQuickMenu.title(for: low()), "Treat a low: Jelly beans · 15 g")
        XCTAssertTrue(MenuBarQuickMenu.title(for: correction(2)).hasPrefix("Usual correction: 2"))
    }

    func testALongFoodNameIsCut() {
        let u = meal("Leftover chicken and vegetable stir fry with brown rice and sesame", carbs: 60)
        let title = MenuBarQuickMenu.title(for: u)
        XCTAssertLessThanOrEqual(title.count, MenuBarQuickMenu.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertTrue(title.hasPrefix("Usual breakfast: Leftover"))
    }

    func testAMealLoggedAsCarbsOnlyStillReads() {
        XCTAssertEqual(MenuBarQuickMenu.title(for: meal("", carbs: 30)), "Usual breakfast: 30 g")
    }
}
