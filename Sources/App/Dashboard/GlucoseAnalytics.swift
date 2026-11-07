import Foundation
import SwiftUI

// Calculations behind the dashboard window. No state.

/// Time ranges offered in the dashboard.
enum DashboardRange: String, CaseIterable, Identifiable {
    case h3, h6, h12, h24, d3, d7, d14, d30

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .h3: return 3 * 3600
        case .h6: return 6 * 3600
        case .h12: return 12 * 3600
        case .h24: return 24 * 3600
        case .d3: return 3 * 86_400
        case .d7: return 7 * 86_400
        case .d14: return 14 * 86_400
        case .d30: return 30 * 86_400
        }
    }

    var shortLabel: String {
        switch self {
        case .h3: return "3H"
        case .h6: return "6H"
        case .h12: return "12H"
        case .h24: return "24H"
        case .d3: return "3D"
        case .d7: return "7D"
        case .d14: return "14D"
        case .d30: return "30D"
        }
    }

    var title: String {
        switch self {
        case .h3: return "Last 3 hours"
        case .h6: return "Last 6 hours"
        case .h12: return "Last 12 hours"
        case .h24: return "Last 24 hours"
        case .d3: return "Last 3 days"
        case .d7: return "Last 7 days"
        case .d14: return "Last 14 days"
        case .d30: return "Last 30 days"
        }
    }
}

/// Share of readings in each of the five consensus ranges (urgent low < 54, low, in range,
/// high, very high > 250 mg/dL), using the same classification as the popover and alerts.
struct RangeBreakdown: Hashable {
    var urgentLow = 0.0
    var low = 0.0
    var inRange = 0.0
    var high = 0.0
    var veryHigh = 0.0

    var below: Double { urgentLow + low }
    var above: Double { high + veryHigh }

    static func compute(_ readings: [GlucoseReading], low: Double, high: Double) -> RangeBreakdown? {
        guard !readings.isEmpty else { return nil }
        var b = RangeBreakdown()
        for r in readings {
            switch GlucoseRange.classify(mgdl: r.mgdl, low: low, high: high) {
            case .urgentLow: b.urgentLow += 1
            case .low: b.low += 1
            case .inRange: b.inRange += 1
            case .high: b.high += 1
            case .veryHigh: b.veryHigh += 1
            }
        }
        let n = Double(readings.count)
        b.urgentLow /= n; b.low /= n; b.inRange /= n; b.high /= n; b.veryHigh /= n
        return b
    }

    struct Row: Identifiable {
        let range: GlucoseRange
        let fraction: Double
        var id: String { range.label }
    }

    /// Top to bottom, the way CGM reports stack them.
    var rows: [Row] {
        [Row(range: .veryHigh, fraction: veryHigh), Row(range: .high, fraction: high),
         Row(range: .inRange, fraction: inRange), Row(range: .low, fraction: low),
         Row(range: .urgentLow, fraction: urgentLow)]
    }
}

extension GlucoseRange {
    /// Colours for range breakdowns in the dashboard: the further from target, the stronger.
    var reportColor: Color {
        switch self {
        case .urgentLow: return .red
        case .low: return .red.opacity(0.55)
        case .inRange: return .green
        case .high: return .orange.opacity(0.6)
        case .veryHigh: return .orange
        }
    }
}

/// A point to plot, tagged with the run of continuous data it belongs to, so lines break across
/// gaps (sensor changes, the phone out of range) instead of drawing a straight line over them.
struct PlotPoint: Identifiable, Hashable {
    let date: Date
    let mgdl: Double
    let segment: Int
    var id: Date { date }
}

/// Glucose by time of day across many days: the ambulatory glucose profile.
struct PatternBin: Identifiable, Hashable {
    let minute: Int        // minutes after midnight, start of the bin
    let p5, p25, p50, p75, p95: Double
    let count: Int
    var id: Int { minute }
}

struct DaySummary: Identifiable, Hashable {
    let day: Date          // start of the local day
    let stats: GlucoseStats
    let breakdown: RangeBreakdown
    /// Episodes below the low threshold lasting 15 minutes or more.
    let lowEpisodes: Int
    var id: Date { day }
}

enum GlucoseAnalytics {
    /// Readings between two dates. `sorted` must be oldest → newest.
    static func slice(_ sorted: [GlucoseReading], from start: Date, to end: Date) -> [GlucoseReading] {
        let lo = lowerBound(sorted, start)
        var hi = lo
        while hi < sorted.count, sorted[hi].timestamp <= end { hi += 1 }
        return Array(sorted[lo..<hi])
    }

    /// The real reading nearest `date`, or nil when the closest one is further than `tolerance`
    /// (the pointer is over a gap). Never interpolates. `sorted` must be oldest → newest.
    static func nearest(to date: Date, in sorted: [GlucoseReading], tolerance: TimeInterval) -> GlucoseReading? {
        guard !sorted.isEmpty else { return nil }
        let i = lowerBound(sorted, date)
        let candidates = [i - 1, i].filter { $0 >= 0 && $0 < sorted.count }.map { sorted[$0] }
        guard let best = candidates.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }), abs(best.timestamp.timeIntervalSince(date)) <= tolerance else { return nil }
        return best
    }

    /// Thins readings to at most two per `bucket` (that bucket's lowest and highest, in time order),
    /// so a 30-day chart stays fast without smoothing away a single low. Then splits into
    /// continuous segments.
    static func plotPoints(_ sorted: [GlucoseReading], bucket: TimeInterval, maxGap: TimeInterval) -> [PlotPoint] {
        var thinned: [GlucoseReading] = []
        if bucket <= HistoryArchive.slot || sorted.count < 3 {
            thinned = sorted
        } else {
            thinned.reserveCapacity(Int(Double(sorted.count) * 2 * HistoryArchive.slot / bucket) + 2)
            var i = 0
            while i < sorted.count {
                let key = (sorted[i].timestamp.timeIntervalSince1970 / bucket).rounded(.down)
                var lo = i, hi = i, j = i
                while j < sorted.count, (sorted[j].timestamp.timeIntervalSince1970 / bucket).rounded(.down) == key {
                    if sorted[j].mgdl < sorted[lo].mgdl { lo = j }
                    if sorted[j].mgdl > sorted[hi].mgdl { hi = j }
                    j += 1
                }
                if lo == hi {
                    thinned.append(sorted[lo])
                } else {
                    thinned.append(sorted[min(lo, hi)])
                    thinned.append(sorted[max(lo, hi)])
                }
                i = j
            }
        }

        var out: [PlotPoint] = []
        out.reserveCapacity(thinned.count)
        var segment = 0
        var previous: Date?
        for r in thinned {
            if let previous, r.timestamp.timeIntervalSince(previous) > maxGap { segment += 1 }
            out.append(PlotPoint(date: r.timestamp, mgdl: r.mgdl, segment: segment))
            previous = r.timestamp
        }
        return out
    }

    /// Share of 15-minute slots in the range that have at least one reading.
    static func coverage(_ readings: [GlucoseReading], from start: Date, to end: Date) -> Double {
        let slot = 15.0 * 60
        let total = end.timeIntervalSince(start) / slot
        guard total > 0 else { return 0 }
        let filled = Set(readings.map { Int(($0.timestamp.timeIntervalSince1970 / slot).rounded(.down)) }).count
        return min(1, Double(filled) / total)
    }

    static func dailyPattern(_ readings: [GlucoseReading], binMinutes: Int = 30,
                             calendar: Calendar = .current) -> [PatternBin] {
        var bins: [Int: [Double]] = [:]
        for r in readings {
            let c = calendar.dateComponents([.hour, .minute], from: r.timestamp)
            let minute = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / binMinutes * binMinutes
            bins[minute, default: []].append(r.mgdl)
        }
        return bins.compactMap { minute, values -> PatternBin? in
            guard values.count >= 3 else { return nil }
            let s = values.sorted()
            return PatternBin(minute: minute,
                              p5: quantile(s, 0.05), p25: quantile(s, 0.25), p50: quantile(s, 0.5),
                              p75: quantile(s, 0.75), p95: quantile(s, 0.95), count: s.count)
        }
        .sorted { $0.minute < $1.minute }
    }

    /// Newest day first.
    static func days(_ readings: [GlucoseReading], low: Double, high: Double,
                     calendar: Calendar = .current) -> [DaySummary] {
        let grouped = Dictionary(grouping: readings) { calendar.startOfDay(for: $0.timestamp) }
        return grouped.compactMap { day, rs -> DaySummary? in
            let sorted = rs.sorted { $0.timestamp < $1.timestamp }
            guard let stats = GlucoseStats.compute(sorted, low: low, high: high),
                  let breakdown = RangeBreakdown.compute(sorted, low: low, high: high) else { return nil }
            return DaySummary(day: day, stats: stats, breakdown: breakdown,
                              lowEpisodes: lowEpisodes(sorted, low: low))
        }
        .sorted { $0.day > $1.day }
    }

    /// Runs below `low` lasting at least 15 minutes (from the first low reading until glucose is
    /// back at or above `low`). A gap of over 30 minutes ends a run at its last low reading.
    static func lowEpisodes(_ sorted: [GlucoseReading], low: Double) -> Int {
        let minimum: TimeInterval = 15 * 60
        let maxGap: TimeInterval = 30 * 60
        var count = 0
        var start: Date?
        var lastLow: Date?
        for r in sorted {
            if let s = start, let l = lastLow, r.timestamp.timeIntervalSince(l) > maxGap {
                if l.timeIntervalSince(s) >= minimum { count += 1 }
                start = nil; lastLow = nil
            }
            if r.mgdl < low {
                if start == nil { start = r.timestamp }
                lastLow = r.timestamp
            } else if let s = start {
                if r.timestamp.timeIntervalSince(s) >= minimum { count += 1 }
                start = nil; lastLow = nil
            }
        }
        if let s = start, let l = lastLow, l.timeIntervalSince(s) >= minimum { count += 1 }
        return count
    }

    /// Linear-interpolated quantile of an ascending array.
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let pos = p * Double(sorted.count - 1)
        let i = Int(pos.rounded(.down))
        let frac = pos - Double(i)
        return i + 1 < sorted.count ? sorted[i] + (sorted[i + 1] - sorted[i]) * frac : sorted[i]
    }

    static func csv(_ readings: [GlucoseReading]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        var lines = ["timestamp,mg_dl,mmol_l,trend"]
        lines.reserveCapacity(readings.count + 1)
        for r in readings {
            lines.append("\(iso.string(from: r.timestamp)),\(Int(r.mgdl.rounded())),\(String(format: "%.1f", r.mmol)),\(r.trend.description)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "2h 05m" style duration for a share of a day.
    static func perDay(_ fraction: Double) -> String {
        let minutes = Int((fraction * 24 * 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    private static func lowerBound(_ sorted: [GlucoseReading], _ date: Date) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
