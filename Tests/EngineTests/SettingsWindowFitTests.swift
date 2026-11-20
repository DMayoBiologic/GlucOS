import XCTest
@testable import GlucOSEngine

/// How the Mac Settings window fits a newly picked tab.
final class SettingsWindowFitTests: XCTestCase {
    func testAShortTabShrinksTheWindowToFit() {
        // 600 pt window, 540 pt scroll view, content wants 470.
        let height = SettingsWindowFit.fittedHeight(window: 600, container: 540, needed: 470, chrome: 60, screenHeight: 1000)
        XCTAssertEqual(height, 530)
    }

    func testALongTabGrowsUpToTheCap() {
        let height = SettingsWindowFit.fittedHeight(window: 600, container: 540, needed: 2000, chrome: 60, screenHeight: 1000)
        XCTAssertEqual(height, SettingsWindowFit.maximumWindowHeight)
    }

    func testNeverSmallerThanTheMinimum() {
        let height = SettingsWindowFit.fittedHeight(window: 600, container: 540, needed: 100, chrome: 60, screenHeight: 1000)
        XCTAssertEqual(height, SettingsWindowFit.minimumContentHeight + 60)
    }

    func testASmallScreenCapsTheHeight() {
        let height = SettingsWindowFit.fittedHeight(window: 600, container: 540, needed: 2000, chrome: 60, screenHeight: 640)
        XCTAssertEqual(height, 640)
    }

    func testTheTopEdgeStaysPut() {
        let y = SettingsWindowFit.originY(top: 900, height: 500, visibleMinY: 0, visibleMaxY: 1000)
        XCTAssertEqual(y, 400)
    }

    func testGrowingPastTheScreenBottomRaisesTheWindow() {
        let y = SettingsWindowFit.originY(top: 650, height: 760, visibleMinY: 25, visibleMaxY: 900)
        XCTAssertEqual(y, 25)
    }

    func testNothingHappensBeforeTheWindowSettles() {
        XCTAssertNil(SettingsWindowFit.step(from: 600, to: 500, settled: false, reduceMotion: false))
    }

    func testASwitchGlidesOrSnapsUnderReduceMotion() {
        XCTAssertEqual(SettingsWindowFit.step(from: 600, to: 500, settled: true, reduceMotion: false), .glide)
        XCTAssertEqual(SettingsWindowFit.step(from: 600, to: 500, settled: true, reduceMotion: true), .snap)
    }

    func testTheSameHeightLeavesTheWindowAlone() {
        XCTAssertNil(SettingsWindowFit.step(from: 600, to: 600, settled: true, reduceMotion: false))
    }
}
