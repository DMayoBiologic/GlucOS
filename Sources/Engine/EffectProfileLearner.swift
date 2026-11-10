import Foundation

// Learns, from the user's own readings and logs, roughly how far glucose has moved for each unit
// of fast-acting insulin and each gram of carbohydrate *as it acted*. The forecast needs these to
// turn "insulin still acting" into "glucose may fall". They are fitted figures with error bars,
// not settings: they're never offered as a correction factor or ratio and never used to work out
// a dose.
//
// Method: cut the history into 30-minute intervals. For each, the glucose change is explained as
//
//     Δglucose = −S × (insulin acting in the interval) + K × (carbs absorbed in the interval) + drift(time of day)
//
// with the amounts acting taken from the population timing curves. Intervals the model can't
// describe are left out (lows and the hour after them, untimed food, hypo treatments, exercise,
// illness and other context tags, data gaps). The fit is robust (Huber-weighted least squares),
// so a few odd intervals (an unlogged snack, a compression low) don't drag it.

/// One fitted figure and how sure the fit is.
struct LearnedEffect: Hashable, Codable {
    /// mg/dL per unit (insulin) or per gram (carbs).
    let value: Double
    let standardError: Double
    /// Doses or meals that contributed.
    let examples: Int

    var relativeError: Double { value > 0 ? standardError / value : .infinity }
}

struct EffectProfile: Hashable, Codable {
    /// Fall per unit of fast-acting insulin, mg/dL. Nil when there wasn't enough to fit it.
    var insulin: LearnedEffect?
    /// Rise per gram of carbohydrate, mg/dL. Nil when there wasn't enough to fit it.
    var carbs: LearnedEffect?
    /// Typical change per hour with no fast insulin or carbs acting, by 6-hour block of the day
    /// (0: midnight–6 am, 1: 6 am–noon, 2: noon–6 pm, 3: 6 pm–midnight), mg/dL per hour.
    var driftPerHour: [Double]
    /// Days of history used and intervals that passed the filters.
    var days: Int
    var intervals: Int
    var learnedAt: Date

    static let empty = EffectProfile(insulin: nil, carbs: nil, driftPerHour: [0, 0, 0, 0], days: 0, intervals: 0,
                                     learnedAt: .distantPast)

    /// Usable in a forecast.
    var reliableInsulin: LearnedEffect? { insulin.flatMap { EffectProfileLearner.isReliable($0, kind: .insulin) ? $0 : nil } }
    var reliableCarbs: LearnedEffect? { carbs.flatMap { EffectProfileLearner.isReliable($0, kind: .carbs) ? $0 : nil } }
}

enum EffectProfileLearner {
    enum Kind { case insulin, carbs }

    static let interval: TimeInterval = 30 * 60
    /// Distinct doses (or meals) needed before a figure can be trusted.
    static let minimumExamples = 5
    /// The fit's standard error must be within this share of the value.
    static let maximumRelativeError = 0.35
    /// Anything outside these is treated as a fitting failure, not a finding.
    static let plausibleInsulin: ClosedRange<Double> = 5...500      // mg/dL per unit
    static let plausibleCarbs: ClosedRange<Double> = 0.3...20        // mg/dL per gram

    static func isReliable(_ e: LearnedEffect, kind: Kind) -> Bool {
        let range = kind == .insulin ? plausibleInsulin : plausibleCarbs
        return e.examples >= minimumExamples && range.contains(e.value) && e.relativeError <= maximumRelativeError
    }

    /// One 30-minute interval prepared for fitting.
    struct Row: Hashable {
        let start: Date
        let change: Double      // mg/dL
        let insulin: Double     // units acting
        let carbs: Double       // grams absorbed
        let block: Int
        let doseIDs: Set<UUID>
        let mealIDs: Set<UUID>
    }

    /// Fits over the most recent 30 days, widening to 90 if that's not enough for either figure.
    static func learn(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry],
                      contexts: [ContextEvent], low: Double, now: Date = Date(),
                      calendar: Calendar = .current) -> EffectProfile {
        let series = GlucoseSeries(readings)
        var best = EffectProfile.empty
        for days in [30, 90] {
            let rows = self.rows(series: series, doses: doses, meals: meals, contexts: contexts, low: low,
                                 from: now.addingTimeInterval(-Double(days) * 86_400), to: now, calendar: calendar)
            var p = fit(rows)
            let available = series.first.map { now.timeIntervalSince($0.timestamp) / 86_400 } ?? 0
            p.days = max(0, min(days, Int(available.rounded(.up))))
            p.learnedAt = now
            best = p
            if p.reliableInsulin != nil || (p.insulin == nil && p.reliableCarbs != nil) {
                break
            }
            // Stop early too when there's no more history to add.
            if let first = series.first, first.timestamp > now.addingTimeInterval(-Double(days) * 86_400) { break }
        }
        return best
    }

    static func block(of date: Date, calendar: Calendar) -> Int {
        min(3, max(0, calendar.component(.hour, from: date) / 6))
    }

    /// Builds the clean intervals between `from` and `to`.
    static func rows(series: GlucoseSeries, doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                     low: Double, from: Date, to: Date, calendar: Calendar) -> [Row] {
        guard let firstReading = series.first?.timestamp else { return [] }
        let fast: [(id: UUID, dose: TimedDose)] = doses.compactMap { d in TimedDose(fastPartOf: d).map { (id: d.id, dose: $0) } }
            .sorted { $0.dose.date < $1.dose.date }
        let carbs: [(id: UUID, meal: TimedCarbs)] = meals.filter { $0.carbs > 0 }
            .map { (id: $0.id, meal: TimedCarbs(date: $0.timestamp, grams: $0.carbs)) }
            .sorted { $0.meal.date < $1.meal.date }
        let untimedFood = (meals.filter { $0.carbs <= 0 }.map(\.timestamp)
            + contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)).sorted()
        let tagged = contexts.filter { !$0.tags.subtracting([.hypoTreatment]).isEmpty }

        // Start on a half-hour boundary.
        let startSeconds = (max(from, firstReading).timeIntervalSince1970 / interval).rounded(.up) * interval
        var t0 = Date(timeIntervalSince1970: startSeconds)
        var rows: [Row] = []
        let foodReach = CarbAbsorptionCurve.standard.totalDuration
        while t0.addingTimeInterval(interval) <= to {
            let t1 = t0.addingTimeInterval(interval)
            defer { t0 = t1 }
            guard let g0 = series.value(at: t0), let g1 = series.value(at: t1),
                  (40...400).contains(g0), (40...400).contains(g1) else { continue }
            // Lows: counter-regulation and (often unlogged) treatment.
            let nearby = series.slice(from: t0.addingTimeInterval(-60 * 60), through: t1)
            if nearby.contains(where: { $0.mgdl < low }) { continue }
            // Food without carbs, or a hypo treatment, still being absorbed.
            if untimedFood.contains(where: { $0 <= t1 && $0 > t0.addingTimeInterval(-foodReach) }) { continue }
            // Exercise, illness, alcohol… or a delivery problem.
            if tagged.contains(where: { c in
                c.tags.contains { tag in
                    if tag == .hypoTreatment { return false }
                    if tag == .siteProblem {
                        return c.timestamp >= t0.addingTimeInterval(-6 * 3600) && c.timestamp <= t1.addingTimeInterval(6 * 3600)
                    }
                    return c.timestamp <= t1 && c.timestamp >= t0.addingTimeInterval(-tag.reach)
                }
            }) { continue }

            var insulin = 0.0, grams = 0.0
            var doseIDs = Set<UUID>(), mealIDs = Set<UUID>()
            for (id, d) in fast where d.date < t1 && d.end > t0 {
                let u = d.acting(from: t0, to: t1)
                if u > 0.005 { insulin += u; doseIDs.insert(id) }
            }
            for (id, m) in carbs where m.date < t1 && m.end > t0 {
                let g = m.absorbed(from: t0, to: t1)
                if g > 0.05 { grams += g; mealIDs.insert(id) }
            }
            rows.append(Row(start: t0, change: g1 - g0, insulin: insulin, carbs: grams,
                            block: block(of: t0, calendar: calendar), doseIDs: doseIDs, mealIDs: mealIDs))
        }
        return rows
    }

    /// Robust fit of the rows. Columns without data are left out of the model.
    static func fit(_ rows: [Row]) -> EffectProfile {
        let doseCount = Set(rows.flatMap(\.doseIDs)).count
        let mealCount = Set(rows.flatMap(\.mealIDs)).count
        let useInsulin = doseCount >= 2 && rows.contains { $0.insulin > 0.05 }
        let useCarbs = mealCount >= 2 && rows.contains { $0.carbs > 1 }
        let blocks = Array(Set(rows.map(\.block))).sorted()
        let p = (useInsulin ? 1 : 0) + (useCarbs ? 1 : 0) + blocks.count
        guard rows.count >= max(12, p * 4) else {
            return EffectProfile(insulin: nil, carbs: nil, driftPerHour: [0, 0, 0, 0], days: 0,
                                 intervals: rows.count, learnedAt: .distantPast)
        }

        func features(_ r: Row) -> [Double] {
            var x: [Double] = []
            if useInsulin { x.append(-r.insulin) }
            if useCarbs { x.append(r.carbs) }
            for b in blocks { x.append(r.block == b ? 1 : 0) }
            return x
        }
        let xs = rows.map(features)
        let ys = rows.map(\.change)

        var weights = [Double](repeating: 1, count: rows.count)
        var beta: [Double]?
        var sigma = 1.0
        for _ in 0..<12 {
            guard let b = weightedLeastSquares(xs, ys, weights) else { break }
            beta = b
            let residuals = zip(xs, ys).map { x, y in y - dot(x, b) }
            // Robust scale: median absolute deviation.
            let mad = EngineMath.median(residuals.map(abs)) / 0.6745
            sigma = max(mad, 1)
            let k = 1.345 * sigma
            let next = residuals.map { abs($0) <= k ? 1.0 : k / abs($0) }
            let moved = zip(next, weights).map { abs($0 - $1) }.max() ?? 0
            weights = next
            if moved < 1e-4 { break }
        }
        guard let beta else {
            return EffectProfile(insulin: nil, carbs: nil, driftPerHour: [0, 0, 0, 0], days: 0,
                                 intervals: rows.count, learnedAt: .distantPast)
        }

        // Standard errors from the weighted normal matrix and the residual variance.
        let n = Double(rows.count), pp = Double(beta.count)
        let residuals = zip(xs, ys).map { x, y in y - dot(x, beta) }
        let weightedRSS = zip(residuals, weights).reduce(0) { $0 + $1.1 * $1.0 * $1.0 }
        let variance = weightedRSS / max(1, n - pp)
        let xtwx = normalMatrix(xs, weights)
        let cov = EngineMath.inverse(xtwx)
        func se(_ i: Int) -> Double { cov.map { (max(0, $0[i][i]) * variance).squareRoot() } ?? .infinity }

        var col = 0
        var insulin: LearnedEffect?, carbs: LearnedEffect?
        if useInsulin { insulin = LearnedEffect(value: beta[col], standardError: se(col), examples: doseCount); col += 1 }
        if useCarbs { carbs = LearnedEffect(value: beta[col], standardError: se(col), examples: mealCount); col += 1 }
        var drift = [0.0, 0.0, 0.0, 0.0]
        for (i, b) in blocks.enumerated() { drift[b] = beta[col + i] * 3600 / interval }
        return EffectProfile(insulin: insulin, carbs: carbs, driftPerHour: drift, days: 0,
                             intervals: rows.count, learnedAt: .distantPast)
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    private static func normalMatrix(_ xs: [[Double]], _ w: [Double]) -> [[Double]] {
        let p = xs.first?.count ?? 0
        var m = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        for (x, wi) in zip(xs, w) {
            for i in 0..<p where x[i] != 0 {
                for j in 0..<p { m[i][j] += wi * x[i] * x[j] }
            }
        }
        return m
    }

    static func weightedLeastSquares(_ xs: [[Double]], _ ys: [Double], _ w: [Double]) -> [Double]? {
        let p = xs.first?.count ?? 0
        guard p > 0 else { return nil }
        let m = normalMatrix(xs, w)
        var v = [Double](repeating: 0, count: p)
        for (k, x) in xs.enumerated() {
            for i in 0..<p { v[i] += w[k] * x[i] * ys[k] }
        }
        return EngineMath.solve(m, v)
    }
}
