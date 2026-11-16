import Foundation

/// One soft cue when the live reading on the app's own screens crosses into or out of the target
/// range (improvement round 43, docs/Redesign.md §6.5): on iPhone Today a light tap plus a brief
/// wash of the new range colour behind the reading, on the Mac popover the wash only. Kept free of
/// SwiftUI so it can be unit-tested. Alerts are separate and unchanged (docs/AlertActions.md).
///
/// The cue fires on the reading that crosses the edge, so it lands with the figure's colour
/// change. It then waits to re-arm until a reading sits at least `margin` inside the new side, so
/// a reading hovering around the edge (69, 71, 68, 72 with the low line at 70) cues once, on the
/// first crossing, and never again until it has clearly settled somewhere.
///
/// Nothing cues on the first reading seen, after the reading was stale or still the saved one
/// from before launch, on the same reading drawn again, or when the target range itself moves:
/// each of those just takes the new side quietly.
struct RangeCrossing: Equatable, Sendable {
    /// Which side of the target range a reading is on. The urgent-low and very-high bands are
    /// still `below` and `above`: going from low to urgent low isn't a crossing of the range.
    enum Side: Equatable, Sendable {
        case below, inRange, above

        static func of(mgdl: Double, low: Double, high: Double) -> Side {
            if mgdl < low { return .below }
            if mgdl > high { return .above }
            return .inRange
        }
    }

    /// What a crossing was.
    enum Cue: Equatable, Sendable {
        /// Out of range, below the low line.
        case wentLow
        /// Out of range, above the high line.
        case wentHigh
        /// Back inside the range, from either side.
        case backInRange

        /// What the iPhone plays for it. A low keeps its warning (it's the crossing that matters
        /// most); the other two are the one light tap.
        var haptic: HapticEvent {
            self == .wentLow ? .enteredLow : .rangeCrossed
        }
    }

    /// How far inside a side a reading has to sit before the next crossing cues: about 0.3 mmol/L,
    /// a little more than a Libre reading's minute-to-minute noise.
    static let margin: Double = 5

    /// The wash behind the reading: how strong the new range colour gets, how long it takes to
    /// come up and how long it takes to fade away. Under a second in all, and it plays once.
    static let washPeakOpacity: Double = 0.18
    static let washRise: TimeInterval = 0.18
    static let washFade: TimeInterval = 0.72
    static var washDuration: TimeInterval { washRise + washFade }

    /// Whether the wash draws. Under Reduce Motion it doesn't (the figure's colour just changes);
    /// the iPhone's tap still plays, since it isn't motion.
    static func washes(reduceMotion: Bool) -> Bool { !reduceMotion }

    private(set) var side: Side?
    /// Whether the next crossing cues: the reading has sat at least `margin` inside `side`.
    private(set) var armed = false
    private var readingAt: Date?
    private var low: Double?
    private var high: Double?

    init() {}

    /// Takes in the reading now on screen and says whether it is a crossing to cue.
    /// `live` is false while the reading is stale or still the one saved before launch.
    mutating func observe(mgdl: Double, at timestamp: Date, low: Double, high: Double,
                          live: Bool) -> Cue? {
        guard live, low < high else {
            // Not news: forget the side so the next live reading starts quietly.
            side = nil
            armed = false
            readingAt = nil
            return nil
        }
        let new = Side.of(mgdl: mgdl, low: low, high: high)
        let depth = Self.depth(mgdl: mgdl, inside: new, low: low, high: high)
        defer {
            readingAt = timestamp
            self.low = low
            self.high = high
        }
        guard let old = side, self.low == low, self.high == high else {
            // First reading, or the target range moved: take the side without a cue.
            side = new
            armed = depth >= Self.margin
            return nil
        }
        // The same reading drawn again says nothing new.
        guard readingAt != timestamp else { return nil }

        var cue: Cue?
        if new != old {
            if armed {
                switch new {
                case .below: cue = .wentLow
                case .above: cue = .wentHigh
                case .inRange: cue = .backInRange
                }
            }
            side = new
            armed = false
        }
        if depth >= Self.margin { armed = true }
        return cue
    }

    /// How far inside `side` a reading is, in mg/dL: from the nearer edge when in range, from the
    /// line it's beyond otherwise.
    static func depth(mgdl: Double, inside side: Side, low: Double, high: Double) -> Double {
        switch side {
        case .below: return low - mgdl
        case .above: return mgdl - high
        case .inRange: return min(mgdl - low, high - mgdl)
        }
    }
}
