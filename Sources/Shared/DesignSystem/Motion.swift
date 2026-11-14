import SwiftUI

// Shared motion pieces: the new-reading ripple, the live dot, card entrances. All of them respect
// Reduce Motion (they hold still), and all of them render a sensible still frame in a widget,
// where nothing animates.

// MARK: - New-reading ripple

extension View {
    /// One soft outline that expands and fades around `shape` each time `trigger` changes: a new
    /// reading arriving. Nothing under Reduce Motion.
    func readingRipple<S: InsettableShape>(trigger: Int, in shape: S, tint: Color) -> some View {
        overlay { ReadingRipple(trigger: trigger, shape: shape, tint: tint) }
    }
}

private struct ReadingRipple<S: InsettableShape>: View {
    let trigger: Int
    let shape: S
    let tint: Color

    private struct Value {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        shape
            .strokeBorder(tint, lineWidth: 2)
            .keyframeAnimator(initialValue: Value(), trigger: trigger) { content, value in
                content.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: 0.01)
                    CubicKeyframe(1.035, duration: 0.9)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.6, duration: 0.01)
                    CubicKeyframe(0, duration: 0.9)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Live dot

/// A small dot beside "Updated 2 min ago" that breathes while readings are arriving, and sits
/// still and amber once they stop, so "live" is something you can see without reading the age.
struct LiveDot: View {
    /// False once the reading is stale: the dot stops and turns amber.
    var live: Bool
    var tint: Color = Tone.success.color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = live ? tint : Tone.warning.color
        ZStack {
            if live && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.45))
                    .phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 2.4 : 1)
                            .opacity(expanded ? 0 : 0.9)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.6) : .linear(duration: 0.01)
                    }
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .dsAnimation(.standard, value: live)
        .accessibilityHidden(true)
    }
}

// MARK: - Entrance

extension View {
    /// Fades and lifts a card into place the first time it appears, `order` steps after the
    /// first, so a screen assembles top to bottom instead of popping in at once. Plays once per
    /// view lifetime; a plain fade under Reduce Motion. Not for widgets.
    ///
    /// `enabled: false` starts the view in place. For list rows: rows built after the screen has
    /// assembled (scrolled into view later) shouldn't play it, since a list rebuilds rows as they
    /// scroll in. Read once, when the view is first built.
    func dsEntrance(_ order: Int = 0, enabled: Bool = true) -> some View {
        modifier(DSEntrance(order: order, enabled: enabled))
    }
}

private struct DSEntrance: ViewModifier {
    let order: Int
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(order: Int, enabled: Bool) {
        self.order = order
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !shown else { return }
                let delay = Double(min(order, 8)) * 0.055
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.55, dampingFraction: 0.86).delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

// MARK: - Draw-in

/// Drives a ring from empty to its value when it first appears. The ring starts `progress` at 0
/// only when `enabled` (never in a widget, where onAppear may not run), and Reduce Motion jumps
/// straight to 1.
struct DrawIn: ViewModifier {
    let enabled: Bool
    @Binding var progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear {
            guard enabled, progress < 1 else { return }
            if reduceMotion { progress = 1; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { progress = 1 }
        }
    }
}
