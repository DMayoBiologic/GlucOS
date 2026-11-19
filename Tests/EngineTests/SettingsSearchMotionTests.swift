import XCTest
@testable import GlucOSEngine

final class SettingsSearchMotionTests: XCTestCase {
    private func anchors(_ query: String) -> [SettingsAnchor] {
        SettingsSearch.results(for: query, in: SettingsCatalog.phone).map(\.anchor)
    }

    func testAFirstSearchStaggersEveryRowTopToBottom() {
        let delays = SettingsSearchMotion.entranceDelays(from: [], to: [.alerts, .lowAlerts, .highAlert])
        XCTAssertEqual(delays[.alerts], 0)
        XCTAssertEqual(delays[.lowAlerts]!, SettingsSearchMotion.staggerStep, accuracy: 1e-9)
        XCTAssertEqual(delays[.highAlert]!, 2 * SettingsSearchMotion.staggerStep, accuracy: 1e-9)
    }

    func testRowsAlreadyListedHoldStill() {
        let delays = SettingsSearchMotion.entranceDelays(from: [.alerts, .lowAlerts], to: [.alerts, .units, .lowAlerts, .relay])
        XCTAssertNil(delays[.alerts])
        XCTAssertNil(delays[.lowAlerts])
        // Only the new rows count towards the stagger, so the first new one doesn't wait.
        XCTAssertEqual(delays[.units], 0)
        XCTAssertEqual(delays[.relay]!, SettingsSearchMotion.staggerStep, accuracy: 1e-9)
    }

    func testNarrowingTheQueryBringsNothingIn() {
        let wide = anchors("al")
        let narrow = anchors("alert")
        XCTAssertFalse(narrow.isEmpty)
        XCTAssertTrue(Set(narrow).isSubset(of: Set(wide)))
        XCTAssertTrue(SettingsSearchMotion.entranceDelays(from: wide, to: narrow).isEmpty)
    }

    func testALongListNeverKeepsTheBottomRowsWaiting() {
        let many = Array(SettingsAnchor.allCases.prefix(20))
        let delays = SettingsSearchMotion.entranceDelays(from: [], to: many)
        let cap = Double(SettingsSearchMotion.maxStaggered - 1) * SettingsSearchMotion.staggerStep
        XCTAssertEqual(delays.count, 20)
        XCTAssertEqual(delays.values.max()!, cap, accuracy: 1e-9)
        XCTAssertLessThan(cap + SettingsSearchMotion.rowEntrance, 0.5)
    }

    func testANewlyMatchedWordGlintsOnceThenSettles() {
        let peak = SettingsSearchMotion.flaredWash(.entering, progress: SettingsSearchMotion.flarePeakAt)
        XCTAssertEqual(peak, SettingsSearchMotion.flarePeak, accuracy: 1e-9)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertEqual(SettingsSearchMotion.flaredWash(.entering, progress: 0), 0)
        XCTAssertEqual(SettingsSearchMotion.flaredWash(.entering, progress: 1), 1, accuracy: 1e-9)
        // Rises to the peak, then only falls back towards resting strength.
        var last = 0.0
        for step in 1...30 {
            let p = Double(step) / 30
            let w = SettingsSearchMotion.flaredWash(.entering, progress: p)
            if p <= SettingsSearchMotion.flarePeakAt { XCTAssertGreaterThanOrEqual(w, last) } else { XCTAssertLessThanOrEqual(w, last + 1e-9) }
            XCTAssertGreaterThanOrEqual(w, 0)
            last = w
        }
    }

    func testKeptAndLeavingWashesMatchTheLogbook() {
        for p in [0.0, 0.25, 0.5, 1.0] {
            XCTAssertEqual(SettingsSearchMotion.flaredWash(.kept, progress: p), LogbookSearchMotion.wash(.kept, progress: p))
            XCTAssertEqual(SettingsSearchMotion.flaredWash(.leaving, progress: p), LogbookSearchMotion.wash(.leaving, progress: p))
        }
    }

    func testOutOfRangeProgressIsClamped() {
        XCTAssertEqual(SettingsSearchMotion.flaredWash(.entering, progress: -1), 0)
        XCTAssertEqual(SettingsSearchMotion.flaredWash(.entering, progress: 2), 1, accuracy: 1e-9)
    }

    func testTheLandingSpringStaysSmall() {
        XCTAssertGreaterThan(SettingsSearchMotion.landingScale, 1)
        XCTAssertLessThanOrEqual(SettingsSearchMotion.landingScale, 1.05)
        XCTAssertLessThan(SettingsSearchMotion.landingDelay + SettingsSearchMotion.landingHold, SettingsSearch.highlightSeconds)
    }
}
