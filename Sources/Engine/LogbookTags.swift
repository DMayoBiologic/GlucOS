import Foundation

// Tags on Logbook entries (docs/LogbookTags.md): "Exercise", "Sick", "Stress", "Alcohol", or the
// user's own ("Travel", "Night shift"). Picked from chips in the log sheet, kept on each entry as
// `labels`, synced with the entry, and offered back as filter chips in Logbook search.
//
// Tags are labels for finding entries. The forecast and the bolus calculator never read them, and
// Insights only describes what followed them (the Tags card, `TagInsights`): the log sheet's "What
// else is going on?" choices (`ContextTag`) still decide which examples Insights sets aside.

enum LogbookTags {
    /// The chips the log sheet always offers, in this order.
    static let builtIn = ["Exercise", "Sick", "Stress", "Alcohol"]

    /// Longest tag kept, in characters. Enough for "Night shift" or "Sports day"; a sentence
    /// belongs in the note.
    static let maxLength = 24

    /// Most tags one entry keeps.
    static let maxPerEntry = 8

    /// How two spellings of a tag are told apart: case, accents and spacing don't count, so
    /// "night  Shift" and "Night shift" are one tag.
    static func key(_ tag: String) -> String {
        tidy(tag).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The tag as it's kept: trimmed, inner spaces collapsed, cut to `maxLength`, with a leading
    /// "#" dropped. A built-in tag typed in any case takes the built-in spelling. Nil when nothing's left.
    static func cleaned(_ text: String) -> String? {
        var t = tidy(text)
        while t.hasPrefix("#") { t = tidy(String(t.dropFirst())) }
        guard !t.isEmpty else { return nil }
        if t.count > maxLength { t = tidy(String(t.prefix(maxLength))) }
        let k = key(t)
        return builtIn.first { key($0) == k } ?? t
    }

    /// The list cleaned, without repeats (the first spelling wins), at most `maxPerEntry`.
    static func normalised(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            guard let t = cleaned(raw), seen.insert(key(t)).inserted else { continue }
            out.append(t)
            if out.count == maxPerEntry { break }
        }
        return out
    }

    /// The tag added when it's missing, taken out when it's there (in any spelling).
    static func toggling(_ tag: String, in tags: [String]) -> [String] {
        guard let t = cleaned(tag) else { return tags }
        let k = key(t)
        if tags.contains(where: { key($0) == k }) { return tags.filter { key($0) != k } }
        return normalised(tags + [t])
    }

    static func contains(_ tags: [String], _ tag: String) -> Bool {
        let k = key(tag)
        return tags.contains { key($0) == k }
    }

    /// The log sheet's chips: the built-in four, then the user's own tags by how often they were
    /// used (most first), then any picked on this entry that neither list has yet.
    static func choices(entries: [LogEntry], picked: [String] = []) -> [String] {
        uniqueList(builtIn + used(entries) + picked)
    }

    /// Tags found in the Logbook, most used first, then by name. What the filter chips offer.
    /// A "What else is going on?" choice that matches a built-in tag (Exercise, Unwell, Stress,
    /// Alcohol) counts as that tag, so the chip finds both.
    static func used(_ entries: [LogEntry]) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for e in entries {
            for t in e.filterTags {
                let k = key(t)
                counts[k, default: (t, 0)].count += 1
            }
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCompare($1.name) == .orderedAscending }
            .map(\.name)
    }

    /// Whether an entry shows under a tag's filter chip.
    static func matches(_ entry: LogEntry, tag: String) -> Bool {
        contains(entry.filterTags, tag)
    }

    /// The built-in tag a "What else is going on?" choice stands for, if any.
    static func builtIn(for context: ContextTag) -> String? {
        switch context {
        case .exercise: return "Exercise"
        case .illness: return "Sick"
        case .stress: return "Stress"
        case .alcohol: return "Alcohol"
        default: return nil
        }
    }

    /// SF Symbol for a tag's chip: the built-ins have their own, the user's tags a plain tag.
    static func symbol(_ tag: String) -> String {
        switch key(tag) {
        case "exercise": return "figure.run"
        case "sick": return "thermometer.medium"
        case "stress": return "bolt.heart"
        case "alcohol": return "wineglass"
        default: return "tag"
        }
    }

    /// "Exercise, Travel": how a row lists its tags.
    static func line(_ tags: [String]) -> String { tags.joined(separator: ", ") }

    private static func tidy(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func uniqueList(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            guard let t = cleaned(raw), seen.insert(key(t)).inserted else { continue }
            out.append(t)
        }
        return out
    }
}

extension LogEntry {
    /// The user's tags on this entry, in the order picked. Empty when there are none.
    var labels: [String] {
        switch self {
        case .dose(let d): return d.labels ?? []
        case .meal(let m): return m.labels ?? []
        case .siteChange(let s): return s.labels ?? []
        case .context(let c): return c.labels ?? []
        }
    }

    /// The same entry with these tags (cleaned; nil when there are none, so an untagged entry
    /// encodes exactly as it did before tags).
    func withLabels(_ tags: [String]) -> LogEntry {
        let kept = LogbookTags.normalised(tags)
        let value: [String]? = kept.isEmpty ? nil : kept
        switch self {
        case .dose(var d): d.labels = value; return .dose(d)
        case .meal(var m): m.labels = value; return .meal(m)
        case .siteChange(var s): s.labels = value; return .siteChange(s)
        case .context(var c): c.labels = value; return .context(c)
        }
    }

    /// The tags a filter chip looks at: the user's tags plus, on a moment, the built-in tag each
    /// matching "What else is going on?" choice stands for.
    var filterTags: [String] {
        var out = labels
        if case .context(let c) = self {
            for t in c.sortedTags {
                if let b = LogbookTags.builtIn(for: t), !LogbookTags.contains(out, b) { out.append(b) }
            }
        }
        return out
    }
}
