import XCTest
@testable import GlucOSEngine

final class WhileAwayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A clock backed by a plain variable, as UserDefaults would hold it.
    private final class Box { var stored: Date? }

    private func clock(_ box: Box) -> LastLookedClock {
        LastLookedClock(load: { box.stored }, save: { box.stored = $0 })
    }

    // MARK: Last looked

    func testFirstLaunchShowsNothingAndStartsTheClock() {
        let box = Box()
        XCTAssertNil(clock(box).open(now: t0), "nothing to compare with on the first launch")
        XCTAssertEqual(box.stored, t0, "the first opening is the first look")
    }

    func testFirstLaunchThenLongAwayShowsTheSpan() {
        let box = Box()
        let c = clock(box)
        c.open(now: t0)
        let later = t0.addingTimeInterval(3 * 3600)
        XCTAssertEqual(c.open(now: later), DateInterval(start: t0, end: later))
    }

    func testUnderTwoHoursShowsNothing() {
        let box = Box()
        box.stored = t0
        let now = t0.addingTimeInterval(2 * 3600 - 1)
        XCTAssertNil(clock(box).open(now: now))
        XCTAssertEqual(box.stored, now, "the opening is still a look")
    }

    func testExactlyTwoHoursShows() {
        let box = Box()
        box.stored = t0
        let now = t0.addingTimeInterval(2 * 3600)
        XCTAssertEqual(clock(box).open(now: now)?.duration, 2 * 3600)
    }

    func testClosingCountsAsALook() {
        // Opened, left open on the desk for 3 hours, then closed: back an hour later is no gap.
        let box = Box()
        let c = clock(box)
        c.open(now: t0)
        c.close(now: t0.addingTimeInterval(3 * 3600))
        XCTAssertNil(c.open(now: t0.addingTimeInterval(4 * 3600)))
    }

    func testSecondOpenForTheSameOpeningFindsNoGap() {
        // An appear and a scene change landing together: the second sees the look just stored.
        let box = Box()
        box.stored = t0
        let c = clock(box)
        let now = t0.addingTimeInterval(5 * 3600)
        XCTAssertNotNil(c.open(now: now))
        XCTAssertNil(c.open(now: now.addingTimeInterval(1)))
    }

    func testClockSetBackShowsNothingAndResets() {
        let box = Box()
        box.stored = t0.addingTimeInterval(10 * 3600)
        XCTAssertNil(clock(box).open(now: t0))
        XCTAssertEqual(box.stored, t0, "the next opening measures from now, not from the future")
    }

    func testLongAbsenceIsCutToTheLastDay() {
        let box = Box()
        box.stored = t0
        let now = t0.addingTimeInterval(3 * 86_400)
        let span = clock(box).open(now: now)
        XCTAssertEqual(span, DateInterval(start: now.addingTimeInterval(-86_400), end: now))
    }

    func testFollowersNeverGetALine() {
        let box = Box()
        box.stored = t0
        let c = clock(box)
        XCTAssertNil(c.open(now: t0.addingTimeInterval(5 * 3600), isFollower: true))
        c.close(now: t0.addingTimeInterval(6 * 3600), isFollower: true)
        XCTAssertEqual(box.stored, t0, "a follower's screen keeps no last look")
    }

    func testUserDefaultsClockRoundTrips() {
        let suite = "WhileAwayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = LastLookedClock.defaults(defaults)
        XCTAssertNil(c.lastLooked)
        XCTAssertNil(c.open(now: t0))
        XCTAssertEqual(c.lastLooked, t0)
        XCTAssertNotNil(LastLookedClock.defaults(defaults).open(now: t0.addingTimeInterval(4 * 3600)))
    }

    // MARK: Figures

    private func readings(_ values: [Double], from start: Date, every minutes: Double = 5) -> [GlucoseReading] {
        values.enumerated().map { i, v in
            GlucoseReading(timestamp: start.addingTimeInterval(Double(i) * minutes * 60), mgdl: v, trend: .flat)
        }
    }

    func testFiguresOverTheSpan() {
        let span = DateInterval(start: t0, duration: 3 * 3600)
        // Before the span: a 40 that mustn't count.
        var rs = readings([40], from: t0.addingTimeInterval(-600))
        rs += readings([100, 120, 60, 150, 200, 110, 100, 100], from: t0.addingTimeInterval(60))
        let alerts = [
            AlertRecord(kind: .low, firedAt: t0.addingTimeInterval(15 * 60)),
            AlertRecord(kind: .low, firedAt: t0.addingTimeInterval(30 * 60)), // same spell: one row
            AlertRecord(kind: .high, firedAt: t0.addingTimeInterval(25 * 60)),
            AlertRecord(kind: .high, firedAt: t0.addingTimeInterval(-3600)), // before the span
        ]
        let w = WhileAway.compute(span: span, readings: rs, alerts: alerts, low: 70, high: 180)!
        XCTAssertEqual(w.lowest.mgdl, 60)
        XCTAssertEqual(w.lowest.at, t0.addingTimeInterval(60 + 10 * 60))
        XCTAssertEqual(w.highest.mgdl, 200)
        XCTAssertEqual(w.timeInRange, 6.0 / 8.0, accuracy: 1e-9)
        XCTAssertEqual(w.lowAlerts, 1)
        XCTAssertEqual(w.highAlerts, 1)
        XCTAssertEqual(WhileAwayText.alerts(w), "2 alerts")
    }

    func testTooFewReadingsShowNothing() {
        let span = DateInterval(start: t0, duration: 3 * 3600)
        let rs = readings([100, 110, 120, 130, 140], from: t0)
        XCTAssertNil(WhileAway.compute(span: span, readings: rs, alerts: [], low: 70, high: 180))
    }

    func testLineWords() {
        let span = DateInterval(start: t0, duration: 5 * 3600 + 20 * 60)
        let rs = readings([70, 90, 202, 150, 120, 110], from: t0)
        let w = WhileAway.compute(span: span, readings: rs, alerts: [AlertRecord(kind: .low, firedAt: t0)],
                                  low: 70, high: 180)!
        XCTAssertEqual(WhileAwayText.line(w, unit: .mgdl), "Away 5 h 20 m · 70–202 · 83% in range · 1 low alert")
        XCTAssertTrue(WhileAwayText.line(w, unit: .mmol).contains("3.9–11.2"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let spoken = WhileAwayText.spoken(w, unit: .mgdl, calendar: utc)
        XCTAssertTrue(spoken.hasPrefix("While you were away, 5 hours 20 minutes: lowest 70"), spoken)
        XCTAssertTrue(spoken.hasSuffix("83 percent in range, 1 low alert."), spoken)
    }

    func testWordsForNoAlertsAndLongAbsence() {
        let span = DateInterval(start: t0, duration: 86_400)
        let rs = readings([100, 100, 100, 100, 100, 100], from: t0)
        let w = WhileAway.compute(span: span, readings: rs, alerts: [], low: 70, high: 180)!
        XCTAssertEqual(WhileAwayText.head(w), "Last 24 h")
        XCTAssertEqual(WhileAwayText.alerts(w), "no alerts")
        XCTAssertEqual(WhileAwayText.duration(2 * 3600), "2 h")
        XCTAssertEqual(WhileAwayText.duration(45 * 60), "45 m")
    }

    // MARK: Logbook

    func testLogbookLinkShowsEverythingOverTheSpan() {
        let span = DateInterval(start: t0, duration: 4 * 3600)
        let link = LogbookLink.whileAway(span)
        XCTAssertEqual(link.filter, .whileAway)
        XCTAssertNil(link.kindChip, "no kind chip: every kind shows")
        XCTAssertEqual(link.period.interval, span)
        XCTAssertEqual(link.period.label, "While you were away")
        XCTAssertFalse(LogbookFilter.whileAway.isListed)
        XCTAssertEqual(link.sourceID, "logbook-whileAway")
        let meal = LogEntry.meal(MealEntry(timestamp: t0.addingTimeInterval(3600), carbs: 30))
        XCTAssertTrue(LogbookFilter.whileAway.matches(meal, lowIDs: []))
    }
}
