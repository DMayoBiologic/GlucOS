import XCTest
@testable import GlucOSEngine

/// Plain notes on the glucose chart: the one line VoiceOver and the peek card use, and the lane.
final class ChartNoteTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testExcerptIsTheFirstLineTrimmed() {
        XCTAssertNil(ChartNote.excerpt(""))
        XCTAssertNil(ChartNote.excerpt("  \n \n"))
        XCTAssertEqual(ChartNote.excerpt("  Felt shaky  "), "Felt shaky")
        XCTAssertEqual(ChartNote.excerpt("\n\n  Felt shaky\nafter the walk"), "Felt shaky")
    }

    func testExcerptIsCappedWithAnEllipsis() {
        let exact = String(repeating: "a", count: ChartNote.excerptLimit)
        XCTAssertEqual(ChartNote.excerpt(exact), exact)
        let cut = ChartNote.excerpt(String(repeating: "a", count: 200))!
        XCTAssertEqual(cut.count, ChartNote.excerptLimit)
        XCTAssertTrue(cut.hasSuffix("…"))
        // The label is shorter than the callout's own cap, which shows more of it.
        XCTAssertLessThan(ChartNote.excerptLimit, MarkerCallout.noteLimit)
    }

    func testLabelIsOneLinePerNote() {
        let time = ClockLabel.time(at, calendar: utc)
        XCTAssertEqual(ChartNote.label("Felt shaky\nafter the walk", at: at, calendar: utc), "Note at \(time): Felt shaky")
        XCTAssertNil(ChartNote.label("   ", at: at, calendar: utc))
    }

    func testLaneMovesUpOnlyNextToAWakeUp() {
        XCTAssertEqual(ChartNote.lane(at: at, wakes: []), ChartNote.lane)
        XCTAssertEqual(ChartNote.lane(at: at, wakes: [at.addingTimeInterval(-5 * 60)]), ChartNote.lane + 1)
        XCTAssertEqual(ChartNote.lane(at: at, wakes: [at.addingTimeInterval(ChartNote.crowding)]), ChartNote.lane)
        XCTAssertEqual(ChartNote.lane(at: at, wakes: [at.addingTimeInterval(-2 * 3600)]), ChartNote.lane)
    }

    /// Notes only say what was typed: nothing worked out about doses.
    func testNoDosingWords() {
        let words = [MarkerPop.Kind.note.title, ChartNote.label("x", at: at, calendar: utc)!]
            + MarkerActions.actions(for: .note).map { MarkerActions.hint($0, kind: .note) }
        for w in words {
            for banned in ["suggest", "recommend", "correction", "bolus", "should"] {
                XCTAssertFalse(w.lowercased().contains(banned), w)
            }
        }
    }
}
