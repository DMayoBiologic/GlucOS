import Foundation

// What Siri and Shortcuts say for "How was my day" (`DaySummaryIntent` on iPhone and Mac,
// docs/iOS.md "Siri and Shortcuts"): today's time in range, average, lows and highs from midnight to
// the newest reading.
//
// The figures are the evening recap's (`EveningRecap.compute`), which reads the day the way "Today so
// far" does (`TodaySoFar.figures`): 5-minute buckets, an hour of the day gone, readings in half of its
// 15-minute slots, and lows and highs as runs of 15 minutes or more. The answer names the hours it
// covers, so a phone that last had a reading at 6 pm says "midnight to 6 pm" rather than pretending
// to know the rest.
//
// Observational only, like Insights: it reports the day and never suggests a change to insulin or
// settings. Plain Foundation, so it's unit-tested.

enum SpokenDay {
    /// The whole day, to the newest reading: the recap's time-of-day cut at its last minute.
    static let endOfDayMinute = 1439

    /// Today's figures at `now`, or nil when today doesn't have enough readings yet.
    static func figures(readings: [GlucoseReading], low: Double, high: Double, now: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> EveningRecap? {
        EveningRecap.compute(readings: readings, low: low, high: high, minute: endOfDayMinute,
                             now: now, calendar: calendar)
    }

    /// The answer at `now`, in the person's unit.
    static func answer(readings: [GlucoseReading], low: Double, high: Double, unit: GlucoseUnit,
                       now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        if let day = figures(readings: readings, low: low, high: high, now: now, calendar: calendar) {
            return text(day, unit: unit)
        }
        let start = calendar.startOfDay(for: now)
        guard readings.contains(where: { $0.mgdl > 0 && $0.timestamp <= now }) else { return noReadings }
        guard readings.contains(where: { $0.mgdl > 0 && $0.timestamp >= start && $0.timestamp <= now }) else {
            return noneToday
        }
        return tooFewToday
    }

    /// "So far today, midnight to 2:30 pm: 78% in range, average 7.4 mmol/L. 1 low and no highs."
    static func text(_ day: EveningRecap, unit: GlucoseUnit) -> String {
        "So far today, \(EveningRecapText.period(day).lowercased()): \(EveningRecapText.body(day, unit: unit))"
    }

    static let noReadings = "GlucOS has no readings of yours yet. Open GlucOS to connect."
    static let noneToday = "GlucOS has no readings from today yet."
    static let tooFewToday = "Not enough readings today yet to say. GlucOS needs an hour of readings since midnight."
}
