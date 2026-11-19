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

    /// Back-in-range moment (round 89): a `.backInRange` crossing after the reading has been out
    /// of range for at least this long also gets one soft ring of the in-range colour around the
    /// reading, the one light tap the crossing already plays on iPhone, and "Back in range" for
    /// VoiceOver. Shorter dips just get the usual crossing cue.
    static let momentAfter: TimeInterval = 15 * 60
    /// A gap longer than this between live readings ends the out-of-range spell unseen, as an
    /// alert episode does (docs/AlertEpisodes.md), so the moment never marks a spell it didn't see.
    static let momentGap: TimeInterval = 30 * 60

    /// The ring sweep: how strong it starts, how far it grows and how long it takes. Once, and
    /// under Reduce Motion it doesn't draw.
    static let ringPeakOpacity: Double = 0.7
    static let ringGrowth: Double = 1.12
    static let ringDuration: TimeInterval = 1.1

    /// Whether this crossing is a back-in-range moment: back in range after `momentAfter` or more
    /// out, on the person's own reading (never a follower's view).
    static func marksMoment(_ cue: Cue?, outFor: TimeInterval?, follower: Bool) -> Bool {
        guard cue == .backInRange, !follower, let outFor else { return false }
        return outFor >= momentAfter
    }

    /// Whether the moment's ring draws: never under Reduce Motion. The tap and the VoiceOver line
    /// aren't motion, so they still come.
    static func ringSweeps(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// What VoiceOver says at the moment, once.
    static let momentAnnouncement = "Back in range"

    private(set) var side: Side?
    /// When the current out-of-range spell began: the first live reading seen outside the range.
    /// Kept through readings that bounce back in without re-arming, and cleared once the reading
    /// is settled back in range, so each spell has one end.
    private(set) var outSince: Date?
    /// How long the reading had been out when the latest reading cued `.backInRange`; nil on
    /// every other reading.
    private(set) var backAfter: TimeInterval?
    /// Whether the next crossing cues: the reading has sat at least `margin` inside `side`.
    private(set) var armed = false
    private var readingAt: Date?
    /// The last live reading's time, to spot a gap longer than `momentGap`.
    private var lastLiveAt: Date?
    private var low: Double?
    private var high: Double?

    init() {}

    /// Takes in the reading now on screen and says whether it is a crossing to cue.
    /// `live` is false while the reading is stale or still the one saved before launch.
    mutating func observe(mgdl: Double, at timestamp: Date, low: Double, high: Double,
                          live: Bool) -> Cue? {
        backAfter = nil
        guard live, low < high else {
            // Not news: forget the side so the next live reading starts quietly. The spell's start
            // is kept (a short stale stretch mid-low is still the same low); `momentGap` drops it.
            side = nil
            armed = false
            readingAt = nil
            return nil
        }
        let new = Side.of(mgdl: mgdl, low: low, high: high)
        let depth = Self.depth(mgdl: mgdl, inside: new, low: low, high: high)
        if let last = lastLiveAt, timestamp.timeIntervalSince(last) > Self.momentGap { outSince = nil }
        defer {
            readingAt = timestamp
            lastLiveAt = timestamp
            self.low = low
            self.high = high
        }
        guard let old = side, self.low == low, self.high == high else {
            // First reading, or the target range moved: take the side without a cue.
            side = new
            armed = depth >= Self.margin
            if new == .inRange { outSince = nil } else if outSince == nil { outSince = timestamp }
            return nil
        }
        // The same reading drawn again says nothing new.
        guard readingAt != timestamp else { return nil }
        if new != .inRange, outSince == nil { outSince = timestamp }

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
        if cue == .backInRange, let since = outSince {
            backAfter = timestamp.timeIntervalSince(since)
            outSince = nil
        } else if new == .inRange, armed {
            // Settled back in range without a cue (a shallow dip that never sat `margin` out):
            // the spell is over, quietly.
            outSince = nil
        }
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
