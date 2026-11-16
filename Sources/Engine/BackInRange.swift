import Foundation

// "Back in range in about 20 min": when glucose is above range, the time the forecast's central
// line first comes back down to the high threshold. Checked against what actually happened
// (docs/ForecastAccuracy.md §24) and shown only while this device's own checks keep it honest.
//
// Rules:
// 1. Only from above range. A low isn't given a time back: the forecast can't see a low being
//    treated (most treatments aren't logged), and a "back soon" next to a low must never read as
//    a reason to wait.
// 2. Only within the drawn forecast. Nothing past its last drawn point is guessed, so the estimate
//    appears when the forecast itself comes back into range and says nothing otherwise.
// 3. The time is where the line crosses the high threshold, linear between forecast points.
// 4. Each settled forecast in this device's log that started above range and came back within its
//    drawn points is a check: its estimate against the first reading back in range that the next
//    reading confirms (looked for up to 6 hours later). A check whose readings run out first is
//    left out rather than guessed.
// 5. The estimate is shown while the median miss of the last 30 days' checks is within 15 minutes,
//    once there are at least 5. Fewer, or a larger typical miss, hides it.
//
// Observational only, like the rest of the forecast: it's an "≈" in the forecast's grey, never in
// a reading's colour, and never a suggestion to dose or eat.

/// How this device's back-in-range estimates have done, and whether one is shown.
struct BackInRangeCheck: Hashable, Codable {
    /// Settled forecasts checked.
    var checks: Int = 0
    /// Median of |estimate − actual|, minutes. Nil with no checks.
    var medianMissMinutes: Double?
    /// Share of checks within `BackInRange.maxTypicalMissMinutes`, 0...1.
    var withinTolerance: Double?

    static let none = BackInRangeCheck()

    var shows: Bool {
        guard checks >= BackInRange.minimumChecks, let m = medianMissMinutes else { return false }
        return m <= BackInRange.maxTypicalMissMinutes
    }
}

enum BackInRange {
    /// The typical miss the estimate may have and still be shown.
    static let maxTypicalMissMinutes = 15.0
    static let minimumChecks = 5
    static let window: TimeInterval = 30 * 86_400
    /// How long after a forecast its actual return is looked for.
    static let lookAhead: TimeInterval = 6 * 3600
    /// The reading that confirms a return must come within this long of it.
    static let confirmWithin: TimeInterval = 20 * 60

    /// Minutes until a line starting at `start` (above `high`) first comes back to `high`, linear
    /// between `points` (minutes ahead, mg/dL; in order, after the start). Nil when it starts in
    /// range or below, or doesn't come back within the points.
    static func minutesBack(start: Double, points: [(minutes: Double, mgdl: Double)], high: Double) -> Double? {
        guard start > high else { return nil }
        var m0 = 0.0, v0 = start
        for p in points {
            if p.mgdl <= high {
                let drop = v0 - p.mgdl
                return drop > 0 ? m0 + (v0 - high) / drop * (p.minutes - m0) : p.minutes
            }
            m0 = p.minutes
            v0 = p.mgdl
        }
        return nil
    }

    /// When the forecast says glucose is back in range, if the checks let it be said.
    static func estimate(_ forecast: GlucoseForecast, high: Double, check: BackInRangeCheck) -> Date? {
        guard check.shows else { return nil }
        let points = forecast.samples.compactMap { s -> (minutes: Double, mgdl: Double)? in
            let m = s.date.timeIntervalSince(forecast.issuedAt) / 60
            return m > 0.01 ? (m, s.mgdl) : nil
        }
        return minutesBack(start: forecast.startMgdl, points: points, high: high)
            .map { forecast.issuedAt.addingTimeInterval($0 * 60) }
    }

    /// Minutes from `start` until glucose was back in range: the first reading in range whose next
    /// reading (within `confirmWithin`) is too. Nil when that wasn't seen in `lookAhead`, or when
    /// the readings stop before it could be.
    static func actualMinutesBack(readings: GlucoseSeries, from start: Date, low: Double, high: Double) -> Double? {
        let slice = readings.slice(from: start.addingTimeInterval(1), through: start.addingTimeInterval(lookAhead + confirmWithin))
        let r = Array(slice)
        guard r.count >= 2 else { return nil }
        for (a, b) in zip(r, r.dropFirst()) {
            guard a.timestamp.timeIntervalSince(start) <= lookAhead else { break }
            let inA = a.mgdl >= low && a.mgdl <= high, inB = b.mgdl >= low && b.mgdl <= high
            if inA && inB && b.timestamp.timeIntervalSince(a.timestamp) <= confirmWithin {
                return a.timestamp.timeIntervalSince(start) / 60
            }
        }
        return nil
    }

    /// Scores this device's settled forecasts from the last 30 days (rule 4).
    static func check(records: [ForecastRecord], readings: GlucoseSeries, device: String,
                      low: Double, high: Double, now: Date = Date()) -> BackInRangeCheck {
        let from = now.addingTimeInterval(-window)
        var misses: [Double] = []
        for r in records where r.device == device && r.settled && r.issuedAt >= from && r.startMgdl > high {
            let points = r.points.filter(\.wasShown).sorted { $0.minutes < $1.minutes }
                .map { (minutes: Double($0.minutes), mgdl: $0.mgdl) }
            guard let estimate = minutesBack(start: r.startMgdl, points: points, high: high) else { continue }
            if let actual = actualMinutesBack(readings: readings, from: r.issuedAt, low: low, high: high) {
                misses.append(abs(estimate - actual))
            } else if let last = readings.last, last.timestamp >= r.issuedAt.addingTimeInterval(lookAhead) {
                // Still out of range six hours on: off by at least that much.
                misses.append(lookAhead / 60 - estimate)
            }
        }
        guard !misses.isEmpty else { return .none }
        let within = Double(misses.filter { $0 <= maxTypicalMissMinutes }.count) / Double(misses.count)
        return BackInRangeCheck(checks: misses.count, medianMissMinutes: EngineMath.median(misses),
                                withinTolerance: within)
    }
}
