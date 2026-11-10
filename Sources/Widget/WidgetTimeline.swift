import WidgetKit
import Foundation
import SwiftUI

// MARK: - Freshness

/// How much the widget should trust the current reading. Drives every colour decision: only a
/// `.fresh` reading is ever shown in its range colour.
enum ReadingFreshness {
    /// Within `GlucoseSnapshot.staleAfter` (6 min).
    case fresh
    /// Older than that: the number is greyed and flagged, never tinted.
    case stale
    /// Older than `expiredAfter`: the number is withdrawn entirely, so a glance can't mistake a
    /// half-hour-old value for the current one.
    case expired
    /// No reading at all.
    case none

    static let expiredAfter: TimeInterval = 30 * 60

    init(_ snapshot: GlucoseSnapshot, at date: Date) {
        guard let current = snapshot.current else { self = .none; return }
        let age = current.age(at: date)
        if age > Self.expiredAfter { self = .expired } else if age > GlucoseSnapshot.staleAfter { self = .stale } else { self = .fresh }
    }

    var showsValue: Bool { self == .fresh || self == .stale }
}

// MARK: - Schedule

/// The dates a timeline needs entries for, so "3m ago" and the stale/expired styling change on
/// time even if the app is quiet (asleep, quit, offline). The app reloads every timeline after
/// each fetch, so in normal use only the first few entries are ever shown.
enum FreshnessSchedule {
    static func dates(for snapshot: GlucoseSnapshot, from now: Date) -> [Date] {
        var dates: [Date] = [now]
        if let reading = snapshot.current?.timestamp {
            // One entry per minute of age for the first hour, which covers both transitions.
            for minute in 1...60 {
                let d = reading.addingTimeInterval(Double(minute) * 60)
                if d > now { dates.append(d) }
            }
            // The exact moments the styling changes, in case they fall between minutes.
            for edge in [GlucoseSnapshot.staleAfter + 1, ReadingFreshness.expiredAfter + 1] {
                let d = reading.addingTimeInterval(edge)
                if d > now { dates.append(d) }
            }
        }
        if dates.count == 1 {
            // Already over an hour old (or no reading): the age text only changes slowly now.
            for m in stride(from: 15, through: 60, by: 15) { dates.append(now.addingTimeInterval(Double(m) * 60)) }
        }
        return Array(Set(dates)).sorted()
    }

    static func reloadDate(after dates: [Date], now: Date) -> Date {
        max(dates.last ?? now, now.addingTimeInterval(5 * 60))
    }
}

// MARK: - Glucose widget timeline

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot
    var configuration = GlucoseWidgetIntent()

    var freshness: ReadingFreshness { ReadingFreshness(snapshot, at: date) }
}

struct GlucoseProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(date: Date(), snapshot: .preview)
    }

    func snapshot(for configuration: GlucoseWidgetIntent, in context: Context) async -> GlucoseEntry {
        let snap = context.isPreview ? .preview : (SharedStore.load() ?? .empty)
        return GlucoseEntry(date: Date(), snapshot: snap, configuration: configuration)
    }

    func timeline(for configuration: GlucoseWidgetIntent, in context: Context) async -> Timeline<GlucoseEntry> {
        let snap = SharedStore.load() ?? .empty
        let now = Date()
        let dates = FreshnessSchedule.dates(for: snap, from: now)
        let entries = dates.map { GlucoseEntry(date: $0, snapshot: snap, configuration: configuration) }
        return Timeline(entries: entries, policy: .after(FreshnessSchedule.reloadDate(after: dates, now: now)))
    }
}

// MARK: - Insight (time in range / sensor) timelines

struct InsightEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot
    let summary: RangeSummary?
    let period: InsightPeriod
}

struct TimeInRangeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> InsightEntry {
        let snap = GlucoseSnapshot.preview
        return InsightEntry(date: Date(), snapshot: snap,
                            summary: RangeSummary(readings: snap.history, low: snap.lowMgdl, high: snap.highMgdl, span: 12 * 3600),
                            period: .last24Hours)
    }

    func snapshot(for configuration: TimeInRangeIntent, in context: Context) async -> InsightEntry {
        context.isPreview ? placeholder(in: context) : entry(for: configuration.period, at: Date())
    }

    func timeline(for configuration: TimeInRangeIntent, in context: Context) async -> Timeline<InsightEntry> {
        let now = Date()
        // A summary over hours or days barely moves between fetches, and every fetch reloads it.
        return Timeline(entries: [entry(for: configuration.period, at: now)], policy: .after(now.addingTimeInterval(30 * 60)))
    }

    private func entry(for period: InsightPeriod, at now: Date) -> InsightEntry {
        let snap = SharedStore.load() ?? .empty
        let readings = WidgetHistory.readings(since: now.addingTimeInterval(-period.seconds), snapshot: snap)
        return InsightEntry(date: now, snapshot: snap,
                            summary: RangeSummary(readings: readings, low: snap.lowMgdl, high: snap.highMgdl, span: period.seconds),
                            period: period)
    }
}

struct SensorProvider: TimelineProvider {
    func placeholder(in context: Context) -> InsightEntry {
        InsightEntry(date: Date(), snapshot: .preview, summary: nil, period: .last24Hours)
    }

    func getSnapshot(in context: Context, completion: @escaping (InsightEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context)
                   : InsightEntry(date: Date(), snapshot: SharedStore.load() ?? .empty, summary: nil, period: .last24Hours))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InsightEntry>) -> Void) {
        let snap = SharedStore.load() ?? .empty
        let now = Date()
        // Hourly is plenty for "x days left"; switch to every 15 min in the last day.
        let step: TimeInterval = (snap.sensor?.daysRemaining(at: now) ?? 2) < 1 ? 15 * 60 : 3600
        let entries = (0..<6).map { InsightEntry(date: now.addingTimeInterval(Double($0) * step), snapshot: snap, summary: nil, period: .last24Hours) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * step))))
    }
}

// MARK: - Longer history

/// Reads the app's on-disk archive (up to 90 days) so the Time in Range widget can cover more than
/// the 12 hours LibreLinkUp returns. The widget has read-only access to the same folder.
enum WidgetHistory {
    static func readings(since start: Date, snapshot: GlucoseSnapshot) -> [GlucoseReading] {
        var all: [GlucoseReading] = []
        if let url = SharedStore.containerURL?.appendingPathComponent("history.json"),
           let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            all = (try? decoder.decode([GlucoseReading].self, from: data)) ?? []
        }
        all += snapshot.history
        if let current = snapshot.current { all.append(current) }

        // One reading per 5-minute slot, matching the archive, so minute-by-minute readings don't
        // outweigh the rest.
        var seen = Set<Int>()
        return all
            .filter { $0.timestamp >= start }
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert(Int($0.timestamp.timeIntervalSince1970 / 300)).inserted }
    }
}

/// Five-band time in range, the way CGM reports (and the international consensus targets) show it.
struct RangeSummary {
    let urgentLow: Double
    let low: Double
    let inRange: Double
    let high: Double
    let veryHigh: Double
    let count: Int
    let meanMgdl: Double
    let cv: Double
    /// Share of the period that has data, by 15-minute slot (Libre's history is 15 minutes apart).
    let coverage: Double

    init?(readings: [GlucoseReading], low lowMgdl: Double, high highMgdl: Double, span: TimeInterval) {
        guard !readings.isEmpty else { return nil }
        var buckets = [GlucoseRange: Int]()
        for r in readings { buckets[GlucoseRange.classify(mgdl: r.mgdl, low: lowMgdl, high: highMgdl), default: 0] += 1 }
        let n = Double(readings.count)
        urgentLow = Double(buckets[.urgentLow] ?? 0) / n
        low = Double(buckets[.low] ?? 0) / n
        inRange = Double(buckets[.inRange] ?? 0) / n
        high = Double(buckets[.high] ?? 0) / n
        veryHigh = Double(buckets[.veryHigh] ?? 0) / n
        count = readings.count
        let values = readings.map(\.mgdl)
        let mean = values.reduce(0, +) / n
        meanMgdl = mean
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(1, n - 1)
        cv = mean > 0 ? variance.squareRoot() / mean : 0
        let slots = Set(readings.map { Int($0.timestamp.timeIntervalSince1970 / 900) }).count
        coverage = min(1, Double(slots) / max(1, span / 900))
    }

    var below: Double { urgentLow + low }
    var above: Double { high + veryHigh }
    var gmiPercent: Double { 3.31 + 0.02392 * meanMgdl }

    /// Bottom to top, for the ring.
    var segments: [(fraction: Double, color: Color)] {
        [(urgentLow, GlucoseRange.urgentLow.tint), (low, GlucoseRange.low.tint), (inRange, GlucoseRange.inRange.tint),
         (high, GlucoseRange.high.tint), (veryHigh, GlucoseRange.veryHigh.tint)]
    }
}
