import XCTest
@testable import GlucOSEngine

/// iPhone haptics: one meaning, one feel, and no double buzz when two moments land together
/// (docs/Redesign.md §7.3, docs/DesignSystem.md rule 7).
final class HapticRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testEachMeaningHasOneFeel() {
        XCTAssertEqual(HapticEvent.choice.feel, .selection)
        XCTAssertEqual(HapticEvent.done.feel, .success)
        XCTAssertEqual(HapticEvent.backInRange.feel, .success)
        XCTAssertEqual(HapticEvent.enteredLow.feel, .warning)
        XCTAssertEqual(HapticEvent.followerNeedsHelp.feel, .warning)
        // Undo feels the same wherever it is (the deleted-entry toast and the question cards).
        XCTAssertEqual(HapticEvent.undone.feel, .lightImpact(intensity: 0.8))
        XCTAssertEqual(HapticEvent.newData.feel, .lightImpact(intensity: 0.8))
        XCTAssertEqual(HapticEvent.scrubRangeEdge.feel, .lightImpact(intensity: 0.9))
        XCTAssertEqual(HapticEvent.scrubLogged.feel, .lightImpact(intensity: 0.6))
        XCTAssertEqual(HapticEvent.rangeCrossed.feel, .lightImpact(intensity: 0.7))
        // Saving from the log sheet is a light tap under the checkmark, not a success buzz.
        XCTAssertEqual(HapticEvent.logSaved.feel, .lightImpact(intensity: 0.7))
    }

    func testALogSavedTapIsAnOutcome() {
        XCTAssertEqual(HapticEvent.logSaved.priority, HapticEvent.done.priority)
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.logSaved, at: t0))
        // A scrub tick or a second save landing with it doesn't buzz again.
        XCTAssertFalse(gate.admit(.scrubLogged, at: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(gate.admit(.logSaved, at: t0.addingTimeInterval(0.2)))
        // A low warning still gets through.
        XCTAssertTrue(gate.admit(.enteredLow, at: t0.addingTimeInterval(0.2)))
    }

    func testWarningsOutrankOutcomesOutrankAcknowledgements() {
        XCTAssertGreaterThan(HapticEvent.enteredLow.priority, HapticEvent.backInRange.priority)
        XCTAssertGreaterThan(HapticEvent.done.priority, HapticEvent.newData.priority)
        XCTAssertGreaterThan(HapticEvent.newData.priority, HapticEvent.scrubLogged.priority)
    }

    func testFirstEventAlwaysPlays() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.newData, at: t0))
    }

    func testPullRefreshTapAfterALowWarningIsHeldBack() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.enteredLow, at: t0))
        XCTAssertFalse(gate.admit(.newData, at: t0.addingTimeInterval(0.1)))
    }

    func testLowWarningStillComesThroughRightAfterAPullRefreshTap() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.newData, at: t0))
        XCTAssertTrue(gate.admit(.enteredLow, at: t0.addingTimeInterval(0.1)))
    }

    func testTheSameOutcomeTwiceInARowBuzzesOnce() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.done, at: t0))
        XCTAssertFalse(gate.admit(.done, at: t0.addingTimeInterval(0.2)))
        XCTAssertFalse(gate.admit(.undone, at: t0.addingTimeInterval(0.3)))
        // Once the quiet gap has passed, it plays again.
        XCTAssertTrue(gate.admit(.done, at: t0.addingTimeInterval(0.2 + HapticGate.quietGap)))
    }

    func testHeldBackEventsDontExtendTheQuietGap() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.done, at: t0))
        XCTAssertFalse(gate.admit(.done, at: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(gate.admit(.done, at: t0.addingTimeInterval(HapticGate.quietGap + 0.01)))
    }

    func testQuickTicksEachPlay() {
        var gate = HapticGate()
        // Tapping a stepper or scrubbing past several markers quickly still ticks each time.
        for i in 0..<5 {
            XCTAssertTrue(gate.admit(.choice, at: t0.addingTimeInterval(Double(i) * 0.1)))
        }
        XCTAssertTrue(gate.admit(.scrubLogged, at: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(gate.admit(.scrubRangeEdge, at: t0.addingTimeInterval(0.6)))
        // But not two in the same instant.
        XCTAssertFalse(gate.admit(.scrubRangeEdge, at: t0.addingTimeInterval(0.62)))
    }

    func testAScrubTickRightAfterASaveIsHeldBack() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.done, at: t0))
        XCTAssertFalse(gate.admit(.scrubRangeEdge, at: t0.addingTimeInterval(0.1)))
    }

    func testClockGoingBackwardsDoesntSilenceHaptics() {
        var gate = HapticGate()
        XCTAssertTrue(gate.admit(.done, at: t0))
        XCTAssertTrue(gate.admit(.done, at: t0.addingTimeInterval(-60)))
    }

    /// Every iPhone haptic goes through `Haptics` / `.haptic`, so the gate sees all of them and
    /// nothing reaches past the System Haptics switch.
    func testNoHapticsBypassTheSharedHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let banned = ["sensoryFeedback(", "UISelectionFeedbackGenerator", "UINotificationFeedbackGenerator",
                      "UIImpactFeedbackGenerator", "CHHapticEngine", "AudioServicesPlaySystemSound"]
        var offenders: [String] = []
        for dir in ["Sources/iOS", "Sources/Shared", "Sources/iOSWidget", "Sources/iOSMessages", "Sources/iOSIntents"] {
            let url = root.appendingPathComponent(dir)
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard file.lastPathComponent != "HapticFeedback.swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for term in banned where code.contains(where: { $0.contains(term) }) {
                    offenders.append("\(file.lastPathComponent): \(term)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
