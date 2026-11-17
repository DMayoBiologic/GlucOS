import XCTest
@testable import GlucOSEngine

/// The one-shot ripple on the chart's current-reading dot (`NewReadingRipple`).
final class NewReadingRippleTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var previous: Date { now.addingTimeInterval(-120) }
    private var fresh: Date { now.addingTimeInterval(-60) }

    private func plays(previous: Date? = nil, newest: Date? = nil, appActive: Bool = true,
                       onScreen: Bool = true, reduceMotion: Bool = false) -> Bool {
        NewReadingRipple.plays(previous: previous, newest: newest, now: now, staleAfter: 6 * 60,
                               appActive: appActive, onScreen: onScreen, reduceMotion: reduceMotion)
    }

    func testANewerFreshReadingRipples() {
        XCTAssertTrue(plays(previous: previous, newest: fresh))
    }

    func testOpeningTheChartDoesNotRipple() {
        XCTAssertFalse(plays(previous: nil, newest: fresh))
        XCTAssertFalse(plays(previous: previous, newest: nil))
    }

    func testSameOrOlderNewestDoesNotRipple() {
        XCTAssertFalse(plays(previous: fresh, newest: fresh))
        XCTAssertFalse(plays(previous: fresh, newest: previous))
    }

    func testAStaleArrivalDoesNotRipple() {
        XCTAssertFalse(plays(previous: now.addingTimeInterval(-3600), newest: now.addingTimeInterval(-7 * 60)))
        XCTAssertTrue(plays(previous: now.addingTimeInterval(-3600), newest: now.addingTimeInterval(-6 * 60)))
    }

    func testBackgroundOffScreenAndReduceMotionHoldStill() {
        XCTAssertFalse(plays(previous: previous, newest: fresh, appActive: false))
        XCTAssertFalse(plays(previous: previous, newest: fresh, onScreen: false))
        XCTAssertFalse(plays(previous: previous, newest: fresh, reduceMotion: true))
    }
}
