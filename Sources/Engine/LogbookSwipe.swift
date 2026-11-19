import Foundation

// How a Logbook row's swipe actions follow the finger on iPhone (docs/LogbookSearch.md "Swiping a
// row", round 95). Display only: what a swipe can do never changes here. Swipe left to delete (a
// full swipe works, and the Undo toast can bring it back); swipe right for Log Again Now, which only
// ever logs on a tap of its button, never on a flick or a full swipe, so a dose can't be logged twice.
//
// As the row slides, the action's icon grows and fades in with the distance, and a soft tick plays
// once the drag passes the point where letting go does something: on the left edge, where the row
// deletes; on the right, where Log Again Now stays open to be tapped. Under Reduce Motion the icon
// is simply there, at full size, as soon as the row moves.

enum LogbookSwipe {
    /// Which side the row slid towards, by the action it shows.
    enum Edge: Equatable, Sendable {
        /// Slid right: Log Again Now, on the leading edge.
        case logAgain
        /// Slid left: Delete, on the trailing edge.
        case delete
    }

    /// What letting go does.
    enum Release: Equatable, Sendable {
        /// The row springs back shut.
        case close
        /// The row stays open on this edge, showing its button to tap.
        case open(Edge)
        /// The row slides away and is deleted (the Undo toast offers it back).
        case delete
    }

    /// How wide an open action is, in points: the row slides this far and stays.
    static let actionWidth: Double = 76
    /// How far past an open Log Again Now the row can be pulled, as a share of the extra distance
    /// (it resists, as nothing more happens out there).
    static let resistance: Double = 0.3
    /// The share of the row's width a left swipe needs before letting go deletes.
    static let deleteShare: Double = 0.55
    /// A left swipe never deletes short of this, however narrow the row.
    static let deleteMinimum: Double = actionWidth + 64
    /// How far back the finger has to come before the tick can play again, so it never repeats
    /// while hovering at the threshold.
    static let hysteresis: Double = 10
    /// A flick at least this fast (points per second) counts as meaning it, even short of a threshold.
    static let flickSpeed: Double = 900
    /// The icon's size while the row has barely moved; it grows to full size as the action opens.
    static let smallestScale: Double = 0.4
    /// How much bigger the trash grows once letting go would delete.
    static let armedScale: Double = 1.15
    /// How far the row moves before a Reduce Motion icon shows.
    static let reduceMotionReveal: Double = 2

    static func edge(_ offset: Double) -> Edge? {
        if offset > 0 { return .logAgain }
        if offset < 0 { return .delete }
        return nil
    }

    /// Where the left swipe deletes, for a row this wide.
    static func deleteThreshold(rowWidth: Double) -> Double {
        max(deleteMinimum, rowWidth * deleteShare)
    }

    /// Where letting go starts to do something on this edge: the delete point on the left, the
    /// open point on the right. The tick plays here.
    static func commitThreshold(_ edge: Edge, rowWidth: Double) -> Double {
        switch edge {
        case .logAgain: return actionWidth
        case .delete: return deleteThreshold(rowWidth: rowWidth)
        }
    }

    /// Where the row sits for a finger this far across (`translation`), starting from `base` (0, or
    /// an open action's width). Log Again Now resists past its open width; Delete follows the finger
    /// to the row's edge.
    static func offset(translation: Double, base: Double = 0, rowWidth: Double) -> Double {
        let raw = base + translation
        if raw > actionWidth { return actionWidth + (raw - actionWidth) * resistance }
        return max(raw, -max(rowWidth, deleteMinimum))
    }

    /// How far the action has opened, 0 to 1, for the row at `offset`.
    static func progress(_ offset: Double) -> Double {
        min(1, max(0, abs(offset) / actionWidth))
    }

    /// The icon's scale: growing with the distance to full size at the open width, a touch bigger
    /// once a left swipe would delete. Always full size under Reduce Motion.
    static func iconScale(offset: Double, rowWidth: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        if armed(offset: offset, rowWidth: rowWidth), edge(offset) == .delete { return armedScale }
        let p = eased(progress(offset))
        return smallestScale + (1 - smallestScale) * p
    }

    /// The icon's opacity: clear while the row has barely moved, fully in by the open width. Under
    /// Reduce Motion it is there as soon as the row moves.
    static func iconOpacity(offset: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return abs(offset) >= reduceMotionReveal ? 1 : 0 }
        return min(1, max(0, (progress(offset) - 0.15) / 0.6))
    }

    /// Whether letting go now does something on this side (deletes on the left, stays open on the right).
    static func armed(offset: Double, rowWidth: Double) -> Bool {
        guard let edge = edge(offset) else { return false }
        return abs(offset) >= commitThreshold(edge, rowWidth: rowWidth)
    }

    /// What letting go does, given where the row is and the finger's speed (positive is rightwards).
    /// Log Again Now never logs here: at most it stays open, and its button takes the tap.
    static func release(offset: Double, velocity: Double, rowWidth: Double) -> Release {
        guard let edge = edge(offset) else { return .close }
        switch edge {
        case .logAgain:
            if velocity < -flickSpeed { return .close }
            return offset >= actionWidth / 2 || velocity > flickSpeed ? .open(.logAgain) : .close
        case .delete:
            if velocity > flickSpeed { return .close }
            if -offset >= deleteThreshold(rowWidth: rowWidth) { return .delete }
            return -offset >= actionWidth / 2 || velocity < -flickSpeed ? .open(.delete) : .close
        }
    }

    /// Where the row rests after letting go.
    static func restingOffset(_ release: Release, rowWidth: Double) -> Double {
        switch release {
        case .close: return 0
        case .open(.logAgain): return actionWidth
        case .open(.delete): return -actionWidth
        case .delete: return -max(rowWidth, deleteMinimum)
        }
    }

    private static func eased(_ p: Double) -> Double {
        // Ease out: quick to start growing, settling as the action opens.
        1 - (1 - p) * (1 - p)
    }

    /// Plays the threshold tick once per crossing, outward only, with `hysteresis` so a finger
    /// resting at the edge doesn't tick again and again.
    struct Tick: Equatable, Sendable {
        private(set) var armed = false

        /// Takes the row's new offset and says whether to tick now.
        mutating func update(offset: Double, rowWidth: Double) -> Bool {
            guard let edge = LogbookSwipe.edge(offset) else {
                armed = false
                return false
            }
            let threshold = LogbookSwipe.commitThreshold(edge, rowWidth: rowWidth)
            if armed {
                if abs(offset) < threshold - LogbookSwipe.hysteresis { armed = false }
                return false
            }
            if abs(offset) >= threshold {
                armed = true
                return true
            }
            return false
        }

        mutating func reset() { armed = false }
    }
}
