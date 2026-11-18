import Foundation

/// What the glucose chart does when something logged appears on it or leaves it: a new meal, dose,
/// treatment, wake-up or note pops in at its time with a small spring, and a deleted one shrinks out
/// (Undo brings it back the same way). Plain Foundation so it can be unit-tested; `GlucoseChart`
/// draws the movement and posts the VoiceOver line.
///
/// One movement per change, nothing repeats (docs/DesignSystem.md, rule 7). Under Reduce Motion the
/// marker just appears or goes, and VoiceOver still hears what changed.
enum MarkerPop {
    /// What a marker is, for what VoiceOver says about it.
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case meal, treatment, insulin, wake, note, sensor

        /// "Meal", as said at the start of a sentence.
        var title: String {
            switch self {
            case .meal: return "Meal"
            case .treatment: return "Treatment"
            case .insulin: return "Insulin"
            case .wake: return "Wake-up"
            case .note: return "Note"
            case .sensor: return "Sensor start"
            }
        }
    }

    /// More markers than this arriving or leaving at once isn't someone logging something: it's a
    /// whole logbook arriving (first sync, signing in) or being cleared. Those change silently,
    /// rather than popping a dozen markers and reading out a list.
    static let burstLimit = 4

    /// How close a hypo-treatment tag has to be to a meal for the meal to count as the treatment.
    /// The log sheet saves both at the same moment; a minute allows for a sync's rounding.
    static let treatmentTolerance: TimeInterval = 60

    struct Change: Equatable {
        /// New markers, in the order they're listed.
        var added: [UUID]
        /// Markers that went, in the order they were listed.
        var removed: [UUID]

        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
        /// Whether this is someone logging or deleting, not a whole logbook changing at once.
        var animates: Bool { !isEmpty && added.count + removed.count <= MarkerPop.burstLimit }
    }

    /// What changed between the markers the chart last saw and the ones it has now. A marker that
    /// keeps its id (an edit, a sync that re-sends it) isn't a change.
    static func change(from old: [UUID], to new: [UUID]) -> Change {
        let oldSet = Set(old), newSet = Set(new)
        return Change(added: new.filter { !oldSet.contains($0) }, removed: old.filter { !newSet.contains($0) })
    }

    /// Whether a meal logged at `meal` is a low treatment, given when hypo-treatment tags were logged.
    static func isTreatment(mealAt meal: Date, treatmentTags: [Date]) -> Bool {
        treatmentTags.contains { abs($0.timeIntervalSince(meal)) <= treatmentTolerance }
    }

    /// What VoiceOver says: "Meal added to chart", "Meal and insulin added to chart",
    /// "Treatment removed from chart". `nil` when there's nothing to say.
    static func announcement(added: [Kind], removed: [Kind]) -> String? {
        let parts = [phrase(added, "added to chart"), phrase(removed, "removed from chart")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private static func phrase(_ kinds: [Kind], _ verb: String) -> String? {
        // Each kind once, in a fixed order, so a dose and a meal saved together read the same way
        // whichever was stored first.
        let names = Kind.allCases.filter(kinds.contains).enumerated().map { i, k in
            i == 0 ? k.title : k.title.lowercased()
        }
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "\(list) \(verb)"
    }
}
