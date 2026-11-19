import Foundation

// Scrubbing Your usual day (round 88). Hold and drag along the chart on iPhone, or point at it on
// the Mac, and a cursor sits on one half-hour of the day with a small card giving that time's
// middle reading and its middle half, while the rest of the chart dims back.
//
// Method:
// 1. The stops are the pattern's filled 30-minute slots, at their middles (where the chart plots
//    them). The cursor sits on the slot nearest the finger. Over a gap with no slot within one
//    slot's width it shows nothing, the same as the chart's own gap.
// 2. The usual day's highest and lowest middle-line slots are landmarks, and the cursor snaps onto
//    them with the chart scrub's own rule (`ScrubSnap`: within 8 pt, held until 14 pt away), so
//    the high and low points of the day are easy to land on.
// 3. VoiceOver's adjustable action steps an hour at a time, to the slot starting on each hour (or
//    its half-hour slot where that's missing), skipping hours with nothing.
//
// Feel (iPhone): `scrubSnapped` when the cursor first lands in a touch or snaps onto a landmark,
// `scrubRangeEdge` when the middle line crosses the low or high line between two stops. Plain
// Foundation so it's unit-tested. Observational only: it says what the days showed, never advice.

enum DayPatternScrub {
    /// How far the nearest slot may be from the finger, in minutes, for the cursor to show.
    static let reach = Double(DayPattern.slotMinutes)
    /// How far VoiceOver's adjustable action moves the cursor per swipe.
    static let voiceOverStep = 60
    /// How much the chart outside the cursor's half-hour fades back to.
    static let dimmedOpacity = 0.35
    /// The minute landmarks are placed at on an arbitrary day, so `ScrubSnap` can work on dates.
    private static let reference = Date(timeIntervalSinceReferenceDate: 0)

    /// The filled slots' middles, earliest first.
    static func stops(_ pattern: DayPattern) -> [Double] {
        pattern.filled.map(\.midMinute)
    }

    /// The filled slot plotted at `minute`, if any.
    static func slot(at minute: Double, in pattern: DayPattern) -> DayPattern.Slot? {
        let i = Int((minute / Double(DayPattern.slotMinutes)).rounded(.down))
        guard pattern.slots.indices.contains(i), let s = pattern.slots[i], s.midMinute == minute else { return nil }
        return s
    }

    /// The nearest filled slot's middle to `finger`, or nil when none is within `reach`. The
    /// earlier wins a tie.
    static func nearest(finger: Double, pattern: DayPattern) -> Double? {
        guard finger.isFinite else { return nil }
        var best: Double?
        for m in stops(pattern) where best == nil || abs(m - finger) < abs(best! - finger) { best = m }
        guard let best, abs(best - finger) <= reach else { return nil }
        return best
    }

    /// The usual day's highest and lowest middle-line slots, as snap targets. A flat day (one
    /// value all day) has none.
    static func landmarks(_ pattern: DayPattern) -> [ScrubSnap.Target] {
        let f = pattern.filled
        guard let peak = f.max(by: { $0.p50 < $1.p50 }), let trough = f.min(by: { $0.p50 < $1.p50 }),
              trough.p50 < peak.p50 else { return [] }
        return [ScrubSnap.Target(date: date(trough.midMinute), kind: .lowest(mgdl: trough.p50)),
                ScrubSnap.Target(date: date(peak.midMinute), kind: .highest(mgdl: peak.p50))]
            .sorted { $0.date < $1.date }
    }

    /// Whether the slot at `minute` is the usual day's highest or lowest.
    static func landmark(at minute: Double, in pattern: DayPattern) -> ScrubSnap.Kind? {
        landmarks(pattern).first { $0.date == date(minute) }?.kind
    }

    /// Where the cursor settles with the finger at `finger`: snapped onto a landmark within
    /// `ScrubSnap.reach` points (held until `ScrubSnap.letGo`), otherwise the nearest slot.
    ///
    /// - Parameters:
    ///   - current: where the cursor was a moment ago, so a landmark it sits on can hold on.
    ///   - minutesPerPoint: how many minutes one point along the chart covers.
    static func settle(finger: Double, pattern: DayPattern, current: Double?, minutesPerPoint: Double) -> Double? {
        guard finger.isFinite else { return nil }
        let targets = landmarks(pattern)
        let held = current.flatMap { c in targets.first { $0.date == date(c) } }
        if let snapped = ScrubSnap.snap(finger: date(finger), targets: targets, current: held,
                                        secondsPerPoint: minutesPerPoint * 60) {
            return snapped.date.timeIntervalSince(reference) / 60
        }
        return nearest(finger: finger, pattern: pattern)
    }

    /// Whether moving from `old` to `new` takes the middle line over the low or high line. Every
    /// slot between the two counts, so a quick drag through a short dip still ticks.
    static func crossesRangeEdge(from old: Double, to new: Double, pattern: DayPattern,
                                 low: Double, high: Double) -> Bool {
        guard old != new else { return false }
        let lo = min(old, new), hi = max(old, new)
        let bands = pattern.filled.lazy.filter { $0.midMinute >= lo && $0.midMinute <= hi }
            .map { ChartScrub.Band(mgdl: $0.p50, low: low, high: high) }
        guard let b = bands.first else { return false }
        return bands.contains { $0 != b }
    }

    /// Where VoiceOver's swipe up (`by` = 1) or down (-1) moves the cursor: the next hour with a
    /// slot, its on-the-hour slot first. From no cursor it starts at noon (or the nearest slot).
    /// Nil past either end.
    static func stepped(_ minute: Double?, by: Int, pattern: DayPattern) -> Double? {
        guard by != 0, !pattern.filled.isEmpty else { return nil }
        let perHour = 60 / DayPattern.slotMinutes
        func hourStop(_ h: Int) -> Double? {
            for i in (h * perHour)..<((h + 1) * perHour) where pattern.slots.indices.contains(i) {
                if let s = pattern.slots[i] { return s.midMinute }
            }
            return nil
        }
        guard let minute else { return hourStop(12) ?? nearest(finger: 720, pattern: pattern) ?? stops(pattern).first }
        var h = Int(minute) / voiceOverStep + (by > 0 ? 1 : -1)
        while h >= 0 && h < 24 {
            if let s = hourStop(h) { return s }
            h += by > 0 ? 1 : -1
        }
        return nil
    }

    private static func date(_ minute: Double) -> Date { reference.addingTimeInterval(minute * 60) }
}

/// What a scrub step should feel like, if anything (`HapticEvent` lives in the app's shared code).
enum DayPatternScrubTick: Equatable {
    /// Landed: first in a touch, or onto the usual day's highest or lowest point.
    case snapped
    /// The middle line crossed the low or high line.
    case rangeEdge

    static func tick(from old: Double?, to new: Double?, pattern: DayPattern, low: Double, high: Double) -> DayPatternScrubTick? {
        guard let new, new != old else { return nil }
        guard let old else { return .snapped }
        if DayPatternScrub.landmark(at: new, in: pattern) != nil { return .snapped }
        return DayPatternScrub.crossesRangeEdge(from: old, to: new, pattern: pattern, low: low, high: high)
            ? .rangeEdge : nil
    }
}

// MARK: - Words

enum DayPatternScrubText {
    /// "2 pm–2:30 pm": the slot's half-hour.
    static func time(_ slot: DayPattern.Slot) -> String {
        "\(DayPatternText.clock(slot.minute))–\(DayPatternText.clock(slot.minute + DayPattern.slotMinutes))"
    }

    /// "6.1–8.4": the middle half, in the card.
    static func middleHalf(_ slot: DayPattern.Slot, unit: GlucoseUnit) -> String {
        "\(unit.format(mgdl: slot.p25))–\(unit.format(mgdl: slot.p75))"
    }

    /// "Highest of the day" or "Lowest of the day" when the cursor is on a landmark.
    static func landmark(_ kind: ScrubSnap.Kind?) -> String? {
        switch kind {
        case .highest: return "Highest of the day"
        case .lowest: return "Lowest of the day"
        default: return nil
        }
    }

    /// What VoiceOver says for a stop: "2 pm to 2:30 pm. Middle 7.2 mmol/L, middle half 6.1 to 8.4.
    /// Highest of the day."
    static func spoken(_ slot: DayPattern.Slot, kind: ScrubSnap.Kind?, unit: GlucoseUnit) -> String {
        let end = DayPatternText.clock(slot.minute + DayPattern.slotMinutes)
        var out = "\(DayPatternText.clock(slot.minute)) to \(end). Middle \(unit.format(mgdl: slot.p50, withUnit: true)), middle half \(unit.format(mgdl: slot.p25)) to \(unit.format(mgdl: slot.p75))."
        if let l = landmark(kind) { out += " \(l)." }
        return out
    }

    static let hint = "Swipe up or down to move through the day an hour at a time."
}
