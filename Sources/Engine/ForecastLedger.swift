import Foundation

// A record of the forecasts GlucOS actually showed, each scored against the readings that came
// after it. The backtest (`ForecastBacktest`) replays what the forecast *would* have said; this is
// the other half: what it *did* say, at the time, with whatever had been learnt by then. Together
// they answer "how accurate has it been?" and show whether it's getting better as history grows.
//
// One forecast is kept every 15 minutes. Each is scored at the horizons the backtest checks, once
// the readings for them are in, and settled a little after its last horizon (readings can arrive
// late, and food or insulin can be logged afterwards with an earlier time). A point is marked
// `afterLog` when anything was logged between the forecast and that point, because the forecast
// is explicitly "if nothing else changes": those points are reported separately.

struct ForecastRecord: Codable, Hashable, Identifiable {
    struct Point: Codable, Hashable {
        let minutes: Int
        let mgdl: Double
        let lower: Double
        let upper: Double
        /// The reading at this point, once known. Nil if there was no reading near it.
        var actual: Double?
        /// Insulin, food or an event was logged between the forecast and this point.
        var afterLog: Bool = false

        var error: Double? { actual.map { $0 - mgdl } }
        var insideRange: Bool? { actual.map { $0 >= lower && $0 <= upper } }
    }

    let id: UUID
    /// The reading the forecast started from.
    let issuedAt: Date
    /// "Mac" or "iPhone".
    let device: String
    let basis: ForecastBasis
    let startMgdl: Double
    /// mg/dL per minute.
    let trendPerMinute: Double
    var points: [Point]
    /// `ForecastLimitation.code`s.
    let limitations: [String]
    /// The range came from this user's accuracy checks rather than the cautious default.
    let calibrated: Bool
    /// The trend timing was tuned to this user (`ForecastTuner`).
    let tuned: Bool
    /// The post-wake adjustment was included.
    let morning: Bool
    /// Every point has been scored (or its time has passed without a reading).
    var settled = false
    /// Sent to the sync server.
    var uploaded = false

    var lastMinutes: Int { points.map(\.minutes).max() ?? 0 }
}

struct ForecastLedger: Codable, Equatable {
    var records: [ForecastRecord] = []

    /// At most one forecast is kept per this long.
    static let spacing: TimeInterval = 15 * 60
    static let retention: TimeInterval = 90 * 86_400
    /// How long after its last point a forecast waits for late readings and logs.
    static let settleAfter: TimeInterval = 20 * 60
    static var checkedMinutes: [Int] { ForecastCalibration.horizons }

    /// Keeps `forecast` if it's the first in its 15 minutes. Returns whether it was added.
    @discardableResult
    mutating func note(_ forecast: GlucoseForecast, device: String, tuned: Bool, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(forecast.issuedAt) <= GlucoseSnapshot.staleAfter else { return false }
        if let last = records.last, forecast.issuedAt.timeIntervalSince(last.issuedAt) < Self.spacing { return false }
        let points: [ForecastRecord.Point] = Self.checkedMinutes.compactMap { m in
            let target = forecast.issuedAt.addingTimeInterval(TimeInterval(m * 60))
            guard let s = forecast.samples.first(where: { abs($0.date.timeIntervalSince(target)) < 30 }) else { return nil }
            return ForecastRecord.Point(minutes: m, mgdl: s.mgdl, lower: s.lowerMgdl, upper: s.upperMgdl)
        }
        guard !points.isEmpty else { return false }
        records.append(ForecastRecord(id: UUID(), issuedAt: forecast.issuedAt, device: device, basis: forecast.basis,
                                      startMgdl: forecast.startMgdl, trendPerMinute: forecast.trendPerMinute,
                                      points: points, limitations: forecast.limitations.map(\.code),
                                      calibrated: forecast.calibrated, tuned: tuned, morning: forecast.morning != nil))
        return true
    }

    /// Fills in readings for points whose time has come, and settles forecasts that are done.
    /// `logTimes` are the times of every dose, meal and event. Returns whether anything changed.
    @discardableResult
    mutating func score(readings: GlucoseSeries, logTimes: [Date], now: Date = Date()) -> Bool {
        let logs = logTimes.sorted()
        var changed = false
        for i in records.indices where !records[i].settled {
            let r = records[i]
            for j in r.points.indices {
                let target = r.issuedAt.addingTimeInterval(TimeInterval(r.points[j].minutes * 60))
                guard target <= now else { continue }
                // Re-read until settled: a later fetch can fill a gap the first one had.
                if let v = readings.value(at: target), v != r.points[j].actual {
                    records[i].points[j].actual = v
                    changed = true
                }
                let logged = Self.anyLog(in: logs, after: r.issuedAt, before: target)
                if logged != r.points[j].afterLog {
                    records[i].points[j].afterLog = logged
                    changed = true
                }
            }
            if now >= r.issuedAt.addingTimeInterval(TimeInterval(r.lastMinutes * 60) + Self.settleAfter) {
                records[i].settled = true
                changed = true
            }
        }
        return changed
    }

    /// Drops forecasts past retention. Returns whether any went.
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let before = records.count
        records.removeAll { $0.issuedAt < cutoff }
        return records.count != before
    }

    /// Settled forecasts not yet sent, oldest first.
    func pendingUpload(limit: Int = 200) -> [ForecastRecord] {
        Array(records.filter { $0.settled && !$0.uploaded }.prefix(limit))
    }

    mutating func markUploaded(_ ids: Set<UUID>) {
        for i in records.indices where ids.contains(records[i].id) { records[i].uploaded = true }
    }

    /// How the forecasts shown between `start` and `end` turned out.
    func accuracy(from start: Date, to end: Date) -> LiveAccuracy {
        LiveAccuracy(records.filter { $0.issuedAt >= start && $0.issuedAt < end })
    }

    private static func anyLog(in sorted: [Date], after start: Date, before end: Date) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= start { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count && sorted[lo] < end
    }
}

/// How a set of shown forecasts turned out, per horizon.
struct LiveAccuracy: Hashable {
    struct Horizon: Hashable {
        let minutes: Int
        let checks: Int
        /// Mean absolute error, mg/dL.
        let meanAbsoluteError: Double
        /// Mean absolute error of assuming no change, mg/dL.
        let naiveError: Double
        /// Mean of actual − forecast, mg/dL. Positive: the forecast ran low.
        let bias: Double
        /// Share of readings inside the forecast's likely range (it aims for about 8 in 10).
        let insideRange: Double
    }

    /// Forecasts that had at least one scored point.
    let forecasts: Int
    /// Points with nothing logged in between: the forecast's own job.
    let clean: [Horizon]
    /// Every scored point, including ones where food or insulin came after the forecast.
    let all: [Horizon]

    static let empty = LiveAccuracy([])

    init(_ records: [ForecastRecord]) {
        forecasts = records.filter { $0.points.contains { $0.actual != nil } }.count
        clean = Self.horizons(records, clean: true)
        all = Self.horizons(records, clean: false)
    }

    func clean(at minutes: Int) -> Horizon? { clean.first { $0.minutes == minutes } }
    func all(at minutes: Int) -> Horizon? { all.first { $0.minutes == minutes } }

    private static func horizons(_ records: [ForecastRecord], clean: Bool) -> [Horizon] {
        var byMinutes: [Int: [(error: Double, naive: Double, inside: Bool)]] = [:]
        for r in records {
            for p in r.points where !(clean && p.afterLog) {
                guard let actual = p.actual, let e = p.error, let inside = p.insideRange else { continue }
                byMinutes[p.minutes, default: []].append((error: e, naive: actual - r.startMgdl, inside: inside))
            }
        }
        return byMinutes.keys.sorted().compactMap { m in
            guard let xs = byMinutes[m], !xs.isEmpty else { return nil }
            let n = Double(xs.count)
            return Horizon(minutes: m, checks: xs.count,
                           meanAbsoluteError: xs.map { abs($0.error) }.reduce(0, +) / n,
                           naiveError: xs.map { abs($0.naive) }.reduce(0, +) / n,
                           bias: xs.map { $0.error }.reduce(0, +) / n,
                           insideRange: Double(xs.filter { $0.inside }.count) / n)
        }
    }
}

/// Plain-language lines about accuracy and tuning, shared by the Mac and iPhone.
enum ForecastAccuracyText {
    /// Checks needed in each period before two periods are compared.
    static let minimumToCompare = 20

    static func tuningLine(_ t: ForecastTuningResult) -> String {
        if t.isTuned {
            let pct = Int((t.improvement * 100).rounded())
            return "Tuned to you: \(t.tuning.summary). That cut the error by \(pct)% compared with the standard timing, across \(t.checks) past forecast points."
        }
        if t.checks >= ForecastTuner.minimumChecks {
            return "Trend timing: the standard one still forecasts you best, checked on \(t.checks) past forecast points."
        }
        return "Trend timing: standard for now. After \(ForecastTuner.minimumChecks) past forecast points GlucOS tries other timings and switches only if one is clearly better (\(t.checks) so far)."
    }

    /// "At 30 minutes ahead: ±0.8 mmol/L this week, ±1.0 in the 3 weeks before. Getting better."
    static func trendLine(lastWeek: LiveAccuracy, before: LiveAccuracy, unit: GlucoseUnit, minutes: Int = 30) -> String? {
        guard let now = lastWeek.clean(at: minutes), let then = before.clean(at: minutes),
              now.checks >= minimumToCompare, then.checks >= minimumToCompare, then.meanAbsoluteError > 0 else { return nil }
        let ratio = now.meanAbsoluteError / then.meanAbsoluteError
        let verdict = ratio <= 0.95 ? "Getting better." : ratio >= 1.05 ? "Less accurate than before." : "About the same."
        return "At \(minutes) minutes ahead: ±\(unit.format(mgdl: now.meanAbsoluteError)) this week, ±\(unit.format(mgdl: then.meanAbsoluteError)) in the 3 weeks before. \(verdict)"
    }
}
