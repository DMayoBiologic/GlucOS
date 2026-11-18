import Foundation

// How the Logbook search moves while the user types, on iPhone and Mac (docs/LogbookSearch.md
// "While you type"). Display only: which words are found never changes here; this only says how
// a line's highlight gets from the last search to this one, what the count reads, and when
// VoiceOver hears it.

/// A stretch of a line's highlight, from one search to the next.
enum SearchHighlightPhase: Equatable, Sendable {
    /// Lit before and still lit: stays as it was.
    case kept
    /// Newly found ("pizz" lighting one more letter than "piz"): fades in.
    case entering
    /// No longer found (a word deleted): fades out.
    case leaving
}

struct SearchHighlightSpan: Equatable {
    var range: Range<String.Index>
    var phase: SearchHighlightPhase
}

enum LogbookSearchMotion {
    /// How long a highlight takes to fade in or out, in seconds. Short, so it keeps up with typing.
    static let highlightFade = 0.25

    /// How long a row the typing left out takes to shrink out before the list closes up, in
    /// seconds, and how small it gets on the way.
    static let shrinkOut = 0.14
    static let leavingScale = 0.92

    /// How long typing has to pause before VoiceOver says the count, in seconds.
    static let pause = 0.8

    /// The line's lit stretches going from the `from` search's words to the `to` search's, in order,
    /// never overlapping. Where both light the same letters they're `kept`, so a highlight that's
    /// already there never blinks as the next letter is typed.
    static func spans(in text: String, from old: [String], to new: [String]) -> [SearchHighlightSpan] {
        let was = LogbookSearch.highlights(in: text, terms: old)
        let now = LogbookSearch.highlights(in: text, terms: new)
        guard !was.isEmpty || !now.isEmpty else { return [] }
        var cuts = Set<String.Index>()
        for r in was + now { cuts.insert(r.lowerBound); cuts.insert(r.upperBound) }
        let points = cuts.sorted()
        var out: [SearchHighlightSpan] = []
        for (a, b) in zip(points, points.dropFirst()) where a < b {
            let inWas = was.contains { $0.lowerBound <= a && b <= $0.upperBound }
            let inNow = now.contains { $0.lowerBound <= a && b <= $0.upperBound }
            let phase: SearchHighlightPhase
            switch (inWas, inNow) {
            case (true, true): phase = .kept
            case (false, true): phase = .entering
            case (true, false): phase = .leaving
            case (false, false): continue
            }
            if let last = out.last, last.phase == phase, last.range.upperBound == a {
                out[out.count - 1].range = last.range.lowerBound..<b
            } else {
                out.append(SearchHighlightSpan(range: a..<b, phase: phase))
            }
        }
        return out
    }

    /// How strong a stretch's wash is, 0 (none) to 1 (fully lit), `progress` of the way through the
    /// fade. Under Reduce Motion the fade is skipped: progress is 1 straight away.
    static func wash(_ phase: SearchHighlightPhase, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch phase {
        case .kept: return 1
        case .entering: return p
        case .leaving: return 1 - p
        }
    }

    /// Whether a stretch is bold. Weight can't fade without the line reflowing, so the words found
    /// are bold at once and words no longer found drop it at once; only the wash fades.
    static func isBold(_ phase: SearchHighlightPhase) -> Bool { phase != .leaving }

    /// The count beside the search: "3 found". Nothing when nothing is found (the empty list says so).
    static func countLabel(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "1 found"
        default: return "\(count) found"
        }
    }

    /// What VoiceOver says once typing pauses.
    static func announcement(count: Int) -> String { countLabel(count) ?? "No matches" }
}

/// Says the search count once per pause in typing: a pause on the same search as last time (typed
/// then deleted back) says nothing new, and an empty field says nothing at all.
struct LogbookSearchAnnouncer: Equatable {
    private(set) var lastQuery: String?

    /// The line to speak for this pause, or nil when there's nothing new to say.
    mutating func line(query: String, count: Int) -> String? {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { lastQuery = nil; return nil }
        guard key != lastQuery else { return nil }
        lastQuery = key
        return LogbookSearchMotion.announcement(count: count)
    }
}
