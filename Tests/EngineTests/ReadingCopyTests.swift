import XCTest
@testable import GlucOSEngine

final class ReadingCopyTests: XCTestCase {
    private func copy(minutesOld: Double, mgdl: Double = 110, trend: Trend = .flat, unit: GlucoseUnit = .mmol,
                      name: String? = nil) -> String {
        ReadingCopy.text(mgdl: mgdl, trend: trend, at: referenceNow.addingTimeInterval(-minutesOld * 60),
                         unit: unit, now: referenceNow, name: name, calendar: utc)
    }

    func testFreshReadingHasValueTrendAndAge() {
        XCTAssertEqual(copy(minutesOld: 2), "6.1 mmol/L, steady, 2 min ago")
        XCTAssertEqual(copy(minutesOld: 3.5, mgdl: 72, trend: .fallingQuickly, unit: .mgdl),
                       "72 mg/dL, falling quickly, 3 min ago")
    }

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(copy(minutesOld: 0.4, trend: .rising), "6.1 mmol/L, rising, just now")
    }

    func testUnknownTrendIsLeftOut() {
        XCTAssertEqual(copy(minutesOld: 1, trend: .unknown), "6.1 mmol/L, 1 min ago")
    }

    func testStaleReadingDropsTheTrend() {
        XCTAssertEqual(copy(minutesOld: 8, trend: .rising), "6.1 mmol/L, 8 min ago")
    }

    func testGapUsesTheChartsWords() {
        let at = referenceNow.addingTimeInterval(-12 * 60)
        let time = ClockLabel.time(at, calendar: utc)
        XCTAssertEqual(copy(minutesOld: 12, trend: .rising), "No readings for 12 min · last 6.1 mmol/L at \(time)")
        XCTAssertTrue(copy(minutesOld: 65).hasPrefix("No readings for 1 hr 5 min · last 6.1 mmol/L at "))
    }

    func testGapStartsAtTheChartsMinimum() {
        XCTAssertFalse(copy(minutesOld: 9.9).hasPrefix("No readings"))
        XCTAssertTrue(copy(minutesOld: ReadingGaps.minimum / 60).hasPrefix("No readings for 10 min"))
    }

    func testFollowedPersonIsNamed() {
        XCTAssertEqual(copy(minutesOld: 2, name: "Sam"), "Sam: 6.1 mmol/L, steady, 2 min ago")
        XCTAssertTrue(copy(minutesOld: 20, name: " Sam ").hasPrefix("Sam: No readings for 20 min"))
        XCTAssertEqual(copy(minutesOld: 2, name: "  "), "6.1 mmol/L, steady, 2 min ago")
    }

    func testSnapshotUsesTheUnitOnScreen() {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = reading(referenceNow.addingTimeInterval(-120), 110, .flat)
        XCTAssertEqual(ReadingCopy.text(s, at: referenceNow, calendar: utc), "6.1 mmol/L, steady, 2 min ago")
        XCTAssertEqual(ReadingCopy.text(s, unit: .mgdl, at: referenceNow, calendar: utc), "110 mg/dL, steady, 2 min ago")
        XCTAssertNil(ReadingCopy.text(GlucoseSnapshot(), at: referenceNow))
    }

    func testNeverSaysAnythingButTheReading() {
        let words = ["forecast", "dose", "insulin", "carb", "bolus", "units", "should"]
        for minutes in [0.5, 4.0, 8.0, 15.0, 90.0] {
            let text = copy(minutesOld: minutes, trend: .rising).lowercased()
            for word in words { XCTAssertFalse(text.contains(word), "\(word) in \(text)") }
        }
    }

    func testCopyingIsALightAcknowledgement() {
        XCTAssertEqual(HapticEvent.copied.feel, .lightImpact(intensity: 0.6))
        XCTAssertFalse(HapticEvent.copied.isTick)
        XCTAssertLessThan(HapticEvent.copied.priority, HapticEvent.enteredLow.priority)
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.copied, at: referenceNow))
        // A low warning landing right after still gets through.
        XCTAssertTrue(gate.admit(.enteredLow, at: referenceNow.addingTimeInterval(0.1)))
    }
}
