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
                PulseBeat(every: PulseInterval.liveDot) { beat in
                    Circle()
                        .fill(color.opacity(0.45))
                        .pulse(beat: beat, scale: 2.4, opacity: 0.9, duration: 1.6)
                }
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .dsAnimation(.standard, value: live)
        .accessibilityHidden(true)
    }
}

// MARK: - Pulse beat

/// Drives a "breathing" pulse (the live dot, the ring at the end of the trace, the rapid-change
/// halo) as one beat every `every` seconds.
///
/// These used to be phase animators with no trigger, which loop forever: while one is on screen,
/// SwiftUI redraws every frame (120 a second on ProMotion iPhones and Macs) and the display can
/// never drop to its low-power refresh rate. With one ~1.6 s beat every few seconds the screen
/// idles in between, and a beat is only a few frames of work. The content gets the beat number
/// as its phase animator's trigger.
struct PulseBeat<Content: View>: View {
    var every: TimeInterval
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: every)) { context in
            content(Int(context.date.timeIntervalSinceReferenceDate / every))
        }
    }
}

/// How often each pulse beats.
enum PulseInterval {
    /// The live dot beside "Updated…": calm, it only says readings are arriving.
    static let liveDot: TimeInterval = 6
    /// The ring at the end of the chart's trace.
    static let trace: TimeInterval = 6
    /// The halo around a rapidly changing trend: more often, since it's meant to catch the eye.
    static let rapid: TimeInterval = 3.5
}

private enum PulsePhase: CaseIterable {
    /// Between beats: not drawn, so nothing sits on screen waiting for the next one.
    case rest
    /// Appears at full strength and its own size...
    case start
    /// ...then swells out and fades away.
    case out
}

extension View {
    /// One pulse each time `beat` changes: the view appears at `opacity`, grows to `scale` while
    /// fading out over `duration`, and stays hidden until the next beat. Use inside `PulseBeat`.
    func pulse(beat: Int, scale: CGFloat, opacity: Double, duration: Double) -> some View {
        phaseAnimator(PulsePhase.allCases, trigger: beat) { content, phase in
            content
                .scaleEffect(phase == .out ? scale : 1)
                .opacity(phase == .start ? opacity : 0)
        } animation: { phase in
            phase == .out ? .easeOut(duration: duration) : .linear(duration: 0.01)
        }
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
