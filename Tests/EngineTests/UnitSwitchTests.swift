import XCTest
@testable import GlucOSEngine

final class UnitSwitchTests: XCTestCase {
    func testShowsTheChosenUnitWhenNotHeld() {
        XCTAssertEqual(UnitSwitch.shown(current: .mmol, chosen: .mgdl, held: false), .mgdl)
        XCTAssertEqual(UnitSwitch.shown(current: .mgdl, chosen: .mmol, held: false), .mmol)
    }

    func testKeepsTheUnitOnScreenWhileHeld() {
        XCTAssertEqual(UnitSwitch.shown(current: .mmol, chosen: .mgdl, held: true), .mmol)
        XCTAssertEqual(UnitSwitch.shown(current: .mgdl, chosen: .mgdl, held: true), .mgdl)
    }

    func testAnnouncesTheNewUnitOnceSpeltOut() {
        XCTAssertEqual(UnitSwitch.announcement(from: .mmol, to: .mgdl), "Now showing milligrams per decilitre")
        XCTAssertEqual(UnitSwitch.announcement(from: .mgdl, to: .mmol), "Now showing millimoles per litre")
    }

    func testSaysNothingWhenTheUnitDidNotChange() {
        XCTAssertNil(UnitSwitch.announcement(from: .mmol, to: .mmol))
        XCTAssertNil(UnitSwitch.announcement(from: .mgdl, to: .mgdl))
    }

    func testPopoverMorphWaitsForItsSectionsToComeIn() {
        let all = Set(PopoverStagger.Section.allCases)
        XCTAssertGreaterThanOrEqual(UnitSwitch.popoverRevealDelay, PopoverStagger.settled(showing: all))
        XCTAssertLessThan(UnitSwitch.popoverRevealDelay, 1)
    }
}
