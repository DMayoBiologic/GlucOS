import Foundation

// How good the forecast has been for this user: replay the history, make the forecast GlucOS
// would have made at each point (using only what was known then), and compare it with what
// glucose actually did. The results set the forecast's likely range and how far ahead it may
// look: a horizon is only shown while the forecast beats simply assuming glucose stays where it
// is. Points where food, insulin or context was logged before the horizon are left out, because
// the forecast is explicitly "if nothing else changes".

struct HorizonStats: Hashable, Codable {
    let minutes: Int
    let samples: Int
    /// Mean absolute error of the forecast, mg/dL.
    let meanAbsoluteError: Double
    /// Mean absolute error of "no change", mg/dL.
    let naiveError: Double
    /// Mean of actual − forecast, mg/dL. Positive: the forecast ran low.
    let bias: Double
    /// 10th and 90th percentiles of actual − forecast, mg/dL.
    let lower: Double
    let upper: Double

    var beatsNaive: Bool { meanAbsoluteError <= naiveError * ForecastCalibration.requiredImprovement }
}

struct ForecastCalibration: Hashable, Codable {
    var byBasis: [ForecastBasis: [HorizonStats]]
    var origins: Int
    var computedAt: Date

    static let horizons = [15, 30, 45, 60, 90, 120, 150, 180]
    static let minimumSamples = 30
    /// The forecast's error must be at most this share of "no change"'s error.
    static let requiredImprovement = 0.95

    func stats(for basis: ForecastBasis) -> [HorizonStats]? {
        guard let s = byBasis[basis], !s.isEmpty else { return nil }
        return s
    }

    /// How far ahead a forecast of this kind may look: the longest horizon up to which every
    /// checked horizon had enough samples and beat "no change". Nil when there's not enough data
    /// to say; 0 when it didn't help even at the shortest horizon.
    func allowedHorizon(for basis: ForecastBasis) -> TimeInterval? {
        guard let stats = byBasis[basis]?.sorted(by: { $0.minutes < $1.minutes }),
              let first = stats.first, first.samples >= Self.minimumSamples else { return nil }
        var allowed = 0
        for s in stats {
            guard s.samples >= Self.minimumSamples, s.beatsNaive else { break }
            allowed = s.minutes
        }
        return TimeInterval(allowed * 60)
    }

    /// Band offsets at `minutes`, interpolated between checked horizons. Only horizons with
    /// enough samples are used. Nil when none qualify.
    static func interpolate(_ stats: [HorizonStats], minutes: Double) -> (lower: Double, upper: Double)? {
        let usable = stats.filter { $0.samples >= minimumSamples }.sorted { $0.minutes < $1.minutes }
        guard let first = usable.first else { return nil }
        // Never narrower than the default's floor, so a lucky stretch of history doesn't
        // produce a falsely precise range.
        let floor = defaultBand(minutes: minutes)
        func widen(_ lo: Double, _ hi: Double) -> (lower: Double, upper: Double) {
            (min(lo, floor.lower * 0.6), max(hi, floor.upper * 0.6))
        }
        if minutes <= Double(first.minutes) {
            let f = minutes / Double(first.minutes)
            return widen(first.lower * f, first.upper * f)
        }
        for (a, b) in zip(usable, usable.dropFirst()) where minutes <= Double(b.minutes) {
            let f = (minutes - Double(a.minutes)) / Double(b.minutes - a.minutes)
            return widen(a.lower + (b.lower - a.lower) * f, a.upper + (b.upper - a.upper) * f)
        }
        let last = usable[usable.count - 1]
        // Beyond the last checked horizon, grow in proportion.
        let f = minutes / Double(last.minutes)
        return widen(last.lower * f, last.upper * f)
    }

    /// A cautious range for before there's history to check against: ±(6 + 0.6 × minutes) mg/dL,
    /// about ±1.4 mmol/L at 30 minutes and ±2.3 mmol/L at an hour.
    static func defaultBand(minutes: Double) -> (lower: Double, upper: Double) {
        let half = 6 + 0.6 * minutes
        return (-half, half)
    }
}

enum ForecastBacktest {
    /// Forecast origins are at least this far apart.
    static let spacing: TimeInterval = 30 * 60

    static func run(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                    profile: EffectProfile, days: Int = 30, now: Date = Date()) -> ForecastCalibration {
        let series = GlucoseSeries(readings)
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let maxH = TimeInterval((ForecastCalibration.horizons.max() ?? 180) * 60)
        let doseTimes = doses.map(\.timestamp).sorted()
        let mealTimes = (meals.map(\.timestamp) + contexts.map(\.timestamp)).sorted()

        var residuals: [ForecastBasis: [Int: [Double]]] = [:]
        var naive: [ForecastBasis: [Int: [Double]]] = [:]
        var origins = 0
        var lastOrigin = Date.distantPast
        for r in series.readings where r.timestamp >= start && r.timestamp.addingTimeInterval(15 * 60) <= now {
            guard r.timestamp.timeIntervalSince(lastOrigin) >= spacing else { continue }
            let input = ForecastInputs(readings: series.upTo(r.timestamp), doses: doses.filter { $0.timestamp <= r.timestamp },
                                       meals: meals.filter { $0.timestamp <= r.timestamp },
                                       contexts: contexts.filter { $0.timestamp <= r.timestamp },
                                       profile: profile, calibration: nil, now: r.timestamp)
            guard case .success(let f) = GlucoseForecaster.forecast(input, maxHorizon: maxH) else { continue }
            lastOrigin = r.timestamp
            origins += 1
            let nextEvent = min(firstAfter(r.timestamp, in: doseTimes) ?? .distantFuture,
                                firstAfter(r.timestamp, in: mealTimes) ?? .distantFuture)
            for h in ForecastCalibration.horizons {
                let target = r.timestamp.addingTimeInterval(TimeInterval(h * 60))
                guard target <= now, target < nextEvent,
                      let actual = series.value(at: target),
                      let predicted = f.samples.first(where: { abs($0.date.timeIntervalSince(target)) < 30 })?.mgdl
                else { continue }
                residuals[f.basis, default: [:]][h, default: []].append(actual - predicted)
                naive[f.basis, default: [:]][h, default: []].append(actual - f.startMgdl)
            }
        }

        var byBasis: [ForecastBasis: [HorizonStats]] = [:]
        for (basis, perHorizon) in residuals {
            byBasis[basis] = ForecastCalibration.horizons.compactMap { h -> HorizonStats? in
                guard let res = perHorizon[h], !res.isEmpty else { return nil }
                let sorted = res.sorted()
                let nv = naive[basis]?[h] ?? []
                return HorizonStats(minutes: h, samples: res.count,
                                    meanAbsoluteError: res.map(abs).reduce(0, +) / Double(res.count),
                                    naiveError: nv.isEmpty ? .infinity : nv.map(abs).reduce(0, +) / Double(nv.count),
                                    bias: res.reduce(0, +) / Double(res.count),
                                    lower: EngineMath.quantile(sorted, 0.1), upper: EngineMath.quantile(sorted, 0.9))
            }
        }
        return ForecastCalibration(byBasis: byBasis, origins: origins, computedAt: now)
    }

    private static func firstAfter(_ date: Date, in sorted: [Date]) -> Date? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count ? sorted[lo] : nil
    }
}
