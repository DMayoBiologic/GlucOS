import Foundation

/// What a finger dragging along the glucose chart passes over that's worth feeling: the trace
/// crossing the low or high line, or something logged (a dose, a meal, waking up). Plain
/// Foundation so it can be unit-tested; `GlucoseChart` turns it into a light haptic tick on iPhone.
///
/// Readings themselves don't tick. On a 24-hour chart that would be a buzz every few pixels and
/// would say nothing, so only the moments that mean something do (docs/DesignSystem.md rule 7).
enum ChartScrub {
    enum Tick: Equatable {
        /// The trace went over the low or high line between the two readings.
        case rangeEdge
        /// A logged marker lies between the two readings.
        case logged
    }

    /// Below the target, inside it, or above it: the bands the chart's two dashed lines divide.
    /// Urgent low and very high count with low and high, as the chart draws no line between them.
    enum Band: Equatable {
        case below, inside, above

        init(mgdl: Double, low: Double, high: Double) {
            self = mgdl < low ? .below : mgdl > high ? .above : .inside
        }
    }

    /// The tick for moving the scrub from the reading at `old` to the reading at `new`, if any.
    ///
    /// A fast drag can skip several readings in one step, so every reading between the two is
    /// looked at, not only the ends: passing through a short low and out again still ticks.
    /// A marker counts once it's been reached in the direction of travel (the side moved towards
    /// includes the marker's own time, the side moved from doesn't), so dragging back over it
    /// ticks again, and resting on it doesn't tick twice. A range edge wins when both happen in
    /// one step, since there's only one tick to give.
    ///
    /// - Parameters:
    ///   - readings: oldest → newest.
    ///   - logged: when each logged marker is, in any order.
    static func tick(from old: Date, to new: Date, readings: [GlucoseReading],
                     lowMgdl: Double, highMgdl: Double, logged: [Date]) -> Tick? {
        guard old != new else { return nil }
        let lo = min(old, new), hi = max(old, new)
        let passed = readings.lazy.filter { $0.timestamp >= lo && $0.timestamp <= hi }
            .map { Band(mgdl: $0.mgdl, low: lowMgdl, high: highMgdl) }
        if let first = passed.first, passed.contains(where: { $0 != first }) { return .rangeEdge }

        let reached: (Date) -> Bool = new > old
            ? { $0 > old && $0 <= new }
            : { $0 < old && $0 >= new }
        return logged.contains(where: reached) ? .logged : nil
    }
}
