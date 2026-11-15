import Foundation

/// What a glucose chart shows, in one or two spoken sentences, for VoiceOver: the period, where
/// glucose is now, its lowest and highest, the share of readings in range, how often it left the
/// range, and where the forecast ends. Read as the chart's value; the audio graph
/// (`GlucoseAudioGraph`) carries the points themselves. Plain Foundation, so it's unit-tested.
enum ChartSummary {
    struct Input {
        var readings: [GlucoseReading]
        var lowMgdl: Double
        var highMgdl: Double
        var unit: GlucoseUnit
        var hours: Double
        /// Whether the newest reading is old. A stale chart says so first and never states a
        /// forecast.
        var stale: Bool = false
        /// Where the forecast ends, if one is shown.
        var forecastEnd: ForecastSample? = nil
        /// How many logged doses, meals and wake-ups are marked on the chart.
        var loggedCount: Int = 0
    }

    static func sentence(_ input: Input) -> String {
        let unit = input.unit
        let readings = input.readings.sorted { $0.timestamp < $1.timestamp }
        let period = "Last \(periodWords(input.hours))"
        guard let last = readings.last else { return "\(period). No readings." }

        var parts: [String] = [period]
        let range = GlucoseRange.classify(mgdl: last.mgdl, low: input.lowMgdl, high: input.highMgdl)
        if input.stale {
            parts.append("Stale: the last reading was \(unit.format(mgdl: last.mgdl))")
        } else {
            parts.append("Now \(unit.format(mgdl: last.mgdl)), \(range.spokenLabel)")
        }
        if readings.count > 1, let lo = readings.min(by: { $0.mgdl < $1.mgdl }), let hi = readings.max(by: { $0.mgdl < $1.mgdl }) {
            parts.append("Lowest \(unit.format(mgdl: lo.mgdl)), highest \(unit.format(mgdl: hi.mgdl))")
        }
        let inRange = readings.filter { $0.mgdl >= input.lowMgdl && $0.mgdl <= input.highMgdl }.count
        parts.append("\(Int((Double(inRange) / Double(readings.count) * 100).rounded())) percent in range")

        let lows = episodes(readings) { $0.mgdl < input.lowMgdl }
        let highs = episodes(readings) { $0.mgdl > input.highMgdl }
        var excursions: [String] = []
        if lows > 0 { excursions.append("below range \(times(lows))") }
        if highs > 0 { excursions.append("above range \(times(highs))") }
        if !excursions.isEmpty { parts.append("Went " + excursions.joined(separator: " and ")) }

        if !input.stale, let f = input.forecastEnd, f.date > last.timestamp {
            let minutes = max(5, Int((f.date.timeIntervalSince(last.timestamp) / 300).rounded()) * 5)
            parts.append("Forecast, not a reading: about \(unit.format(mgdl: f.mgdl)) in \(minutes) minutes")
        }
        if input.loggedCount > 0 {
            parts.append(input.loggedCount == 1 ? "1 entry logged" : "\(input.loggedCount) entries logged")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// Stretches of consecutive readings that meet `test`.
    static func episodes(_ readings: [GlucoseReading], where test: (GlucoseReading) -> Bool) -> Int {
        var count = 0
        var inside = false
        for r in readings {
            let hit = test(r)
            if hit && !inside { count += 1 }
            inside = hit
        }
        return count
    }

    private static func times(_ n: Int) -> String {
        switch n {
        case 1: return "once"
        case 2: return "twice"
        default: return "\(n) times"
        }
    }

    private static func periodWords(_ hours: Double) -> String {
        if hours >= 48, hours.truncatingRemainder(dividingBy: 24) == 0 { return "\(Int(hours / 24)) days" }
        let h = Int(hours.rounded())
        return h == 1 ? "hour" : "\(h) hours"
    }
}

extension GlucoseRange {
    /// The range in lower case, for the middle of a spoken sentence.
    var spokenLabel: String {
        switch self {
        case .urgentLow: return "urgent low"
        case .low: return "low"
        case .inRange: return "in range"
        case .high: return "high"
        case .veryHigh: return "very high"
        }
    }
}
