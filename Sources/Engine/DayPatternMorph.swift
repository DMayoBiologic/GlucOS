import Foundation

/// How the "Your usual day" chart gets from one period's pattern to the next, and how its bands
/// draw in. Plain values so the motion can be unit-tested; `DayPatternView` drives it on screen.
/// Nothing here changes the pattern itself, only what's drawn of it on the way; at rest the chart
/// shows exactly the computed pattern.
enum DayPatternMorph {
    /// The pattern part way from `from` to `to` at `t` (0 = `from`, 1 = `to`, clamped). Slots pair
    /// up by time of day, so each band glides up or down in place. A slot that only one side has
    /// takes `to`'s state straight away (a gap opens or closes at once, never drawn half way).
    static func blend(from: DayPattern, to: DayPattern, t: Double) -> DayPattern {
        let t = min(max(t, 0), 1)
        guard t < 1, from.slots.count == to.slots.count else { return to }
        let slots = zip(from.slots, to.slots).map { a, b -> DayPattern.Slot? in
            guard let a, let b else { return b }
            func lerp(_ k: KeyPath<DayPattern.Slot, Double>) -> Double { a[keyPath: k] + (b[keyPath: k] - a[keyPath: k]) * t }
            return DayPattern.Slot(minute: b.minute, p10: lerp(\.p10), p25: lerp(\.p25), p50: lerp(\.p50),
                                   p75: lerp(\.p75), p90: lerp(\.p90), count: b.count)
        }
        return DayPattern(window: to.window, slots: slots, days: to.days)
    }

    /// The bands grown `reveal` of the way out from the middle line (0 = just the line, 1 = the
    /// whole pattern, clamped): the draw-in when the card first shows.
    static func spread(_ pattern: DayPattern, reveal: Double) -> DayPattern {
        let r = min(max(reveal, 0), 1)
        guard r < 1 else { return pattern }
        let slots = pattern.slots.map { s -> DayPattern.Slot? in
            guard let s else { return nil }
            func out(_ v: Double) -> Double { s.p50 + (v - s.p50) * r }
            return DayPattern.Slot(minute: s.minute, p10: out(s.p10), p25: out(s.p25), p50: s.p50,
                                   p75: out(s.p75), p90: out(s.p90), count: s.count)
        }
        return DayPattern(window: pattern.window, slots: slots, days: pattern.days)
    }

    /// The chart's glucose axis in mg/dL: the 8-in-10 band with 10 to spare, never narrower than
    /// 60–200 or the target range.
    static func yDomain(_ pattern: DayPattern, low: Double, high: Double) -> ClosedRange<Double> {
        let f = pattern.filled
        let lo = min(f.map(\.p10).min() ?? 60, low, 60) - 10
        let hi = max(f.map(\.p90).max() ?? 200, high, 200) + 10
        return lo...hi
    }

    /// The axis part way between the two patterns' axes, so it glides with the bands rather than
    /// jumping when the period changes.
    static func yDomain(from: DayPattern, to: DayPattern, t: Double, low: Double, high: Double) -> ClosedRange<Double> {
        let t = min(max(t, 0), 1)
        let b = yDomain(to, low: low, high: high)
        guard t < 1 else { return b }
        let a = yDomain(from, low: low, high: high)
        return (a.lowerBound + (b.lowerBound - a.lowerBound) * t)...(a.upperBound + (b.upperBound - a.upperBound) * t)
    }
}
