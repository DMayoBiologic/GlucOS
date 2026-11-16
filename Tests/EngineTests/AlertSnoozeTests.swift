import XCTest
@testable import GlucOSEngine

// "Log treatment" and "Snooze 30 min" (docs/AlertActions.md). The relay's copy of these rules is
// tested against the same cases in supabase/functions/relay/checkins_test.ts ("snooze: …").
final class AlertSnoozeTests: XCTestCase {
    let now = referenceNow

    func snapshot(_ mgdl: Double, at time: Date) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = reading(time.addingTimeInterval(-30), mgdl, .flat)
        s.history = readings(endingAt: time.addingTimeInterval(-330), minutes: 60) { _ in mgdl }
        return s
    }

    func testUrgentLowsAreNeverSnoozable() {
        var s = AlertSnoozes()
        XCTAssertFalse(s.snooze(.urgentLow, minutes: 30, now: now))
        XCTAssertFalse(s.snooze(.predictedUrgentLow, minutes: 30, now: now))
        XCTAssertEqual(s, AlertSnoozes())
        XCTAssertTrue(s.snooze(.low, minutes: 30, now: now))
        XCTAssertFalse(s.silences(.urgentLow, at: now.addingTimeInterval(60)))
        XCTAssertFalse(s.silences(.predictedUrgentLow, at: now.addingTimeInterval(60)))
        XCTAssertNil(AlertNotice.Kind.urgentLow.snoozeLevel)
        XCTAssertEqual(AlertNotice.Kind.urgentLow.treatment, .low)
        XCTAssertEqual(AlertNotice.Kind.urgentLow.actionCategory, AlertSnoozes.treatOnlyCategory)
    }

    func testALowSnoozeQuietsLowsForThirtyMinutes() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: AlertSnoozes.snoozeMinutes, now: now)
        XCTAssertTrue(s.silences(.low, at: now.addingTimeInterval(29 * 60)))
        XCTAssertTrue(s.silences(.predictedLow, at: now.addingTimeInterval(60)))
        XCTAssertFalse(s.silences(.low, at: now.addingTimeInterval(30 * 60)))
        XCTAssertFalse(s.silences(.high, at: now.addingTimeInterval(60)))
    }

    func testEscalationGetsThroughAHighSnooze() {
        var high = AlertSnoozes()
        high.snooze(.high, minutes: 30, now: now)
        XCTAssertTrue(high.silences(.predictedHigh, at: now.addingTimeInterval(60)))
        XCTAssertFalse(high.silences(.veryHigh, at: now.addingTimeInterval(60)))
        XCTAssertFalse(high.silences(.predictedVeryHigh, at: now.addingTimeInterval(60)))
        var veryHigh = AlertSnoozes()
        veryHigh.snooze(.veryHigh, minutes: 30, now: now)
        XCTAssertTrue(veryHigh.silences(.high, at: now.addingTimeInterval(60)))
        XCTAssertTrue(veryHigh.silences(.predictedVeryHigh, at: now.addingTimeInterval(60)))
    }

    func testSnoozesAreCappedAndNeverShortened() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 600, now: now)
        XCTAssertEqual(s.low, now.timeIntervalSince1970 + 3600)
        s.snooze(.low, minutes: AlertSnoozes.treatingMinutes(.low), now: now)
        XCTAssertEqual(s.low, now.timeIntervalSince1970 + 3600)
        s.prune(now: now.addingTimeInterval(3601))
        XCTAssertEqual(s, AlertSnoozes())
    }

    func testButtonsByKind() {
        XCTAssertEqual(AlertNotice.Kind.low.actionCategory, AlertSnoozes.snoozeAndTreatCategory)
        XCTAssertEqual(AlertNotice.Kind.predictedVeryHigh.actionCategory, AlertSnoozes.snoozeAndTreatCategory)
        XCTAssertEqual(AlertNotice.Kind.high.treatment, .high)
        XCTAssertEqual(AlertNotice.Kind.predictedLow.treatment, .low)
        for k in [AlertNotice.Kind.rapidChange, .stale, .sensorExpiring, .apiBroken] {
            XCTAssertNil(k.actionCategory)
            XCTAssertNil(k.snoozeLevel)
        }
        // The JSON matches the relay's {low, high, veryHigh}.
        var s = AlertSnoozes()
        s.low = 100
        let json = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Double]
        XCTAssertEqual(json, ["low": 100])
    }

    /// A low that lasts 40 minutes, read every minute, snoozed after the first alert: nothing for 30
    /// minutes, then the alert again on the first reading after the snooze rather than a repeat
    /// timer later.
    func testASnoozedLowComesStraightBackWhenTheSnoozeEnds() {
        var planner = AlertPlanner()
        var snoozes = AlertSnoozes()
        let prefs = AlertPreferences()
        var delivered: [TimeInterval] = []
        for minute in 0...40 {
            let t = now.addingTimeInterval(Double(minute * 60))
            let due = planner.evaluate(snapshot(62, at: t), prefs: prefs, now: t)
            if !planner.unsnoozed(due, snoozes: snoozes, now: t).isEmpty { delivered.append(Double(minute)) }
            if minute == 0 { snoozes.snooze(.low, minutes: 30, now: t) }
        }
        XCTAssertEqual(delivered, [0, 30])
    }

    func testAnUrgentLowGetsThroughALowSnooze() {
        var planner = AlertPlanner()
        var snoozes = AlertSnoozes()
        snoozes.snooze(.low, minutes: 30, now: now)
        let t = now.addingTimeInterval(60)
        let due = planner.evaluate(snapshot(50, at: t), prefs: AlertPreferences(), now: t)
        XCTAssertEqual(planner.unsnoozed(due, snoozes: snoozes, now: t).map(\.kind), [.urgentLow])
    }

    /// Round 31: lows and predicted lows show Log treatment and Snooze 30 min, urgent lows Log
    /// treatment only, and the rules behind the buttons are unchanged.
    func testLowAlertButtons() {
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .low), ["Log treatment", "Snooze 30 min"])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .predictedLow), ["Log treatment", "Snooze 30 min"])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .urgentLow), ["Log treatment"])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .predictedUrgentLow), ["Log treatment"])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .high), ["Log treatment", "Snooze 30 min"])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .stale), [])
        XCTAssertEqual(AlertSnoozes.buttonTitles(for: .rapidChange), [])
        // Same identifiers the relay's pushes name, so nothing changes for older builds.
        XCTAssertEqual(AlertSnoozes.treatAction, "alert.treat")
        XCTAssertEqual(AlertSnoozes.snoozeAction, "alert.snooze")
        XCTAssertEqual(AlertNotice.Kind.predictedLow.treatment, .low)
        XCTAssertEqual(AlertSnoozes.treatingMinutes(.low), 15)
    }

    /// Snooze 30 min on a low quiets that low (and the predicted low with it) only: highs, very
    /// highs and urgent lows still fire.
    func testALowSnoozeLeavesOtherAlertsAlone() {
        var s = AlertSnoozes()
        XCTAssertTrue(s.snooze(.predictedLow, minutes: AlertSnoozes.snoozeMinutes, now: now))
        let t = now.addingTimeInterval(60)
        XCTAssertTrue(s.silences(.predictedLow, at: t))
        XCTAssertTrue(s.silences(.low, at: t))
        for kind: AlertNotice.Kind in [.urgentLow, .predictedUrgentLow, .high, .veryHigh, .predictedHigh, .rapidChange] {
            XCTAssertFalse(s.silences(kind, at: t), "\(kind)")
        }
    }
}
