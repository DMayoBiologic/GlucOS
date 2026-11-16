import Foundation

/// Whether the main reading on the app's own screens (iPhone Today and its collapsed title, the Mac
/// popover) is the one saved before this launch or one fetched since, kept free of SwiftUI so it
/// can be unit-tested (docs/Redesign.md §4.7).
///
/// On a cold launch the store already holds the last saved snapshot, so the screen shows that
/// reading at once rather than a blank card or a spinner. Until this launch's first fetch lands it
/// is `.stored`: dimmed, with its age, and the hero's refresh spinner hidden. When the fetch lands
/// the figure cross-fades to the live value once on `.sweep` (at once under Reduce Motion) instead
/// of rolling its digits, and nothing repeats.
///
/// A saved reading that is already stale keeps the stale look (grey, struck through) and isn't
/// dimmed on top; it still hands over in the one cross-fade. A sensor warming up shows its
/// countdown instead of any reading, so it is never `.stored`.
enum LaunchReading: Equatable, Sendable {
    /// The reading saved before this launch, still waiting for this launch's first fetch.
    case stored
    /// Fetched since launch, or nothing saved to show (the waiting card has its own words).
    case live

    static func phase(hasReading: Bool, fetchedThisLaunch: Bool, warmingUp: Bool) -> LaunchReading {
        hasReading && !fetchedThisLaunch && !warmingUp ? .stored : .live
    }

    /// How opaque the reading is drawn while it waits: clearly there, clearly not current.
    static let storedOpacity: Double = 0.5

    /// Whether the reading is dimmed. A stale one is already grey and crossed through.
    func dims(stale: Bool) -> Bool { self == .stored && !stale }

    /// Whether the hero's refresh spinner shows. The dimmed reading already says it is being checked.
    func showsSpinner(isRefreshing: Bool) -> Bool { isRefreshing && self == .live }

    /// The age line's lead-in. A saved reading is never "Updated", even while it is under the stale limit.
    func ageLead(stale: Bool) -> String { stale || self == .stored ? "Last reading" : "Updated" }

    /// What VoiceOver adds to the reading while it waits.
    var spokenNote: String? { self == .stored ? "Saved reading, checking for a newer one" : nil }

    /// Whether a new reading's ripple plays. Not for the launch handover itself, which is one fade.
    static func playsRipple(from old: (timestamp: Date?, phase: LaunchReading),
                            to new: (timestamp: Date?, phase: LaunchReading),
                            reduceMotion: Bool) -> Bool {
        guard let a = old.timestamp, let b = new.timestamp, a != b, !reduceMotion else { return false }
        return old.phase == new.phase
    }
}
