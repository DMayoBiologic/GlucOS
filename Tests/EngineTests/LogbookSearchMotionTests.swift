import XCTest
@testable import GlucOSEngine

final class LogbookSearchMotionTests: XCTestCase {
    private func lit(_ text: String, _ old: [String], _ new: [String]) -> [String] {
        LogbookSearchMotion.spans(in: text, from: old, to: new).map { "\(text[$0.range]):\($0.phase)" }
    }

    func testTheNextLetterFadesInWithoutRelightingTheRest() {
        XCTAssertEqual(lit("Pizza, ham", ["piz"], ["pizz"]), ["Piz:kept", "z:entering"])
    }

    func testANewWordFadesInAndTheOldOneStays() {
        XCTAssertEqual(lit("Pizza, ham and pineapple", ["pizza"], ["pizza", "ham"]),
                       ["Pizza:kept", "ham:entering"])
    }

    func testADeletedWordFadesOut() {
        XCTAssertEqual(lit("Pizza, ham", ["pizza", "ham"], ["pizza"]), ["Pizza:kept", "ham:leaving"])
        XCTAssertEqual(lit("Pizza", ["pizza"], []), ["Pizza:leaving"])
    }

    func testAFirstSearchFadesEverythingIn() {
        XCTAssertEqual(lit("Toast and toast", [], ["toast"]), ["Toast:entering", "toast:entering"])
    }

    func testNothingFoundEitherSideHasNoSpans() {
        XCTAssertTrue(LogbookSearchMotion.spans(in: "Rice", from: ["pasta"], to: ["pizza"]).isEmpty)
        XCTAssertTrue(LogbookSearchMotion.spans(in: "", from: [], to: ["pizza"]).isEmpty)
    }

    func testSpansAreInOrderAndNeverOverlap() {
        let text = "Pizza, pizza crust"
        let spans = LogbookSearchMotion.spans(in: text, from: ["pi"], to: ["pizza", "crust"])
        for (a, b) in zip(spans, spans.dropFirst()) { XCTAssertLessThanOrEqual(a.range.upperBound, b.range.lowerBound) }
        XCTAssertEqual(spans.map { String(text[$0.range]) }.joined(separator: "|"), "Pi|zza|pi|zza|crust")
    }

    func testTheWashFadesBetweenSearches() {
        XCTAssertEqual(LogbookSearchMotion.wash(.kept, progress: 0), 1)
        XCTAssertEqual(LogbookSearchMotion.wash(.entering, progress: 0), 0)
        XCTAssertEqual(LogbookSearchMotion.wash(.entering, progress: 0.5), 0.5)
        XCTAssertEqual(LogbookSearchMotion.wash(.leaving, progress: 0.25), 0.75)
        // Done (or Reduce Motion): only what this search found is lit.
        XCTAssertEqual(LogbookSearchMotion.wash(.entering, progress: 1), 1)
        XCTAssertEqual(LogbookSearchMotion.wash(.leaving, progress: 1), 0)
        XCTAssertEqual(LogbookSearchMotion.wash(.leaving, progress: 3), 0)
        XCTAssertEqual(LogbookSearchMotion.wash(.entering, progress: -1), 0)
    }

    func testOnlyWordsStillFoundAreBold() {
        XCTAssertTrue(LogbookSearchMotion.isBold(.kept))
        XCTAssertTrue(LogbookSearchMotion.isBold(.entering))
        XCTAssertFalse(LogbookSearchMotion.isBold(.leaving))
    }

    func testTheCountReadsLikeTheLabel() {
        XCTAssertNil(LogbookSearchMotion.countLabel(0))
        XCTAssertEqual(LogbookSearchMotion.countLabel(1), "1 found")
        XCTAssertEqual(LogbookSearchMotion.countLabel(14), "14 found")
        XCTAssertEqual(LogbookSearchMotion.announcement(count: 0), "No matches")
        XCTAssertEqual(LogbookSearchMotion.announcement(count: 3), "3 found")
    }

    func testVoiceOverHearsEachPauseOnce() {
        var a = LogbookSearchAnnouncer()
        XCTAssertEqual(a.line(query: "piz", count: 4), "4 found")
        XCTAssertEqual(a.line(query: "pizza", count: 2), "2 found")
        // Typed on, then deleted back to the same search: nothing new to say.
        XCTAssertNil(a.line(query: " Pizza ", count: 2))
        XCTAssertEqual(a.line(query: "pizza x", count: 0), "No matches")
    }

    func testAnEmptyFieldSaysNothingAndStartsAfresh() {
        var a = LogbookSearchAnnouncer()
        XCTAssertEqual(a.line(query: "toast", count: 1), "1 found")
        XCTAssertNil(a.line(query: "  ", count: 30))
        XCTAssertEqual(a.line(query: "toast", count: 1), "1 found")
    }

    func testTheFadeKeepsUpWithTyping() {
        // Done well before the pause VoiceOver waits for.
        XCTAssertLessThan(LogbookSearchMotion.highlightFade, LogbookSearchMotion.pause)
        XCTAssertLessThanOrEqual(LogbookSearchMotion.highlightFade, 0.3)
    }

    func testRowsShrinkOutQuicklyAndOnlyALittle() {
        // Gone before the next keystroke usually lands, and small enough a change to read as a shrink.
        XCTAssertLessThanOrEqual(LogbookSearchMotion.shrinkOut, 0.15)
        XCTAssertGreaterThan(LogbookSearchMotion.leavingScale, 0.85)
        XCTAssertLessThan(LogbookSearchMotion.leavingScale, 1)
    }
}
