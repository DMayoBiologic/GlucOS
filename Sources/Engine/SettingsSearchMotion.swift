import Foundation

// How Settings search moves on iPhone and Mac (docs/SettingsSearch.md "Motion"). Display only:
// what a search finds, and where a jump lands, never change here. This only says when a result
// row comes in, how bright a newly matched word's wash gets on the way, and how a landed row
// springs. Under Reduce Motion every piece is skipped and the change is instant.

enum SettingsSearchMotion {
    /// The gap between one new result row and the next, in seconds, so they come in top to bottom.
    static let staggerStep = 0.035
    /// Rows past this many come in together with the last staggered one, so a long list never
    /// keeps the bottom rows waiting.
    static let maxStaggered = 6
    /// How long one row takes to fade and rise into place, in seconds, and how far it rises.
    static let rowEntrance = 0.26
    static let rowRise = 6.0

    /// How long a newly matched word's wash takes to flare and settle, in seconds.
    static let washFlare = 0.55
    /// How much brighter than its resting strength the wash gets at its peak, and how far through
    /// the flare that peak comes.
    static let flarePeak = 1.8
    static let flarePeakAt = 0.3

    /// How long after the scroll starts the landed row springs and its section icon bounces, in
    /// seconds: once the scroll's spring has brought the row on screen.
    static let landingDelay = 0.3
    /// How much a landed row grows before it springs back, and how long it holds there.
    static let landingScale = 1.025
    static let landingHold = 0.16

    /// The delay before each row that this change of query newly shows, in seconds. Rows already
    /// listed under the old query are absent: they stay where they are and don't come in again.
    /// The first new row has no delay; each later one waits `staggerStep` more, up to
    /// `maxStaggered` steps.
    static func entranceDelays(from old: [SettingsAnchor], to new: [SettingsAnchor]) -> [SettingsAnchor: Double] {
        let kept = Set(old)
        var out: [SettingsAnchor: Double] = [:]
        var rank = 0
        for anchor in new where !kept.contains(anchor) {
            out[anchor] = Double(min(rank, maxStaggered - 1)) * staggerStep
            rank += 1
        }
        return out
    }

    /// A highlight stretch's wash strength `progress` of the way through the flare: 1 is its
    /// resting strength. Newly matched letters rise past it to `flarePeak` and settle back, so the
    /// word the typing just found glints once; letters still matched hold at 1, letters no longer
    /// matched fade out. Under Reduce Motion progress is 1 straight away: no flare, just the wash.
    static func flaredWash(_ phase: SearchHighlightPhase, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch phase {
        case .kept: return 1
        case .leaving: return 1 - p
        case .entering:
            if p <= flarePeakAt { return flarePeak * (p / flarePeakAt) }
            return flarePeak - (flarePeak - 1) * ((p - flarePeakAt) / (1 - flarePeakAt))
        }
    }
}
