import Foundation

// Tunes the forecast's trend timing to the user. How long a trend keeps going differs from person
// to person (and with how noisy their sensor is), so instead of always fading the trend over 30
// minutes, GlucOS replays its past forecasts with a few alternative timings and switches to one
// only when the history clearly says it forecasts better:
//
//   • enough checks to judge (`minimumChecks`),
//   • at least 3% less error than the standard timing on the same forecast points, each horizon
//     counting equally (errors 60 minutes out are three times those at 15, so a plain sum would
//     let the far end drown out the near one), and
//   • better in both the earlier and the later half of the history, so one odd week can't pick it.
//
// It runs with every relearn, so as history builds up it can settle on a better timing, or go
// back to the standard one if that stops being true.

/// What tuning found, for the model and the Outlook page.
struct ForecastTuningResult: Hashable, Codable {
    /// The timing the forecast uses. Standard unless the checks below justified another.
    var tuning: ForecastTuning
    /// Forecast points the comparison used.
    var checks: Int
    /// Mean absolute error at 15, 30 and 60 minutes with the standard timing, mg/dL.
    var standardError: Double
    /// The same with `tuning`, mg/dL. Equal to `standardError` when standard.
    var tunedError: Double

    static let untuned = ForecastTuningResult(tuning: .standard, checks: 0, standardError: 0, tunedError: 0)

    var isTuned: Bool { !tuning.isStandard }
    /// Share of the standard timing's error removed, 0–1.
    var improvement: Double { standardError > 0 ? max(0, 1 - tunedError / standardError) : 0 }
}

enum ForecastTuner {
    static let fades: [TimeInterval] = [15, 20, 30, 45].map { $0 * 60 }
    static let windows: [TimeInterval] = [15, 20].map { $0 * 60 }
    /// How much of the trend to carry forward. A trend that usually carries on at part strength
    /// is better scaled down than faded sooner: it stays right in direction for the whole fade.
    /// The trend's strength is fitted once the timing is settled, kept within this range and
    /// rounded to 5%. A trend that usually carries on at part strength is better scaled down than
    /// faded sooner.
    static let gainRange: ClosedRange<Double> = 0.25...1
    static var candidates: [ForecastTuning] {
        fades.flatMap { f in windows.map { ForecastTuning(trendFade: f, trendWindow: $0) } }
    }
    static let scoredHorizons: Set<Int> = [15, 30, 60]
    /// The trend's strength only matters near the start, so it's judged there.
    static let gainHorizons: Set<Int> = [15, 30]
    static let minimumChecks = 120
    /// A candidate's error must be at most this share of the standard timing's.
    static let requiredImprovement = 0.97

    /// Checked points are only scored as far as their kind of forecast is ever shown.
    static func scored(_ check: ForecastBacktest.Check) -> Bool {
        scoredHorizons.contains(check.minutes) && !check.fresh
            && (check.basis != .trend || TimeInterval(check.minutes * 60) <= GlucoseForecaster.trendHorizon)
    }

    static func tune(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                     profile: EffectProfile, days: Int = 30, now: Date = Date(),
                     profileAt: ((Date) -> EffectProfile)? = nil) -> ForecastTuningResult {
        func residuals(_ t: ForecastTuning, gain: Double) -> [Key: Double] {
            var t = t
            t.trendGain = gain
            let c = ForecastBacktest.checks(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                            profile: profile, days: days, now: now, profileAt: profileAt, tuning: t)
            var out: [Key: Double] = [:]
            for check in c.checks where scored(check) && gainHorizons.contains(check.minutes) {
                out[Key(origin: check.origin, minutes: check.minutes)] = check.residual
            }
            return out
        }
        func errors(_ t: ForecastTuning) -> [Key: Double] {
            let c = ForecastBacktest.checks(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                            profile: profile, days: days, now: now, profileAt: profileAt, tuning: t)
            var out: [Key: Double] = [:]
            for check in c.checks where scored(check) {
                out[Key(origin: check.origin, minutes: check.minutes)] = abs(check.residual)
            }
            return out
        }
        let standard = errors(.standard)
        let standardMean = mean(standard.values)
        guard standard.count >= minimumChecks else {
            return ForecastTuningResult(tuning: .standard, checks: standard.count, standardError: standardMean,
                                        tunedError: standardMean)
        }
        // 1. Strength: how much of the trend to carry forward. Fitted rather than picked from a
        // list: replaying once with the trend and once without it separates the trend's part of
        // each forecast (T) from the rest, and the share of T that actually happened is a
        // least-squares slope. Fitted separately on the earlier and later half of the history, the
        // larger is used, so one stretch can't talk the trend down.
        var base: (tuning: ForecastTuning, errors: [Key: Double]) = (.standard, standard)
        if let gain = fittedGain(withTrend: residuals(.standard, gain: 1), withoutTrend: residuals(.standard, gain: 0)) {
            let candidate = ForecastTuning(trendGain: gain)
            let theirs = errors(candidate)
            // The fit already says it's better; this only checks it's no worse in either half
            // in the figure the user sees (typical error, rather than squared error).
            if Self.ratio(theirs, against: standard, horizons: gainHorizons, required: 1) != nil {
                base = (candidate, theirs)
            }
        }
        // 2. Timing, at that strength: how long the trend lasts and how far back it's measured.
        var chosen = base
        var bestRatio = 1.0
        for timing in candidates where !timing.isStandard {
            var candidate = timing
            candidate.trendGain = base.tuning.trendGain
            let theirs = errors(candidate)
            if let ratio = Self.ratio(theirs, against: base.errors, horizons: scoredHorizons), ratio < bestRatio {
                bestRatio = ratio
                chosen = (candidate, theirs)
            }
        }
        guard !chosen.tuning.isStandard else {
            return ForecastTuningResult(tuning: .standard, checks: standard.count, standardError: standardMean,
                                        tunedError: standardMean)
        }
        let shared = standard.keys.filter { chosen.errors[$0] != nil }
        return ForecastTuningResult(tuning: chosen.tuning, checks: shared.count,
                                    standardError: mean(shared.map { standard[$0]! }),
                                    tunedError: mean(shared.map { chosen.errors[$0]! }))
    }

    /// The share of the trend that carried on (see step 1 of `tune`), or nil when there's too
    /// little to fit or it's within 5% of all of it. `withTrend` and `withoutTrend` are actual −
    /// forecast for the same points with the trend at full strength and with none.
    static func fittedGain(withTrend: [Key: Double], withoutTrend: [Key: Double]) -> Double? {
        let keys = withTrend.keys.filter { withoutTrend[$0] != nil }
        guard keys.count >= minimumChecks else { return nil }
        let mid = EngineMath.median(keys.map { $0.origin.timeIntervalSince1970 })
        var xy = [0.0, 0.0], xx = [0.0, 0.0]
        for k in keys {
            let half = k.origin.timeIntervalSince1970 < mid ? 0 : 1
            let r0 = withoutTrend[k]!
            let trendPart = r0 - withTrend[k]!
            xy[half] += r0 * trendPart
            xx[half] += trendPart * trendPart
        }
        guard xx.allSatisfy({ $0 > 0 }) else { return nil }
        let gain = max(xy[0] / xx[0], xy[1] / xx[1])
        let rounded = (min(gainRange.upperBound, max(gainRange.lowerBound, gain)) * 20).rounded() / 20
        return rounded < 0.95 ? rounded : nil
    }

    /// The candidate's error as a share of the baseline's on the points both made at `horizons`,
    /// each horizon counting equally (errors 60 minutes out are about three times those at 15, so
    /// a plain sum would let the far end drown out the near one). Nil unless there are enough
    /// points, it's at least `required` of the baseline (3% better unless said otherwise), and no
    /// worse in either the earlier or the later half.
    static func ratio(_ theirs: [Key: Double], against base: [Key: Double], horizons: Set<Int>,
                      required: Double = requiredImprovement) -> Double? {
        // Compare on the points both made, so a timing can't win by skipping hard ones.
        let shared = base.keys.filter { horizons.contains($0.minutes) && theirs[$0] != nil }
        guard shared.count >= minimumChecks else { return nil }
        var perHorizon: [Int: (sum: Double, n: Int)] = [:]
        for k in shared {
            perHorizon[k.minutes, default: (0, 0)].sum += base[k]!
            perHorizon[k.minutes, default: (0, 0)].n += 1
        }
        let weight = perHorizon.mapValues { $0.sum > 0 ? Double($0.n) / $0.sum : 0 }
        let mid = EngineMath.median(shared.map { $0.origin.timeIntervalSince1970 })
        var sums = [0.0, 0.0], baseSums = [0.0, 0.0], counts = [0, 0]
        for k in shared {
            let half = k.origin.timeIntervalSince1970 < mid ? 0 : 1
            let w = weight[k.minutes] ?? 0
            sums[half] += theirs[k]! * w
            baseSums[half] += base[k]! * w
            counts[half] += 1
        }
        let total = baseSums[0] + baseSums[1]
        guard counts.allSatisfy({ $0 > 0 }), total > 0 else { return nil }
        let ratio = (sums[0] + sums[1]) / total
        guard ratio <= required, sums[0] <= baseSums[0], sums[1] <= baseSums[1], ratio < 1 else { return nil }
        return ratio
    }

    private static func mean<S: Sequence>(_ xs: S) -> Double where S.Element == Double {
        var sum = 0.0, n = 0
        for x in xs { sum += x; n += 1 }
        return n > 0 ? sum / Double(n) : 0
    }

    struct Key: Hashable {
        let origin: Date
        let minutes: Int
    }
}
