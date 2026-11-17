import Foundation

/// When a container that grows and shrinks with its content (the Mac popover, iPhone Today's stack)
/// should glide to its new height rather than jump. Kept free of SwiftUI so it can be unit-tested.
///
/// A height change glides only when something was actually added or taken away: the snoozed chip,
/// a notice or status banner, the inline Log treatment button, the details section. Everything else
/// snaps, so nothing animates on its own:
/// - the first measurement, and every measurement while the popover is opening (it opens at its
///   size, even if its content changed while it was closed);
/// - a change smaller than `threshold`, such as a reading's text settling by a fraction of a point,
///   so a new reading never sets off a resize (docs/Redesign.md §4.6);
/// - anything under Reduce Motion, where the new size is simply there.
enum ContentResize {
    enum Step: Equatable, Sendable {
        /// Take the new height at once.
        case snap
        /// Animate from the old height to the new one.
        case glide
    }

    /// Smallest change, in points, worth animating. The smallest thing that comes and goes (the
    /// snoozed chip) is about 30 pt; anything under this is text settling.
    static let threshold: Double = 4

    /// What to do when the measured height goes from `old` to `new`. `old` is 0 before the first
    /// measurement. `settled` is false while the popover is opening.
    static func step(from old: Double, to new: Double, settled: Bool, reduceMotion: Bool) -> Step {
        guard settled, !reduceMotion, old > 0, new > 0 else { return .snap }
        return abs(new - old) >= threshold ? .glide : .snap
    }
}
