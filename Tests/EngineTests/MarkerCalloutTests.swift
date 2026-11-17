import XCTest
@testable import GlucOSEngine

/// What a chart marker's callout says, when a touch is a tap, and where the card sits.
final class MarkerCalloutTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testNoteIsTrimmedFoldedAndCapped() {
        XCTAssertNil(MarkerCallout.note(""))
        XCTAssertNil(MarkerCallout.note("  \n\n  "))
        XCTAssertEqual(MarkerCallout.note("  pizza night  "), "pizza night")
        XCTAssertEqual(MarkerCallout.note("first\n\n\n  second "), "first\nsecond")
        let long = String(repeating: "a", count: 300)
        let cut = MarkerCallout.note(long)!
        XCTAssertEqual(cut.count, MarkerCallout.noteLimit)
        XCTAssertTrue(cut.hasSuffix("…"))
        let exact = String(repeating: "b", count: MarkerCallout.noteLimit)
        XCTAssertEqual(MarkerCallout.note(exact), exact)
    }

    func testContentDropsEmptyAmountAndNote() {
        let c = MarkerCallout.Content(title: "Woke up", amount: "  ", note: " ")
        XCTAssertNil(c.amount)
        XCTAssertNil(c.note)
        XCTAssertEqual(MarkerCallout.Content(title: "Meal", amount: "45 g", note: "toast").note, "toast")
    }

    func testAmounts() {
        XCTAssertEqual(MarkerCallout.doseAmount(units: "4 u", name: "Novorapid", viaPump: false), "4 u Novorapid")
        XCTAssertEqual(MarkerCallout.doseAmount(units: "1.5 u", name: " ", viaPump: true), "1.5 u · Pump")
        XCTAssertEqual(MarkerCallout.mealAmount(grams: "45 g", food: "Toast"), "45 g · Toast")
        XCTAssertEqual(MarkerCallout.mealAmount(grams: "45 g", food: ""), "45 g")
        XCTAssertEqual(MarkerCallout.mealAmount(grams: nil, food: " Apple "), "Apple")
        XCTAssertNil(MarkerCallout.mealAmount(grams: nil, food: ""))
    }

    func testTimeLineSaysWhenAndHowLongAgo() {
        let at = now.addingTimeInterval(-25 * 60)
        XCTAssertEqual(MarkerCallout.timeLine(at, now: now, calendar: utc),
                       "\(ClockLabel.time(at, calendar: utc)) · 25 min ago")
    }

    func testTapVersusHoldVersusScrub() {
        XCTAssertTrue(MarkerCallout.isTap(heldFor: 0.1, dx: 2, dy: 3))
        // Held to the peek: a peek, not a tap.
        XCTAssertFalse(MarkerCallout.isTap(heldFor: MarkerPeek.holdDuration, dx: 0, dy: 0))
        // Slid off the marker: a scrub.
        XCTAssertFalse(MarkerCallout.isTap(heldFor: 0.1, dx: 12, dy: 0))
    }

    func testTappingTogglesOrMoves() {
        XCTAssertEqual(MarkerCallout.toggled(open: nil, tapped: a), a)
        XCTAssertNil(MarkerCallout.toggled(open: a, tapped: a))
        XCTAssertEqual(MarkerCallout.toggled(open: a, tapped: b), b)
    }

    func testCardStaysInsideThePlotAndGrowsFromTheMarker() {
        // Middle of the plot: centred on the marker, growing from its middle.
        XCTAssertEqual(MarkerCallout.centerX(markerX: 200, plotMinX: 0, plotMaxX: 400, width: 200), 200)
        XCTAssertEqual(MarkerCallout.anchorX(markerX: 200, centerX: 200, width: 200), 0.5)
        // Near the left edge: pushed in, growing from the marker's side.
        let left = MarkerCallout.centerX(markerX: 20, plotMinX: 0, plotMaxX: 400, width: 200)
        XCTAssertEqual(left, 100)
        XCTAssertEqual(MarkerCallout.anchorX(markerX: 20, centerX: left, width: 200), 0.1, accuracy: 1e-9)
        // Near the right edge.
        let right = MarkerCallout.centerX(markerX: 395, plotMinX: 0, plotMaxX: 400, width: 200)
        XCTAssertEqual(right, 300)
        XCTAssertEqual(MarkerCallout.anchorX(markerX: 395, centerX: right, width: 200), 0.975, accuracy: 1e-9)
        // A plot narrower than the card: centred on the plot; the anchor never leaves the card.
        XCTAssertEqual(MarkerCallout.centerX(markerX: 10, plotMinX: 0, plotMaxX: 150, width: 200), 75)
        XCTAssertEqual(MarkerCallout.anchorX(markerX: -500, centerX: 75, width: 200), 0)
    }

    func testSpokenForVoiceOver() {
        let at = now
        let time = ClockLabel.time(at, calendar: utc)
        let meal = MarkerCallout.Content(title: "Meal", amount: "45 g · Toast", note: "with butter")
        XCTAssertEqual(MarkerCallout.spoken(meal, date: at, calendar: utc), "Meal, 45 grams, Toast, \(time), has a note")
        let dose = MarkerCallout.Content(title: "Insulin", amount: "1 u Novorapid · Pump")
        XCTAssertEqual(MarkerCallout.spoken(dose, date: at, calendar: utc), "Insulin, 1 unit Novorapid, Pump, \(time)")
        XCTAssertEqual(MarkerCallout.spoken(.init(title: "Woke up"), date: at, calendar: utc), "Woke up, \(time)")
    }
}
