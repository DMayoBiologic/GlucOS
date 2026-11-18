import XCTest
@testable import GlucOSEngine

/// "Send a test alert" (docs/TestAlert.md): it looks and sounds like a low alert, but is never
/// logged, snoozed, bannered or counted, and never joins or replaces a real episode's notification.
final class TestAlertTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private var info: [AnyHashable: Any] {
        TestAlert.userInfo(chart: TestAlert.chart(unit: .mmol, lowMgdl: 70, highMgdl: 180, now: t0))
    }

    // MARK: Looks like a low

    func testTitledTestAlertWithTheLowAlertsButtonsAndAChart() {
        XCTAssertEqual(TestAlert.title, "Test alert")
        XCTAssertEqual(TestAlert.imitates, .low)
        XCTAssertEqual(TestAlert.categoryIdentifier, AlertSnoozes.snoozeAndTreatCategory)
        XCTAssertEqual(TestAlert.categoryIdentifier, AlertNotice.Kind.low.actionCategory)
        let chart = AlertChart(userInfo: info)
        XCTAssertNotNil(chart, "the content extension and the Mac picture draw it")
        XCTAssertEqual(chart?.lowMgdl, 70)
        XCTAssertEqual(chart?.highMgdl, 180)
        XCTAssertEqual(chart?.history.count, 37)
        XCTAssertEqual(chart?.history.last, 62)
        XCTAssertEqual(chart?.forecast.count, 12)
        XCTAssertTrue(TestAlert.isTest(info))
    }

    func testSampleIsALowNeverAnUrgentLow() {
        for low in stride(from: 60.0, through: 100, by: 1) {
            let v = TestAlert.sampleMgdl(lowMgdl: low)
            XCTAssertEqual(GlucoseRange.classify(mgdl: v, low: low, high: 180), .low, "low \(low)")
            let chart = TestAlert.chart(unit: .mgdl, lowMgdl: low, highMgdl: 180, now: t0)
            XCTAssertTrue(chart.forecast.allSatisfy { Double($0) >= 54 })
            XCTAssertTrue(chart.history.compactMap { $0 }.allSatisfy { Double($0) >= 54 })
        }
    }

    func testBodySaysItIsASampleInTheUsersUnit() {
        XCTAssertEqual(TestAlert.body(unit: .mgdl, lowMgdl: 70),
                       "Sample low, 62 mg/dL, falling. This is how a low alert looks and sounds. Nothing is logged or snoozed.")
        XCTAssertTrue(TestAlert.body(unit: .mmol, lowMgdl: 70).hasPrefix("Sample low, 3.4 mmol/L"))
    }

    // MARK: Never logged, snoozed, bannered or counted

    func testCarriesNoKindSoNothingReadsItAsAnAlert() {
        XCTAssertNil(info["kind"])
        XCTAssertNil(TestAlert.ownKind(info))
        XCTAssertTrue(AlertEpisodes.Shown.list(from: info[AlertEpisodes.Shown.earlierKey]).isEmpty)
        XCTAssertNil(AlertBanner(kind: info["kind"] as? String, isFollowerCopy: false,
                                 title: TestAlert.title, body: "", firedAt: t0))
    }

    func testStillTurnedAwayIfItEverCarriedAKind() {
        var withKind = info
        withKind["kind"] = AlertNotice.Kind.low.rawValue
        XCTAssertNil(TestAlert.ownKind(withKind))
        // A real low with the same fields is the user's own.
        XCTAssertEqual(TestAlert.ownKind(["kind": "low"]), .low)
        XCTAssertNil(TestAlert.ownKind(["kind": "low", "followID": "abc"]))
        XCTAssertEqual(TestAlert.ownKind(["kind": "low", TestAlert.userInfoKey: false]), .low)
    }

    func testNeverAddsAnAlertRecordSoTheCountPreviewIsUnchanged() {
        // What AlertLogRecorder does as a notification arrives.
        func recorded(_ userInfo: [AnyHashable: Any], at time: Date, into records: inout [AlertRecord]) {
            guard let kind = TestAlert.ownKind(userInfo),
                  let r = AlertLog.fired(kind, at: time, in: records) else { return }
            records.append(r)
        }
        var records: [AlertRecord] = []
        for m in stride(from: 0.0, to: 600, by: 30) { recorded(info, at: at(m), into: &records) }
        XCTAssertTrue(records.isEmpty)

        // A low spell in a week of readings: the preview with the tests sent is the one without.
        let readings = (0..<300).map { i in
            GlucoseReading(timestamp: at(Double(i) * 5), mgdl: (100..<110).contains(i) ? 62 : 110, trend: .flat)
        }
        let now = readings.last!.timestamp
        let before = AlertCountPreview.make(readings: readings, records: [], now: now)!
        let after = AlertCountPreview.make(readings: readings, records: records, now: now)!
        XCTAssertEqual(after.counts(lowMgdl: 70, highMgdl: 180, prefs: AlertPreferences()),
                       before.counts(lowMgdl: 70, highMgdl: 180, prefs: AlertPreferences()))
    }

    // MARK: Never joins or replaces an episode

    func testIdentifierIsNeverAnEpisodesOrAKinds() {
        let id = TestAlert.identifier(now: t0)
        XCTAssertEqual(id, "glucos.test.1800000000")
        for kind in AlertNotice.Kind.allCases {
            XCTAssertNotEqual(id, AlertNotice(kind: kind, title: "", body: "", critical: false).identifier)
            XCTAssertFalse(id.hasPrefix("glucos.\(kind.rawValue)."))
        }
        for side in ["low", "high"] { XCTAssertFalse(id.hasPrefix("glucos.\(side).")) }
    }

    func testARealLowDuringATestKeepsItsOwnEpisode() {
        // A low opens an episode, a test is sent mid-way (it never touches the episodes), and the
        // next repeat still replaces the low's alert, not the test's.
        var e = AlertEpisodes()
        func snap(_ mgdl: Double, _ minute: Double) -> GlucoseSnapshot {
            var s = GlucoseSnapshot()
            s.current = GlucoseReading(timestamp: at(minute), mgdl: mgdl, trend: .flat)
            return s
        }
        _ = e.observe(snap(65, 0), now: at(0))
        let first = e.record(.low, now: at(0))?.identifier
        let untouched = e
        let test = TestAlert.identifier(now: at(5))
        XCTAssertEqual(e, untouched)
        _ = e.observe(snap(62, 15), now: at(15))
        let repeatID = e.record(.low, now: at(15))?.identifier
        XCTAssertEqual(first, repeatID)
        XCTAssertNotEqual(repeatID, test)
        XCTAssertTrue(e.record(.low, now: at(20))?.earlier.allSatisfy { $0.kind == .low } ?? false)
    }

    func testEachTestHasItsOwnIdentifier() {
        XCTAssertNotEqual(TestAlert.identifier(now: at(0)), TestAlert.identifier(now: at(1)))
    }
}
