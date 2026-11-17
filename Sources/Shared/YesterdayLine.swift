import Foundation

/// Yesterday's readings drawn faintly behind today's trace, so this morning can be read against
/// yesterday morning at a glance. Off unless turned on (`AppSettings.showYesterdayLine`, or the
/// chart's long-press / right-click menu). Display only: nothing here feeds the forecast, alerts or
/// any dosing figure.
///
/// "Yesterday" means the same time on the clock a day earlier, not exactly 86,400 seconds earlier,
/// so 8 am lines up with 8 am on the days the clocks change (a 23- or 25-hour day). Readings from
/// the hour the clocks skipped have no time today and are left out; the hour repeated when the
/// clocks go back is drawn once, against its first occurrence.
enum YesterdayLine {
    /// A gap this long between two of yesterday's readings breaks the line, as a sensor change or a
    /// phone out of signal would, rather than drawing straight across it.
    static let gap: TimeInterval = 20 * 60
    /// How far from "this time yesterday" a reading may be and still be said as yesterday's.
    static let tolerance: TimeInterval = 10 * 60
    /// The faint line doesn't need every reading: at most one per this many seconds.
    static let spacing: TimeInterval = 4.5 * 60

    /// One of yesterday's readings, at the time today it's drawn against.
    struct Point: Equatable, Identifiable {
        /// When it was actually read, yesterday.
        let readAt: Date
        /// The same clock time today, where the chart draws it.
        let date: Date
        let mgdl: Double
        /// Which unbroken stretch of the line it's on (`gap`), from 0.
        let segment: Int

        var id: Date { readAt }
    }

    /// `date` moved to the same clock time a day later.
    static func forward(_ date: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: date)
    }

    /// `date` moved to the same clock time a day earlier.
    static func back(_ date: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -1, to: date)
    }

    /// Whether the clocks change anywhere between `start` and `end` in `calendar`'s time zone, or
    /// in the day before either (whose readings are being moved).
    static func clocksChange(between start: Date, and end: Date, calendar: Calendar) -> Bool {
        guard let next = calendar.timeZone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-2 * 86_400))
        else { return false }
        return next <= end.addingTimeInterval(86_400)
    }

    /// Yesterday's readings that land between `start` and `end` today, oldest first, in
    /// `segment`s, thinned to about one per `spacing`. `readings` is oldest → newest and may hold
    /// today's readings too (they land tomorrow, past `end`, and drop out).
    static func points(readings: [GlucoseReading], from start: Date, to end: Date,
                       calendar: Calendar = .current) -> [Point] {
        guard start < end else { return [] }
        // Only readings near a day before the window need looking at. Two hours either side
        // covers any daylight saving shift.
        let lo = start.addingTimeInterval(-86_400 - 2 * 3600)
        let hi = end.addingTimeInterval(-86_400 + 2 * 3600)
        var i = ChartSpan.firstIndex(in: readings, atOrAfter: lo)
        // Most days the clocks don't change: a plain 24 hours, with no calendar sums per reading.
        let plain = !clocksChange(between: start, and: end, calendar: calendar)
        var out: [Point] = []
        var segment = 0
        var lastReadAt: Date?
        while i < readings.count, readings[i].timestamp <= hi {
            let r = readings[i]
            i += 1
            let shifted: Date
            if plain {
                shifted = r.timestamp.addingTimeInterval(86_400)
            } else {
                // A reading from the skipped hour comes back to a different time: it has no
                // matching time today.
                guard let f = forward(r.timestamp, calendar: calendar),
                      let b = back(f, calendar: calendar), abs(b.timeIntervalSince(r.timestamp)) < 1
                else { continue }
                shifted = f
            }
            guard shifted >= start, shifted <= end else { continue }
            if let prev = out.last {
                // Always moving forward, so the line never doubles back on itself.
                guard shifted > prev.date else { continue }
                if shifted.timeIntervalSince(prev.date) < spacing { continue }
                if let last = lastReadAt,
                   r.timestamp.timeIntervalSince(last) > gap || shifted.timeIntervalSince(prev.date) > gap {
                    segment += 1
                }
            }
            out.append(Point(readAt: r.timestamp, date: shifted, mgdl: r.mgdl, segment: segment))
            lastReadAt = r.timestamp
        }
        return out
    }

    /// Yesterday's reading at the same clock time as `date`, if there was one within `tolerance`.
    static func reading(at date: Date, in readings: [GlucoseReading],
                        calendar: Calendar = .current) -> GlucoseReading? {
        guard let target = back(date, calendar: calendar) else { return nil }
        var i = ChartSpan.firstIndex(in: readings, atOrAfter: target.addingTimeInterval(-tolerance))
        var best: GlucoseReading?
        while i < readings.count, readings[i].timestamp <= target.addingTimeInterval(tolerance) {
            let r = readings[i]
            if best.map({ abs(r.timestamp.timeIntervalSince(target)) < abs($0.timestamp.timeIntervalSince(target)) }) ?? true {
                best = r
            }
            i += 1
        }
        return best
    }

    /// For VoiceOver: "Yesterday at this time: 6.2 millimoles per litre." `nil` with no reading.
    static func spoken(_ reading: GlucoseReading?, unit: GlucoseUnit) -> String? {
        guard let reading else { return nil }
        return "Yesterday at this time: \(unit.format(mgdl: reading.mgdl)) \(WidgetSpeech.unitWords(unit))."
    }

    /// The menu item that turns it on or off.
    static func menuTitle(showing: Bool) -> String {
        showing ? "Hide Yesterday's Line" : "Show Yesterday's Line"
    }

    /// How far back a chart needs readings to draw yesterday under a span of `hours` (plus its lead
    /// and an hour's slack for the clocks changing).
    static func hoursNeeded(forSpan hours: Double) -> Double { hours + 24 + 1 }
}
