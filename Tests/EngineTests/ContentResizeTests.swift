import XCTest
@testable import GlucOSEngine

/// When the Mac popover and iPhone Today glide to a new height.
final class ContentResizeTests: XCTestCase {
    func testAChipOrNoticeComingOrGoingGlides() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 636, settled: true, reduceMotion: false), .glide)
        XCTAssertEqual(ContentResize.step(from: 636, to: 600, settled: true, reduceMotion: false), .glide)
    }

    func testTheFirstMeasurementSnaps() {
        XCTAssertEqual(ContentResize.step(from: 0, to: 600, settled: true, reduceMotion: false), .snap)
    }

    func testOpeningSnapsEvenAfterContentChangedWhileClosed() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 700, settled: false, reduceMotion: false), .snap)
    }

    func testTextSettlingOnANewReadingSnaps() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 600.5, settled: true, reduceMotion: false), .snap)
        XCTAssertEqual(ContentResize.step(from: 600, to: 603.9, settled: true, reduceMotion: false), .snap)
        XCTAssertEqual(ContentResize.step(from: 600, to: 600 + ContentResize.threshold, settled: true, reduceMotion: false), .glide)
    }

    func testNoChangeSnaps() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 600, settled: true, reduceMotion: false), .snap)
    }

    func testReduceMotionAlwaysSnaps() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 700, settled: true, reduceMotion: true), .snap)
    }

    func testAnEmptyMeasurementSnaps() {
        XCTAssertEqual(ContentResize.step(from: 600, to: 0, settled: true, reduceMotion: false), .snap)
    }
}
