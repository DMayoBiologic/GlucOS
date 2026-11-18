import XCTest
@testable import GlucOSEngine

/// What the chart marker peek card offers, when a hold turns into it, and what VoiceOver hears.
final class MarkerActionsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testWakeUpsAndNotesOnlyOfferEdit() {
        XCTAssertEqual(MarkerActions.actions(for: .wake), [.edit])
        XCTAssertEqual(MarkerActions.actions(for: .note), [.edit])
        XCTAssertEqual(MarkerActions.hint(.edit, kind: .note), "Opens this note in the log sheet.")
        for kind in [MarkerPop.Kind.meal, .treatment, .insulin] {
            XCTAssertEqual(MarkerActions.actions(for: kind), [.edit, .logAgainNow])
        }
        XCTAssertEqual(MarkerActions.actions(for: nil), [.edit, .logAgainNow])
    }

    func testPinComesWellAfterThePeek() {
        // A quick look and let go still only peeks.
        XCTAssertGreaterThanOrEqual(MarkerActions.pinAfter, MarkerPeek.holdDuration + 0.3)
        // And before the system's own long press would have taken over on a hold elsewhere, the
        // menu has already stood down (MarkerPeekPressKey), so the pin is never beaten to it.
        XCTAssertLessThan(MarkerActions.pinAfter, 1.5)
    }

    func testPinsOnlyWhenHeldStillLongEnough() {
        XCTAssertFalse(MarkerActions.pins(heldFor: MarkerPeek.holdDuration, dx: 0, dy: 0))
        XCTAssertFalse(MarkerActions.pins(heldFor: MarkerActions.pinAfter - 0.01, dx: 0, dy: 0))
        XCTAssertTrue(MarkerActions.pins(heldFor: MarkerActions.pinAfter, dx: 0, dy: 0))
        XCTAssertTrue(MarkerActions.pins(heldFor: 2, dx: 6, dy: 6))
        // Slid off: that was a scrub, never a card.
        XCTAssertFalse(MarkerActions.pins(heldFor: 2, dx: MarkerPeek.holdSlop + 1, dy: 0))
    }

    func testTitlesAndSymbols() {
        XCTAssertEqual(MarkerActions.Action.edit.title, "Edit")
        XCTAssertEqual(MarkerActions.Action.logAgainNow.title, "Log Again Now")
        XCTAssertEqual(MarkerActions.Action.edit.systemImage, "pencil")
        XCTAssertEqual(MarkerActions.Action.logAgainNow.systemImage, "arrow.clockwise")
    }

    func testHintsNameTheEntry() {
        XCTAssertEqual(MarkerActions.hint(.edit, kind: .meal), "Opens this meal in the log sheet.")
        XCTAssertEqual(MarkerActions.hint(.logAgainNow, kind: .insulin), "Logs this dose again at the current time.")
        XCTAssertEqual(MarkerActions.hint(.logAgainNow, kind: .treatment), "Logs this treatment again at the current time.")
        XCTAssertEqual(MarkerActions.hint(.edit, kind: .wake), "Opens this wake-up in the log sheet.")
        XCTAssertEqual(MarkerActions.hint(.edit, kind: nil), "Opens this entry in the log sheet.")
    }

    func testLoggedAgainAnnouncement() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let time = ClockLabel.time(at, calendar: utc)
        XCTAssertEqual(MarkerActions.loggedAgain(kind: .meal, at: at, calendar: utc), "Meal logged again at \(time).")
        XCTAssertEqual(MarkerActions.loggedAgain(kind: nil, at: at, calendar: utc), "Entry logged again at \(time).")
    }

    /// Nothing on the card works anything out: it never offers to change an amount.
    func testNoDosingWords() {
        let words = MarkerActions.Action.allCases.map(\.title)
            + MarkerPop.Kind.allCases.flatMap { k in MarkerActions.Action.allCases.map { MarkerActions.hint($0, kind: k) } }
        for w in words {
            for banned in ["suggest", "recommend", "correction", "bolus", "should"] {
                XCTAssertFalse(w.lowercased().contains(banned), w)
            }
        }
    }
}
