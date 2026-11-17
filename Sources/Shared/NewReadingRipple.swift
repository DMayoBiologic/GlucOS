import Foundation

/// Whether the current-reading dot at the end of the chart's trace gives its one soft ripple, kept
/// free of SwiftUI so it can be unit-tested (docs/Redesign.md §4.6, §8).
///
/// Only iPhone Today and the Mac popover ripple. The ripple plays once when a newer reading lands
/// and then the chart holds still until the next one: nothing loops (the power rule, §4.6).
///
/// It stays still when:
/// - the chart is just opening (`previous` is nil): what's there is already there;
/// - the newest reading didn't move forward (same reading, a history backfill, a reorder);
/// - the new reading is already stale (catching up after a gap isn't "a reading just arrived");
/// - the app is in the background, or the chart isn't on screen (a closed Mac popover keeps it);
/// - Reduce Motion is on.
enum NewReadingRipple {
    static func plays(previous: Date?, newest: Date?, now: Date, staleAfter: TimeInterval,
                      appActive: Bool, onScreen: Bool, reduceMotion: Bool) -> Bool {
        guard appActive, onScreen, !reduceMotion,
              let previous, let newest, newest > previous else { return false }
        return now.timeIntervalSince(newest) <= staleAfter
    }

    /// How far the ring grows from the dot's own size, how strongly it starts, and how long it
    /// takes to fade: one soft breath, smaller and fainter than a hero ripple.
    static let scale: Double = 2.2
    static let startOpacity: Double = 0.55
    static let duration: Double = 1.4
}
