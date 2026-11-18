import Foundation

/// Where a scrub along the glucose chart settles when the finger (or the Mac's pointer) comes close
/// to something worth landing on: a logged marker, or a day's lowest or highest reading. Within a
/// few points of one, the scrub line jumps onto it and holds there until the finger moves a little
/// further away, so the exact low of the day or the reading at a dose is easy to land on without
/// pixel-hunting. Plain Foundation so it can be unit-tested; `GlucoseChart` moves the readout,
/// plays `scrubSnapped` on iPhone and tells VoiceOver once.
enum ScrubSnap {
    /// How close, in points along the time axis, the finger has to come for the scrub to snap.
    static let reach: Double = 8
    /// How far it has to move away again before the snap lets go. Further than `reach`, so the
    /// line never flickers on and off at the edge.
    static let letGo: Double = 14

    /// How far, in points, the finger has to move from where it came down before anything snaps.
    /// Until then it may be a tap that opens a marker's callout or a hold that peeks at it
    /// (`MarkerPeek`), and those have their own tap; moving further than a hold allows is a scrub.
    static let armDistance: Double = MarkerPeek.holdSlop

    /// Whether a scrub that started at `start` has moved far enough to snap.
    static func arms(start: Date, finger: Date, secondsPerPoint: Double) -> Bool {
        guard secondsPerPoint > 0, secondsPerPoint.isFinite else { return false }
        return abs(finger.timeIntervalSince(start)) / secondsPerPoint > armDistance
    }

    enum Kind: Equatable {
        /// Something logged: a dose, a meal, a tag. `label` is the marker's own VoiceOver label,
        /// e.g. "6 units Novorapid at 12:56 pm".
        case logged(id: UUID, label: String)
        /// The lowest reading of its day.
        case lowest(mgdl: Double)
        /// The highest reading of its day.
        case highest(mgdl: Double)
    }

    struct Target: Equatable {
        let date: Date
        let kind: Kind
    }

    /// A logged marker the scrub can land on.
    struct Logged: Equatable {
        let id: UUID
        let date: Date
        let label: String
    }

    /// Each day's lowest and highest reading among `readings`, kept only where they lie in
    /// `visible`. A whole day is looked at, not only the part on screen, so "lowest today" is the
    /// day's own lowest. A day that never moved (its lowest is its highest) has neither. On a tie
    /// the earliest reading counts.
    static func extremes(readings: [GlucoseReading], visible: ClosedRange<Date>,
                         calendar: Calendar = .autoupdatingCurrent) -> [Target] {
        var days: [Date: (low: GlucoseReading, high: GlucoseReading)] = [:]
        for r in readings {
            let day = calendar.startOfDay(for: r.timestamp)
            guard let seen = days[day] else { days[day] = (r, r); continue }
            let low = r.mgdl < seen.low.mgdl || (r.mgdl == seen.low.mgdl && r.timestamp < seen.low.timestamp) ? r : seen.low
            let high = r.mgdl > seen.high.mgdl || (r.mgdl == seen.high.mgdl && r.timestamp < seen.high.timestamp) ? r : seen.high
            days[day] = (low, high)
        }
        var out: [Target] = []
        for day in days.keys.sorted() {
            guard let e = days[day], e.low.mgdl < e.high.mgdl else { continue }
            if visible.contains(e.low.timestamp) { out.append(Target(date: e.low.timestamp, kind: .lowest(mgdl: e.low.mgdl))) }
            if visible.contains(e.high.timestamp) { out.append(Target(date: e.high.timestamp, kind: .highest(mgdl: e.high.mgdl))) }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Everything the scrub can land on: the logged markers first, then each day's lowest and
    /// highest, so a marker wins when a marker and an extreme are equally close.
    static func targets(logged: [Logged], readings: [GlucoseReading], visible: ClosedRange<Date>,
                        calendar: Calendar = .autoupdatingCurrent) -> [Target] {
        logged.filter { visible.contains($0.date) }
            .map { Target(date: $0.date, kind: .logged(id: $0.id, label: $0.label)) }
            + extremes(readings: readings, visible: visible, calendar: calendar)
    }

    /// What the scrub is snapped to with the finger at `finger`, or nil when it follows the finger.
    ///
    /// - Parameters:
    ///   - current: what it was snapped to a moment ago. It holds on until the finger is more
    ///     than `letGo` points from it, unless something else is now strictly closer.
    ///   - secondsPerPoint: how much time one point along the chart's time axis covers.
    static func snap(finger: Date, targets: [Target], current: Target?, secondsPerPoint: Double) -> Target? {
        guard secondsPerPoint > 0, secondsPerPoint.isFinite else { return nil }
        let points = { (t: Target) in abs(t.date.timeIntervalSince(finger)) / secondsPerPoint }
        let nearest = targets.min { points($0) < points($1) }
        if let current, targets.contains(current), points(current) <= letGo {
            guard let nearest, points(nearest) < points(current), points(nearest) <= reach else { return current }
            return nearest
        }
        guard let nearest, points(nearest) <= reach else { return nil }
        return nearest
    }

    /// What VoiceOver says once when the scrub snaps: the marker's own label, or "Lowest today,
    /// 3.9 mmol/L at 2:15 pm".
    static func spoken(_ target: Target, unit: GlucoseUnit, now: Date,
                       calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch target.kind {
        case .logged(_, let label):
            return label
        case .lowest(let mgdl), .highest(let mgdl):
            let which: String
            if case .lowest = target.kind { which = "Lowest" } else { which = "Highest" }
            let day: String
            if calendar.isDate(target.date, inSameDayAs: now) {
                day = "today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(target.date, inSameDayAs: yesterday) {
                day = "yesterday"
            } else {
                day = "on " + target.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                                    timeZone: calendar.timeZone).weekday(.wide))
            }
            let time = ClockLabel.time(target.date, calendar: calendar, locale: locale)
            return "\(which) \(day), \(unit.format(mgdl: mgdl, withUnit: true)) at \(time)"
        }
    }
}
