import Foundation

// The Dynamic Island's compact trend line: an
// optional tiny last-hour line beside the trend arrow, off by default, switched on in Settings ›
// Lock Screen. It's drawn from the history every Live Activity update already carries, so it needs
// no new push fields and works the same on cards the app sends and cards the relay sends.
//
// On each new reading the line glides one slot to the left and the new point comes in from the
// right edge, rather than every point jumping to its neighbour's height. ActivityKit can only
// interpolate between two states, so the values are kept in a ring keyed by the reading's 5-minute
// slot (`slot mod ringSize`): a value that's on both the old and the new card sits at the same
// ring index in both, so only the slot's position moves. The two slots after the reading hold the
// reading itself until they're filled, so incoming points grow out of the line's end, and two
// slots older than the left edge keep their real values, so the line leaving on the left is true. A jump of three or more slots (a 15-minute gap) can briefly show one odd
// segment at the right edge while it glides. Under Reduce Motion the view doesn't animate at all.
//
// Free of SwiftUI so it's unit-tested; the widget extension draws it (IslandSparklineShape).

enum IslandSparkline {
    /// The iPhone setting, in the app group so the widget extension can read it.
    static let defaultsKey = "islandSparkline"
    static let defaultOn = false

    /// Five-minute steps across the line: 12 steps, 13 points, the last hour.
    static let visibleSteps = 12
    /// How many slots a card can move on by and still glide cleanly.
    static let glideSlots = 2
    /// Ring of slots: the visible 13, one more off the left edge so the line runs out of view as it
    /// glides, `glideSlots` older ones (so the slots leaving on the left keep their values) and
    /// `glideSlots` incoming ones (so new points grow out of the reading).
    static let ringSize = visibleSteps + 2 + 2 * glideSlots
    /// The vertical scale never shrinks below this (2 mmol/L), so a flat hour reads as flat.
    static let minSpanMgdl: Double = 36
    /// Fewer readings than this in the last hour and the line isn't drawn.
    static let minReadings = 4

    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultOn
    }

    /// One card's worth of line: what ActivityKit interpolates between two states.
    struct Frame: Equatable {
        /// The reading's 5-minute slot, `floor(readingAt / 300)`.
        var endSlot: Double
        /// mg/dL by slot: index `slot mod ringSize`. Gaps are filled from their neighbours.
        var ring: [Double]
        /// The vertical scale, mg/dL.
        var lowMgdl: Double
        var highMgdl: Double
    }

    /// The line for a card, or nil when the last hour has too few readings to draw one.
    /// `history` is `GlucoseActivityState.history`: one value per 5-minute slot, oldest first,
    /// ending at the reading.
    static func frame(history: [Int?], readingAt: Double) -> Frame? {
        guard let last = history.last, let current = last else { return nil }
        let end = Int((readingAt / GlucoseActivityState.historyStep).rounded(.down))
        // Slots end-15 ... end, oldest first: the visible hour, the one just off the left edge and
        // two older ones. A card one or two slots later still holds the same values for the slots
        // sliding out on the left; the ring's last two indices are the next two slots.
        let wanted = visibleSteps + 2 + glideSlots
        var tail: [Int?] = Array(history.suffix(wanted))
        if tail.count < wanted { tail = Array(repeating: nil, count: wanted - tail.count) + tail }

        let visible = tail.suffix(visibleSteps + 1)
        guard visible.compactMap({ $0 }).count >= minReadings else { return nil }

        let filled = fillGaps(tail)
        var ring = [Double](repeating: Double(current), count: ringSize)
        for (i, v) in filled.enumerated() {
            let slot = end - (wanted - 1 - i)
            ring[index(slot)] = v
        }
        // The slots after the reading start at the reading, so the next card's new points grow
        // out of the line's end instead of from wherever an old value left them.
        for ahead in 1...glideSlots { ring[index(end + ahead)] = Double(current) }

        let shown = filled.suffix(visibleSteps + 1)
        var lo = shown.min() ?? Double(current)
        var hi = shown.max() ?? Double(current)
        if hi - lo < minSpanMgdl {
            let mid = (lo + hi) / 2
            lo = mid - minSpanMgdl / 2
            hi = mid + minSpanMgdl / 2
        }
        return Frame(endSlot: Double(end), ring: ring, lowMgdl: lo, highMgdl: hi)
    }

    /// The points to draw for a frame part-way through a glide (`endSlot` may be fractional):
    /// `back` is how many steps before the right edge (0 = the edge; slightly negative while a
    /// new point slides in), `level` is 0 at the bottom to 1 at the top. Oldest first, including
    /// one point just past the left edge so the line runs off it; the view clips to its bounds.
    static func points(endSlot: Double, ring: [Double], lowMgdl: Double, highMgdl: Double)
        -> [(back: Double, level: Double)] {
        guard ring.count == ringSize else { return [] }
        let top = Int(endSlot.rounded(.up))
        let span = max(highMgdl - lowMgdl, 1)
        var out: [(back: Double, level: Double)] = []
        // Newest slot that can be drawn is `top`; go back the ring's length minus one so no
        // index is used twice.
        for slot in (top - (ringSize - 1))...top {
            let back = endSlot - Double(slot)
            guard back <= Double(visibleSteps + 1) else { continue }
            let level = min(1, max(0, (ring[index(slot)] - lowMgdl) / span))
            out.append((back, level))
        }
        return out
    }

    static func points(_ f: Frame) -> [(back: Double, level: Double)] {
        points(endSlot: f.endSlot, ring: f.ring, lowMgdl: f.lowMgdl, highMgdl: f.highMgdl)
    }

    static func index(_ slot: Int) -> Int {
        let m = slot % ringSize
        return m < 0 ? m + ringSize : m
    }

    /// Gaps filled by a straight line between their neighbours; a gap at either end takes the
    /// nearest value. Needs at least one value.
    static func fillGaps(_ values: [Int?]) -> [Double] {
        let known = values.enumerated().compactMap { i, v in v.map { (i, Double($0)) } }
        guard let first = known.first, let lastKnown = known.last else { return [] }
        return values.indices.map { i in
            if let v = values[i] { return Double(v) }
            if i < first.0 { return first.1 }
            if i > lastKnown.0 { return lastKnown.1 }
            let before = known.last { $0.0 < i }!
            let after = known.first { $0.0 > i }!
            let f = Double(i - before.0) / Double(after.0 - before.0)
            return before.1 + (after.1 - before.1) * f
        }
    }
}
