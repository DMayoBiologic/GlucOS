import XCTest
@testable import GlucOSEngine

final class SensorEndTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func local(_ date: Date, _ zone: String) -> DateComponents {
        calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func sensor(_ activated: Date, days: Int = 15) -> SensorInfo {
        SensorInfo(serial: "0M0001ABCDE", activated: activated, lifetimeDays: days)
    }

    private func reading(_ at: Date, _ mgdl: Double = 110) -> GlucoseReading {
        GlucoseReading(timestamp: at, mgdl: mgdl, trend: .flat)
    }

    // MARK: Countdown

    func testCountdownShowsOnlyInTheLast24Hours() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let s = sensor(start)
        XCTAssertNil(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-24 * 3600 - 1)))
        let first = try XCTUnwrap(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-24 * 3600)))
        XCTAssertEqual(first.day, 15)
        XCTAssertEqual(first.lifetimeDays, 15)
        XCTAssertEqual(first.line, "Sensor day 15 of 15 · 24 h left")
        XCTAssertNil(SensorEnd.countdown(sensor: s, at: s.expires))
        XCTAssertNil(SensorEnd.countdown(sensor: nil, at: start))
        XCTAssertEqual(SensorEnd.countdownStarts(sensor: s), s.expires.addingTimeInterval(-24 * 3600))
    }

    func testTimeLeftRoundsUpToWholeMinutes() throws {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        func left(_ remaining: TimeInterval) throws -> String {
            try XCTUnwrap(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-remaining))).left
        }
        XCTAssertEqual(try left(6 * 3600 + 12 * 60), "6 h 12 min left")
        XCTAssertEqual(try left(6 * 3600 + 11 * 60 + 1), "6 h 12 min left")
        XCTAssertEqual(try left(3600), "1 h left")
        XCTAssertEqual(try left(59 * 60), "59 min left")
        XCTAssertEqual(try left(20), "1 min left")
        XCTAssertEqual(SensorEnd.spokenLeft(3600 + 60), "1 hour 1 minute")
        XCTAssertEqual(SensorEnd.spokenLeft(2 * 3600), "2 hours")
        XCTAssertEqual(SensorEnd.spokenLeft(42 * 60), "42 minutes")
    }

    func testLastTwoHoursAreUrgent() throws {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(try XCTUnwrap(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-2 * 3600))).isUrgent)
        XCTAssertTrue(try XCTUnwrap(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-2 * 3600 + 1))).isUrgent)
    }

    func testSpokenCountdownSaysWordsAndTheEndTime() throws {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        let c = try XCTUnwrap(SensorEnd.countdown(sensor: s, at: s.expires.addingTimeInterval(-(6 * 3600 + 12 * 60))))
        let utc = calendar("UTC")
        let at = ClockLabel.time(s.expires, calendar: utc, locale: locale)
        XCTAssertEqual(c.spoken(calendar: utc, locale: locale),
                       "Sensor day 15 of 15, 6 hours 12 minutes left. Ends at \(at).")
    }

    /// Declan's sensor: started 5 Nov 2026 8:59:22 pm in Perth, 15 days, ends 20 Nov 8:59:22 pm.
    func testDayCountForARealSensorInPerth() throws {
        let s = sensor(date("Australia/Perth", 2026, 11, 5, 20, 59, 22))
        XCTAssertEqual(local(s.expires, "Australia/Perth"), DateComponents(year: 2026, month: 11, day: 20, hour: 20, minute: 59))
        XCTAssertEqual(SensorEnd.day(of: s, at: date("Australia/Perth", 2026, 11, 5, 21)), 1)
        XCTAssertEqual(SensorEnd.day(of: s, at: date("Australia/Perth", 2026, 11, 6, 20, 59, 21)), 1)
        XCTAssertEqual(SensorEnd.day(of: s, at: date("Australia/Perth", 2026, 11, 6, 20, 59, 22)), 2)
        let c = try XCTUnwrap(SensorEnd.countdown(sensor: s, at: date("Australia/Perth", 2026, 11, 20, 10)))
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.line, "Sensor day 15 of 15 · 11 h left")
    }

    /// Wear time is real hours: across the start of daylight saving in Sydney the sensor still
    /// lasts 15 × 24 hours, so it ends an hour later by the clock, and the day count follows the
    /// hours, not the calendar.
    func testDayCountAcrossDaylightSavingCountsRealHours() throws {
        let zone = "Australia/Sydney"
        let s = sensor(date(zone, 2026, 9, 20, 21))          // AEST, UTC+10
        XCTAssertEqual(local(s.expires, zone).hour, 22)       // 5 Oct, AEDT, UTC+11
        XCTAssertEqual(local(s.expires, zone).day, 5)
        let c = try XCTUnwrap(SensorEnd.countdown(sensor: s, at: date(zone, 2026, 10, 4, 22)))
        XCTAssertEqual(c.remaining, 24 * 3600)
        XCTAssertEqual(c.day, 15)
        // 9:30 pm on 4 Oct by the clock is still day 14: day 15 starts at 10 pm after the change.
        XCTAssertEqual(SensorEnd.day(of: s, at: date(zone, 2026, 10, 4, 21, 30)), 14)
    }

    func testDayNeverPassesTheLifetime() {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(SensorEnd.day(of: s, at: s.expires.addingTimeInterval(3 * 86_400)), 15)
        XCTAssertEqual(SensorEnd.day(of: s, at: s.activated.addingTimeInterval(-60)), 1)
    }

    // MARK: Ended

    func testEndedOnceTheEndPassesWithNothingNewer() throws {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        let last = reading(s.expires.addingTimeInterval(-60))
        XCTAssertNil(SensorEnd.ended(sensor: s, current: last, isStale: false, at: s.expires.addingTimeInterval(-1)))
        let e = try XCTUnwrap(SensorEnd.ended(sensor: s, current: last, isStale: false, at: s.expires))
        XCTAssertEqual(e.endedAt, s.expires)
        XCTAssertEqual(e.lastReading, last)
        XCTAssertNotNil(SensorEnd.ended(sensor: s, current: nil, isStale: true, at: s.expires.addingTimeInterval(3600)))
    }

    func testFreshReadingsPastTheEndAreNotEnded() {
        let s = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        let later = reading(s.expires.addingTimeInterval(30 * 60))
        let now = s.expires.addingTimeInterval(32 * 60)
        XCTAssertNil(SensorEnd.ended(sensor: s, current: later, isStale: false, at: now))
        // Once they stop, it has ended.
        XCTAssertNotNil(SensorEnd.ended(sensor: s, current: later, isStale: true, at: now.addingTimeInterval(3600)))
    }

    func testANewSensorWarmingUpIsNotEnded() {
        let old = sensor(Date(timeIntervalSince1970: 1_800_000_000))
        let fresh = sensor(old.expires.addingTimeInterval(2 * 3600))
        var snap = GlucoseSnapshot()
        snap.sensor = fresh
        snap.current = reading(old.expires.addingTimeInterval(-60))
        let now = fresh.activated.addingTimeInterval(10 * 60)
        XCTAssertNotNil(snap.warmUp(at: now))
        XCTAssertNil(snap.sensorEnded(at: now))
        XCTAssertNil(SensorEnd.ended(sensor: old, current: snap.current, isStale: true, warmingUp: true, at: now))
        // With the old sensor still reported, the snapshot says ended.
        snap.sensor = old
        XCTAssertNotNil(snap.sensorEnded(at: now))
    }

    func testEndedLineSaysWhichDay() {
        let utc = calendar("UTC")
        let endedAt = date("UTC", 2026, 11, 20, 20, 59)
        let e = SensorEnd.Ended(endedAt: endedAt, lastReading: nil)
        let t = ClockLabel.time(endedAt, calendar: utc, locale: locale)
        XCTAssertEqual(e.endedLine(now: date("UTC", 2026, 11, 20, 22), calendar: utc, locale: locale), "Ended at \(t)")
        XCTAssertEqual(e.endedLine(now: date("UTC", 2026, 11, 21, 8), calendar: utc, locale: locale), "Ended yesterday \(t)")
        XCTAssertTrue(e.spoken(now: date("UTC", 2026, 11, 20, 22), calendar: utc, locale: locale)
            .hasPrefix("Your sensor has ended. Ended at \(t). Apply a new sensor"))
    }

    // MARK: Evening-before reminder

    func testReminderIsAt7pmTheEveningBeforeInPerth() throws {
        let zone = "Australia/Perth"
        let ends = date(zone, 2026, 11, 20, 20, 59, 22)
        let fire = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: ends, now: date(zone, 2026, 11, 18, 12), calendar: calendar(zone)))
        XCTAssertEqual(local(fire, zone), DateComponents(year: 2026, month: 11, day: 19, hour: 19, minute: 0))
        // Once that's past, there's nothing to schedule.
        XCTAssertNil(SensorEndReminder.fireDate(endsAt: ends, now: fire, calendar: calendar(zone)))
        XCTAssertNil(SensorEndReminder.fireDate(endsAt: ends, now: date(zone, 2026, 11, 20, 8), calendar: calendar(zone)))
    }

    func testReminderStays7pmByTheClockAcrossDaylightSavingInSydney() throws {
        let zone = "Australia/Sydney", cal = calendar(zone)
        let early = date(zone, 2026, 9, 1, 12)
        // Ends on the day saving starts (4 Oct): the reminder is 7 pm AEST on the 3rd.
        let startDay = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 10, 4, 20), now: early, calendar: cal))
        XCTAssertEqual(local(startDay, zone), DateComponents(year: 2026, month: 10, day: 3, hour: 19, minute: 0))
        // Ends the day after: the reminder is on the change day itself, still 7 pm (now AEDT).
        let afterStart = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 10, 5, 10), now: early, calendar: cal))
        XCTAssertEqual(local(afterStart, zone), DateComponents(year: 2026, month: 10, day: 4, hour: 19, minute: 0))
        XCTAssertEqual(afterStart.timeIntervalSince(startDay), 23 * 3600)
        // Ends the day after saving ends (5 Apr): 7 pm on the 25-hour day.
        let autumn = date(zone, 2026, 3, 1, 12)
        let afterEnd = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 4, 6, 9), now: autumn, calendar: cal))
        XCTAssertEqual(local(afterEnd, zone), DateComponents(year: 2026, month: 4, day: 5, hour: 19, minute: 0))
        let before = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 4, 5, 9), now: autumn, calendar: cal))
        XCTAssertEqual(afterEnd.timeIntervalSince(before), 25 * 3600)
    }

    func testReminderAcrossDaylightSavingInNewYork() throws {
        let zone = "America/New_York", cal = calendar(zone)
        let spring = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 3, 9, 8), now: date(zone, 2026, 3, 1, 0), calendar: cal))
        XCTAssertEqual(local(spring, zone), DateComponents(year: 2026, month: 3, day: 8, hour: 19, minute: 0))
        let fall = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: date(zone, 2026, 11, 2, 10), now: date(zone, 2026, 10, 25, 0), calendar: cal))
        XCTAssertEqual(local(fall, zone), DateComponents(year: 2026, month: 11, day: 1, hour: 19, minute: 0))
    }

    func testSmallHoursEndIsTonight() throws {
        let zone = "America/New_York", cal = calendar(zone)
        let ends = date(zone, 2026, 3, 9, 0, 30)
        let fire = try XCTUnwrap(SensorEndReminder.fireDate(endsAt: ends, now: date(zone, 2026, 3, 1, 0), calendar: cal))
        XCTAssertEqual(local(fire, zone), DateComponents(year: 2026, month: 3, day: 8, hour: 19, minute: 0))
        XCTAssertEqual(SensorEndReminder.title(endsAt: ends, calendar: cal), "Your sensor ends tonight")
        let t = ClockLabel.time(ends, calendar: cal, locale: locale)
        XCTAssertEqual(SensorEndReminder.body(endsAt: ends, calendar: cal, locale: locale),
                       "It ends at \(t). Have a new sensor ready before bed so you don't lose readings overnight.")
    }

    func testDaytimeEndIsTomorrow() {
        let zone = "Australia/Perth", cal = calendar(zone)
        let ends = date(zone, 2026, 11, 20, 20, 59, 22)
        XCTAssertEqual(SensorEndReminder.title(endsAt: ends, calendar: cal), "Your sensor ends tomorrow")
        let t = ClockLabel.time(ends, calendar: cal, locale: locale)
        XCTAssertEqual(SensorEndReminder.body(endsAt: ends, calendar: cal, locale: locale),
                       "It ends at \(t) tomorrow. Have a new sensor ready; GlucOS counts down its warm-up when you start it.")
    }

    func testSettingsSearchFindsTheReminder() {
        for items in [SettingsCatalog.phone, SettingsCatalog.mac] {
            XCTAssertEqual(SettingsSearch.results(for: "reminder", in: items).first?.anchor, .sensorEndReminder)
        }
    }
}
