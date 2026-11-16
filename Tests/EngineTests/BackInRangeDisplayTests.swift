import XCTest
@testable import GlucOSEngine

/// Where "Back in range ≈ X min" may be shown (iPhone Today card, Mac popover, Mac menu bar
/// tooltip, Live Activity, widgets): one rule, `GlucoseSnapshot.backInRange(at:)`, so they never
/// disagree.
final class BackInRangeDisplayTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    /// A live reading `ageSeconds` old with an outlook issued from it, coming back in `backMinutes`.
    private func snapshot(mgdl: Double = 230, ageSeconds: TimeInterval = 60, backMinutes: Double? = 23,
                          lowExpected: Bool = false, trend: Trend = .falling) -> GlucoseSnapshot {
        var s = GlucoseSnapshot()
        s.unit = .mmol
        let at = referenceNow.addingTimeInterval(-ageSeconds)
        s.current = GlucoseReading(timestamp: at, mgdl: mgdl, trend: trend)
        var o = OutlookSnapshot(issuedAt: at, basis: .trend)
        o.backInRangeAt = backMinutes.map { at.addingTimeInterval($0 * 60) }
        if lowExpected { o.lowExpectedAt = at.addingTimeInterval(40 * 60) }
        s.outlook = o
        return s
    }

    func testShownAboveRangeRoundedToFiveMinutes() {
        let back = snapshot().backInRange(at: referenceNow)
        XCTAssertEqual(back?.minutes, 25)
        XCTAssertEqual(BackInRangeText.short(minutes: 25), "Back in range ≈ 25 min")
    }

    func testNeverUnderFiveMinutes() {
        XCTAssertEqual(snapshot(backMinutes: 1).backInRange(at: referenceNow)?.minutes, 5)
    }

    func testHiddenInRangeOrLow() {
        XCTAssertNil(snapshot(mgdl: 150).backInRange(at: referenceNow), "only from above range")
        XCTAssertNil(snapshot(mgdl: 60).backInRange(at: referenceNow), "never for a low")
    }

    func testHiddenWithALowExpected() {
        XCTAssertNil(snapshot(lowExpected: true).backInRange(at: referenceNow),
                     "a 'back soon' next to a low warning must never read as a reason to wait")
    }

    func testHiddenWhenTheChecksHideIt() {
        // The engine leaves backInRangeAt nil while this device's checks miss by more than 15 min.
        XCTAssertNil(snapshot(backMinutes: nil).backInRange(at: referenceNow))
    }

    func testHiddenWhenStale() {
        XCTAssertNil(snapshot(ageSeconds: 7 * 60).backInRange(at: referenceNow))
    }

    func testHiddenOnceTheEstimateHasPassed() {
        XCTAssertNil(snapshot(backMinutes: -2).backInRange(at: referenceNow))
    }

    // MARK: Menu bar tooltip

    func testToolTipAddsBackInRangeWithClockTime() {
        let s = snapshot()
        let tip = MenuBarGlance.toolTip(snapshot: s, hasCredentials: true, showForecast: true,
                                        now: referenceNow, calendar: utc, locale: locale)
        let lines = tip.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "GlucOS: \(s.unit.format(mgdl: 230, withUnit: true)), high, falling")
        let at = ClockLabel.time(s.current!.timestamp.addingTimeInterval(25 * 60), calendar: utc, locale: locale)
        XCTAssertEqual(lines[1], "Back in range ≈ 25 min (around \(at)) if nothing else changes")
    }

    func testToolTipLeavesItOutWithForecastOff() {
        let tip = MenuBarGlance.toolTip(snapshot: snapshot(), hasCredentials: true, showForecast: false,
                                        now: referenceNow, calendar: utc, locale: locale)
        XCTAssertFalse(tip.contains("Back in range"))
    }

    func testToolTipLeavesItOutWithALowExpected() {
        let tip = MenuBarGlance.toolTip(snapshot: snapshot(lowExpected: true), hasCredentials: true,
                                        showForecast: true, now: referenceNow, calendar: utc, locale: locale)
        XCTAssertFalse(tip.contains("Back in range"))
    }

    func testToolTipWhenStaleSaysSinceWhenAndNoEstimate() {
        let s = snapshot(ageSeconds: 12 * 60)
        let tip = MenuBarGlance.toolTip(snapshot: s, hasCredentials: true, showForecast: true,
                                        now: referenceNow, calendar: utc, locale: locale)
        let since = ClockLabel.time(s.current!.timestamp, calendar: utc, locale: locale)
        XCTAssertEqual(tip, "GlucOS: no new reading since \(since). Last reading \(s.unit.format(mgdl: 230, withUnit: true))")
    }

    func testToolTipWithNoReading() {
        XCTAssertEqual(MenuBarGlance.toolTip(snapshot: GlucoseSnapshot(), hasCredentials: false, showForecast: true),
                       "GlucOS: not connected")
        XCTAssertEqual(MenuBarGlance.toolTip(snapshot: GlucoseSnapshot(), hasCredentials: true, showForecast: true),
                       "GlucOS: waiting for a reading")
    }

    // MARK: Live Activity

    func testLiveActivityCarriesTheGatedEstimate() throws {
        let state = try XCTUnwrap(GlucoseActivityState.make(from: snapshot(), now: referenceNow))
        let reading = try XCTUnwrap(snapshot().current).timestamp
        XCTAssertEqual(try XCTUnwrap(state.backInRangeAt), reading.addingTimeInterval(23 * 60).timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(state.backInRangeMinutes(stale: false), 25)
        XCTAssertNil(state.backInRangeMinutes(stale: true), "a stale card says nothing ahead")
        XCTAssertEqual(BackInRangeText.compact(minutes: 25), "In range ≈ 25 min")
    }

    func testLiveActivityLeavesItOutWhereTheTodayCardWould() throws {
        for s in [snapshot(backMinutes: nil), snapshot(lowExpected: true), snapshot(mgdl: 150), snapshot(mgdl: 60)] {
            let state = try XCTUnwrap(GlucoseActivityState.make(from: s, now: referenceNow))
            XCTAssertNil(state.backInRangeAt)
            XCTAssertNil(state.backInRangeMinutes(stale: false))
        }
        let stale = try XCTUnwrap(GlucoseActivityState.make(from: snapshot(), now: referenceNow.addingTimeInterval(10 * 60)))
        XCTAssertNil(stale.backInRangeAt)
    }

    func testLiveActivityCardNeverShowsItForALowOrWithALowExpected() throws {
        // A relay card is drawn by the same view: whatever it sends, the card checks again.
        var state = try XCTUnwrap(GlucoseActivityState.make(from: snapshot(), now: referenceNow))
        state.lowExpectedAt = state.readingAt + 30 * 60
        XCTAssertNil(state.backInRangeMinutes(stale: false))
        state.lowExpectedAt = nil
        state.mgdl = 60
        XCTAssertNil(state.backInRangeMinutes(stale: false))
        state.mgdl = 230
        state.backInRangeAt = state.readingAt - 60
        XCTAssertNil(state.backInRangeMinutes(stale: false), "an estimate already passed")
    }

    func testLiveActivityStateDecodesWithoutTheField() throws {
        // Relay cards from before 2.14.0 have no backInRangeAt.
        let state = try XCTUnwrap(GlucoseActivityState.make(from: snapshot(backMinutes: nil), now: referenceNow))
        let json = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("backInRangeAt"))
        XCTAssertEqual(try JSONDecoder().decode(GlucoseActivityState.self, from: json), state)
    }

    // MARK: Widgets

    func testWidgetSpeechSaysItWhenShown() {
        let text = WidgetSpeech.reading(snapshot(), state: .fresh, at: referenceNow)
        XCTAssertTrue(text.hasSuffix("Back in range in about 25 minutes if nothing else changes."), text)
        XCTAssertFalse(WidgetSpeech.reading(snapshot(lowExpected: true), state: .fresh, at: referenceNow).contains("Back in range"))
        XCTAssertFalse(WidgetSpeech.reading(snapshot(backMinutes: nil), state: .fresh, at: referenceNow).contains("Back in range"))
    }

    func testWidgetsReloadWhenTheEstimateChangesAndOnlyThen() {
        let a = snapshot()
        func with(_ minutes: Double?) -> GlucoseSnapshot {
            var b = a
            b.outlook?.backInRangeAt = minutes.map { a.current!.timestamp.addingTimeInterval($0 * 60) }
            return b
        }
        let groups = { (x: GlucoseSnapshot, y: GlucoseSnapshot) in
            WidgetReload.groups(from: WidgetReload.signature(x), to: WidgetReload.signature(y))
        }
        XCTAssertEqual(groups(a, with(23)), [], "the same estimate")
        XCTAssertEqual(groups(with(nil), a), [.glucose], "the estimate appearing")
        XCTAssertEqual(groups(a, with(31)), [.glucose], "the estimate moving")
        XCTAssertEqual(groups(a, with(nil)), [.glucose], "the estimate going")
    }
}
