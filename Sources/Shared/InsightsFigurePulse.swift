import Foundation

// Insights figures give one soft pulse when new data changes them (round 85). A figure that rolls
// because a reading arrived (or an entry synced in) while Insights is open grows a touch and
// settles back, so the eye catches what just moved. A figure that rolls because the person changed
// something themselves (a card's 7/14/30-day picker, stepping to an earlier period, Compare) only
// rolls, as before: they already know why it moved. Once per change, never repeating, nothing under
// Reduce Motion, and VoiceOver hears only the final value. Off everywhere but iPhone and Mac Insights,
// which are the only screens that set a data revision.

enum InsightsFigurePulse {
    /// What the Insights data was built from, set by the Insights screen. A new reading or a
    /// logged entry changes it; a picker, a period step or a toggle never does.
    struct Revision: Hashable, Sendable {
        var newestReading: Date?
        var readingCount: Int
        var loggedCount: Int

        /// Not on an Insights screen: figures never pulse.
        static let none = Revision(newestReading: nil, readingCount: -1, loggedCount: -1)

        init(newestReading: Date?, readingCount: Int, loggedCount: Int) {
            self.newestReading = newestReading
            self.readingCount = readingCount
            self.loggedCount = loggedCount
        }
    }

    /// One figure as drawn: its text, the data it came from and the period step it shows.
    struct Shown: Equatable, Sendable {
        var text: String
        var revision: Revision
        var periodBack: Int
    }

    /// How far the figure grows at the top of the pulse.
    static let peakScale = 1.07
    /// Up to the peak, then back.
    static let riseDuration = 0.16
    static let settleDuration = 0.42
    static var totalDuration: Double { riseDuration + settleDuration }

    /// Whether going from `old` to `new` pulses. Only when the figure's text changed with new data
    /// on the same period, on an Insights screen, after its count-up, and never under Reduce Motion.
    static func pulses(from old: Shown, to new: Shown, reduceMotion: Bool, countingUp: Bool) -> Bool {
        guard !reduceMotion, !countingUp else { return false }
        guard old.revision != .none, new.revision != .none else { return false }
        guard old.revision != new.revision else { return false }
        guard old.periodBack == new.periodBack else { return false }
        return old.text != new.text
    }
}
