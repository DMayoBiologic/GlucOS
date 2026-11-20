import Foundation

// How a saved insulin's row leaves Settings › Your Insulins and comes back (round 101). Deleting
// it shrinks the row away from the bottom edge up while the rows below slide up into its place;
// Undo on the toast grows it back in the same place, the same motion in reverse. Under Reduce
// Motion nothing moves: the row fades out where it is and the rows below then jump, and Undo fades
// it back in. Plain Foundation so `swift test` covers the rules.

enum RowRemoval {
    /// How long the row takes to shrink away or grow back, in seconds.
    static let duration: Double = 0.3
    /// The fade under Reduce Motion, in seconds.
    static let fadeDuration: Double = 0.2
    /// How small the row has got by the time it's gone (it shrinks toward its top edge).
    static let shrunkScale: Double = 0.96

    /// The row's scale with `fraction` of its height left: 1 at full height, `shrunkScale` at none.
    static func scale(fraction: Double) -> Double {
        shrunkScale + (1 - shrunkScale) * clamped(fraction)
    }

    /// The row's opacity with `fraction` of its height left. It fades a little ahead of the
    /// shrink, so its text is gone before the row is too short to hold it.
    static func opacity(fraction: Double) -> Double {
        min(1, clamped(fraction) * 1.5)
    }

    /// The rows that are new in `new`: the ones that fade in under Reduce Motion. A reorder brings
    /// none.
    static func arrivals(from old: [UUID], to new: [UUID]) -> Set<UUID> {
        Set(new).subtracting(old)
    }

    private static func clamped(_ f: Double) -> Double { min(max(f, 0), 1) }
}
