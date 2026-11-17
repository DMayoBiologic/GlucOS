import Foundation

/// How the iPhone Today stage folds into the navigation bar as you scroll (improvement round 46).
/// The big value, unit, trend row and needle shrink and fade as they near the bar, while the bar's
/// compact reading (value and trend arrow) grows in from 60 % and the "GlucOS" wordmark fades out.
/// Scrolling back up plays it in reverse. Everything follows the scroll position, never a timer, so
/// it can't jump or run on by itself, and nothing animates while the list is still.
///
/// Under Reduce Motion nothing scales: the stage and the bar's reading cross-fade, still following
/// the scroll. VoiceOver reads the reading once, from the stage; the bar's copy is hidden from it.
///
/// Plain Foundation so `swift test` covers it. The views are `PhoneHomeView` and `PhoneHeroCard`.
enum HeaderCollapse {
    /// Where the fold starts, in points of scroll past the stage's top: as soon as the stage starts
    /// to pass under the bar. Never negative, or the stage would be part-folded at rest when it is
    /// the first thing on the page.
    static let lead: Double = 0
    /// How many points of scrolling the fold takes, start to finish.
    static let span: Double = 120
    /// Progress is rounded to this many steps, so the screen redraws at most this many times
    /// across the fold, not on every point scrolled (power rule, docs/Redesign.md §4.6).
    static let steps: Double = 56

    /// The stage's size at the end of the fold.
    static let stageEndScale: Double = 0.55
    /// The bar's reading's size at the start of the fold.
    static let titleStartScale: Double = 0.6

    /// 0 with the stage at rest, 1 once it has folded into the bar. `scrolled` is the content
    /// offset plus the top inset (0 at rest, negative while pulling to refresh); `stageTop` is the
    /// stage's top within the scrolling content, which moves down when banners show above it.
    static func progress(scrolled: Double, stageTop: Double) -> Double {
        guard scrolled.isFinite, stageTop.isFinite else { return 0 }
        let raw = (scrolled - max(0, stageTop) - lead) / span
        let clamped = min(1, max(0, raw))
        return (clamped * steps).rounded() / steps
    }

    /// The stage's scale: shrinks towards the bar, or stays put under Reduce Motion.
    static func stageScale(_ progress: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 1 - (1 - stageEndScale) * clamp(progress)
    }

    /// The stage fades over the second half of the fold, so it is still readable while it shrinks.
    static func stageOpacity(_ progress: Double) -> Double {
        min(1, max(0, 2 - 2 * clamp(progress)))
    }

    /// The bar's reading: grows in from `titleStartScale`, or stays full size under Reduce Motion.
    static func titleScale(_ progress: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : titleStartScale + (1 - titleStartScale) * clamp(progress)
    }

    /// The bar's reading fades in over the second half, as the stage fades out: a cross-fade.
    static func titleOpacity(_ progress: Double) -> Double {
        1 - stageOpacity(progress)
    }

    /// The "GlucOS" wordmark gives way over the first half, before the reading arrives.
    static func wordmarkOpacity(_ progress: Double) -> Double {
        min(1, max(0, 1 - 2 * clamp(progress)))
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
