import Foundation

// Tunes the forecast's trend timing to the user. How long a trend keeps going differs from person
// to person (and with how noisy their sensor is), so instead of always fading the trend over 30
// minutes, GlucOS replays its past forecasts with a few alternative timings and switches to one
// only when the history clearly says it forecasts better:
//
//   • enough checks to judge (`minimumChecks`),
//   • at least 3% less error than the standard timing on the same forecast points, and
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
    static var candidates: [ForecastTuning] {
        fades.flatMap { f in windows.map { ForecastTuning(trendFade: f, trendWindow: $0) } }
    }
    static let scoredHorizons: Set<Int> = [15, 30, 60]
    static let minimumChecks = 120
    /// A candidate's error must be at most this share of the standard timing's.
    static let requiredImprovement = 0.97

    static func tune(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                     profile: EffectProfile, days: Int = 30, now: Date = Date(),
                     profileAt: ((Date) -> EffectProfile)? = nil) -> ForecastTuningResult {
        func errors(_ t: ForecastTuning) -> [Key: Double] {
            let c = ForecastBacktest.checks(readings: readings, doses: doses, meals: meals, contexts: contexts,
                                            profile: profile, days: days, now: now, profileAt: profileAt, tuning: t)
            var out: [Key: Double] = [:]
            for check in c.checks where scoredHorizons.contains(check.minutes) {
                out[Key(origin: check.origin, minutes: check.minutes)] = abs(check.residual)
            }
            return out
        }
        let standard = errors(.standard)
        guard standard.count >= minimumChecks else {
            let mean = standard.isEmpty ? 0 : standard.values.reduce(0, +) / Double(standard.count)
            return ForecastTuningResult(tuning: .standard, checks: standard.count, standardError: mean, tunedError: mean)
        }
        let standardMean = standard.values.reduce(0, +) / Double(standard.count)
        var best = ForecastTuningResult(tuning: .standard, checks: standard.count, standardError: standardMean,
                                        tunedError: standardMean)
        var bestRatio = 1.0
        for candidate in candidates where !candidate.isStandard {
            let theirs = errors(candidate)
            // Compare on the points both made, so a timing can't win by skipping hard ones.
            let shared = standard.keys.filter { theirs[$0] != nil }
            guard shared.count >= minimumChecks else { continue }
            let mid = EngineMath.median(shared.map { $0.origin.timeIntervalSince1970 })
            var sums = [0.0, 0.0], baseSums = [0.0, 0.0], counts = [0, 0]
            for k in shared {
                let half = k.origin.timeIntervalSince1970 < mid ? 0 : 1
                sums[half] += theirs[k]!
                baseSums[half] += standard[k]!
                counts[half] += 1
            }
            guard counts.allSatisfy({ $0 > 0 }) else { continue }
            let tuned = (sums[0] + sums[1]) / Double(shared.count)
            let base = (baseSums[0] + baseSums[1]) / Double(shared.count)
            guard base > 0 else { continue }
            let ratio = tuned / base
            let betterInBothHalves = sums[0] < baseSums[0] && sums[1] < baseSums[1]
            if ratio <= requiredImprovement, betterInBothHalves, ratio < bestRatio {
                bestRatio = ratio
                best = ForecastTuningResult(tuning: candidate, checks: shared.count, standardError: base, tunedError: tuned)
            }
        }
        return best
    }

    private struct Key: Hashable {
        let origin: Date
        let minutes: Int
    }
}
