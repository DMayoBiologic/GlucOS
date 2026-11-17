import XCTest
@testable import GlucOSEngine

final class HomeQuickActionTests: XCTestCase {
    func testOffersThreeItemsInHomeScreenOrder() {
        XCTAssertEqual(HomeQuickAction.offered(logsOwnReadings: true), [.logTreatment, .logMeal, .latestReading])
        XCTAssertEqual(HomeQuickAction.offered(logsOwnReadings: true).map(\.title),
                       ["Log treatment", "Log meal", "Latest reading"])
    }

    func testFollowerPhoneGetsNone() {
        XCTAssertEqual(HomeQuickAction.offered(logsOwnReadings: false), [])
    }

    func testEachActionOpensTheRightPlace() {
        // The same low sheet as Siri, the control and the alert's button; never a log by itself.
        XCTAssertEqual(HomeQuickAction.logTreatment.destination, .treating(.low))
        XCTAssertEqual(HomeQuickAction.logMeal.destination, .log(.food))
        XCTAssertEqual(HomeQuickAction.latestReading.destination, .today)
        XCTAssertEqual(HomeQuickAction.origin, .homeScreen)
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
        XCTAssertEqual(HomeQuickAction.latestReading.type, "glucos.quick.latest-reading")
    }

    func testUnknownTypesDoNothing() {
        XCTAssertNil(HomeQuickAction(type: "log-meal"), "the bare raw value isn't an item type")
        XCTAssertNil(HomeQuickAction(type: "glucos.quick."))
        XCTAssertNil(HomeQuickAction(type: "glucos.quick.log-insulin"))
        XCTAssertNil(HomeQuickAction(type: "com.apple.shortcut"))
        XCTAssertNil(HomeQuickAction.resolve(type: "glucos.quick.nope", logsOwnReadings: true))
    }

    func testResolveFollowsThePhonesMode() {
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.log-treatment", logsOwnReadings: true), .logTreatment)
        XCTAssertEqual(HomeQuickAction.resolve(type: "glucos.quick.latest-reading", logsOwnReadings: true), .latestReading)
        // An item iOS still shows from before the phone switched to following.
        for action in HomeQuickAction.allCases {
            XCTAssertNil(HomeQuickAction.resolve(type: action.type, logsOwnReadings: false))
        }
    }

    func testHomeScreenCaption() {
        XCTAssertEqual(LogOrigin.homeScreen.caption, "Logged from the Home Screen")
    }
}
