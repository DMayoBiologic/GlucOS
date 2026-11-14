import Foundation

// What the iPhone Live Activity (Lock Screen card and Dynamic Island) shows. The iPhone app fills
// it in while it's running and the push relay sends it over APNs the rest of the time, so the
// same struct is encoded by both and decoded by ActivityKit. ActivityKit decodes pushes with a
// plain JSONDecoder, so everything here is numbers, strings and arrays: no `Date`, whose default
// encoding is easy to get wrong in a push payload. Keep it small: a push is at most 4 KB.

struct GlucoseActivityState: Codable, Hashable {
    /// The reading, mg/dL.
    var mgdl: Double
    /// `Trend.rawValue`.
    var trend: Int
    /// When the reading was taken, seconds since 1970.
    var readingAt: Double
    /// Change since the reading about 5 minutes before, mg/dL.
    var deltaMgdl: Double?
    /// `GlucoseUnit.rawValue`.
    var unit: String
    var lowMgdl: Double
    var highMgdl: Double
    /// mg/dL every 5 minutes up to and including the reading, oldest first. `nil` marks a gap.
    var history: [Int?]
    /// The forecast's central line every 5 minutes after the reading, mg/dL. Empty when there
    /// isn't a current forecast.
    var forecast: [Int] = []
    /// The likely range at the end of the forecast, mg/dL.
    var forecastLower: Int?
    var forecastUpper: Int?
    /// Fast-acting insulin still to act, units.
    var insulinOnBoard: Double?
    /// When the forecast's central line first goes below the low threshold, seconds since 1970.
    var lowExpectedAt: Double?
    /// "phone" or "relay": who sent this update. Shown nowhere; handy when debugging.
    var source: String = "phone"

    static let historyStep: TimeInterval = 5 * 60
    /// How much history the card's sparkline covers.
    static let historyHours: Double = 3
    /// How far ahead the card's forecast goes at most.
    static let forecastMinutes = 60

    // MARK: Reading back

    var readingDate: Date { Date(timeIntervalSince1970: readingAt) }
    var glucoseTrend: Trend { Trend(rawValue: trend) ?? .unknown }
    var glucoseUnit: GlucoseUnit { GlucoseUnit(rawValue: unit) ?? .mmol }
    var range: GlucoseRange { GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl) }

    /// When the card should turn grey: the same 6 minutes as everywhere else.
    var staleDate: Date { readingDate.addingTimeInterval(GlucoseSnapshot.staleAfter) }
    func isStale(at now: Date = Date()) -> Bool { now > staleDate }

    var valueText: String { glucoseUnit.format(mgdl: mgdl) }
    var deltaText: String? { deltaMgdl.map { glucoseUnit.formatDelta(mgdl: $0) } }

    /// The history as dated readings, for a chart. Gaps are left out.
    var historyReadings: [GlucoseReading] {
        let n = history.count
        return history.enumerated().compactMap { i, v in
            guard let v else { return nil }
            let t = readingDate.addingTimeInterval(-Double(n - 1 - i) * Self.historyStep)
            return GlucoseReading(timestamp: t, mgdl: Double(v), trend: .unknown)
        }
    }

    /// The forecast as dated points, for a chart.
    var forecastPoints: [(date: Date, mgdl: Double)] {
        forecast.enumerated().map { i, v in
            (readingDate.addingTimeInterval(Double(i + 1) * Self.historyStep), Double(v))
        }
    }

    /// The forecast point the card names: 30 minutes ahead when the forecast reaches that far
    /// (further out is too uncertain to headline on a glance), else its last point.
    var forecastHeadline: (minutes: Int, mgdl: Double)? {
        if forecast.count >= 6 { return (30, Double(forecast[5])) }
        guard let last = forecast.last else { return nil }
        return (forecast.count * 5, Double(last))
    }

    var lowExpectedDate: Date? { lowExpectedAt.map { Date(timeIntervalSince1970: $0) } }

    // MARK: Building

    /// The state for a snapshot, or nil when there's no reading. `readings` is everything known
    /// (the snapshot's history is used when it's empty); only the last few hours are kept.
    static func make(from s: GlucoseSnapshot, readings: [GlucoseReading] = [], source: String = "phone",
                     now: Date = Date()) -> GlucoseActivityState? {
        guard let current = s.current else { return nil }
        var all = readings.isEmpty ? s.history : readings
        all.append(current)

        // One value per 5-minute slot, ending at the reading. Each slot takes the reading nearest
        // its centre, if one is within half a slot.
        let slots = Int(historyHours * 3600 / historyStep) + 1
        let window = all.filter {
            let age = current.timestamp.timeIntervalSince($0.timestamp)
            return age >= -60 && age <= historyHours * 3600 + historyStep
        }
        var history: [Int?] = []
        history.reserveCapacity(slots)
        for i in 0..<slots {
            let centre = current.timestamp.addingTimeInterval(-Double(slots - 1 - i) * historyStep)
            let nearest = window.min { abs($0.timestamp.timeIntervalSince(centre)) < abs($1.timestamp.timeIntervalSince(centre)) }
            if let nearest, abs(nearest.timestamp.timeIntervalSince(centre)) <= historyStep / 2 {
                history.append(Int(nearest.mgdl.rounded()))
            } else {
                history.append(nil)
            }
        }
        history[slots - 1] = Int(current.mgdl.rounded())

        var state = GlucoseActivityState(mgdl: current.mgdl, trend: current.trend.rawValue,
                                         readingAt: current.timestamp.timeIntervalSince1970,
                                         deltaMgdl: s.deltaMgdl, unit: s.unit.rawValue,
                                         lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, history: history,
                                         source: source)
        // The forecast only while it belongs to this reading, and never for a stale one.
        if let o = s.outlook, !s.isStale(at: now), o.isCurrent(at: now) {
            let ahead = o.forecast.filter {
                let m = $0.date.timeIntervalSince(current.timestamp)
                return m > 60 && m <= Double(forecastMinutes * 60) + 60
            }
            // Resample onto the 5-minute grid the card uses.
            var points: [ForecastSample] = []
            for step in 1...(forecastMinutes / 5) {
                let target = current.timestamp.addingTimeInterval(Double(step) * historyStep)
                guard let p = ahead.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }),
                      abs(p.date.timeIntervalSince(target)) <= 150 else { break }
                points.append(p)
            }
            state.forecast = points.map { Int($0.mgdl.rounded()) }
            state.forecastLower = points.last.map { Int($0.lowerMgdl.rounded()) }
            state.forecastUpper = points.last.map { Int($0.upperMgdl.rounded()) }
            if o.showsInsulin { state.insulinOnBoard = o.insulinOnBoard }
            state.lowExpectedAt = o.lowExpectedAt?.timeIntervalSince1970
        }
        return state
    }
}
