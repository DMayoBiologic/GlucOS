import XCTest
@testable import GlucOSEngine

/// The calm "No readings for N min" state on the widgets, StandBy, the Lock Screen and the Live
/// Activity (`WidgetGap`, docs/ReadingGaps.md "On widgets").
final class WidgetGapTests: XCTestCase {
    /// A reading `minutesOld` old; the app's last good check `checkedMinutesAgo` ago (nil: never).
    private func snapshot(minutesOld: Double, checkedMinutesAgo: Double? = 0) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        s.current = reading(referenceNow.addingTimeInterval(-minutesOld * 60), 110, .flat)
        s.sensor = SensorInfo(serial: "0M0001", activated: referenceNow.addingTimeInterval(-5 * 86_400), lifetimeDays: 15)
        s.fetchedAt = checkedMinutesAgo.map { referenceNow.addingTimeInterval(-$0 * 60) } ?? .distantPast
        return s
    }

    private func reason(_ s: GlucoseSnapshot) -> WidgetGap.Reason?? {
        WidgetGap.state(s, at: referenceNow).map(\.reason)
    }

    func testStartsWhereTheChartsGapsDo() {
        XCTAssertEqual(WidgetGap.after, ReadingGaps.minimum)
        XCTAssertNil(WidgetGap.state(snapshot(minutesOld: 9.9), at: referenceNow))
        XCTAssertNotNil(WidgetGap.state(snapshot(minutesOld: 10), at: referenceNow))
        XCTAssertNil(WidgetGap.state(.empty, at: referenceNow), "never a reading is its own state")
    }

    func testHeadlinesUseTheChartsLengths() {
        let s = WidgetGap.state(snapshot(minutesOld: 12), at: referenceNow)!
        XCTAssertEqual(WidgetGap.headline(s), "No readings for 12 min")
        XCTAssertEqual(WidgetGap.compactHeadline(s), "No readings for 12m")
        let long = WidgetGap.state(snapshot(minutesOld: 65), at: referenceNow)!
        XCTAssertEqual(WidgetGap.headline(long), "No readings for 1 hr 5 min")
        XCTAssertEqual(WidgetGap.compactHeadline(long), "No readings for 1h 5m")
    }

    func testCheckingWithNothingNewIsNoSignal() {
        XCTAssertEqual(reason(snapshot(minutesOld: 20, checkedMinutesAgo: 0)), .some(.noSignal))
        // Half the stretch checked is enough, as in the chart.
        XCTAssertEqual(reason(snapshot(minutesOld: 20, checkedMinutesAgo: 10)), .some(.noSignal))
    }

    func testNotCheckedForMostOfItSaysSince() {
        let s = snapshot(minutesOld: 60, checkedMinutesAgo: 50)
        XCTAssertEqual(reason(s), .some(.notChecked(since: s.fetchedAt)))
        let title = WidgetGap.Reason.notChecked(since: s.fetchedAt).title(calendar: utc)
        XCTAssertEqual(title, "Not checked since \(ClockLabel.time(s.fetchedAt, calendar: utc))")
        let never = WidgetGap.state(snapshot(minutesOld: 20, checkedMinutesAgo: nil), at: referenceNow)
        XCTAssertNotNil(never)
        XCTAssertNil(never?.reason, "never checked: no reason")
    }

    func testFailingChecksSayCantConnect() {
        var s = snapshot(minutesOld: 20)
        s.lastError = "offline"
        XCTAssertEqual(reason(s), .some(.cantConnect))
        XCTAssertEqual(StandByGlance.caption(s, at: referenceNow), "Can't connect · 20 min")
    }

    func testSensorReasonsComeFirst() {
        var ended = snapshot(minutesOld: 20)
        ended.sensor = SensorInfo(serial: "0M0001",
                                  activated: referenceNow.addingTimeInterval(-15 * 86_400 - 22 * 60), lifetimeDays: 15)
        ended.lastError = "offline"
        XCTAssertEqual(reason(ended), .some(.sensorEnded))

        var warming = snapshot(minutesOld: 40)
        warming.sensor = SensorInfo(serial: "0M0002", activated: referenceNow.addingTimeInterval(-30 * 60), lifetimeDays: 15)
        XCTAssertEqual(reason(warming), .some(.warmUp))
    }

    func testTitlesMatchTheChartCard() {
        XCTAssertEqual(WidgetGap.Reason.warmUp.title(), ReadingGaps.Reason.warmUp.title)
        XCTAssertEqual(WidgetGap.Reason.sensorEnded.title(), ReadingGaps.Reason.sensorEnded.title)
        XCTAssertEqual(WidgetGap.Reason.noSignal.title(), ReadingGaps.Reason.noSignal.title)
    }

    func testSpokenIsOneCalmSentencePlusWhatToDo() {
        let s = WidgetGap.state(snapshot(minutesOld: 12), at: referenceNow)!
        XCTAssertEqual(WidgetGap.spoken(s), "No readings for 12 minutes: No signal from LibreLinkUp.")
        let unknown = WidgetGap.state(snapshot(minutesOld: 12, checkedMinutesAgo: nil), at: referenceNow)!
        XCTAssertEqual(WidgetGap.spoken(unknown, last: "The last reading was 6.1."),
                       "No readings for 12 minutes. The last reading was 6.1.")
        var failing = snapshot(minutesOld: 12)
        failing.lastError = "offline"
        let f = WidgetGap.state(failing, at: referenceNow)!
        XCTAssertTrue(WidgetGap.spoken(f).hasSuffix("Open GlucOS to reconnect."))
    }

    func testRectangularCaption() {
        XCTAssertNil(AccessoryGlance.gapCaption(snapshot(minutesOld: 8), at: referenceNow))
        XCTAssertEqual(AccessoryGlance.gapCaption(snapshot(minutesOld: 12), at: referenceNow), "No signal")
        XCTAssertEqual(AccessoryGlance.gapCaption(snapshot(minutesOld: 12, checkedMinutesAgo: nil), at: referenceNow), "No readings")
        // Withdrawn with no reason: the bottom line already says it.
        XCTAssertNil(AccessoryGlance.gapCaption(snapshot(minutesOld: 45, checkedMinutesAgo: nil), at: referenceNow))
    }

    func testNoDosingWords() {
        let reasons: [WidgetGap.Reason] = [.warmUp, .sensorEnded, .cantConnect, .noSignal, .notChecked(since: referenceNow)]
        for r in reasons {
            let words = (r.title(calendar: utc) + " " + r.short + " " + (r.spokenHint ?? "")).lowercased()
            for banned in ["insulin", "dose", "bolus", "carb", "eat", "treat"] {
                XCTAssertFalse(words.contains(banned), "\(r): \(banned)")
            }
        }
    }

    func testLiveActivityNamesTheTime() {
        let s = snapshot(minutesOld: 12)
        let state = GlucoseActivityState.make(from: s, now: referenceNow)!
        XCTAssertEqual(state.noReadingsLine(calendar: utc),
                       "No readings since \(ClockLabel.time(s.current!.timestamp, calendar: utc))")
    }

    // MARK: Motion

    func testMotionKeyIsTheReadingUntilTheGapStarts() {
        let before = WidgetGapMotion.key(snapshot(minutesOld: 9.9), at: referenceNow)
        XCTAssertEqual(before, .init(phase: .reading, minutes: 0))
        XCTAssertEqual(WidgetGapMotion.key(snapshot(minutesOld: 2), at: referenceNow), before,
                       "fresh and stale share one phase: nothing fades before 10 minutes")
        XCTAssertEqual(WidgetGapMotion.key(.empty, at: referenceNow).phase, .reading)
        XCTAssertEqual(WidgetGapMotion.key(snapshot(minutesOld: 10), at: referenceNow),
                       .init(phase: .gap, minutes: 10))
    }

    func testMotionMinutesMatchTheWordsAndStepOncePerMinute() {
        for old in [12.0, 13, 47, 65] {
            let s = snapshot(minutesOld: old)
            let key = WidgetGapMotion.key(s, at: referenceNow)
            XCTAssertEqual(key.minutes, Int(old))
            let words = WidgetGap.headline(WidgetGap.state(s, at: referenceNow)!)
            if old < 60 { XCTAssertTrue(words.contains("\(Int(old)) min"), words) }
        }
        XCTAssertNotEqual(WidgetGapMotion.key(snapshot(minutesOld: 12), at: referenceNow),
                          WidgetGapMotion.key(snapshot(minutesOld: 13), at: referenceNow),
                          "each per-minute entry rolls the digits")
    }

    func testReadingsResumingReturnToTheReadingPhase() {
        var s = snapshot(minutesOld: 25)
        XCTAssertEqual(WidgetGapMotion.key(s, at: referenceNow).phase, .gap)
        s.current = reading(referenceNow.addingTimeInterval(-60), 120, .flat)
        XCTAssertEqual(WidgetGapMotion.key(s, at: referenceNow), .init(phase: .reading, minutes: 0))
    }
}
