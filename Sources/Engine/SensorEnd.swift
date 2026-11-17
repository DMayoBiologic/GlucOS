import Foundation

// A sensor's last day and its end (docs/SensorEnd.md): a quiet "Sensor day 15 of 15 · 6 h left"
// line under the reading on iPhone Today and the Mac popover once it's in its last 24 hours, an
// opt-in reminder the evening before, and a "sensor ended" card in place of the old sensor's last
// reading that points to starting a new one (whose warm-up countdown then takes over). Plain
// Foundation, so the timing is unit-tested, daylight saving included.

enum SensorEnd {
    /// How long before the end the countdown line shows.
    static let countdownWindow: TimeInterval = 24 * 3600
    /// Under this much time left the line takes the warning colour.
    static let urgentWindow: TimeInterval = 2 * 3600

    // MARK: Last 24 hours

    /// The sensor's last day: which day of its life it's on and how long it has left.
    struct Countdown: Equatable {
        /// Day of the sensor's life, counted from 1 in whole 24-hour periods since it started
        /// (wear time is real hours, so a daylight-saving change doesn't move it).
        let day: Int
        let lifetimeDays: Int
        let remaining: TimeInterval
        let endsAt: Date

        var isUrgent: Bool { remaining < SensorEnd.urgentWindow }

        /// "6 h 12 min left", "6 h left", "42 min left". Whole minutes rounded up, so it never
        /// says 0 while there's still time to go.
        var left: String { SensorEnd.leftText(remaining) + " left" }

        /// "Sensor day 15 of 15 · 6 h 12 min left".
        var line: String { "Sensor day \(day) of \(lifetimeDays) · \(left)" }

        /// For VoiceOver, in whole words and with the clock time it ends:
        /// "Sensor day 15 of 15, 6 hours 12 minutes left. Ends at 8:59 pm."
        func spoken(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
            "Sensor day \(day) of \(lifetimeDays), \(SensorEnd.spokenLeft(remaining)) left. Ends at \(ClockLabel.time(endsAt, calendar: calendar, locale: locale))."
        }
    }

    /// The countdown, or nil: no sensor, more than 24 hours left, or already ended.
    static func countdown(sensor: SensorInfo?, at now: Date = Date()) -> Countdown? {
        guard let sensor, sensor.lifetimeDays > 0 else { return nil }
        let remaining = sensor.expires.timeIntervalSince(now)
        guard remaining > 0, remaining <= countdownWindow else { return nil }
        return Countdown(day: day(of: sensor, at: now), lifetimeDays: sensor.lifetimeDays,
                         remaining: remaining, endsAt: sensor.expires)
    }

    /// Day of the sensor's life at `now`, 1...lifetime.
    static func day(of sensor: SensorInfo, at now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(sensor.activated))
        return min(max(1, sensor.lifetimeDays), Int(elapsed / 86_400) + 1)
    }

    /// When the countdown first shows, for a view that waits for it rather than ticking.
    static func countdownStarts(sensor: SensorInfo?) -> Date? {
        sensor.map { $0.expires.addingTimeInterval(-countdownWindow) }
    }

    static func leftText(_ remaining: TimeInterval) -> String {
        let m = max(1, Int((remaining / 60).rounded(.up)))
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func spokenLeft(_ remaining: TimeInterval) -> String {
        let m = max(1, Int((remaining / 60).rounded(.up)))
        func minutes(_ n: Int) -> String { n == 1 ? "1 minute" : "\(n) minutes" }
        if m < 60 { return minutes(m) }
        let h = m / 60, r = m % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return r == 0 ? hours : "\(hours) \(minutes(r))"
    }

    // MARK: Ended

    /// The sensor has reached the end of its life and nothing newer has come in.
    struct Ended: Equatable {
        let endedAt: Date
        /// The old sensor's last reading, said in small type so it's not mistaken for a live one.
        let lastReading: GlucoseReading?

        static let title = "Your sensor has ended"
        static let detail = "Apply a new sensor and start it in the LibreLink app. GlucOS counts down its hour of warm-up here, then shows the first reading."

        /// "Ended at 8:59 pm", "Ended yesterday 8:59 pm".
        func endedLine(now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
            let when = ClockLabel.dayTime(endedAt, now: now, calendar: calendar, locale: locale)
            let isToday = ClockLabel.day(of: endedAt, now: now, calendar: calendar) == .today
            return "Ended \(isToday ? "at " : "")\(isToday ? when : when.lowercasedFirstWord)"
        }

        func spoken(now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
            "\(Self.title). \(endedLine(now: now, calendar: calendar, locale: locale)). \(Self.detail)"
        }
    }

    /// The ended state, or nil. A sensor still sending fresh readings past its nominal end (a
    /// grace period, or a lifetime set wrongly) isn't called ended until they stop; a new
    /// sensor's warm-up has its own countdown.
    static func ended(sensor: SensorInfo?, current: GlucoseReading?, isStale: Bool,
                      warmingUp: Bool = false, at now: Date = Date()) -> Ended? {
        guard let sensor, sensor.lifetimeDays > 0, !warmingUp, now >= sensor.expires else { return nil }
        if let current, current.timestamp >= sensor.expires, !isStale { return nil }
        return Ended(endedAt: sensor.expires, lastReading: current)
    }
}

extension GlucoseSnapshot {
    /// The sensor's last-day countdown (`SensorEnd.Countdown`), or nil.
    func sensorCountdown(at now: Date = Date()) -> SensorEnd.Countdown? {
        SensorEnd.countdown(sensor: sensor, at: now)
    }

    /// The sensor-ended state (`SensorEnd.Ended`), or nil.
    func sensorEnded(at now: Date = Date()) -> SensorEnd.Ended? {
        SensorEnd.ended(sensor: sensor, current: current, isStale: isStale(at: now),
                        warmingUp: warmUp(at: now) != nil, at: now)
    }
}

// MARK: - Evening-before reminder

/// The opt-in reminder the evening before a sensor ends (docs/SensorEnd.md): one local
/// notification at 7 pm on the day before its last day, so there's time to find a new one. It
/// isn't an alert: no sound, and a Focus holds it back like any ordinary notification.
enum SensorEndReminder {
    static let identifier = "glucos.sensorEnd"
    static let kind = "sensorEnd"
    /// 7 pm, in minutes after midnight.
    static let minute = 19 * 60
    /// An end before this hour (in the small hours) is "tonight" rather than "tomorrow".
    static let overnightHour = 5

    /// 7 pm by the clock on the day before the one the sensor ends, or nil when that's already
    /// past. By the clock, so it's still 7 pm on a day daylight saving starts or ends.
    static func fireDate(endsAt: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let endDay = calendar.startOfDay(for: endsAt)
        guard let eve = calendar.date(byAdding: .day, value: -1, to: endDay),
              let at = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: eve)
        else { return nil }
        return at > now ? at : nil
    }

    /// Whether the end falls in the small hours after the reminder, said as "tonight".
    static func endsOvernight(_ endsAt: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.component(.hour, from: endsAt) < overnightHour
    }

    static func title(endsAt: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        endsOvernight(endsAt, calendar: calendar) ? "Your sensor ends tonight" : "Your sensor ends tomorrow"
    }

    /// "It ends at 8:59 pm tomorrow. Have a new sensor ready; GlucOS counts down its warm-up when
    /// you start it."
    static func body(endsAt: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let time = ClockLabel.time(endsAt, calendar: calendar, locale: locale)
        if endsOvernight(endsAt, calendar: calendar) {
            return "It ends at \(time). Have a new sensor ready before bed so you don't lose readings overnight."
        }
        return "It ends at \(time) tomorrow. Have a new sensor ready; GlucOS counts down its warm-up when you start it."
    }

    static let settingsFooter = "A reminder at 7 pm the evening before your sensor ends, so there's time to find a new one. Separate from the sensor ending alert."

    /// What the pending reminder was last scheduled from, so a refresh that changes nothing
    /// schedules nothing.
    struct Key: Hashable {
        var endsAt: Date
        var fireAt: Date?
    }
}

private extension String {
    /// "Yesterday 8:59 pm" → "yesterday 8:59 pm"; "Mon 9 Nov…" stays as it is.
    var lowercasedFirstWord: String {
        hasPrefix("Yesterday") ? "yesterday" + dropFirst("Yesterday".count) : self
    }
}
