import XCTest
@testable import GlucOSEngine

/// "Last 7 days: this would have alerted N times (was M)" in Settings (docs/AlertCountPreview.md).
/// Each fixture is a run of 5-minute readings replayed through the real alert rules.
final class AlertCountPreviewTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Six hours of in range readings, then `values` every 5 minutes. Returns the readings and the
    /// minute the first of `values` lands on.
    private func fixture(_ values: [Double], lead: Int = 72, tail: Int = 0) -> (readings: [GlucoseReading], start: Double) {
        let all = Array(repeating: 110.0, count: lead) + values + Array(repeating: 110.0, count: tail)
        let readings = all.enumerated().map { i, v in
            GlucoseReading(timestamp: at(Double(i) * 5), mgdl: v, trend: .flat)
        }
        return (readings, Double(lead) * 5)
    }

    private func preview(_ readings: [GlucoseReading], records: [AlertRecord] = []) -> AlertCountPreview {
        AlertCountPreview.make(readings: readings, records: records,
                                now: readings.map(\.timestamp).max()!)!
    }

    private let prefs = AlertPreferences()

    // MARK: Enough readings

    func testNeedsSixHoursOfReadings() {
        XCTAssertNil(AlertCountPreview.make(readings: [], records: [], now: t0))
        let short = fixture([], lead: 72).readings          // 71 gaps of 5 min: 5 h 55 min
        XCTAssertNil(AlertCountPreview.make(readings: short, records: [], now: short.last!.timestamp))
        let enough = fixture([], lead: 73).readings
        XCTAssertNotNil(AlertCountPreview.make(readings: enough, records: [], now: enough.last!.timestamp))
    }

    func testOnlyTheLastSevenDaysCount() {
        // A low spell eight days ago, then a week of in range readings every 15 minutes.
        var readings = (0..<8).map { GlucoseReading(timestamp: at(Double($0) * 5), mgdl: 60, trend: .flat) }
        let weekStart = 8.0 * 1440
        readings += (0..<(7 * 96)).map { GlucoseReading(timestamp: at(weekStart + Double($0) * 15), mgdl: 110, trend: .flat) }
        let now = readings.last!.timestamp
        let p = AlertCountPreview.make(readings: readings, records: [], now: now)!
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs), .init(low: 0, high: 0))
        XCTAssertEqual(p.days, 7)
        XCTAssertEqual(p.start, at(weekStart))
        XCTAssertEqual(p.readings.count, 7 * 96)
    }

    func testFewerDaysSayHowMany() {
        let readings = fixture([], lead: 24 * 12 * 2 + 30).readings   // 2 days and a bit
        XCTAssertEqual(preview(readings).days, 3)
        XCTAssertEqual(preview(fixture([]).readings + [GlucoseReading(timestamp: at(365), mgdl: 110, trend: .flat)]).days, 1)
    }

    func testReadingsInAnyOrderAndDuplicatesCountOnce() {
        let (readings, _) = fixture(Array(repeating: 65, count: 8))
        let shuffled = (readings + readings.prefix(80)).shuffled()
        XCTAssertEqual(preview(shuffled).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs),
                       preview(readings).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs))
    }

    // MARK: The alert rules

    func testALowSpellRepeatsOnTheRepeatTimer() {
        // 40 minutes at 65: alerts at 0, 15 and 30 minutes in with the 15-minute repeat.
        let p = preview(fixture(Array(repeating: 65, count: 8), tail: 4).readings)
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 3)
        // A lower limit leaves 65 in range.
        XCTAssertEqual(p.counts(lowMgdl: 63, highMgdl: 180, prefs: prefs).low, 0)
        // A 30-minute repeat: 0 and 30 minutes in.
        var slower = prefs
        slower.cooldownMinutes = 30
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: slower).low, 2)
    }

    func testComingBackIntoRangeResetsTheRepeatTimer() {
        // Low, in range for one reading, low again 10 minutes after the first alert.
        let p = preview(fixture([65, 72, 66], tail: 2).readings)
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 2)
        // With the limit at 74 the middle reading is low too, so the timer holds: one alert.
        XCTAssertEqual(p.counts(lowMgdl: 74, highMgdl: 180, prefs: prefs).low, 1)
    }

    func testRaisingTheHighLimitCountsFewerHighs() {
        // An hour at 200 then an hour at 190.
        let values = Array(repeating: 200.0, count: 12) + Array(repeating: 190, count: 12)
        let p = preview(fixture(values, tail: 2).readings)
        // 180: one spell, 2 hours, every 15 minutes.
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).high, 8)
        // 195: only the first hour.
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 195, prefs: prefs).high, 4)
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 210, prefs: prefs).high, 0)
    }

    func testUrgentLowsAndVeryHighsAlwaysCount() {
        // 20 minutes under 54 and 20 minutes over 250, apart.
        let values = Array(repeating: 50.0, count: 4) + Array(repeating: 110, count: 4) + Array(repeating: 260, count: 4)
        let p = preview(fixture(values, tail: 2).readings)
        // Urgent lows repeat every 5 minutes; very highs on the 15-minute timer.
        let c = p.counts(lowMgdl: 60, highMgdl: 240, prefs: prefs)
        XCTAssertEqual(c, .init(low: 4, high: 2))
        // Turning high alerts off still leaves very highs.
        var noHigh = prefs
        noHigh.high = false
        XCTAssertEqual(p.counts(lowMgdl: 60, highMgdl: 180, prefs: noHigh).high, 2)
        XCTAssertEqual(p.counts(lowMgdl: 60, highMgdl: 180, prefs: prefs).high, 2)
    }

    func testHighAlertsOffCountsNoPlainHighs() {
        let p = preview(fixture(Array(repeating: 200, count: 8), tail: 2).readings)
        var noHigh = prefs
        noHigh.high = false
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: noHigh).high, 0)
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).high, 3)
    }

    func testAlertsOffCountNothing() {
        let p = preview(fixture(Array(repeating: 50, count: 8)).readings)
        var off = prefs
        off.enabled = false
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: off), .init())
    }

    func testOtherAlertsAreNotCounted() {
        // Falling fast through range, then a gap long enough to go stale: neither is a low or high.
        var readings = fixture([]).readings
        let last = readings.last!.timestamp
        readings += [GlucoseReading(timestamp: last.addingTimeInterval(300), mgdl: 100, trend: .fallingQuickly),
                     GlucoseReading(timestamp: last.addingTimeInterval(3600), mgdl: 100, trend: .flat)]
        XCTAssertEqual(preview(readings).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs), .init())
    }

    // MARK: Snoozes

    func testASnoozeTappedThenQuietsItsLevelAndFiresWhenItEnds() {
        // An hour at 65: 0, 15, 30, 45 minutes in without a snooze.
        let (readings, s) = fixture(Array(repeating: 65, count: 12), tail: 2)
        XCTAssertEqual(preview(readings).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 4)
        // "Snooze 30 min" a minute after the first: quiet until 31 minutes in, then due on the
        // next reading (35) and 15 minutes after (50).
        let tap = AlertRecord(kind: .low, firedAt: at(s), response: .snoozed, respondedAt: at(s + 1), snoozeMinutes: 30)
        XCTAssertEqual(preview(readings, records: [tap]).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 3)
        // "Log treatment" quiets a low for 15 minutes: 0, then 20 (released at 15), then 35, 50.
        let treat = AlertRecord(kind: .low, firedAt: at(s), response: .treating, respondedAt: at(s + 1), snoozeMinutes: 15)
        XCTAssertEqual(preview(readings, records: [treat]).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 4)
    }

    func testASnoozeNeverQuietsUrgentLowsOrTheOtherSide() {
        let values = Array(repeating: 50.0, count: 4) + Array(repeating: 200, count: 4)
        let (readings, s) = fixture(values, tail: 2)
        let lowTap = AlertRecord(kind: .low, firedAt: at(s), response: .snoozed, respondedAt: at(s), snoozeMinutes: 30)
        let plain = preview(readings).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs)
        XCTAssertEqual(preview(readings, records: [lowTap]).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs), plain)
        // A very-high snooze quiets highs too.
        let vhTap = AlertRecord(kind: .veryHigh, firedAt: at(s), response: .snoozed, respondedAt: at(s), snoozeMinutes: 60)
        XCTAssertEqual(preview(readings, records: [vhTap]).counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).high, 0)
    }

    func testUnansweredAlertsAndOldTapsAreIgnored() {
        let (readings, s) = fixture(Array(repeating: 65, count: 12), tail: 2)
        let unanswered = AlertRecord(kind: .low, firedAt: at(s))
        let ancient = AlertRecord(kind: .low, firedAt: at(-20_000), response: .snoozed,
                                  respondedAt: at(-20_000), snoozeMinutes: 30)
        let p = preview(readings, records: [unanswered, ancient])
        XCTAssertTrue(p.snoozes.isEmpty)
        XCTAssertEqual(p.counts(lowMgdl: 70, highMgdl: 180, prefs: prefs).low, 4)
    }

    // MARK: Wording

    func testTheLine() {
        XCTAssertEqual(AlertCountLine.text(days: 7, count: 3, was: 5), "Last 7 days: this would have alerted 3 times (was 5)")
        XCTAssertEqual(AlertCountLine.text(days: 7, count: 3, was: 3), "Last 7 days: this would have alerted 3 times")
        XCTAssertEqual(AlertCountLine.text(days: 7, count: 1, was: nil), "Last 7 days: this would have alerted once")
        XCTAssertEqual(AlertCountLine.text(days: 3, count: 0, was: 2), "Last 3 days: this would not have alerted (was 2)")
        XCTAssertEqual(AlertCountLine.text(days: 1, count: 2, was: nil), "Last day: this would have alerted 2 times")
    }

    func testWhatVoiceOverSays() {
        XCTAssertEqual(AlertCountLine.spoken(.low, days: 7, count: 3, was: 5),
                       "Low alerts, last 7 days: this limit would have alerted 3 times, down from 5")
        XCTAssertEqual(AlertCountLine.spoken(.high, days: 7, count: 6, was: 2),
                       "High alerts, last 7 days: this limit would have alerted 6 times, up from 2")
        XCTAssertEqual(AlertCountLine.spoken(.high, days: 7, count: 0, was: 0),
                       "High alerts, last 7 days: this limit would not have alerted")
    }
}
