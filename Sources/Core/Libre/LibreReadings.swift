import Foundation

/// Turns decoded sensor data into GlucOS readings, and measures them against LibreLinkUp's.
public enum LibreReadings {

    /// Readings from one NFC read, oldest first: the 8-hour history every 15 minutes, then the last
    /// 16 minutes every minute. `readAt` is when the phone read the sensor (the sensor's current minute).
    static func readings(fram: LibreFRAM, readAt: Date) -> [GlucoseReading] {
        let cal = fram.calibration
        let trendPoints = cal.points(fram.trend)
        // History points older than the trend window; the trend covers the rest more finely.
        var historyPoints = cal.points(fram.history)
        if let newestTrendMinute = trendPoints.map(\.minute).max() {
            historyPoints = historyPoints.filter { $0.minute < newestTrendMinute - 15 }
        }
        return build(points: historyPoints + trendPoints, age: fram.age, at: readAt)
    }

    /// Readings from one Bluetooth packet (7 recent minutes and 3 history points), oldest first.
    static func readings(packet: LibreBLEPacket, calibration: LibreCalibration, receivedAt: Date) -> [GlucoseReading] {
        let trend = calibration.points(packet.trend)
        let oldestTrend = trend.map(\.minute).min() ?? Int.max
        let history = calibration.points(packet.history).filter { $0.minute < oldestTrend }
        return build(points: history + trend, age: packet.age, at: receivedAt)
    }

    private static func build(points: [LibreGlucosePoint], age: Int, at date: Date) -> [GlucoseReading] {
        let sorted = points.sorted { $0.minute < $1.minute }
        var seen = Set<Int>()
        let unique = sorted.filter { seen.insert($0.minute).inserted }
        return unique.map { p in
            let t = date.addingTimeInterval(-Double(age - p.minute) * 60)
            return GlucoseReading(timestamp: t, mgdl: p.mgdl, trend: trend(at: p.minute, in: unique))
        }
    }

    /// Libre-style arrow from the rate over the previous 15 minutes (mg/dL per minute):
    /// beyond ±2 quickly, beyond ±1 rising/falling, otherwise steady.
    static func trend(at minute: Int, in points: [LibreGlucosePoint]) -> Trend {
        let window = points.filter { $0.minute <= minute && $0.minute >= minute - 15 }
        guard let last = window.last, let first = window.first, last.minute - first.minute >= 5 else { return .unknown }
        let rate = (last.mgdl - first.mgdl) / Double(last.minute - first.minute)
        switch rate {
        case ..<(-2): return .fallingQuickly
        case ..<(-1): return .falling
        case ...1: return .flat
        case ...2: return .rising
        default: return .risingQuickly
        }
    }

    /// How sensor-decoded readings compare with LibreLinkUp's (Abbott's algorithm) at the same times.
    public struct Agreement: Equatable, Sendable {
        public let pairs: Int
        /// Mean absolute difference, mg/dL.
        public let meanAbsoluteDifference: Double
        /// Mean absolute relative difference, 0...1.
        public let mard: Double
        /// Mean of (ours − LinkUp), mg/dL: positive means GlucOS reads higher.
        public let bias: Double
    }

    /// Pairs each reading with the LinkUp reading closest in time (within `tolerance`).
    static func agreement(_ ours: [GlucoseReading], linkUp: [GlucoseReading], tolerance: TimeInterval = 150) -> Agreement? {
        let reference = linkUp.filter { $0.mgdl > 0 }
        guard !reference.isEmpty else { return nil }
        var diffs: [(Double, Double)] = []
        for r in ours {
            guard let match = reference.min(by: {
                abs($0.timestamp.timeIntervalSince(r.timestamp)) < abs($1.timestamp.timeIntervalSince(r.timestamp))
            }), abs(match.timestamp.timeIntervalSince(r.timestamp)) <= tolerance else { continue }
            diffs.append((r.mgdl - match.mgdl, match.mgdl))
        }
        guard !diffs.isEmpty else { return nil }
        let n = Double(diffs.count)
        return Agreement(pairs: diffs.count,
                         meanAbsoluteDifference: diffs.map { abs($0.0) }.reduce(0, +) / n,
                         mard: diffs.map { abs($0.0) / $0.1 }.reduce(0, +) / n,
                         bias: diffs.map(\.0).reduce(0, +) / n)
    }
}
