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
        /// How much this point's range was widened when shown. Nil in records from before ranges
        /// were widened per horizon: the record's `rangeScale` applies.
        var scale: Double? = nil
        /// False when this point was past the horizon the forecast was drawn to: live checks had
        /// cut it off (`ForecastLiveHorizon`), and it's kept only to go on scoring that horizon.
        /// Nil (older records) or true: drawn.
        var shown: Bool? = nil

        var wasShown: Bool { shown ?? true }
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
    /// How much the range was widened when shown (`ForecastRangeScale`). Nil in records from
    /// before widening existed, which were never widened.
    var rangeScale: Double? = nil
    /// The app version that showed the forecast ("1.2.0"), so accuracy can be followed per
    /// release. Nil in records from before versions were kept, and in the relay's.
    var appVersion: String? = nil
    /// Every point has been scored (or its time has passed without a reading).
    var settled = false
    /// Sent to the sync server.
    var uploaded = false

    var lastMinutes: Int { points.map(\.minutes).max() ?? 0 }

    /// The device name the push relay records the Live Activity's own forecasts under, in the
    /// server's ledger. The apps never record under it.
    static let relayDevice = "relay"

    /// How a device is named to the user: the relay's forecasts are the ones on the Lock Screen.
    static func displayName(device: String) -> String {
        device == relayDevice ? "Lock Screen" : device
    }
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
    /// The part live checks cut off (`GlucoseForecast.unshown`) is kept too, marked as not shown.
    @discardableResult
    mutating func note(_ forecast: GlucoseForecast, device: String, tuned: Bool, appVersion: String? = nil,
                       now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(forecast.issuedAt) <= GlucoseSnapshot.staleAfter else { return false }
        if let last = records.last, forecast.issuedAt.timeIntervalSince(last.issuedAt) < Self.spacing { return false }
        let points: [ForecastRecord.Point] = Self.checkedMinutes.compactMap { m in
            let target = forecast.issuedAt.addingTimeInterval(TimeInterval(m * 60))
            let near = { (x: ForecastSample) in abs(x.date.timeIntervalSince(target)) < 30 }
            if let s = forecast.unshown.first(where: near), !forecast.samples.contains(where: near) {
                return ForecastRecord.Point(minutes: m, mgdl: s.mgdl, lower: s.lowerMgdl, upper: s.upperMgdl,
                                            scale: forecast.rangeScale(atMinutes: m), shown: false)
            }
            guard let s = forecast.samples.first(where: near) else { return nil }
            return ForecastRecord.Point(minutes: m, mgdl: s.mgdl, lower: s.lowerMgdl, upper: s.upperMgdl,
                                        scale: forecast.rangeScale(atMinutes: m))
        }
        guard !points.isEmpty else { return false }
        records.append(ForecastRecord(id: UUID(), issuedAt: forecast.issuedAt, device: device, basis: forecast.basis,
                                      startMgdl: forecast.startMgdl, trendPerMinute: forecast.trendPerMinute,
                                      points: points, limitations: forecast.limitations.map(\.code),
                                      calibrated: forecast.calibrated, tuned: tuned, morning: forecast.morning != nil,
                                      rangeScale: forecast.rangeScale, appVersion: appVersion))
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

    /// How the forecasts shown between `start` and `end` turned out, on one device or (nil) all.
    func accuracy(from start: Date, to end: Date, device: String? = nil, appVersion: String? = nil) -> LiveAccuracy {
        LiveAccuracy(records.filter {
            $0.issuedAt >= start && $0.issuedAt < end && (device == nil || $0.device == device)
                && (appVersion == nil || $0.appVersion == appVersion)
        })
    }

    /// When `device` first recorded a forecast on `appVersion`: roughly when that update was
    /// installed. Nil if it hasn't recorded one yet.
    func firstRecord(device: String, appVersion: String) -> Date? {
        records.first { $0.device == device && $0.appVersion == appVersion }?.issuedAt
    }

    /// Shown points needed before the range is widened, per kind of forecast (or all kinds
    /// together when one kind has too few).
    static let minimumForRange = 40
    /// Shown points needed at one horizon before it gets its own widening, and among fast-moving
    /// forecasts before they get theirs.
    static let minimumForHorizon = 25
    /// How far back shown forecasts count towards the range.
    static let rangeWindow: TimeInterval = 14 * 86_400
    /// The last few hours are checked again on their own, so a day of bigger misses widens the
    /// range that day rather than days later, once it outweighs the two weeks before it.
    static let recentWindow: TimeInterval = 12 * 3600
    /// Shown points needed in `recentWindow` before they can widen the range.
    static let minimumRecent = 20

    /// How much wider the range needs to be to have held 4 in 5 of the readings that followed
    /// the forecasts shown in the last 14 days (points with nothing logged in between). Each
    /// point is measured against the range before any earlier widening, so the figure settles
    /// rather than compounding. Each checked horizon with enough points of its own gets its own
    /// figure. On top of that, two corrections, each measured against the range the steady
    /// figures would have drawn:
    /// - forecasts that started with glucose moving fast (`ForecastRangeScale.fastTrendPerMinute`)
    ///   get their own figure, because they miss far more often (about half the time, 8–15 Nov
    ///   2026) and would otherwise widen every other forecast to cover them;
    /// - the last 12 hours on their own, so the range keeps up when misses grow.
    /// Where the range was cut off at the sensor's limit on one side, the other side's width
    /// stands in for it (they were left out before, and they're the volatile ones).
    func rangeScale(now: Date = Date()) -> ForecastRangeScale {
        let from = now.addingTimeInterval(-Self.rangeWindow)
        let recentFrom = now.addingTimeInterval(-Self.recentWindow)
        var steady: [RangeMiss] = [], fast: [RangeMiss] = [], recent: [RangeMiss] = []
        for r in records where r.issuedAt >= from && r.issuedAt <= now && r.device != ForecastRecord.relayDevice {
            for m in Self.rangeMisses(r) {
                if m.fast { fast.append(m) } else { steady.append(m) }
                if r.issuedAt >= recentFrom { recent.append(m) }
            }
        }
        guard steady.count >= Self.minimumForRange else {
            return ForecastRangeScale(byBasis: [:], checks: steady.count + fast.count)
        }
        func needed(_ ratios: [Double]) -> Double {
            min(ForecastRangeScale.maximum, max(1, EngineMath.quantile(ratios.sorted(), 0.8)))
        }
        let overall = needed(steady.map(\.ratio))
        var out: [ForecastBasis: Double] = [:]
        var outHorizon: [ForecastBasis: [Int: Double]] = [:]
        for basis in ForecastBasis.allCases {
            let xs = steady.filter { $0.basis == basis }
            out[basis] = xs.count >= Self.minimumForRange ? needed(xs.map(\.ratio)) : overall
            for (m, hs) in Dictionary(grouping: xs, by: \.minutes) where hs.count >= Self.minimumForHorizon {
                outHorizon[basis, default: [:]][m] = needed(hs.map(\.ratio))
            }
        }
        var scale = ForecastRangeScale(byBasis: out, byHorizon: outHorizon, checks: steady.count + fast.count)
        if fast.count >= Self.minimumForHorizon {
            scale.fastTrend = needed(fast.map { $0.ratio / scale.factor(for: $0.basis, minutes: Double($0.minutes)) })
        }
        if recent.count >= Self.minimumRecent {
            scale.recent = needed(recent.map {
                $0.ratio / (scale.factor(for: $0.basis, minutes: Double($0.minutes)) * ($0.fast ? scale.fastTrend : 1))
            })
            scale.recentChecks = recent.count
        }
        return scale
    }

    /// One shown point, as how far off it landed in units of its range before any widening:
    /// 1 is right on the edge.
    struct RangeMiss {
        let basis: ForecastBasis
        let minutes: Int
        let ratio: Double
        let fast: Bool
    }

    /// The points of `r` that count towards the range: scored, with nothing logged in between.
    static func rangeMisses(_ r: ForecastRecord) -> [RangeMiss] {
        let low = GlucoseForecaster.sensorRange.lowerBound - 0.5, high = GlucoseForecaster.sensorRange.upperBound + 0.5
        let fast = abs(r.trendPerMinute) >= ForecastRangeScale.fastTrendPerMinute
        return r.points.compactMap { p in
            guard !p.afterLog, let actual = p.actual else { return nil }
            let shown = max(1, p.scale ?? r.rangeScale ?? 1)
            var above = (p.upper - p.mgdl) / shown, below = (p.mgdl - p.lower) / shown
            let cutHigh = p.upper >= high, cutLow = p.lower <= low
            if cutHigh && cutLow { return nil }
            if cutHigh { above = below }
            if cutLow { below = above }
            guard above > 0.5, below > 0.5 else { return nil }
            let e = actual - p.mgdl
            return RangeMiss(basis: r.basis, minutes: p.minutes, ratio: e >= 0 ? e / above : -e / below, fast: fast)
        }
    }

    /// How far back this device's forecasts count towards cutting a horizon: the same week the
    /// Insights card shows, so a horizon it calls "further off than no change" isn't drawn.
    static let liveHorizonWindow: TimeInterval = 7 * 86_400
    /// Clean checks a horizon needs before its live figures can cut it or bring it back
    /// (`ForecastScorecard.minimumChecks`).
    static let minimumForLiveHorizon = 30
    /// A drawn horizon is cut once its error reaches this share of no change's ("further off than
    /// no change" on the Insights card)...
    static let liveCutRatio = 1.05
    /// ...and drawn again once it's back to this share ("closer than no change"). In between, it
    /// stays as it is, so it doesn't flicker on and off from one check to the next.
    static let liveRestoreRatio = ForecastCalibration.requiredImprovement

    /// How far ahead each kind of forecast may be drawn on `device`, from how its forecasts in
    /// the last week did against no change, horizon by horizon, on points with nothing logged in
    /// between. Each horizon that's drawn now is cut when it's clearly worse than no change;
    /// one that's cut (its points in the latest forecast were kept back) comes back once it's
    /// clearly better, and stays cut while it has too few checks to say. Everything past the
    /// first cut horizon goes with it. The relay's records are never mixed in.
    func liveHorizon(device: String, now: Date = Date()) -> ForecastLiveHorizon {
        let from = now.addingTimeInterval(-Self.liveHorizonWindow)
        let mine = records.filter { $0.device == device && $0.issuedAt >= from && $0.issuedAt <= now }
            .sorted { $0.issuedAt < $1.issuedAt }
        var out = ForecastLiveHorizon()
        // Insulin-only forecasts are judged apart from those after a meal (`ForecastLimitation.insulinOnly`).
        let only = ForecastLimitation.insulinOnly.code
        let kinds: [(ForecastBasis, Bool)] = ForecastBasis.allCases.map { ($0, false) } + [(.trendInsulinCarbs, true)]
        for (basis, insulinOnly) in kinds {
            let ofBasis = mine.filter { $0.basis == basis && $0.limitations.contains(only) == insulinOnly }
            var shown = 0
            for h in Self.checkedMinutes.sorted() {
                let latest = ofBasis.last { r in r.points.contains { $0.minutes == h } }
                let cutNow = latest?.points.first { $0.minutes == h }?.wasShown == false
                var errors: [Double] = [], naive: [Double] = []
                for r in ofBasis {
                    for p in r.points where p.minutes == h && !p.afterLog {
                        guard let actual = p.actual, let e = p.error else { continue }
                        errors.append(abs(e))
                        naive.append(abs(actual - r.startMgdl))
                    }
                }
                let cut: Bool
                if errors.count >= Self.minimumForLiveHorizon {
                    let mae = errors.reduce(0, +) / Double(errors.count)
                    let nc = naive.reduce(0, +) / Double(naive.count)
                    let ratio = nc > 0 ? mae / nc : (mae > 0 ? .infinity : 1)
                    cut = cutNow ? ratio > Self.liveRestoreRatio : ratio >= Self.liveCutRatio
                } else {
                    cut = cutNow
                }
                if cut {
                    let c = ForecastLiveHorizon.Cut(shownMinutes: shown, failedAt: h)
                    if insulinOnly { out.insulinOnly = c } else { out.byBasis[basis] = c }
                    break
                }
                shown = h
            }
        }
        return out
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

    /// Why the range is wider than the replay alone would make it. Nil when it isn't.
    static func rangeLine(_ s: ForecastRangeScale) -> String? {
        guard s.isWidened else { return nil }
        let pct = Int(((s.largest - 1) * 100).rounded())
        var line = "The likely range is drawn \(pct)% wider than the replay suggests, because readings landed outside it more than 1 time in 5 across the last \(s.checks) forecast points shown here."
        if s.recent > 1.005 { line += " The last 12 hours missed more often, so it's wider for now." }
        if s.fastTrend > 1.005 { line += " It's wider still while glucose is moving fast." }
        return line
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
