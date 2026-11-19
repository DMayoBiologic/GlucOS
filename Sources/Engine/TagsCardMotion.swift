import Foundation

/// How the Insights Tags card moves (docs/LogbookTags.md, "Motion"): when each tag's in-range bar
/// grows in, how a new set of rows differs from the last (which tags arrived, left or moved), and
/// the one line VoiceOver says about it. Plain values, so the rules are tested without SwiftUI.
enum TagsCardMotion {
    /// The first bar starts this long after the card begins to rise, so it grows with the figures.
    static let growStart: Double = 0.15
    /// Each tag's bar starts this much after the one before it, in reading order.
    static let growStep: Double = 0.05
    /// Later tiles never wait longer than this, however many tags there are.
    static let growLimit: Double = 0.45
    /// How long a cross-fade takes under Reduce Motion.
    static let reducedFade: Double = 0.2
    /// How far a newly listed tag slides in from, in points.
    static let slideDistance: Double = 24

    /// When a tag's bar starts growing in, by its place in the card.
    static func growDelay(order: Int) -> Double {
        min(growLimit, growStart + growStep * Double(max(0, order)))
    }

    /// How much of the bar's track the time in range after a tag fills, 0...1.
    static func fraction(_ share: Double) -> Double {
        guard share.isFinite else { return 0 }
        return min(1, max(0, share))
    }

    /// What changed between two lists of tag ids (`TagInsights.Row.id`), in card order.
    struct Change: Equatable {
        /// Tags on the new list that weren't on the old one, in their new order.
        var added: [String] = []
        /// Tags on the old list that aren't on the new one, in their old order.
        var removed: [String] = []
        /// Whether the tags both lists share now sit in a different order.
        var reordered = false

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && !reordered }
    }

    static func change(from old: [String], to new: [String]) -> Change {
        let oldSet = Set(old), newSet = Set(new)
        let kept = old.filter(newSet.contains)
        let keptNew = new.filter(oldSet.contains)
        return Change(added: new.filter { !oldSet.contains($0) },
                      removed: old.filter { !newSet.contains($0) },
                      reordered: kept != keptNew)
    }

    /// The one line VoiceOver says when the card's tags change while it's on screen: which tag
    /// now leads when the order or period moved, then what arrived and left. Nil when nothing a
    /// listener would notice changed (new readings that only nudge the figures stay quiet; the
    /// tiles say their figures when focused).
    ///
    /// `oldNames`/`newNames` are the tags as the chips spell them, in card order.
    static func announcement(oldNames: [String], newNames: [String], periodChanged: Bool,
                             periodSpoken: String) -> String? {
        let key = { (s: String) in LogbookTags.key(s) }
        let change = change(from: oldNames.map(key), to: newNames.map(key))
        guard periodChanged || !change.isEmpty else { return nil }
        guard let first = newNames.first else { return "Tags: nothing tagged in \(periodSpoken)." }
        let added = newNames.filter { change.added.contains(key($0)) }
        let removed = oldNames.filter { change.removed.contains(key($0)) }
        let leadMoved = oldNames.first.map(key) != key(first)
        var parts: [String] = []
        if periodChanged {
            parts.append("Tags over \(periodSpoken): \(first) first.")
        } else if leadMoved {
            parts.append("Tags: \(first) now first.")
        } else {
            parts.append("Tags:")
        }
        if !added.isEmpty { parts.append("Added \(list(added)).") }
        if !removed.isEmpty { parts.append("No longer listed: \(list(removed)).") }
        if parts.count == 1, parts[0] == "Tags:" { parts[0] = "Tags: new order." }
        return parts.joined(separator: " ")
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
