import Foundation

// A usual day: where glucose tends to sit at each time of day over the last 14 or 30 days, drawn as
// a middle line (the median) with the middle half (25th–75th percentile) and most readings (10th–
// 90th) shaded around it. The same picture as an ambulatory glucose profile (AGP), built from the
// readings GlucOS stores locally (up to 90 days).
//
// Method:
// 1. Readings are first averaged into 5-minute buckets per calendar day, so a stretch of 1-minute
//    Bluetooth readings counts the same as LibreLinkUp's 15-minute history and no single day
//    outweighs the others.
// 2. The buckets are grouped into 30-minute slots of the day (local time). A slot needs
//    `minimumPerSlot` buckets, otherwise it's left as a gap rather than guessed.
// 3. Each slot's 10th, 25th, 50th, 75th and 90th percentiles are taken, then smoothed with a
//    1-2-1 average over the neighbouring slots (wrapping round midnight). A weighted average keeps
//    the percentiles in order, so the bands never cross.
//
// Observational only, like every Insights card: it describes what happened and never suggests a
// change to insulin or settings. Plain Foundation, so it's unit-tested; worked out once per data
// change off the main thread (see `DayPatternCache`), never per frame.

struct DayPattern: Hashable {
    enum Window: Int, CaseIterable, Identifiable, Hashable {
        case fortnight = 14
        case month = 30

        var id: Int { rawValue }
        var days: Int { rawValue }
        var label: String { "\(rawValue) days" }
    }

    struct Slot: Hashable {
        /// Minutes after midnight the slot starts at.
        let minute: Int
        let p10: Double
        let p25: Double
        let p50: Double
        let p75: Double
        let p90: Double
        /// 5-minute buckets behind the slot.
        let count: Int

        /// The slot's middle, where it's plotted.
        var midMinute: Double { Double(minute) + Double(DayPattern.slotMinutes) / 2 }
    }

    static let slotMinutes = 30
    static let bucketMinutes = 5
    static var slotCount: Int { 1440 / slotMinutes }
    /// Days with readings needed before the pattern is shown.
    static let minimumDays = 5
    /// 5-minute buckets a slot needs (two days' worth of 15-minute history).
    static let minimumPerSlot = 8
    /// The share of slots that must have enough data, or the day has too many holes to read.
    static let minimumSlotShare = 0.75

    let window: Window
    /// One per 30-minute slot from midnight, nil where there weren't enough readings.
    let slots: [Slot?]
    /// Calendar days in the window that had readings.
    let days: Int

    var filled: [Slot] { slots.compactMap { $0 } }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], window: Window, now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> DayPattern? {
        let cutoff = now.addingTimeInterval(-Double(window.days) * 86_400)
        // (day key × buckets per day + bucket) -> (sum, n)
        let bucketsPerDay = 1440 / bucketMinutes
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        var dayKeys = Set<Int>()
        for r in readings where r.timestamp > cutoff && r.timestamp <= now && r.mgdl > 0 {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: r.timestamp)
            guard let y = c.year, let m = c.month, let d = c.day, let h = c.hour, let mi = c.minute else { continue }
            let day = y * 10_000 + m * 100 + d
            dayKeys.insert(day)
            let key = day * bucketsPerDay + (h * 60 + mi) / bucketMinutes
            let old = buckets[key] ?? (0, 0)
            buckets[key] = (old.sum + r.mgdl, old.n + 1)
        }
        guard dayKeys.count >= minimumDays else { return nil }

        let bucketsPerSlot = slotMinutes / bucketMinutes
        var bySlot = [[Double]](repeating: [], count: slotCount)
        for (key, b) in buckets {
            let slot = (key % bucketsPerDay) / bucketsPerSlot
            bySlot[slot].append(b.sum / Double(b.n))
        }

        let raw: [Slot?] = bySlot.enumerated().map { i, values in
            guard values.count >= minimumPerSlot else { return nil }
            let s = values.sorted()
            return Slot(minute: i * slotMinutes,
                        p10: percentile(s, 0.10), p25: percentile(s, 0.25), p50: percentile(s, 0.50),
                        p75: percentile(s, 0.75), p90: percentile(s, 0.90), count: values.count)
        }
        let present = raw.compactMap { $0 }.count
        guard Double(present) >= minimumSlotShare * Double(slotCount) else { return nil }
        // A 14-day window touches 15 calendar days (part of the first and today).
        return DayPattern(window: window, slots: smooth(raw), days: min(dayKeys.count, window.days))
    }

    /// Linear interpolation between the two nearest ranks. `sorted` must be ascending and non-empty.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }

    /// 1-2-1 weights over each slot and its neighbours, wrapping round midnight. A missing
    /// neighbour is left out and the weights renormalised; a missing slot stays missing.
    static func smooth(_ slots: [Slot?]) -> [Slot?] {
        let n = slots.count
        return slots.indices.map { i in
            guard let mid = slots[i] else { return nil }
            let parts: [(Slot, Double)] = [(slots[(i - 1 + n) % n], 1.0), (mid, 2.0), (slots[(i + 1) % n], 1.0)]
                .compactMap { s, w in s.map { ($0, w) } }
            let total = parts.reduce(0) { $0 + $1.1 }
            func avg(_ k: KeyPath<Slot, Double>) -> Double { parts.reduce(0) { $0 + $1.0[keyPath: k] * $1.1 } / total }
            return Slot(minute: mid.minute, p10: avg(\.p10), p25: avg(\.p25), p50: avg(\.p50),
                        p75: avg(\.p75), p90: avg(\.p90), count: mid.count)
        }
    }

    // MARK: Highlights

    /// Consecutive slots, as indices into `slots`.
    struct Run: Hashable {
        let first: Int
        let last: Int
    }

    struct Highlights: Hashable {
        /// The median's highest and lowest slots.
        var peak: Slot
        var trough: Slot
        /// The slot whose lowest tenth dips furthest below range, if any does.
        var lowDip: Slot?
        /// The longest run of slots whose median is above range.
        var medianAbove: Run?
        /// Same, for the top of the middle half (often above range, though the middle line isn't).
        var middleHalfAbove: Run?
        /// The middle half stays inside the target at every slot.
        var middleHalfInRange: Bool
        /// The slot with the widest middle half: when the day is least predictable.
        var widest: Slot
    }

    func highlights(low: Double, high: Double) -> Highlights? {
        let f = filled
        guard let peak = f.max(by: { $0.p50 < $1.p50 }), let trough = f.min(by: { $0.p50 < $1.p50 }),
              let widest = f.max(by: { ($0.p75 - $0.p25) < ($1.p75 - $1.p25) }) else { return nil }
        let dip = f.filter { $0.p10 < low }.min(by: { $0.p10 < $1.p10 })
        return Highlights(peak: peak, trough: trough, lowDip: dip,
                          medianAbove: longestRun { $0.p50 > high },
                          middleHalfAbove: longestRun { $0.p75 > high },
                          middleHalfInRange: f.allSatisfy { $0.p25 >= low && $0.p75 <= high },
                          widest: widest)
    }

    /// The longest stretch of consecutive slots (indices into `slots`) meeting `test`. A missing
    /// slot breaks a run. Doesn't wrap round midnight, so the times read in order.
    func longestRun(_ test: (Slot) -> Bool) -> Run? {
        var best: Run?
        var start: Int?
        for i in 0...slots.count {
            let hit = i < slots.count && (slots[i].map(test) ?? false)
            if hit, start == nil { start = i }
            if !hit, let s = start {
                if best.map({ $0.last - $0.first < i - 1 - s }) ?? true { best = Run(first: s, last: i - 1) }
                start = nil
            }
        }
        return best
    }
}

// MARK: - Words

/// The card's words, shown and spoken. Times read as people say them ("3 am", "2:30 pm"); values
/// use the person's unit without the unit name, like the rest of Insights.
enum DayPatternText {
    static let title = "Your usual day"
    /// A middle line that moves less than this (0.5 mmol/L) over the day reads as steady.
    static let steadyMgdl = 9.0

    static func emptyLine(_ window: DayPattern.Window) -> String {
        "Your usual day shows here once GlucOS has \(DayPattern.minimumDays) days of readings in the last \(window.days) days."
    }

    /// "3 am", "2:30 pm", "midnight", "noon".
    static func clock(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        if m == 0 { return "midnight" }
        if m == 720 { return "noon" }
        let h24 = m / 60, mm = m % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        let suffix = h24 < 12 ? "am" : "pm"
        return mm == 0 ? "\(h12) \(suffix)" : "\(h12):\(mm < 10 ? "0" : "")\(mm) \(suffix)"
    }

    /// "from 12 pm to 3 pm", for a run of slots: the end is where the last slot finishes.
    static func span(_ run: DayPattern.Run) -> String {
        "from \(clock(run.first * DayPattern.slotMinutes)) to \(clock((run.last + 1) * DayPattern.slotMinutes))"
    }

    /// The visible lines under the chart, most useful first.
    static func lines(_ p: DayPattern, unit: GlucoseUnit, low: Double, high: Double) -> [String] {
        guard let h = p.highlights(low: low, high: high) else { return [] }
        var out: [String] = []
        if h.peak.p50 - h.trough.p50 < steadyMgdl {
            out.append("Steady through the day, around \(unit.format(mgdl: (h.peak.p50 + h.trough.p50) / 2)).")
        } else {
            out.append("Highest around \(clock(h.peak.minute)) (\(unit.format(mgdl: h.peak.p50))), lowest around \(clock(h.trough.minute)) (\(unit.format(mgdl: h.trough.p50))).")
        }
        if h.middleHalfInRange {
            out.append("The middle half stays in range all day.")
        } else if let run = h.medianAbove {
            out.append("The middle line is above range \(span(run)).")
        } else if let run = h.middleHalfAbove {
            out.append("Readings are often above range \(span(run)).")
        }
        if let dip = h.lowDip {
            out.append("The lowest tenth dips below range around \(clock(dip.minute)).")
        }
        return out
    }

    /// The whole card in a few sentences, for VoiceOver.
    static func spoken(_ p: DayPattern, unit: GlucoseUnit, low: Double, high: Double) -> String {
        var parts = ["Usual day over the last \(p.window.days) days, from \(p.days) days of readings"]
        parts.append("Target \(unit.format(mgdl: low)) to \(unit.format(mgdl: high)) \(unit.label)")
        parts += lines(p, unit: unit, low: low, high: high).map { String($0.dropLast()) }
        if let h = p.highlights(low: low, high: high) {
            parts.append("Most variable around \(clock(h.widest.minute))")
        }
        return parts.joined(separator: ". ") + "."
    }

    static let legendMedian = "Middle"
    static let legendInner = "Middle half"
    static let legendOuter = "8 in 10 readings"
    static let footnote = "Each time of day across the period: the line is the middle reading, the darker band holds half of readings and the lighter band 8 in 10. Observations, not advice."
}

// MARK: - Cache

/// Keeps the last pattern for each window, so Insights works it out once per data change rather
/// than on every redraw, resize or visit. A new reading changes the pattern by a hair, so the key
/// moves on every 15 minutes of new data (and at least once a day as the window slides).
@MainActor
final class DayPatternCache {
    static let shared = DayPatternCache()

    struct Key: Hashable {
        var window: DayPattern.Window
        /// The newest reading, rounded down to 15 minutes.
        var newest: Date?
        var count15: Int
    }

    private var stored: [DayPattern.Window: (key: Key, pattern: DayPattern?)] = [:]

    nonisolated static func key(readings: [GlucoseReading], window: DayPattern.Window) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        // Backfilled history (a sensor scan, a relay fill) adds many readings without a newer one.
        return Key(window: window, newest: newest, count15: readings.count / 15)
    }

    /// The stored pattern for `key`, if it's already been worked out.
    func cached(_ key: Key) -> DayPattern?? {
        guard let s = stored[key.window], s.key == key else { return nil }
        return .some(s.pattern)
    }

    func pattern(for key: Key, readings: [GlucoseReading], now: Date = Date()) async -> DayPattern? {
        if let hit = cached(key) { return hit }
        let window = key.window
        let p = await Task.detached(priority: .utility) {
            DayPattern.compute(readings: readings, window: window, now: now)
        }.value
        stored[window] = (key, p)
        return p
    }
}
