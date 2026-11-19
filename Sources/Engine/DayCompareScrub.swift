import Foundation

// One scrub cursor across both days of a comparison (docs/LogbookSearch.md, "Comparing two days").
// Drag along the compare chart on iPhone, or point at it on the Mac, and a single line sits at one
// clock time over both days, with each day's value there and how far apart they are.
//
// Method:
// 1. The cursor snaps to the readings: every point of either day's trace (the 5-minute means the
//    chart draws) is a stop, and the cursor sits on the stop nearest the finger. Over a stretch
//    where neither day has a point for more than the chart's gap (20 minutes) it shows nothing,
//    the same rule that breaks the lines.
// 2. Each day's value at the cursor is its own nearest point within one 5-minute bucket, so a day
//    with a gap there says "no reading" rather than borrowing one from far away. On a 25-hour day
//    the repeated hour has two points at one clock time; the nearer counts, the earlier on a tie.
// 3. The difference is the two values apart, said as which line is higher. It shows what was
//    there only, never which day was better.
//
// Feel (iPhone): readings themselves don't tick (`ChartScrub`): the cursor ticks with
// `scrubSnapped` when it first lands on a reading in a touch or after crossing a stretch with
// none, and with `scrubRangeEdge` when either day's line crosses the low or high line between two
// stops. VoiceOver hears each stop once per touch, and can step the cursor an hour at a time.

/// Where the shared cursor sits and what each day reads there.
struct DayCompareReadout: Equatable {
    /// Minutes since local midnight by the wall clock.
    let minute: Double
    let first: Double?
    let second: Double?

    /// Second minus first in mg/dL, nil unless both days have a value here.
    var difference: Double? {
        guard let first, let second else { return nil }
        return second - first
    }
}

enum DayCompareScrub {
    /// How far a day's nearest point may be from the cursor and still be its value there.
    static let valueReach = Double(DayChart.bucketMinutes)
    /// How far the nearest stop may be from the finger for the cursor to show at all.
    static let snapReach = Double(DayChart.gapMinutes)
    /// How far VoiceOver's adjustable action moves the cursor per swipe.
    static let voiceOverStep = 60.0

    /// Every point's clock minute across both days, oldest to newest, each once.
    static func stops(_ first: [[DayComparePoint]], _ second: [[DayComparePoint]]) -> [Double] {
        Array(Set((first + second).joined().map(\.minute))).sorted()
    }

    /// The stop the cursor settles on with the finger at `finger`, or nil when none is within
    /// `snapReach`. The earlier stop wins a tie. `stops` must be sorted.
    static func snap(finger: Double, stops: [Double]) -> Double? {
        guard !stops.isEmpty, finger.isFinite else { return nil }
        // First stop at or after the finger.
        var lo = 0, hi = stops.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stops[mid] < finger { lo = mid + 1 } else { hi = mid }
        }
        var best: Double?
        for i in [lo - 1, lo] where i >= 0 && i < stops.count {
            let s = stops[i]
            if best == nil || abs(s - finger) < abs(best! - finger) { best = s }
        }
        guard let best, abs(best - finger) <= snapReach else { return nil }
        return best
    }

    /// A day's value at `minute`: its nearest point within `valueReach`, or nil.
    static func value(at minute: Double, in runs: [[DayComparePoint]]) -> Double? {
        var best: DayComparePoint?
        for run in runs {
            for p in run where abs(p.minute - minute) <= valueReach {
                if best == nil || abs(p.minute - minute) < abs(best!.minute - minute) { best = p }
            }
        }
        return best?.mgdl
    }

    static func readout(at minute: Double, first: [[DayComparePoint]], second: [[DayComparePoint]]) -> DayCompareReadout {
        DayCompareReadout(minute: minute, first: value(at: minute, in: first), second: value(at: minute, in: second))
    }

    /// Whether moving the cursor from `old` to `new` takes either day's line over the low or high
    /// line. Every point between the two is looked at, so a fast drag through a short low still
    /// counts.
    static func crossesRangeEdge(from old: Double, to new: Double, first: [[DayComparePoint]],
                                 second: [[DayComparePoint]], low: Double, high: Double) -> Bool {
        guard old != new else { return false }
        let lo = min(old, new), hi = max(old, new)
        for runs in [first, second] {
            for run in runs {
                let bands = run.lazy.filter { $0.minute >= lo && $0.minute <= hi }
                    .map { ChartScrub.Band(mgdl: $0.mgdl, low: low, high: high) }
                if let b = bands.first, bands.contains(where: { $0 != b }) { return true }
            }
        }
        return false
    }

    /// Where VoiceOver's swipe up (`by` = 1) or down (-1) moves the cursor: the next whole hour
    /// with a reading near it, starting from noon when there's no cursor yet. Nil at either end.
    static func stepped(_ minute: Double?, by: Int, stops: [Double]) -> Double? {
        guard by != 0, !stops.isEmpty else { return nil }
        guard let minute else { return snap(finger: 720, stops: stops) ?? stops[stops.count / 2] }
        let step = voiceOverStep
        var hour = by > 0 ? (minute / step).rounded(.down) + 1 : (minute / step).rounded(.up) - 1
        while hour >= 0 && hour * step <= DayCompare.minutesPerDay {
            if let s = snap(finger: hour * step, stops: stops), by > 0 ? s > minute : s < minute { return s }
            hour += by > 0 ? 1 : -1
        }
        return nil
    }
}

/// What a scrub tick should feel like, if anything (`HapticEvent` lives in the app's shared code).
enum DayCompareScrubTick: Equatable {
    /// Landed on a reading: first in a touch, or after a stretch with none.
    case landed
    /// Either day's line crossed the low or high line.
    case rangeEdge

    /// The tick for the cursor moving from `old` (nil: it wasn't showing) to `new`.
    static func tick(from old: Double?, to new: Double?, first: [[DayComparePoint]],
                     second: [[DayComparePoint]], low: Double, high: Double) -> DayCompareScrubTick? {
        guard let new, new != old else { return nil }
        guard let old else { return .landed }
        return DayCompareScrub.crossesRangeEdge(from: old, to: new, first: first, second: second, low: low, high: high)
            ? .rangeEdge : nil
    }
}

// MARK: - Words

enum DayCompareScrubText {
    /// Above the chart before a scrub: what it does.
    static let hint = "Drag across the chart to compare times"
    static let macHint = "Point at the chart to compare times"

    /// "6:15 pm", the cursor's clock time.
    static func time(_ minute: Double) -> String { DayPatternText.clock(Int(minute.rounded())) }

    /// "7.2", or "–" where the day has no reading.
    static func value(_ mgdl: Double?, unit: GlucoseUnit) -> String {
        mgdl.map { unit.format(mgdl: $0) } ?? "–"
    }

    /// Whether the two read the same once rounded to what's shown.
    static func same(_ r: DayCompareReadout, unit: GlucoseUnit) -> Bool {
        guard let d = r.difference else { return false }
        return unit.format(mgdl: abs(d)) == unit.format(mgdl: 0)
    }

    /// Which line is higher at the cursor: true the first, false the second, nil when level or
    /// either is missing.
    static func firstHigher(_ r: DayCompareReadout, unit: GlucoseUnit) -> Bool? {
        guard let d = r.difference, !same(r, unit: unit) else { return nil }
        return d < 0
    }

    /// "1.1 higher", "Same", or nil when a day has no reading. Shown beside the higher line's swatch.
    static func difference(_ r: DayCompareReadout, unit: GlucoseUnit) -> String? {
        guard let d = r.difference else { return nil }
        if same(r, unit: unit) { return "Same" }
        return "\(unit.format(mgdl: abs(d))) higher"
    }

    /// What VoiceOver says for a stop: "6:15 pm. Today 7.2 mmol/L, Monday 11 November 6.1 mmol/L.
    /// Today 1.1 mmol/L higher." A day with nothing there says "no reading".
    static func spoken(_ r: DayCompareReadout, first: String, second: String, unit: GlucoseUnit) -> String {
        let say = { (v: Double?) in v.map { unit.format(mgdl: $0, withUnit: true) } ?? "no reading" }
        var out = "\(time(r.minute)). \(first) \(say(r.first)), \(second) \(say(r.second))."
        if let d = r.difference {
            if same(r, unit: unit) {
                out += " The same."
            } else {
                out += " \(d < 0 ? first : second) \(unit.format(mgdl: abs(d), withUnit: true)) higher."
            }
        }
        return out
    }
}
