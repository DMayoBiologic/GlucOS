import XCTest
@testable import GlucOSEngine

final class HomeQuickActionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usual(_ id: String, _ kind: UsualGlance.Kind, until: Date? = nil) -> UsualGlance {
        UsualGlance(id: id, kind: kind, title: "Usual \(id)", detail: "Toast and banana · 45 g",
                    systemImage: "fork.knife", spoken: "Usual \(id)", until: until)
    }

    // MARK: The list

    func testSensorPhoneGetsFourInHomeScreenOrder() {
        let items = HomeQuickAction.items(mode: .sensor, at: now)
        XCTAssertEqual(items.map(\.title), ["Log treatment", "Log meal", "Log insulin", "What's my glucose"])
        XCTAssertEqual(items.map(\.destination), [.treating(.low), .log(.food), .log(.insulin), .today])
        XCTAssertLessThanOrEqual(items.count, HomeQuickAction.limit)
    }

    func testUsualMealTakesLogMealsPlace() {
        let meal = usual("meal-breakfast", .meal, until: now.addingTimeInterval(3600))
        let items = HomeQuickAction.items(mode: .sensor, usuals: [meal], at: now)
        XCTAssertEqual(items.count, HomeQuickAction.limit, "iOS shows four at most")
        XCTAssertEqual(items.map(\.type), ["glucos.quick.log-treatment", "glucos.quick.usual.meal-breakfast",
                                           "glucos.quick.log-insulin", "glucos.quick.latest-reading"])
        XCTAssertEqual(items[1].title, "Usual meal-breakfast")
        XCTAssertEqual(items[1].subtitle, "Toast and banana · 45 g")
        XCTAssertEqual(items[1].symbol, "fork.knife")
        XCTAssertEqual(items[1].destination, .usual(id: "meal-breakfast"))
    }

    func testTopUsualSkipsCorrectionsLowsAndEndedMeals() {
        // A usual correction is a dose and only lasts while a fresh high does; Treat a low is what
        // Log treatment already fills in. Neither goes on the Home Screen.
        let correction = usual("correction", .correction)
        let low = usual("low", .low)
        let ended = usual("meal-breakfast", .meal, until: now)
        XCTAssertNil(HomeQuickAction.topUsual([correction, low, ended], at: now))
        XCTAssertEqual(HomeQuickAction.items(mode: .sensor, usuals: [correction, low, ended], at: now),
                       HomeQuickAction.items(mode: .sensor, at: now))

        let lunch = usual("meal-lunch", .meal, until: now.addingTimeInterval(60))
        XCTAssertEqual(HomeQuickAction.topUsual([low, correction, lunch], at: now)?.id, "meal-lunch")
        XCTAssertEqual(HomeQuickAction.topUsual([usual("meal-snack", .meal)], at: now)?.id, "meal-snack",
                       "a meal with no end stays")
    }

    func testListFollowsTheUsualsAsTheyChange() {
        let breakfast = usual("meal-breakfast", .meal, until: now.addingTimeInterval(600))
        let before = HomeQuickAction.items(mode: .sensor, usuals: [breakfast], at: now)
        let after = HomeQuickAction.items(mode: .sensor, usuals: [usual("meal-lunch", .meal)], at: now)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after[1].type, "glucos.quick.usual.meal-lunch")
        // The slot ending puts Log meal back.
        XCTAssertEqual(HomeQuickAction.items(mode: .sensor, usuals: [breakfast], at: now.addingTimeInterval(600))[1].type,
                       "glucos.quick.log-meal")
    }

    func testFollowerPhoneGetsOnlyTheReading() {
        let items = HomeQuickAction.items(mode: .follower, usuals: [usual("meal-lunch", .meal)], at: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.type, "glucos.quick.latest-reading")
        XCTAssertEqual(items.first?.title, "Latest readings")
        XCTAssertEqual(items.first?.destination, .today)
    }

    func testUndecidedPhoneGetsNone() {
        XCTAssertEqual(HomeQuickAction.items(mode: .unset, usuals: [usual("meal-lunch", .meal)], at: now), [])
    }

    // MARK: Each action

    func testEachActionOpensTheRightPlace() {
        // The same low sheet as Siri, the control and the alert's button; never a log by itself.
        XCTAssertEqual(HomeQuickAction.logTreatment.destination, .treating(.low))
        XCTAssertEqual(HomeQuickAction.logMeal.destination, .log(.food))
        // An empty dose step: no units filled in.
        XCTAssertEqual(HomeQuickAction.logInsulin.destination, .log(.insulin))
        XCTAssertEqual(HomeQuickAction.latestReading.destination, .today)
        XCTAssertEqual(HomeQuickAction.origin, .homeScreen)
        XCTAssertEqual(HomeQuickAction.allCases.filter(\.logs), [.logTreatment, .logMeal, .logInsulin])
    }

    func testTypesRoundTripAndAreUnique() {
        for action in HomeQuickAction.allCases {
            XCTAssertEqual(HomeQuickAction(type: action.type), action)
            XCTAssertTrue(action.type.hasPrefix("glucos.quick."))
            XCTAssertFalse(action.subtitle.isEmpty)
            XCTAssertFalse(action.symbol.isEmpty)
        }
        XCTAssertEqual(Set(HomeQuickAction.allCases.map(\.type)).count, HomeQuickAction.allCases.count)
        // iOS keeps the items between launches, so the strings must not drift.
        XCTAssertEqual(HomeQuickAction.logTreatment.type, "glucos.quick.log-treatment")
        XCTAssertEqual(HomeQuickAction.logMeal.type, "glucos.quick.log-meal")
        XCTAssertEqual(HomeQuickAction.logInsulin.type, "glucos.quick.log-insulin")
        XCTAssertEqual(HomeQuickAction.latestReading.type, "glucos.quick.latest-reading")
    }

    // MARK: A tapped item

    func testUnknownTypesDoNothing() {
        XCTAssertNil(HomeQuickAction(type: "log-meal"), "the bare raw value isn't an item type")
        XCTAssertNil(HomeQuickAction(type: "glucos.quick."))
        XCTAssertNil(HomeQuickAction(type: "glucos.quick.usual.meal-lunch"), "a usual isn't a fixed action")
        XCTAssertNil(HomeQuickAction(type: "com.apple.shortcut"))
        XCTAssertNil(HomeQuickAction.resolve(type: "glucos.quick.nope", mode: .sensor))
        XCTAssertNil(HomeQuickAction.resolve(type: "glucos.quick.usual.", mode: .sensor))
        XCTAssertNil(HomeQuickAction.resolve(type: "com.apple.shortcut", mode: .sensor))
    }

    func testResolveOnASensorPhone() {
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.log-treatment", mode: .sensor), .treating(.low))
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.log-insulin", mode: .sensor), .log(.insulin))
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.latest-reading", mode: .sensor), .today)
        // A usual's item still opens its entry after the list moved on: the sheet re-checks it.
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.usual.meal-dinner", mode: .sensor),
                       .usual(id: "meal-dinner"))
    }

    func testFollowerAndUndecidedPhonesIgnoreLeftoverLoggingItems() {
        // Items iOS still shows from before the phone switched to following.
        for action in HomeQuickAction.allCases where action.logs {
            XCTAssertNil(HomeQuickAction.resolve(type: action.type, mode: .follower))
        }
        XCTAssertNil(HomeQuickAction.resolve(type: "glucos.quick.usual.meal-lunch", mode: .follower))
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.latest-reading", mode: .follower), .today)
        for action in HomeQuickAction.allCases {
            XCTAssertNil(HomeQuickAction.resolve(type: action.type, mode: .unset))
        }
    }

    func testHomeScreenCaption() {
        XCTAssertEqual(LogOrigin.homeScreen.caption, "Logged from the Home Screen")
    }
}
