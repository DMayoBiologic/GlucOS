import XCTest
@testable import GlucOSEngine

/// Opening a Logbook entry in the edit sheet (docs/LogbookSearch.md "Editing an entry"): each
/// surface keys its own zoom source, Reduce Motion is a plain cross-fade, and VoiceOver focus
/// waits for the sheet to land.
final class LogbookEditMorphTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testSourceIsStableForAnEntry() {
        XCTAssertEqual(LogbookEditMorph.sourceID(.row, a), LogbookEditMorph.sourceID(.row, a))
    }

    func testEverySurfaceAndEntryHasItsOwnSource() {
        var seen = Set<String>()
        for surface in LogbookEditMorph.Surface.allCases {
            for id in [a, b] { seen.insert(LogbookEditMorph.sourceID(surface, id)) }
        }
        XCTAssertEqual(seen.count, LogbookEditMorph.Surface.allCases.count * 2)
    }

    func testSourcesNeverCollideWithTheLastLoggedZoom() {
        // The "last logged" line zooms into the Logbook on its own fixed id.
        for surface in LogbookEditMorph.Surface.allCases {
            XCTAssertNotEqual(LogbookEditMorph.sourceID(surface, a), "logbook-last-logged")
        }
    }

    func testReduceMotionIsAPlainCrossFade() {
        XCTAssertEqual(LogbookEditMorph.Style(reduceMotion: false), .morph)
        XCTAssertEqual(LogbookEditMorph.Style(reduceMotion: true), .crossFade)
        XCTAssertEqual(LogbookEditMorph.macStartScale(reduceMotion: true), 1)
        XCTAssertLessThan(LogbookEditMorph.macStartScale(reduceMotion: false), 1)
        XCTAssertGreaterThan(LogbookEditMorph.macStartScale(reduceMotion: false), 0.9)
    }

    func testFadesAreShort() {
        for reduce in [false, true] {
            let d = LogbookEditMorph.fadeDuration(reduceMotion: reduce)
            XCTAssertGreaterThan(d, 0)
            XCTAssertLessThanOrEqual(d, 0.3)
        }
    }

    func testTitleFocusWaitsForTheSheetToLand() {
        XCTAssertGreaterThan(LogbookEditMorph.titleFocusDelay(reduceMotion: false),
                             LogbookEditMorph.fadeDuration(reduceMotion: false))
        XCTAssertGreaterThan(LogbookEditMorph.titleFocusDelay(reduceMotion: true),
                             LogbookEditMorph.fadeDuration(reduceMotion: true))
        XCTAssertLessThan(LogbookEditMorph.titleFocusDelay(reduceMotion: false), 1)
    }

    func testScrimIsLight() {
        XCTAssertGreaterThan(LogbookEditMorph.macScrimOpacity, 0)
        XCTAssertLessThan(LogbookEditMorph.macScrimOpacity, 0.3)
    }
}
