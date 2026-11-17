import XCTest
@testable import GlucOSEngine

/// Episode keying for low and high alerts (docs/AlertEpisodes.md). The relay's copy is tested with
/// the same numbers in supabase/functions/relay/episodes_test.ts.
final class AlertEpisodesTests: XCTestCase {
    let t0 = referenceNow

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func snapshot(_ mgdl: Double, minute: Double, unit: GlucoseUnit = .mgdl) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = unit
        s.current = reading(at(minute), mgdl)
        return s
    }

    /// One reading through the planner and the episodes, the way AlertManager does it. Returns the
    /// identifiers of the alerts shown and the summaries due.
    func step(_ p: inout AlertPlanner, _ e: inout AlertEpisodes, _ mgdl: Double, minute: Double,
              prefs: AlertPreferences = AlertPreferences()) -> (ids: [String], ended: [AlertEpisodes.BackInRange]) {
        let s = snapshot(mgdl, minute: minute)
        let now = at(minute).addingTimeInterval(30)
        let ended = e.observe(s, now: now)
        let ids = p.evaluate(s, prefs: prefs, now: now).map { e.identifier(for: $0, now: now) }
        return (ids, ended)
    }

    func testAlertsFromOneLowShareAnIdentifierAndTheNextLowGetsItsOwn() {
        var p = AlertPlanner(), e = AlertEpisodes()
        let m0 = step(&p, &e, 80, minute: 0)
        XCTAssertEqual(m0.ids, [])
        let m5 = step(&p, &e, 65, minute: 5)
        XCTAssertEqual(m5.ids, ["glucos.low.1789999500"])
        let m10 = step(&p, &e, 60, minute: 10)
        XCTAssertEqual(m10.ids, [])
        let m15 = step(&p, &e, 58, minute: 15)
        XCTAssertEqual(m15.ids, [])
        // The 15-minute repeat replaces the first alert instead of stacking under it.
        let m20 = step(&p, &e, 61, minute: 20)
        XCTAssertEqual(m20.ids, ["glucos.low.1789999500"])
        let m25 = step(&p, &e, 68, minute: 25)
        XCTAssertEqual(m25.ids, [])
        let back = step(&p, &e, 82, minute: 30)
        XCTAssertEqual(back.ids, [])
        XCTAssertEqual(back.ended.count, 1)
        let b = back.ended[0]
        XCTAssertEqual(b.identifier, "glucos.low.1789999500")
        XCTAssertEqual(b.minutes, 25)
        XCTAssertEqual(b.title(), "Back in range after 25 min")
        XCTAssertEqual(b.body(unit: .mgdl), "Lowest 58 mg/dL, now 82 mg/dL.")
        XCTAssertEqual(b.shown.map(\.kind), [.low, .low])
        XCTAssertNil(e.low)
        // A later low is a new episode, so its alert stacks rather than replacing the summary.
        let next = step(&p, &e, 66, minute: 60)
        XCTAssertEqual(next.ids, ["glucos.low.1790002800"])
    }

    func testSummaryIsInTheUsersUnitAndHighsSayHighest() {
        var e = AlertEpisodes()
        _ = e.observe(snapshot(200, minute: 0), now: at(0))
        _ = e.record(.high, now: at(0))
        _ = e.observe(snapshot(262, minute: 40), now: at(40))
        _ = e.record(.veryHigh, now: at(40))
        _ = e.observe(snapshot(240, minute: 80), now: at(80))
        let ended = e.observe(snapshot(170, minute: 95, unit: .mmol), now: at(95))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0].title(), "Back in range after 1 h 35 min")
        XCTAssertEqual(ended[0].body(unit: .mmol), "Highest 14.5 mmol/L, now 9.4 mmol/L.")
        XCTAssertEqual(ended[0].identifier, "glucos.high.1789999200")
    }

    func testUrgentLowJoinsTheLowAndStaysCritical() {
        var p = AlertPlanner(), e = AlertEpisodes()
        let s = snapshot(65, minute: 0)
        _ = e.observe(s, now: at(0.5))
        let low = p.evaluate(s, prefs: AlertPreferences(), now: at(0.5))
        XCTAssertEqual(low.map { e.identifier(for: $0, now: at(0.5)) }, ["glucos.low.1789999200"])
        let u = snapshot(50, minute: 5)
        _ = e.observe(u, now: at(5.5))
        let urgent = p.evaluate(u, prefs: AlertPreferences(), now: at(5.5))
        XCTAssertEqual(urgent.map(\.kind), [.urgentLow])
        // Replacing changes only where it shows: the urgent low keeps its sound and level.
        XCTAssertTrue(urgent[0].critical)
        XCTAssertEqual(e.identifier(for: urgent[0], now: at(5.5)), "glucos.low.1789999200")
        XCTAssertEqual(e.low?.extremeMgdl, 50)
    }

    func testOtherAlertsKeepTheirOwnIdentifiers() {
        var e = AlertEpisodes()
        for kind in [AlertNotice.Kind.rapidChange, .stale, .sensorExpiring, .apiBroken] {
            XCTAssertNil(AlertEpisodes.side(of: kind))
            XCTAssertNil(e.record(kind, now: t0))
            let n = AlertNotice(kind: kind, title: "", body: "", critical: false)
            XCTAssertEqual(e.identifier(for: n, now: t0), "glucos.\(kind.rawValue)")
        }
        XCTAssertNil(e.low)
        XCTAssertNil(e.high)
        for kind in AlertNotice.Kind.allCases where kind.treatment != nil {
            XCTAssertNotNil(AlertEpisodes.side(of: kind), "\(kind) has alert buttons, so it belongs to an episode")
        }
    }

    func testNoSummaryWhenNothingWasShown() {
        var e = AlertEpisodes()
        // High alerts switched off: the high is tracked but nothing was shown, so nothing to update.
        _ = e.observe(snapshot(200, minute: 0), now: at(0))
        XCTAssertNotNil(e.high)
        XCTAssertEqual(e.observe(snapshot(150, minute: 30), now: at(30)), [])
        XCTAssertNil(e.high)
    }

    func testAHeadsUpOpensTheEpisodeAndTheLowJoinsIt() {
        var e = AlertEpisodes()
        _ = e.observe(snapshot(85, minute: 0), now: at(0))
        XCTAssertEqual(e.record(.predictedLow, now: at(0))?.identifier, "glucos.low.1789999200")
        // Still in range a reading later: the heads-up stays open, so its repeat replaces it.
        XCTAssertEqual(e.observe(snapshot(78, minute: 5), now: at(5)), [])
        XCTAssertNotNil(e.low)
        _ = e.observe(snapshot(66, minute: 15), now: at(15))
        let low = e.record(.low, now: at(15))
        XCTAssertEqual(low?.identifier, "glucos.low.1789999200")
        XCTAssertEqual(low?.earlier.map(\.kind), [.predictedLow])
        let ended = e.observe(snapshot(75, minute: 35), now: at(35))
        XCTAssertEqual(ended.map(\.minutes), [20])
    }

    func testAHeadsUpThatNeverCameTrueEndsQuietly() {
        var e = AlertEpisodes()
        _ = e.record(.predictedHigh, now: at(0))
        XCTAssertEqual(e.observe(snapshot(150, minute: 44), now: at(44)), [])
        XCTAssertNotNil(e.high)
        XCTAssertEqual(e.observe(snapshot(150, minute: 45), now: at(45)), [])
        XCTAssertNil(e.high)
    }

    func testALongGapInReadingsEndsTheEpisodeWithoutASummary() {
        var e = AlertEpisodes()
        _ = e.observe(snapshot(60, minute: 0), now: at(0))
        _ = e.record(.low, now: at(0))
        XCTAssertEqual(e.observe(snapshot(100, minute: 31), now: at(31)), [])
        XCTAssertNil(e.low)
    }

    func testStaleReadingsChangeNothing() {
        var e = AlertEpisodes()
        _ = e.observe(snapshot(60, minute: 0), now: at(0))
        _ = e.record(.low, now: at(0))
        XCTAssertEqual(e.observe(snapshot(100, minute: 5), now: at(20)), [])
        XCTAssertNotNil(e.low)
    }

    func testGoingStraightToTheOtherSideEndsTheEpisodeQuietly() {
        var e = AlertEpisodes()
        _ = e.observe(snapshot(60, minute: 0), now: at(0))
        _ = e.record(.low, now: at(0))
        XCTAssertEqual(e.observe(snapshot(190, minute: 5), now: at(5)), [])
        XCTAssertNil(e.low)
        XCTAssertNotNil(e.high)
    }

    func testEarlierAlertsRoundTripThroughUserInfoAndAreCapped() {
        var e = AlertEpisodes()
        for i in 0..<15 { _ = e.record(.low, now: at(Double(i * 5))) }
        let last = e.record(.urgentLow, now: at(80))
        XCTAssertEqual(last?.earlier.count, AlertEpisodes.shownLimit)
        let value: Any = last!.earlier.map(\.userInfoValue)
        let back = AlertEpisodes.Shown.list(from: value)
        XCTAssertEqual(back, last!.earlier)
        // As decoded from a push payload's JSON.
        let json = try! JSONSerialization.jsonObject(with: Data(#"[["low", 1789999200], ["nope", 1], ["urgentLow"]]"#.utf8))
        XCTAssertEqual(AlertEpisodes.Shown.list(from: json), [AlertEpisodes.Shown(kind: .low, at: t0)])
        XCTAssertEqual(AlertEpisodes.Shown.list(from: nil), [])
    }

    func testDurations() {
        XCTAssertEqual(AlertEpisodes.duration(1), "1 min")
        XCTAssertEqual(AlertEpisodes.duration(59), "59 min")
        XCTAssertEqual(AlertEpisodes.duration(60), "1 h")
        XCTAssertEqual(AlertEpisodes.duration(125), "2 h 5 min")
    }
}
