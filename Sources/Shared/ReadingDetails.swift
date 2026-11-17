import Foundation

/// Where the reading on screen came from (improvement round 56). Today every current reading is
/// LibreLinkUp's: the relay only fills in history on the iPhone, and reading the sensor directly
/// (#40) isn't shipped. The other cases are here so the details card says so the day one lands.
enum ReadingSource: String, Codable, CaseIterable {
    /// Read from the sensor by this device.
    case sensor
    /// Abbott's LibreLinkUp, fetched by this device.
    case libreLinkUp
    /// GlucOS's push relay, passed on from another device.
    case relay

    var label: String {
        switch self {
        case .sensor: return "Sensor"
        case .libreLinkUp: return "LibreLinkUp"
        case .relay: return "GlucOS relay"
        }
    }

    /// One line under the label on the details card.
    var detail: String {
        switch self {
        case .sensor: return "Read straight from your sensor"
        case .libreLinkUp: return "Fetched from Abbott's servers"
        case .relay: return "Passed on by your other device"
        }
    }

    var systemImage: String {
        switch self {
        case .sensor: return "sensor.tag.radiowaves.forward"
        case .libreLinkUp: return "cloud"
        case .relay: return "arrow.triangle.2.circlepath"
        }
    }
}

/// What the details card shows when the current reading is tapped (iPhone Today) or clicked (Mac
/// popover): when it was taken, where it came from, the trend as a rate per minute, and when the
/// next one is due. Worked out here, away from the views, so it's tested. The card speaks it as
/// one VoiceOver sentence (`spoken`).
struct ReadingDetails: Equatable {
    /// Libre 2 Plus and Libre 3 send LibreLinkUp a new current reading once a minute.
    static let sensorInterval: TimeInterval = 60
    /// The rate uses the reading before this one only when it's this recent; an older one would
    /// average over a turn. Otherwise the card falls back to the trend arrow's band.
    static let maxRateGap: TimeInterval = 20 * 60

    enum Rate: Equatable {
        /// Measured against an earlier reading: mg/dL a minute (signed) over `minutes`.
        case measured(mgdlPerMinute: Double, minutes: Int)
        /// No recent earlier reading: the band LibreLinkUp's arrow stands for.
        case band(Trend)
        /// Stale or no trend: nothing to say about the rate.
        case unavailable
    }

    enum NextDue: Equatable {
        /// The next check that should bring the next reading.
        case at(Date)
        /// That check is due now or running.
        case anyMoment
        /// The reading is stale: the next one should have come by `since`.
        case overdue(since: Date)
    }

    let takenAt: Date
    let age: TimeInterval
    let source: ReadingSource
    let rate: Rate
    let nextDue: NextDue
    let stale: Bool

    /// - Parameters:
    ///   - lastCheck: when this device last asked for a reading (nil before the first ask).
    ///   - checkEvery: how often it asks (Settings › Check for new readings).
    init?(snapshot s: GlucoseSnapshot, lastCheck: Date?, checkEvery: TimeInterval, now: Date) {
        guard let cur = s.current else { return nil }
        takenAt = cur.timestamp
        age = max(0, cur.age(at: now))
        source = s.source ?? .libreLinkUp
        stale = s.isStale(at: now)
        rate = Self.rate(current: cur, history: s.history, stale: stale)
        nextDue = Self.nextDue(takenAt: cur.timestamp, stale: stale, lastCheck: lastCheck,
                               checkEvery: checkEvery, now: now)
    }

    static func rate(current cur: GlucoseReading, history: [GlucoseReading], stale: Bool) -> Rate {
        guard !stale else { return .unavailable }
        // The newest earlier reading at least ~4 minutes back, like the delta beside the reading,
        // so a one-minute wobble isn't scaled up into a rate.
        if let prev = history.last(where: { cur.timestamp.timeIntervalSince($0.timestamp) >= 240 }) {
            let gap = cur.timestamp.timeIntervalSince(prev.timestamp)
            if gap <= maxRateGap {
                return .measured(mgdlPerMinute: (cur.mgdl - prev.mgdl) / (gap / 60),
                                 minutes: Int((gap / 60).rounded()))
            }
        }
        return cur.trend == .unknown ? .unavailable : .band(cur.trend)
    }

    static func nextDue(takenAt: Date, stale: Bool, lastCheck: Date?, checkEvery: TimeInterval,
                        now: Date) -> NextDue {
        let expected = takenAt.addingTimeInterval(sensorInterval)
        if stale { return .overdue(since: expected) }
        // The first of this device's checks that lands after the sensor's next reading.
        let step = max(30, checkEvery)
        var due = (lastCheck ?? now).addingTimeInterval(step)
        while due < expected { due = due.addingTimeInterval(step) }
        return due <= now ? .anyMoment : .at(due)
    }

    // MARK: Words

    /// "3:41 pm".
    func takenText(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        ClockLabel.time(takenAt, calendar: calendar, locale: locale)
    }

    /// "42s ago", "4m ago", "just now".
    var ageText: String {
        let secs = Int(age)
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        return m % 60 == 0 ? "\(m / 60)h ago" : "\(m / 60)h \(m % 60)m ago"
    }

    /// "+1.3 mg/dL a minute", "−0.07 mmol/L a minute", "About 1–2 mg/dL a minute, rising".
    func rateText(unit: GlucoseUnit) -> String {
        switch rate {
        case .unavailable:
            return "Not known"
        case .measured(let perMinute, _):
            let v = unit.value(fromMgdl: perMinute)
            let shown = Self.format(abs(v), unit: unit)
            if Double(shown) == 0 { return "No change" }
            return "\(v >= 0 ? "+" : "−")\(shown) \(unit.label) a minute"
        case .band(let trend):
            let one = Self.bandFormat(unit.value(fromMgdl: 1), unit: unit)
            let two = Self.bandFormat(unit.value(fromMgdl: 2), unit: unit)
            switch trend {
            case .flat: return "Under \(one) \(unit.label) a minute"
            case .rising, .falling: return "About \(one)–\(two) \(unit.label) a minute"
            case .risingQuickly, .fallingQuickly: return "Over \(two) \(unit.label) a minute"
            case .unknown: return "Not known"
            }
        }
    }

    /// The line under the rate: what it's measured over.
    var rateCaption: String {
        switch rate {
        case .measured(_, let minutes): return "Over the last \(minutes) min"
        case .band(let trend): return "\(trend.description), from the trend arrow"
        case .unavailable: return stale ? "The reading is too old" : "No trend from the sensor"
        }
    }

    func nextDueText(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch nextDue {
        case .at(let date): return "Around \(ClockLabel.time(date, calendar: calendar, locale: locale))"
        case .anyMoment: return "Any moment now"
        case .overdue(let since): return "Overdue since \(ClockLabel.time(since, calendar: calendar, locale: locale))"
        }
    }

    /// The whole card as one sentence for VoiceOver.
    func spoken(unit: GlucoseUnit, calendar: Calendar = .autoupdatingCurrent,
                locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["Reading details",
                     "Taken at \(takenText(calendar: calendar, locale: locale)), \(ageText)",
                     "Source, \(source.label)"]
        switch rate {
        case .unavailable: parts.append("Rate not known")
        case .measured(_, let minutes):
            let text = rateText(unit: unit)
            parts.append(text == "No change" ? "No change over the last \(minutes) minutes"
                         : "Changing \(text.replacingOccurrences(of: "−", with: "minus ")) over the last \(minutes) minutes")
        case .band(let trend): parts.append("\(trend.description), \(rateText(unit: unit))")
        }
        switch nextDue {
        case .at(let date): parts.append("Next reading around \(ClockLabel.time(date, calendar: calendar, locale: locale))")
        case .anyMoment: parts.append("Next reading any moment now")
        case .overdue(let since): parts.append("Next reading overdue since \(ClockLabel.time(since, calendar: calendar, locale: locale))")
        }
        return parts.joined(separator: ". ")
    }

    /// Two decimals in mmol/L (a minute's change is small), one in mg/dL.
    private static func format(_ v: Double, unit: GlucoseUnit) -> String {
        String(format: unit == .mmol ? "%.2f" : "%.1f", v)
    }

    /// The arrow's band edges are whole mg/dL, so no decimal there.
    private static func bandFormat(_ v: Double, unit: GlucoseUnit) -> String {
        String(format: unit == .mmol ? "%.2f" : "%.0f", v)
    }
}
