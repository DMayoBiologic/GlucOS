import Foundation

/// The undo toast's clock (iPhone and Mac): how long the toast has left, drawn as a thin bar
/// that drains over its lifetime. A finger on the toast (iPhone) or the pointer over it (Mac)
/// pauses it, and letting go carries on from where it stopped rather than starting again. Plain
/// Foundation so it can be unit-tested; `UndoCountdownBar` draws it and the toasts end on it.
///
/// One drain per toast, nothing repeats (docs/DesignSystem.md, rule 7): the bar is a single linear
/// animation from what's left to empty, and under Reduce Motion it steps down once a second instead.
struct UndoCountdown: Equatable, Sendable {
    /// The toast's whole lifetime, in seconds (`LogbookUndo.toastSeconds`, or the VoiceOver one).
    let total: Double
    /// Seconds left when the clock last stopped or started.
    private(set) var remaining: Double
    /// When it last started running; nil while paused.
    private(set) var runningSince: Date?

    /// Letting go with less than this left gives it this much, so the toast doesn't vanish the
    /// moment a finger lifts off it.
    static let minimumAfterPause: Double = 1

    init(total: Double, start: Date) {
        self.total = max(0, total)
        remaining = self.total
        runningSince = start
    }

    var isPaused: Bool { runningSince == nil }

    /// Seconds left at `now`.
    func left(at now: Date) -> Double {
        guard let since = runningSince else { return remaining }
        return max(0, remaining - max(0, now.timeIntervalSince(since)))
    }

    /// How full the bar is at `now`, from 1 (just shown) to 0 (gone).
    func fraction(at now: Date) -> Double {
        total > 0 ? min(1, left(at: now) / total) : 0
    }

    /// Under Reduce Motion the bar moves once a second, to the whole seconds left, so nothing glides.
    func steppedFraction(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, (left(at: now) - 0.001).rounded(.up) / total))
    }

    /// True once it has run out and nothing is holding it.
    func isOver(at now: Date) -> Bool { !isPaused && left(at: now) <= 0 }

    /// A finger landed on the toast, or the pointer moved over it.
    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        remaining = left(at: now)
        runningSince = nil
    }

    /// The finger lifted, or the pointer left: carry on from where it stopped.
    mutating func resume(at now: Date) {
        guard isPaused else { return }
        remaining = max(remaining, min(total, Self.minimumAfterPause))
        runningSince = now
    }

    /// True when the deleted entries changed in a way that should start the toast again and be
    /// announced: something new was deleted. Undo on part of the buffer, or sync ending some of
    /// it (`LogbookUndo.superseded`), keeps the clock going and says nothing.
    static func restarts(from old: [UUID], to new: [UUID]) -> Bool {
        !Set(new).subtracting(old).isEmpty
    }
}

/// Swiping the undo toast away: sideways either way, or down off the bottom edge. Up is the
/// wrong way, so the toast only gives a little there. A swipe away just dismisses: it never undoes.
enum UndoSwipe {
    /// How far it has to go to be dismissed, in points.
    static let distance: Double = 70
    /// A quick flick that would carry it at least this far dismisses too.
    static let flickDistance: Double = 160
    /// How much the toast moves for a drag upward, the wrong way.
    static let upwardGive: Double = 0.2

    enum Direction: Equatable, Sendable { case leading, trailing, down }

    /// Where the toast sits for a drag of (dx, dy): with the finger, except a little resistance upward.
    static func offset(dx: Double, dy: Double) -> (x: Double, y: Double) {
        (dx, dy < 0 ? dy * upwardGive : dy)
    }

    /// Which way a drag that ended at (dx, dy), and would have carried on to (endX, endY), sends the
    /// toast; nil springs it back.
    static func dismissal(dx: Double, dy: Double, endX: Double, endY: Double) -> Direction? {
        let sideways = abs(dx) >= dy
        if sideways {
            if abs(dx) >= distance || abs(endX) >= flickDistance {
                return (abs(dx) >= distance ? dx : endX) < 0 ? .leading : .trailing
            }
            return nil
        }
        return dy >= distance || endY >= flickDistance ? .down : nil
    }

    /// Where the toast flies to when it's swiped away, for a toast `width` points wide.
    static func exit(_ direction: Direction, width: Double) -> (x: Double, y: Double) {
        switch direction {
        case .leading: return (-(width + 40), 0)
        case .trailing: return (width + 40, 0)
        case .down: return (0, 160)
        }
    }
}
