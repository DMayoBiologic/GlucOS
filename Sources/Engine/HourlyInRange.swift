import Foundation

// Insights "Time in range by hour": over the last 7, 14 or 30 days, the share of time in range for
// each hour of the day, drawn as a strip of 24 cells (docs/HourlyInRange.md).
//
// Method:
// 1. Readings are averaged into 5-minute buckets, as for Lows, Highs, Overnight and time in range,
//    over the `days` × 24 hours up to the newest reading.
// 2. Each bucket goes to the local clock hour it starts in (`Calendar.component(.hour)`), so the
//    cells are what the clock on the wall said. On the day the clocks go forward the skipped hour
//    simply has nothing that day; on the day they go back the repeated hour gets both passes.
// 3. An hour counts on a day when half its twelve 5-minute buckets have readings. A cell needs 3
//    such days; with fewer it's drawn empty ("not enough readings") rather than guessed at.
// 4. A cell's time in range is the share of its counted buckets at or between the low and high
//    lines, the same split as the time-in-range bars, with the shares below and above beside it.
// 5. The card needs readings on 3 days, as Overnight asks of nights.
// 6. Colour: 70% or more in range is the in-range hue, the consensus target. Under that a cell takes
//    the low or high hue, whichever side it spent more time on, strong under 50% and faint between.
//
// Observational only: it describes when in the day glucose tends to sit in range and never suggests
// a change to insulin, food or any setting. Plain Foundation, so it's unit-tested. Worked out off
// the main thread once per data change (`HourlyInRangeCache`).

struct HourlyInRange: Hashable {
    /// The same 7, 14 and 30 days as the Lows, Highs and Overnight cards.
    typealias Period = LowsSummary.Period

    static let hoursInDay = 24
    /// Days with readings the card needs before it shows.
    static let minimumDays = 3
    /// Days an hour needs, counted, before its cell gets a figure.
    static let minimumHourDays = 3
    /// 5-minute buckets an hour needs on a day to count that day: half of twelve.
    static let minimumBucketsPerHour = 6
    /// At or above this share in range a cell is "in range" (the consensus 70% target).
    static let targetShare = 0.7
    /// Under this share in range a cell's colour is strong.
    static let strongShare = 0.5

    /// How a cell is coloured.
    enum Shade: Hashable, Sendable {
        /// 70% or more in range.
        case inRange
        /// Under 70%, more of the rest above the high line; `strong` under 50%.
        case high(strong: Bool)
        /// Under 70%, more of the rest below the low line; `strong` under 50%.
        case low(strong: Bool)
    }

    /// One hour of the day across the period's counted days.
    struct Hour: Hashable, Sendable {
        /// Local clock hour, 0 (midnight to 1 am) to 23.
        let hour: Int
        let timeInRange: Double
        let timeBelow: Double
        let timeAbove: Double
        /// Days the hour counted on.
        let days: Int
        /// 5-minute buckets behind the figures.
        let buckets: Int

        var shade: Shade {
            if timeInRange >= HourlyInRange.targetShare { return .inRange }
            let strong = timeInRange < HourlyInRange.strongShare
            return timeBelow > timeAbove ? .low(strong: strong) : .high(strong: strong)
        }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    /// One per local hour from midnight; nil where the hour lacked readings on enough days.
    let hours: [Hour?]
    /// Days with at least one counted hour.
    let days: Int
    /// The share of every counted bucket in range, 0...1.
    let timeInRange: Double

    var counted: [Hour] { hours.compactMap { $0 } }

    /// The hour most in range; the earliest on a tie.
    var best: Hour? {
        var out: Hour?
        for h in counted where out == nil || h.timeInRange > out!.timeInRange { out = h }
        return out
    }

    /// The hour least in range; the earliest on a tie.
    var toughest: Hour? {
        var out: Hour?
        for h in counted where out == nil || h.timeInRange < out!.timeInRange { out = h }
        return out
    }

    /// Hours at 70% or more in range.
    var hoursMeetingTarget: Int { counted.filter { $0.timeInRange >= Self.targetShare }.count }

    func hour(_ h: Int) -> Hour? { h >= 0 && h < hours.count ? hours[h] : nil }

    // MARK: Compute

    /// The local clock hour a moment falls in, as the cells and the Logbook read it.
    static func hour(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        calendar.component(.hour, from: date)
    }

    static func compute(readings: [GlucoseReading], low: Double, high: Double, period: Period,
                        calendar: Calendar = .autoupdatingCurrent) -> HourlyInRange? {
        guard let newest = readings.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp
        let start = end.addingTimeInterval(-Double(period.days) * 86_400)

        let size = Double(TodaySoFar.bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.mgdl > 0 && r.timestamp > start && r.timestamp <= end {
            let key = Int((r.timestamp.timeIntervalSince1970 / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        guard !sums.isEmpty else { return nil }

        // Each bucket's mean, grouped by local day and clock hour.
        struct Slot: Hashable { let day: Date; let hour: Int }
        var slots: [Slot: [Double]] = [:]
        for (key, v) in sums {
            let at = Date(timeIntervalSince1970: Double(key) * size)
            let slot = Slot(day: calendar.startOfDay(for: at), hour: calendar.component(.hour, from: at))
            slots[slot, default: []].append(v.sum / Double(v.n))
        }

        var perHour = Array(repeating: (inRange: 0, below: 0, above: 0, total: 0, days: 0), count: hoursInDay)
        var countedDays = Set<Date>()
        for (slot, values) in slots where values.count >= minimumBucketsPerHour {
            guard slot.hour >= 0 && slot.hour < hoursInDay else { continue }
            countedDays.insert(slot.day)
            var h = perHour[slot.hour]
            for v in values {
                if v < low { h.below += 1 } else if v > high { h.above += 1 } else { h.inRange += 1 }
            }
            h.total += values.count
            h.days += 1
            perHour[slot.hour] = h
        }
        guard countedDays.count >= minimumDays else { return nil }

        var hours: [Hour?] = []
        var inRange = 0, total = 0
        for (i, h) in perHour.enumerated() {
            guard h.days >= minimumHourDays, h.total > 0 else { hours.append(nil); continue }
            let t = Double(h.total)
            hours.append(Hour(hour: i, timeInRange: Double(h.inRange) / t, timeBelow: Double(h.below) / t,
                              timeAbove: Double(h.above) / t, days: h.days, buckets: h.total))
            inRange += h.inRange
            total += h.total
        }
        guard total > 0 else { return nil }
        return HourlyInRange(period: period, end: end, hours: hours, days: countedDays.count,
                             timeInRange: Double(inRange) / Double(total))
    }
}

// MARK: - Words

/// The card's words, shown and spoken. Times read as people say them ("7–8 am", "11 am–noon").
enum HourlyInRangeText {
    static let title = "Time in range by hour"

    static func emptyLine(_ period: HourlyInRange.Period) -> String {
        "Each hour of the day over \(period.spoken) shows here once GlucOS has readings from \(HourlyInRange.minimumDays) days."
    }

    static func percent(_ share: Double) -> String { HighsSummaryText.percent(share) }

    /// "midnight", "7 am", "noon", "3 pm": the start of an hour.
    static func clock(_ hour: Int) -> String { DayPatternText.clock(hour * 60) }

    /// The cell's hour as shown: "7–8 am", "11 am–noon", "noon–1 pm", "11 pm–midnight",
    /// "midnight–1 am".
    static func span(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let from = clock(h), to = clock(h + 1)
        // "7–8 am": one suffix when both ends are plain hours on the same side of noon.
        if h != 0, h != 11, h != 12, h != 23 {
            let suffix = h < 12 ? " am" : " pm"
            let a = from.replacingOccurrences(of: suffix, with: ""), b = to.replacingOccurrences(of: suffix, with: "")
            return "\(a)–\(b)\(suffix)"
        }
        return "\(from)–\(to)"
    }

    /// The same with a capital, to start a line or a VoiceOver label: "Midnight–1 am".
    static func spanTitle(_ hour: Int) -> String {
        let s = span(hour)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// For VoiceOver: "7 am to 8 am", "11 pm to midnight".
    static func spokenSpan(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let s = "\(clock(h)) to \(clock(h + 1))"
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// The axis labels under the strip.
    static func tick(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        default: return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
        }
    }

    /// "Most in range 2–3 pm (92%), least 7–8 am (54%)." One line when every counted hour is the
    /// same figure.
    static func headline(_ s: HourlyInRange) -> String {
        guard let best = s.best, let worst = s.toughest else { return "" }
        if percent(best.timeInRange) == percent(worst.timeInRange) {
            return "\(percent(best.timeInRange)) in range in every hour with readings."
        }
        return "Most in range \(span(best.hour)) (\(percent(best.timeInRange))), least \(span(worst.hour)) (\(percent(worst.timeInRange)))."
    }

    /// "16 of 24 hours at 70% or more in range."
    static func targetLine(_ s: HourlyInRange) -> String {
        let n = s.hoursMeetingTarget, of = s.counted.count
        let hours = of == 1 ? "hour" : "hours"
        return "\(n) of \(of) \(hours) at \(percent(HourlyInRange.targetShare)) or more in range."
    }

    /// Under a cell's figure, or its tooltip: "30% above, 4% below, 12 days".
    static func detail(_ h: HourlyInRange.Hour) -> String {
        var parts: [String] = []
        if h.timeAbove > 0 { parts.append("\(percent(h.timeAbove)) above") }
        if h.timeBelow > 0 { parts.append("\(percent(h.timeBelow)) below") }
        parts.append(h.days == 1 ? "1 day" : "\(h.days) days")
        return parts.joined(separator: ", ")
    }

    /// The Mac tooltip: "7–8 am: 54% in range, 30% above, 12 days".
    static func help(_ hour: Int, _ h: HourlyInRange.Hour?) -> String {
        guard let h else { return "\(spanTitle(hour)): not enough readings" }
        return "\(spanTitle(hour)): \(percent(h.timeInRange)) in range, \(detail(h))"
    }

    /// A cell's VoiceOver value: "54 percent in range, 30 percent above, 16 percent below, over 12
    /// days." or "Not enough readings."
    static func spokenCell(_ h: HourlyInRange.Hour?) -> String {
        guard let h else { return "Not enough readings." }
        var parts = ["\(HighsSummaryText.spokenPercent(h.timeInRange)) in range"]
        if h.timeAbove > 0 { parts.append("\(HighsSummaryText.spokenPercent(h.timeAbove)) above") }
        if h.timeBelow > 0 { parts.append("\(HighsSummaryText.spokenPercent(h.timeBelow)) below") }
        return parts.joined(separator: ", ") + ", over " + (h.days == 1 ? "1 day." : "\(h.days) days.")
    }

    /// "Opens the Logbook on what was logged between 7 am and 8 am over the last 14 days".
    static func logbookHint(_ hour: Int, _ period: HourlyInRange.Period) -> String {
        "Opens the Logbook on what was logged between \(clock(hour)) and \(clock(hour + 1)) over \(period.spoken)"
    }

    /// With "Compare to previous period" on: "Biggest change from the previous 14 days: 7–8 am, up
    /// 12 pts."
    static func changeLine(hour: Int, delta: InsightsDelta, previous phrase: String) -> String {
        "Biggest change from \(phrase): \(span(hour)), \(delta.direction == .up ? "up" : "down") \(delta.magnitude)."
    }

    /// The legend under the strip, in order.
    static let legend: [(shade: HourlyInRange.Shade, label: String)] = [
        (.inRange, "70%+ in range"),
        (.high(strong: true), "Mostly high"),
        (.low(strong: true), "Mostly low"),
    ]

    static func footnote(_ s: HourlyInRange) -> String {
        var t = "Each cell is one hour of the clock. An hour counts on a day with readings for half of it, and needs \(HourlyInRange.minimumHourDays) such days. Tap an hour to see what was logged then."
        if s.days < s.period.days {
            t += " Based on \(s.days) days with readings."
        }
        return t + " Observations, not advice."
    }

    /// The whole card for VoiceOver before the cells: the period, overall figure and best/toughest.
    static func spoken(_ s: HourlyInRange) -> String {
        var parts = ["Time in range by hour, \(s.period.spoken)"]
        parts.append("\(HighsSummaryText.spokenPercent(s.timeInRange)) in range overall")
        if let best = s.best, let worst = s.toughest, best.hour != worst.hour {
            parts.append("Most in range \(spokenSpan(best.hour).lowercased()), \(HighsSummaryText.spokenPercent(best.timeInRange))")
            parts.append("least \(spokenSpan(worst.hour).lowercased()), \(HighsSummaryText.spokenPercent(worst.timeInRange))")
        }
        parts.append(String(targetLine(s).dropLast()))
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a change of either line,
/// or a new period.
@MainActor
final class HourlyInRangeCache {
    static let shared = HourlyInRangeCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
        var period: HourlyInRange.Period
    }

    private var stored: (key: Key, value: HourlyInRange?)?

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double,
                                period: HourlyInRange.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high, period: period)
    }

    func cached(_ key: Key) -> HourlyInRange?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> HourlyInRange? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            HourlyInRange.compute(readings: readings, low: low, high: high, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
