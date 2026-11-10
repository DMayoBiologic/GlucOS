import Foundation

/// Readings sorted by time, with fast lookups. Values between readings are interpolated only
/// across short gaps, so a missing stretch of data never turns into an invented value.
struct GlucoseSeries {
    let readings: [GlucoseReading]

    /// Longest gap that may be bridged when interpolating.
    static let maxBridge: TimeInterval = 20 * 60
    /// How close the nearest reading must be when there's nothing to interpolate from.
    static let nearestTolerance: TimeInterval = 5 * 60

    init(_ readings: [GlucoseReading], sorted: Bool = false) {
        self.readings = sorted ? readings : readings.sorted { $0.timestamp < $1.timestamp }
    }

    var isEmpty: Bool { readings.isEmpty }
    var first: GlucoseReading? { readings.first }
    var last: GlucoseReading? { readings.last }

    /// Index of the first reading at or after `date`.
    func lowerBound(_ date: Date) -> Int {
        var lo = 0, hi = readings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Glucose at `date`: interpolated between the readings either side when they're close
    /// enough together, otherwise the nearest reading within `nearestTolerance`, otherwise nil.
    func value(at date: Date) -> Double? {
        let i = lowerBound(date)
        let after = i < readings.count ? readings[i] : nil
        let before = i > 0 ? readings[i - 1] : nil
        if let after, after.timestamp == date { return after.mgdl }
        if let before, let after, after.timestamp.timeIntervalSince(before.timestamp) <= Self.maxBridge {
            let span = after.timestamp.timeIntervalSince(before.timestamp)
            let f = date.timeIntervalSince(before.timestamp) / span
            return before.mgdl + (after.mgdl - before.mgdl) * f
        }
        let candidates = [before, after].compactMap { $0 }
            .filter { abs($0.timestamp.timeIntervalSince(date)) <= Self.nearestTolerance }
        return candidates.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }?.mgdl
    }

    /// Readings with `start <= timestamp <= end`.
    func slice(from start: Date, through end: Date) -> ArraySlice<GlucoseReading> {
        let lo = lowerBound(start)
        var hi = lo
        while hi < readings.count && readings[hi].timestamp <= end { hi += 1 }
        return readings[lo..<hi]
    }

    /// Readings up to and including `date`.
    func upTo(_ date: Date) -> GlucoseSeries {
        let hi = lowerBound(date.addingTimeInterval(0.001))
        return GlucoseSeries(Array(readings[..<hi]), sorted: true)
    }
}

/// Small statistics helpers, kept here so the engine has no dependency on the dashboard code.
enum EngineMath {
    /// Linear-interpolated quantile of sorted values, `p` in 0...1.
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        if sorted.count == 1 { return sorted[0] }
        let pos = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    static func median(_ values: [Double]) -> Double { quantile(values.sorted(), 0.5) }

    /// Least-squares slope of `y` against `x`. Nil with fewer than two distinct x values.
    static func slope(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in x.indices {
            sxx += (x[i] - mx) * (x[i] - mx)
            sxy += (x[i] - mx) * (y[i] - my)
        }
        guard sxx > 1e-9 else { return nil }
        return sxy / sxx
    }

    /// Solves `A x = b` for a small square system by Gaussian elimination with partial pivoting.
    /// Nil when the matrix is singular (or close to it).
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a, v = b
        let scale = max(1e-12, a.flatMap { $0 }.map(abs).max() ?? 1)
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-10 * scale else { return nil }
            m.swapAt(col, pivot); v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                guard f != 0 else { continue }
                for k in col..<n { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }

    /// Inverse of a small square matrix, by solving against each unit vector.
    static func inverse(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var columns: [[Double]] = []
        for i in 0..<n {
            var e = [Double](repeating: 0, count: n)
            e[i] = 1
            guard let c = solve(a, e) else { return nil }
            columns.append(c)
        }
        return (0..<n).map { r in (0..<n).map { c in columns[c][r] } }
    }
}
