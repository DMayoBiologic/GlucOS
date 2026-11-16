import XCTest
@testable import GlucOSEngine

/// The cold-launch handover from the saved reading to the first live one (`LaunchReading`).
final class LaunchReadingTests: XCTestCase {
    func testSavedReadingWaitsForThisLaunchsFirstFetch() {
        XCTAssertEqual(LaunchReading.phase(hasReading: true, fetchedThisLaunch: false, warmingUp: false), .stored)
        XCTAssertEqual(LaunchReading.phase(hasReading: true, fetchedThisLaunch: true, warmingUp: false), .live)
    }

    func testNothingSavedOrWarmingUpIsNeverStored() {
        // The waiting card and the warm-up countdown have their own words; there's no figure to dim.
        XCTAssertEqual(LaunchReading.phase(hasReading: false, fetchedThisLaunch: false, warmingUp: false), .live)
        XCTAssertEqual(LaunchReading.phase(hasReading: true, fetchedThisLaunch: false, warmingUp: true), .live)
    }

    func testStaleSavedReadingKeepsTheStaleLookInsteadOfDimming() {
        XCTAssertTrue(LaunchReading.stored.dims(stale: false))
        XCTAssertFalse(LaunchReading.stored.dims(stale: true))
        XCTAssertFalse(LaunchReading.live.dims(stale: false))
        XCTAssertLessThan(LaunchReading.storedOpacity, 1)
        XCTAssertGreaterThan(LaunchReading.storedOpacity, 0.3)
    }

    func testNoSpinnerWhileTheSavedReadingWaits() {
        XCTAssertFalse(LaunchReading.stored.showsSpinner(isRefreshing: true))
        XCTAssertTrue(LaunchReading.live.showsSpinner(isRefreshing: true))
        XCTAssertFalse(LaunchReading.live.showsSpinner(isRefreshing: false))
    }

    func testSavedReadingIsNeverUpdated() {
        XCTAssertEqual(LaunchReading.stored.ageLead(stale: false), "Last reading")
        XCTAssertEqual(LaunchReading.stored.ageLead(stale: true), "Last reading")
        XCTAssertEqual(LaunchReading.live.ageLead(stale: false), "Updated")
        XCTAssertEqual(LaunchReading.live.ageLead(stale: true), "Last reading")
        XCTAssertNotNil(LaunchReading.stored.spokenNote)
        XCTAssertNil(LaunchReading.live.spokenNote)
    }

    func testHandoverIsOneFadeWithNoRipple() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(300)
        // The first fetch brings a newer reading: the cross-fade alone, no ripple on top.
        XCTAssertFalse(LaunchReading.playsRipple(from: (t0, .stored), to: (t1, .live), reduceMotion: false))
        // Later readings ripple as before.
        XCTAssertTrue(LaunchReading.playsRipple(from: (t0, .live), to: (t1, .live), reduceMotion: false))
        XCTAssertFalse(LaunchReading.playsRipple(from: (t0, .live), to: (t1, .live), reduceMotion: true))
        XCTAssertFalse(LaunchReading.playsRipple(from: (t0, .live), to: (t0, .live), reduceMotion: false))
        XCTAssertFalse(LaunchReading.playsRipple(from: (nil, .live), to: (t1, .live), reduceMotion: false))
    }
}
