import SwiftUI

// The cold-launch handover from the saved reading to the first live one (`LaunchReading`,
// docs/Redesign.md §4.7): one cross-fade on `.sweep`, nothing under Reduce Motion, never a loop.

/// Wraps the main figure so the saved reading cross-fades to the first live one, rather than its
/// digits rolling over. The old and new figures overlap for the fade, so the row doesn't widen.
struct LaunchFigure<Content: View>: View {
    let phase: LaunchReading
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leadingFirstTextBaseline) {
            content()
                .id(phase)
                .transition(reduceMotion ? .identity : .opacity)
        }
        .animation(reduceMotion ? nil : DSMotion.sweep.animation, value: phase)
    }
}

private struct LaunchDim: ViewModifier {
    let phase: LaunchReading
    let stale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(phase.dims(stale: stale) ? LaunchReading.storedOpacity : 1)
            .animation(reduceMotion ? nil : DSMotion.sweep.animation, value: phase)
    }
}

extension View {
    /// Dims the reading while it is the one saved before this launch (unless it is already stale),
    /// and brightens it in the same `.sweep` as the figure's cross-fade. At once under Reduce Motion.
    func launchDim(_ phase: LaunchReading, stale: Bool) -> some View {
        modifier(LaunchDim(phase: phase, stale: stale))
    }
}

/// What a hero's new-reading ripple watches: the reading, and whether this change is the launch
/// handover (which plays no ripple, `LaunchReading.playsRipple`).
struct RippleKey: Equatable {
    let timestamp: Date?
    let phase: LaunchReading
}
