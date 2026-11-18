import Foundation

/// How the compare-two-days chart (`DayCompare`) moves, kept free of SwiftUI so it can be tested.
///
/// - When the comparison opens, the second day's line draws in from midnight on the left to the
///   end of the day on the right (`revealed`), over `drawInDuration`.
/// - When a day is replaced (the chevrons) or the two days swap, each changed line cross-slides:
///   the old line slides `slideMinutes` away and fades out while the new one slides in from the
///   other side and fades in (`slid`). A later day comes in from the right, an earlier one from
///   the left, so the motion matches the calendar.
/// - Under Reduce Motion nothing moves: the line is simply there, or switches at once.
///
/// Display only: the figures and the spoken summary always come from the full, unshifted day.
enum DayCompareMotion: Equatable, Sendable {
    /// The line draws in from the left.
    case drawIn
    /// The line cross-slides; `direction` is +1 when the new day is later (it enters from the
    /// right and the old one leaves to the left) and -1 when it's earlier.
    case slide(direction: Double)
    /// Reduce Motion, or nothing changed: it appears or switches at once.
    case instant

    static let drawInDuration = 0.7
    static let slideDuration = 0.42
    /// How far, in minutes of the day, a line travels while it slides in or out.
    static let slideMinutes = 150.0

    /// The motion when the comparison first opens.
    static func opening(reduceMotion: Bool) -> DayCompareMotion {
        reduceMotion ? .instant : .drawIn
    }

    /// The motion when one line's day changes from `old` to `new`.
    static func change(from old: Date, to new: Date, reduceMotion: Bool) -> DayCompareMotion {
        if reduceMotion || old == new { return .instant }
        return .slide(direction: new > old ? 1 : -1)
    }

    /// Where the incoming and outgoing lines sit, in minutes, and how opaque each is, at
    /// `progress` (0 = the change has just started, 1 = it's done).
    struct SlideFrame: Equatable, Sendable {
        let incomingOffset: Double
        let incomingOpacity: Double
        let outgoingOffset: Double
        let outgoingOpacity: Double
    }

    static func frame(progress: Double, direction: Double) -> SlideFrame {
        let p = min(max(progress, 0), 1)
        let d: Double = direction < 0 ? -1 : 1
        return SlideFrame(incomingOffset: d * (1 - p) * slideMinutes, incomingOpacity: p,
                          outgoingOffset: -d * p * slideMinutes, outgoingOpacity: 1 - p)
    }

    /// How far the scale has glided at slide `progress`: eased in, so it holds close to the old
    /// scale while the leaving lines are still clearly visible and settles as they fade out.
    static func scaleProgress(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p
    }

    /// A chart scale part way from `old` to `new`, so the axis glides with a slide.
    static func blend(_ old: ClosedRange<Double>, _ new: ClosedRange<Double>, progress: Double) -> ClosedRange<Double> {
        let p = min(max(progress, 0), 1)
        let lo = old.lowerBound + (new.lowerBound - old.lowerBound) * p
        let hi = old.upperBound + (new.upperBound - old.upperBound) * p
        return lo...max(hi, lo)
    }

    /// The runs drawn up to `fraction` of the day (0...1), the last one ending on an interpolated
    /// point at the edge so the line's tip moves smoothly rather than jumping reading to reading.
    static func revealed(_ runs: [[DayComparePoint]], fraction: Double) -> [[DayComparePoint]] {
        let f = min(max(fraction, 0), 1)
        if f >= 1 { return runs }
        if f <= 0 { return [] }
        return clipped(runs, from: -Double.infinity, to: f * DayCompare.minutesPerDay)
    }

    /// The runs moved `offset` minutes along the day and cut to midnight-to-midnight, with
    /// interpolated points where a run crosses either edge.
    static func slid(_ runs: [[DayComparePoint]], by offset: Double) -> [[DayComparePoint]] {
        guard offset != 0 else { return runs }
        let moved = runs.map { $0.map { DayComparePoint(minute: $0.minute + offset, mgdl: $0.mgdl) } }
        return clipped(moved, from: 0, to: DayCompare.minutesPerDay)
    }

    /// Keeps the part of each run between `lo` and `hi` minutes. Runs are in rising minute order.
    static func clipped(_ runs: [[DayComparePoint]], from lo: Double, to hi: Double) -> [[DayComparePoint]] {
        var out: [[DayComparePoint]] = []
        for run in runs {
            var kept: [DayComparePoint] = []
            for (i, p) in run.enumerated() {
                if i > 0 {
                    let prev = run[i - 1]
                    // A segment crossing either edge gets a point exactly on it.
                    if prev.minute < lo, p.minute > lo, lo <= hi { kept.append(edge(prev, p, at: lo)) }
                    if prev.minute < hi, p.minute > hi, hi >= lo {
                        kept.append(edge(prev, p, at: hi))
                        break
                    }
                }
                if p.minute > hi { break }
                if p.minute >= lo { kept.append(p) }
            }
            if !kept.isEmpty { out.append(kept) }
        }
        return out
    }

    private static func edge(_ a: DayComparePoint, _ b: DayComparePoint, at minute: Double) -> DayComparePoint {
        let span = b.minute - a.minute
        let t = span == 0 ? 0 : (minute - a.minute) / span
        return DayComparePoint(minute: minute, mgdl: a.mgdl + (b.mgdl - a.mgdl) * t)
    }
}
