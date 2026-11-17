import SwiftUI
import Observation

/// Today's stage folding into the navigation bar as you scroll (improvement round 46,
/// `HeaderCollapse`). One small observable object carries the fold's progress, so only the
/// stage's figure and the bar's title redraw while scrolling; the rest of Today doesn't.
@Observable @MainActor
final class TodayHeaderCollapse {
    /// 0 at rest, 1 folded into the bar, in `HeaderCollapse.steps` steps.
    private(set) var progress: Double = 0
    @ObservationIgnored private var scrolled: Double = 0
    @ObservationIgnored private var stageTop: Double = 0

    /// The name of the scrolling content's coordinate space, which the stage measures its top in.
    static let space = "TodayContent"

    func update(scrolled: Double? = nil, stageTop: Double? = nil) {
        if let scrolled { self.scrolled = scrolled }
        if let stageTop { self.stageTop = stageTop }
        let next = HeaderCollapse.progress(scrolled: self.scrolled, stageTop: self.stageTop)
        // Only a new step redraws anything.
        if next != progress { progress = next }
    }
}

/// The stage's figure (value, unit, trend row and needle) shrinking towards the bar and fading
/// out. Under Reduce Motion it only fades. Purely visual, so the layout below never moves and the
/// stage's VoiceOver label is unchanged.
private struct StageCollapse: ViewModifier {
    @Environment(TodayHeaderCollapse.self) private var collapse: TodayHeaderCollapse?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let p = collapse?.progress ?? 0
        content
            .scaleEffect(HeaderCollapse.stageScale(p, reduceMotion: reduceMotion), anchor: .top)
            .opacity(HeaderCollapse.stageOpacity(p))
    }
}

extension View {
    /// Folds this part of the Today stage into the bar as it scrolls (no effect elsewhere).
    func todayStageCollapse() -> some View { modifier(StageCollapse()) }
}

/// The bar's title on Today: the "GlucOS" wordmark at rest, giving way to the compact reading
/// (value and trend arrow) that grows in as the stage folds. Cross-fades only under Reduce Motion.
/// VoiceOver hears the reading from the stage, so the compact copy is hidden from it.
struct PhoneCollapsingTitle<Reading: View>: View {
    let collapse: TodayHeaderCollapse
    /// There's a reading to show (not waiting for one, not warming up a sensor).
    let showsReading: Bool
    @ViewBuilder let reading: () -> Reading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = showsReading ? collapse.progress : 0
        ZStack {
            Text("GlucOS")
                .font(.headline)
                .opacity(HeaderCollapse.wordmarkOpacity(p))
                .accessibilityAddTraits(.isHeader)
            // Not drawn at all at rest, so the bar costs nothing until you scroll.
            if p > 0 {
                reading()
                    .scaleEffect(HeaderCollapse.titleScale(p, reduceMotion: reduceMotion))
                    .opacity(HeaderCollapse.titleOpacity(p))
                    .accessibilityHidden(true)
            }
        }
    }
}
