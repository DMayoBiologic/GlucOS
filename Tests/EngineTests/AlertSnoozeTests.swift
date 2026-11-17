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

    // MARK: The "snoozed" chip (AlertSnoozeChip)

    private var perth: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }
    private let us = Locale(identifier: "en_US")
    /// 2:00:20 pm in Perth.
    private let afternoon = Date(timeIntervalSince1970: 1_794_808_820)

    private func plain(_ s: String?) -> String? {
        s?.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func chip(_ s: AlertSnoozes, at t: Date) -> AlertSnoozeChip? {
        AlertSnoozeChip(s, now: t, calendar: perth, locale: us)
    }

    func testNoChipWithoutASnooze() {
        XCTAssertNil(chip(AlertSnoozes(), at: afternoon))
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        // Gone the moment it ends, never "0 min".
        XCTAssertNil(chip(s, at: afternoon.addingTimeInterval(30 * 60)))
        XCTAssertEqual(chip(s, at: afternoon.addingTimeInterval(30 * 60 - 1))?.remaining, "1 min")
        // An urgent low can't be snoozed, so it never shows one.
        var u = AlertSnoozes()
        u.snooze(.urgentLow, minutes: 30, now: afternoon)
        XCTAssertNil(chip(u, at: afternoon))
    }

    func testChipSaysUntilWhenAndMinutesLeft() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        let c = chip(s, at: afternoon)!
        XCTAssertEqual(plain(c.title), "Low alerts snoozed until 2:30 PM")
        XCTAssertEqual(c.remaining, "30 min")
        XCTAssertEqual(plain(c.accessibilityLabel), "Low alerts snoozed until 2:30 PM, 30 minutes left")
        // Rounded up: 12 min 20 s left reads 13 min.
        XCTAssertEqual(chip(s, at: afternoon.addingTimeInterval(17 * 60 + 40))?.remaining, "13 min")
        XCTAssertEqual(plain(chip(s, at: afternoon.addingTimeInterval(29 * 60 + 30))?.accessibilityLabel),
                       "Low alerts snoozed until 2:30 PM, 1 minute left")
    }

    func testChipNamesWhatEachSnoozeCovers() {
        var high = AlertSnoozes()
        high.snooze(.predictedHigh, minutes: 30, now: afternoon)
        XCTAssertEqual(plain(chip(high, at: afternoon)?.title), "High alerts snoozed until 2:30 PM")
        // A very-high snooze quiets highs too, and a shorter high snooze under it says nothing new.
        var vh = AlertSnoozes()
        vh.snooze(.veryHigh, minutes: 30, now: afternoon)
        vh.snooze(.high, minutes: 15, now: afternoon)
        XCTAssertEqual(plain(chip(vh, at: afternoon)?.title), "High and very high alerts snoozed until 2:30 PM")
        // Same end: one time. Different ends: each its own, soonest first.
        var both = AlertSnoozes()
        both.snooze(.low, minutes: 30, now: afternoon)
        both.snooze(.high, minutes: 30, now: afternoon)
        XCTAssertEqual(plain(chip(both, at: afternoon)?.title), "Low and high alerts snoozed until 2:30 PM")
        var apart = AlertSnoozes()
        apart.snooze(.high, minutes: 30, now: afternoon)
        apart.snooze(.low, minutes: 15, now: afternoon)
        let c = chip(apart, at: afternoon)!
        XCTAssertEqual(plain(c.title), "Low alerts snoozed until 2:15 PM, high until 2:30 PM")
        XCTAssertEqual(c.remaining, "30 min")
    }

    func testResumeEndsEverySnooze() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        s.snooze(.veryHigh, minutes: 30, now: afternoon)
        s.resumeAll()
        XCTAssertEqual(s, AlertSnoozes())
        XCTAssertFalse(s.silences(.low, at: afternoon.addingTimeInterval(60)))
        XCTAssertFalse(s.silences(.high, at: afternoon.addingTimeInterval(60)))
    }

    func testChipRedrawsOnceAMinuteAndAtEachEnd() {
        XCTAssertEqual(AlertSnoozes().redrawDates(from: afternoon), [])
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        let dates = s.redrawDates(from: afternoon)
        // 2:01 … 2:30 on the minute, then the end at 2:30:20: 31 redraws in 30 minutes.
        XCTAssertEqual(dates.count, 31)
        XCTAssertEqual(dates.first, Date(timeIntervalSince1970: 1_794_808_860))
        XCTAssertEqual(dates.last, afternoon.addingTimeInterval(30 * 60))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) <= 60 && $1 > $0 })
    }

    func testRelayStatusSnoozesDecodeAndAreOptional() throws {
        let old = try JSONDecoder().decode(RelayStatus.self, from: Data(#"""
        {"version":"2.14.0","hasAccount":true,"hasDeviceToken":true,"hasPushToStartToken":false,
         "liveActivityEnabled":true,"alertsEnabled":true}
        """#.utf8))
        XCTAssertNil(old.snoozes)
        let new = try JSONDecoder().decode(RelayStatus.self, from: Data(#"""
        {"version":"2.15.0","hasAccount":true,"hasDeviceToken":true,"hasPushToStartToken":false,
         "liveActivityEnabled":true,"alertsEnabled":true,"snoozes":{"low":1794810620}}
        """#.utf8))
        XCTAssertEqual(new.snoozes?.low, 1_794_810_620)
        XCTAssertNil(new.snoozes?.high)
        let none = try JSONDecoder().decode(RelayStatus.self, from: Data(#"""
        {"version":"2.15.0","hasAccount":true,"hasDeviceToken":true,"hasPushToStartToken":false,
         "liveActivityEnabled":true,"alertsEnabled":true,"snoozes":{}}
        """#.utf8))
        XCTAssertEqual(none.snoozes, AlertSnoozes())
    }

    // MARK: The Lock Screen card and the menu bar (SnoozeBadge)
    // The relay builds the same badge (`cardSnooze`), tested on the same cases in checkins_test.ts.

    func testBadgeNamesTheLastEndAndWhatItCovers() {
        XCTAssertNil(AlertSnoozes().badge(at: afternoon))
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        XCTAssertEqual(s.badge(at: afternoon), SnoozeBadge(until: afternoon.addingTimeInterval(1800).timeIntervalSince1970,
                                                           levels: ["low"]))
        XCTAssertNil(s.badge(at: afternoon.addingTimeInterval(1800)))
        // Soonest first; the badge's time is the last end.
        s.snooze(.high, minutes: 10, now: afternoon)
        XCTAssertEqual(s.badge(at: afternoon)?.levels, ["high", "low"])
        XCTAssertEqual(s.badge(at: afternoon)?.until, afternoon.addingTimeInterval(1800).timeIntervalSince1970)
        // A very-high snooze covers a high one that ends no later, not one that outlasts it.
        var vh = AlertSnoozes()
        vh.snooze(.veryHigh, minutes: 20, now: afternoon)
        vh.snooze(.high, minutes: 10, now: afternoon)
        XCTAssertEqual(vh.badge(at: afternoon)?.levels, ["veryHigh"])
        vh.snooze(.high, minutes: 30, now: afternoon)
        XCTAssertEqual(vh.badge(at: afternoon)?.levels, ["veryHigh", "high"])
        // Urgent lows are never snoozed, so never badged.
        var u = AlertSnoozes()
        u.snooze(.urgentLow, minutes: 30, now: afternoon)
        XCTAssertNil(u.badge(at: afternoon))
    }

    func testBadgeWording() {
        let until = afternoon.addingTimeInterval(1800).timeIntervalSince1970
        func badge(_ levels: [String]) -> SnoozeBadge { SnoozeBadge(until: until, levels: levels) }
        XCTAssertEqual(plain(badge(["low"]).shortText(calendar: perth, locale: us)), "until 2:30 PM")
        XCTAssertEqual(plain(badge(["low"]).sentence(calendar: perth, locale: us)), "Low alerts snoozed until 2:30 PM")
        XCTAssertEqual(plain(badge(["veryHigh"]).sentence(calendar: perth, locale: us)),
                       "High and very high alerts snoozed until 2:30 PM")
        XCTAssertEqual(plain(badge(["low", "veryHigh"]).sentence(calendar: perth, locale: us)),
                       "Low, high and very high alerts snoozed until 2:30 PM")
        XCTAssertEqual(plain(badge(["veryHigh", "high"]).sentence(calendar: perth, locale: us)),
                       "High and very high alerts snoozed until 2:30 PM")
        // A level a newer relay adds still reads sensibly.
        XCTAssertEqual(plain(badge(["somethingNew"]).sentence(calendar: perth, locale: us)),
                       "Alerts snoozed until 2:30 PM")
    }

    func testCardCarriesTheSnoozeAndOldCardsDecode() throws {
        let card = #"""
        {"mgdl":70,"trend":3,"readingAt":1794808800,"unit":"mmol","lowMgdl":70,"highMgdl":180,
         "history":[70],"forecast":[],"source":"relay"
        """#
        let old = try JSONDecoder().decode(GlucoseActivityState.self, from: Data((card + "}").utf8))
        XCTAssertNil(old.snooze)
        let new = try JSONDecoder().decode(GlucoseActivityState.self, from: Data(
            (card + #","snooze":{"until":1794810620,"levels":["low"]}}"#).utf8))
        XCTAssertEqual(new.snooze, SnoozeBadge(until: 1_794_810_620, levels: ["low"]))
        // Drawn after the end (before the next card arrives): no bell-slash.
        XCTAssertNotNil(new.runningSnooze(at: Date(timeIntervalSince1970: 1_794_810_619)))
        XCTAssertNil(new.runningSnooze(at: Date(timeIntervalSince1970: 1_794_810_620)))
        // `make` never sets it: the app and the relay add it to the owner's card.
        XCTAssertNil(GlucoseActivityState.make(from: snapshot(100, at: afternoon), now: afternoon)?.snooze)
    }

    func testMenuBarShowsTheSnoozeOnlyWhileItRuns() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: afternoon)
        let badge = s.badge(at: afternoon)
        let snap = snapshot(80, at: afternoon)
        func glance(_ b: SnoozeBadge?, at t: Date) -> MenuBarGlance {
            MenuBarGlance.make(snapshot: snap, recent: [], hasCredentials: true, showDelta: false, showSparkline: false,
                               colorByRange: true, snooze: b, now: t)
        }
        XCTAssertFalse(glance(nil, at: afternoon).snoozed)
        XCTAssertTrue(glance(badge, at: afternoon).snoozed)
        XCTAssertFalse(glance(badge, at: afternoon.addingTimeInterval(1800)).snoozed)
        // A yes or no: the glance (and so the drawing) doesn't change with the minutes left.
        XCTAssertEqual(glance(badge, at: afternoon.addingTimeInterval(1)), glance(badge, at: afternoon.addingTimeInterval(61)))

        let tip = MenuBarGlance.toolTip(snapshot: snap, hasCredentials: true, showForecast: false, snooze: badge,
                                        now: afternoon, calendar: perth, locale: us)
        XCTAssertEqual(plain(tip.components(separatedBy: "\n").last), "Low alerts snoozed until 2:30 PM")
        let plainTip = MenuBarGlance.toolTip(snapshot: snap, hasCredentials: true, showForecast: false,
                                             now: afternoon, calendar: perth, locale: us)
        XCTAssertFalse(plainTip.contains("snoozed"))
        let ended = MenuBarGlance.toolTip(snapshot: snap, hasCredentials: true, showForecast: false, snooze: badge,
                                          now: afternoon.addingTimeInterval(1800), calendar: perth, locale: us)
        XCTAssertFalse(ended.contains("snoozed"))
    }

    // MARK: Countdown ring

    func testCountdownStartsWhenTheSnoozeIsSetAndDrains() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: now)
        let ring = AlertSnoozeCountdown.tracking(s.chipEnd(at: now), previous: nil, now: now)
        XCTAssertEqual(ring?.start, now)
        XCTAssertEqual(ring?.end, now.addingTimeInterval(1800))
        XCTAssertEqual(ring?.fraction(at: now) ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(ring?.fraction(at: now.addingTimeInterval(900)) ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ring?.fraction(at: now.addingTimeInterval(1800)) ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(ring?.fraction(at: now.addingTimeInterval(4000)) ?? 1, 0, accuracy: 0.0001)
    }

    func testCountdownKeepsItsStartForTheSameEnd() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: now)
        let first = AlertSnoozeCountdown.tracking(s.chipEnd(at: now), previous: nil, now: now)
        // Twenty minutes on (a relaunch, a redraw): the same end keeps the same start, so the ring
        // doesn't refill even though 10 minutes left would fit a 15-minute snooze.
        let later = now.addingTimeInterval(1200)
        let again = AlertSnoozeCountdown.tracking(s.chipEnd(at: later), previous: first, now: later)
        XCTAssertEqual(again, first)
        XCTAssertEqual(again?.fraction(at: later) ?? 0, 1.0 / 3, accuracy: 0.0001)
    }

    func testCountdownGuessesTheStartOfAnAdoptedSnooze() {
        // A relay snooze with 22 minutes left, first seen now: most likely a 30-minute one.
        let end = now.addingTimeInterval(22 * 60)
        let ring = AlertSnoozeCountdown.tracking(end, previous: nil, now: now)
        XCTAssertEqual(ring?.start, end.addingTimeInterval(-1800))
        // 12 minutes left of a Log treatment low: 15.
        let short = AlertSnoozeCountdown.tracking(now.addingTimeInterval(12 * 60), previous: nil, now: now)
        XCTAssertEqual(short?.start, now.addingTimeInterval(-180))
        // The relay's longest, 60.
        let long = AlertSnoozeCountdown.tracking(now.addingTimeInterval(45 * 60), previous: nil, now: now)
        XCTAssertEqual(long?.start, now.addingTimeInterval(-900))
    }

    func testCountdownRefillsWhenLongerAndKeepsDrainingWhenShorter() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 15, now: now)
        let first = AlertSnoozeCountdown.tracking(s.chipEnd(at: now), previous: nil, now: now)
        // Ten minutes on, a high is snoozed for 30: the chip now counts to the later end, full.
        let later = now.addingTimeInterval(600)
        s.snooze(.high, minutes: 30, now: later)
        let longer = AlertSnoozeCountdown.tracking(s.chipEnd(at: later), previous: first, now: later)
        XCTAssertEqual(longer?.start, later)
        XCTAssertEqual(longer?.fraction(at: later) ?? 0, 1, accuracy: 0.0001)
        // Five minutes on, the relay cuts it to end 10 minutes after the high was snoozed: same
        // start, so the ring drops to half rather than refilling.
        let next = later.addingTimeInterval(300)
        let cut = later.addingTimeInterval(600)
        let shorter = AlertSnoozeCountdown.tracking(cut, previous: longer, now: next)
        XCTAssertEqual(shorter?.start, later)
        XCTAssertEqual(shorter?.fraction(at: next) ?? 1, 0.5, accuracy: 0.0001)
    }

    func testCountdownEndsWithTheSnooze() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 30, now: now)
        let ring = AlertSnoozeCountdown.tracking(s.chipEnd(at: now), previous: nil, now: now)
        let after = now.addingTimeInterval(1801)
        XCTAssertNil(s.chipEnd(at: after))
        XCTAssertNil(AlertSnoozeCountdown.tracking(s.chipEnd(at: after), previous: ring, now: after))
        XCTAssertNil(AlertSnoozeCountdown.tracking(now, previous: ring, now: now))
    }

    func testChipEndFollowsTheChipsMinutesLeft() {
        var s = AlertSnoozes()
        s.snooze(.low, minutes: 15, now: now)
        s.snooze(.veryHigh, minutes: 30, now: now)
        s.snooze(.high, minutes: 20, now: now)
        // The very high covers the shorter high; the chip counts to the last end.
        XCTAssertEqual(s.chipEnd(at: now), now.addingTimeInterval(1800))
        XCTAssertEqual(AlertSnoozeChip(s, now: now)?.remaining, "30 min")
    }

    func testCountdownRoundTripsThroughJSON() throws {
        let ring = AlertSnoozeCountdown(start: now, end: now.addingTimeInterval(1800))
        let data = try JSONEncoder().encode(ring)
        XCTAssertEqual(try JSONDecoder().decode(AlertSnoozeCountdown.self, from: data), ring)
    }
}
