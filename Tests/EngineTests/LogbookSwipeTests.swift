import XCTest
@testable import GlucOSEngine

/// Logbook row swipes on iPhone (docs/LogbookSearch.md "Swiping a row"): the icons follow the finger,
/// one tick per crossing, and Log Again Now never logs on letting go.
final class LogbookSwipeTests: XCTestCase {
    private let width = 390.0

    func testLogAgainNeverLogsOnRelease() {
        // However far or fast, letting go of a right swipe at most leaves the button open.
        for offset in [10.0, 40, 76, 120, 300] {
            for velocity in [0.0, 500, 2_000, 5_000] {
                let release = LogbookSwipe.release(offset: offset, velocity: velocity, rowWidth: width)
                XCTAssertNotEqual(release, .delete)
                XCTAssertTrue(release == .close || release == .open(.logAgain), "\(offset) \(velocity)")
            }
        }
        XCTAssertEqual(LogbookSwipe.release(offset: 80, velocity: 0, rowWidth: width), .open(.logAgain))
        XCTAssertEqual(LogbookSwipe.release(offset: 20, velocity: 0, rowWidth: width), .close)
        XCTAssertEqual(LogbookSwipe.release(offset: 20, velocity: 1_200, rowWidth: width), .open(.logAgain))
        XCTAssertEqual(LogbookSwipe.release(offset: 80, velocity: -1_200, rowWidth: width), .close)
    }

    func testFullLeftSwipeDeletesShortOneOpens() {
        let threshold = LogbookSwipe.deleteThreshold(rowWidth: width)
        XCTAssertEqual(threshold, width * 0.55, accuracy: 0.001)
        XCTAssertEqual(LogbookSwipe.release(offset: -threshold - 1, velocity: 0, rowWidth: width), .delete)
        XCTAssertEqual(LogbookSwipe.release(offset: -60, velocity: 0, rowWidth: width), .open(.delete))
        XCTAssertEqual(LogbookSwipe.release(offset: -20, velocity: 0, rowWidth: width), .close)
        // A flick back the other way shuts it, even past the threshold.
        XCTAssertEqual(LogbookSwipe.release(offset: -threshold - 1, velocity: 1_500, rowWidth: width), .close)
        // A narrow row still needs a real swipe.
        XCTAssertEqual(LogbookSwipe.deleteThreshold(rowWidth: 100), LogbookSwipe.deleteMinimum)
    }

    func testRowResistsPastLogAgain() {
        XCTAssertEqual(LogbookSwipe.offset(translation: 50, rowWidth: width), 50)
        XCTAssertEqual(LogbookSwipe.offset(translation: 176, rowWidth: width), 76 + 100 * 0.3, accuracy: 0.001)
        // From an open button, the drag adds to where it sits.
        XCTAssertEqual(LogbookSwipe.offset(translation: -30, base: 76, rowWidth: width), 46)
        // Left follows the finger to the row's edge, no further.
        XCTAssertEqual(LogbookSwipe.offset(translation: -1_000, rowWidth: width), -width)
    }

    func testIconsGrowAndFadeWithDistance() {
        let small = LogbookSwipe.iconScale(offset: 5, rowWidth: width, reduceMotion: false)
        let mid = LogbookSwipe.iconScale(offset: 38, rowWidth: width, reduceMotion: false)
        let full = LogbookSwipe.iconScale(offset: 76, rowWidth: width, reduceMotion: false)
        XCTAssertLessThan(small, mid)
        XCTAssertLessThan(mid, full)
        XCTAssertEqual(full, 1, accuracy: 0.001)
        XCTAssertEqual(LogbookSwipe.iconScale(offset: 0, rowWidth: width, reduceMotion: false), LogbookSwipe.smallestScale)
        XCTAssertEqual(LogbookSwipe.iconOpacity(offset: 0, reduceMotion: false), 0)
        XCTAssertGreaterThan(LogbookSwipe.iconOpacity(offset: 40, reduceMotion: false), 0)
        XCTAssertEqual(LogbookSwipe.iconOpacity(offset: -76, reduceMotion: false), 1)
        // The trash grows a touch once letting go would delete; Log Again Now never does.
        XCTAssertEqual(LogbookSwipe.iconScale(offset: -300, rowWidth: width, reduceMotion: false), LogbookSwipe.armedScale)
        XCTAssertEqual(LogbookSwipe.iconScale(offset: 120, rowWidth: width, reduceMotion: false), 1, accuracy: 0.001)
    }

    func testReduceMotionShowsIconsAtOnce() {
        XCTAssertEqual(LogbookSwipe.iconScale(offset: 3, rowWidth: width, reduceMotion: true), 1)
        XCTAssertEqual(LogbookSwipe.iconScale(offset: -300, rowWidth: width, reduceMotion: true), 1)
        XCTAssertEqual(LogbookSwipe.iconOpacity(offset: 3, reduceMotion: true), 1)
        XCTAssertEqual(LogbookSwipe.iconOpacity(offset: 0, reduceMotion: true), 0)
    }

    func testTickOncePerCrossingWithHysteresis() {
        var tick = LogbookSwipe.Tick()
        // On the right it ticks where letting go starts leaving the button open.
        XCTAssertEqual(LogbookSwipe.commitThreshold(.logAgain, rowWidth: width), 38)
        XCTAssertFalse(tick.update(offset: 30, rowWidth: width))
        XCTAssertTrue(tick.update(offset: 39, rowWidth: width))
        XCTAssertEqual(LogbookSwipe.release(offset: 39, velocity: 0, rowWidth: width), .open(.logAgain))
        // Resting at the edge or wobbling inside the hysteresis doesn't tick again.
        XCTAssertFalse(tick.update(offset: 42, rowWidth: width))
        XCTAssertFalse(tick.update(offset: 30, rowWidth: width))
        XCTAssertFalse(tick.update(offset: 39, rowWidth: width))
        // Coming well back re-arms it.
        XCTAssertFalse(tick.update(offset: 20, rowWidth: width))
        XCTAssertTrue(tick.update(offset: 40, rowWidth: width))
        // Left ticks at the delete point, not the open point.
        tick.reset()
        XCTAssertFalse(tick.update(offset: -100, rowWidth: width))
        XCTAssertTrue(tick.update(offset: -LogbookSwipe.deleteThreshold(rowWidth: width), rowWidth: width))
        XCTAssertFalse(tick.update(offset: 0, rowWidth: width))
        XCTAssertFalse(tick.armed)
    }

    func testRestingPlaces() {
        XCTAssertEqual(LogbookSwipe.restingOffset(.close, rowWidth: width), 0)
        XCTAssertEqual(LogbookSwipe.restingOffset(.open(.logAgain), rowWidth: width), 76)
        XCTAssertEqual(LogbookSwipe.restingOffset(.open(.delete), rowWidth: width), -76)
        XCTAssertEqual(LogbookSwipe.restingOffset(.delete, rowWidth: width), -width)
    }
}
