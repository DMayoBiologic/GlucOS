import XCTest
@testable import GlucOSEngine

/// The reading details card's contents (`ReadingDetails`, round 56).
final class ReadingDetailsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let posix = Locale(identifier: "en_US")
    /// Clock times can use narrow no-break spaces before AM/PM.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func snapshot(current mgdl: Double = 120, trend: Trend = .rising, at time: Date? = nil,
                          previous: (mgdl: Double, minutesBefore: Double)? = (114, 5),
                          source: ReadingSource? = nil) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        let now = time ?? t0
        s.current = GlucoseReading(timestamp: now, mgdl: mgdl, trend: trend)
        if let previous {
            s.history = [GlucoseReading(timestamp: now.addingTimeInterval(-previous.minutesBefore * 60),
                                        mgdl: previous.mgdl, trend: trend)]
        }
        s.source = source
        return s
    }

    func testNoReadingNoDetails() {
        XCTAssertNil(ReadingDetails(snapshot: GlucoseSnapshot(), lastCheck: nil, checkEvery: 60, now: t0))
    }

    func testOldSnapshotsWithoutASourceAreLibreLinkUp() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(), lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.source, .libreLinkUp)
        let relay = try XCTUnwrap(ReadingDetails(snapshot: snapshot(source: .relay), lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(relay.source, .relay)
    }

    func testSourceSurvivesASavedSnapshotAndOldOnesStillDecode() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let saved = try dec.decode(GlucoseSnapshot.self, from: enc.encode(snapshot(source: .sensor)))
        XCTAssertEqual(saved.source, .sensor)
        // A snapshot written before round 56 has no "source" key.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(snapshot())) as? [String: Any])
        json.removeValue(forKey: "source")
        let old = try dec.decode(GlucoseSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.source)
        XCTAssertNotNil(old.current)
    }

    func testRateIsMeasuredAgainstTheReadingFiveMinutesBack() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(), lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.rate, .measured(mgdlPerMinute: 1.2, minutes: 5))
        XCTAssertEqual(d.rateText(unit: .mgdl), "+1.2 mg/dL a minute")
        XCTAssertEqual(d.rateText(unit: .mmol), "+0.07 mmol/L a minute")
        XCTAssertEqual(d.rateCaption, "Over the last 5 min")
    }

    func testFallingRateHasAMinusSign() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(current: 100, trend: .falling, previous: (110, 5)),
                                             lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.rateText(unit: .mgdl), "−2.0 mg/dL a minute")
    }

    func testFlatIsNoChange() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(current: 120, trend: .flat, previous: (120, 5)),
                                             lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.rateText(unit: .mmol), "No change")
    }

    func testOneMinuteWobbleIsNotScaledUp() throws {
        // Only a reading under 4 minutes back: the trend arrow's band instead.
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(previous: (110, 1)), lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.rate, .band(.rising))
        XCTAssertEqual(d.rateText(unit: .mgdl), "About 1–2 mg/dL a minute")
        XCTAssertEqual(d.rateText(unit: .mmol), "About 0.06–0.11 mmol/L a minute")
        XCTAssertEqual(d.rateCaption, "Rising, from the trend arrow")
    }

    func testAnOldPreviousReadingFallsBackToTheBand() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(trend: .risingQuickly, previous: (60, 45)),
                                             lastCheck: t0, checkEvery: 60, now: t0))
        XCTAssertEqual(d.rate, .band(.risingQuickly))
        XCTAssertEqual(d.rateText(unit: .mgdl), "Over 2 mg/dL a minute")
    }

    func testStaleReadingHasNoRateAndIsOverdue() throws {
        let now = t0.addingTimeInterval(GlucoseSnapshot.staleAfter + 60)
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(), lastCheck: now, checkEvery: 60, now: now))
        XCTAssertTrue(d.stale)
        XCTAssertEqual(d.rate, .unavailable)
        XCTAssertEqual(d.nextDue, .overdue(since: t0.addingTimeInterval(60)))
        XCTAssertEqual(plain(d.nextDueText(calendar: utc, locale: posix)), "Overdue since 8:01 AM")
    }

    func testNextReadingIsTheFirstCheckAfterTheSensorsNextMinute() {
        // Checked 10 s after the reading, every 30 s: 40 s is too soon, 70 s brings the next one.
        XCTAssertEqual(ReadingDetails.nextDue(takenAt: t0, stale: false, lastCheck: t0.addingTimeInterval(10),
                                              checkEvery: 30, now: t0.addingTimeInterval(15)),
                       .at(t0.addingTimeInterval(70)))
        // Every 5 minutes: the next check, whenever that is.
        XCTAssertEqual(ReadingDetails.nextDue(takenAt: t0, stale: false, lastCheck: t0.addingTimeInterval(20),
                                              checkEvery: 300, now: t0.addingTimeInterval(30)),
                       .at(t0.addingTimeInterval(320)))
    }

    func testALateCheckIsAnyMoment() {
        XCTAssertEqual(ReadingDetails.nextDue(takenAt: t0, stale: false, lastCheck: t0,
                                              checkEvery: 60, now: t0.addingTimeInterval(90)),
                       .anyMoment)
    }

    func testAgeWords() throws {
        func age(_ secs: TimeInterval) throws -> String {
            try XCTUnwrap(ReadingDetails(snapshot: snapshot(), lastCheck: nil, checkEvery: 60,
                                         now: t0.addingTimeInterval(secs))).ageText
        }
        XCTAssertEqual(try age(2), "just now")
        XCTAssertEqual(try age(42), "42s ago")
        XCTAssertEqual(try age(250), "4m ago")
    }

    func testSpokenAsOneSentence() throws {
        let d = try XCTUnwrap(ReadingDetails(snapshot: snapshot(), lastCheck: t0.addingTimeInterval(10),
                                             checkEvery: 60, now: t0.addingTimeInterval(42)))
        XCTAssertEqual(plain(d.spoken(unit: .mgdl, calendar: utc, locale: posix)),
                       "Reading details. Taken at 8:00 AM, 42s ago. Source, LibreLinkUp. "
                       + "Changing +1.2 mg/dL a minute over the last 5 minutes. Next reading around 8:01 AM")
    }
}
