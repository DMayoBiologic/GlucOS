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

// MARK: - Card reveal

private struct EntranceHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The card around this view hasn't risen in yet (`dsReveal`), so its own first-appearance
    /// motion (figures counting up, rings and bars drawing in, sparklines sweeping) waits for it,
    /// rather than playing out unseen below the fold. False everywhere else.
    var entranceHeld: Bool {
        get { self[EntranceHeldKey.self] }
        set { self[EntranceHeldKey.self] = newValue }
    }
}

extension View {
    /// Runs `action` when the view appears, or, inside a card that hasn't risen in yet, when that
    /// card starts to rise. Use it in place of `onAppear` for a view's first-appearance motion.
    /// `action` should guard against running twice, as an `onAppear` one would.
    func onEntrance(perform action: @escaping () -> Void) -> some View {
        modifier(OnEntrance(action: action))
    }

    /// Rises and fades a card in once, the first time it comes into view on this visit, a short
    /// stagger after any card that came into view with it. `.scrolledIntoView` waits until the
    /// card is scrolled on screen (iPhone Insights); `.appear` plays when the screen opens, `order`
    /// steps after the first (Mac Insights). Never replays for the same `id` from the same
    /// `reveals`; a plain fade under Reduce Motion. The card's own count-ups and draw-ins
    /// (`onEntrance`) start as it rises. Not for widgets.
    func dsReveal(_ id: AnyHashable, in reveals: CardReveals, when trigger: CardRevealTrigger,
                  order: Int = 0) -> some View {
        modifier(DSReveal(id: id, reveals: reveals, trigger: trigger, order: order))
    }
}

enum CardRevealTrigger {
    case appear
    case scrolledIntoView
}

private struct OnEntrance: ViewModifier {
    let action: () -> Void
    @Environment(\.entranceHeld) private var held
    @State private var onScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen = true
                if !held { action() }
            }
            .onDisappear { onScreen = false }
            .onChange(of: held) { _, nowHeld in
                if !nowHeld && onScreen { action() }
            }
    }
}

private struct DSReveal: ViewModifier {
    let id: AnyHashable
    let reveals: CardReveals
    let trigger: CardRevealTrigger
    let order: Int
    @State private var shown: Bool
    /// The scroll view has said whether the card is visible at least once.
    @State private var reported = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A card that isn't drawn yet can't be reached by VoiceOver, so it couldn't be swiped to and
    /// scrolled into view. With VoiceOver on, every card rises in as the screen opens.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var waitsForScroll: Bool { trigger == .scrolledIntoView && !voiceOver }

    init(id: AnyHashable, reveals: CardReveals, trigger: CardRevealTrigger, order: Int) {
        self.id = id
        self.reveals = reveals
        self.trigger = trigger
        self.order = order
        _shown = State(initialValue: reveals.hasRevealed(id))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.entranceHeld, !shown)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985, anchor: .top)
            .modifier(VisibilityWatch(active: waitsForScroll && !shown) { visible in
                reported = true
                if visible { reveal() }
            })
            .onAppear {
                guard !shown else { return }
                if !waitsForScroll {
                    reveal(after: Double(min(order, 8)) * 0.055)
                } else {
                    // Should the scroll view never say (no scroll view around it), rise in anyway
                    // rather than stay invisible.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if !reported { reveal() }
                    }
                }
            }
    }

    private func reveal(after fixed: TimeInterval? = nil) {
        guard !shown, let batched = reveals.claim(id) else {
            // Already risen on this visit (its view was rebuilt): just be there.
            if !shown { shown = true }
            return
        }
        let delay = fixed ?? batched
        let start = {
            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(response: 0.55, dampingFraction: 0.86)
            withAnimation(animation) { shown = true }
        }
        // Waits in real time, not as an animation delay, so the card's count-ups (held until
        // `shown`) start with the rise instead of before it.
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
        } else {
            start()
        }
    }
}

/// Reports whether the view is at least a little on screen in its scroll view, while `active`.
private struct VisibilityWatch: ViewModifier {
    let active: Bool
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        // Always attached once available, whether or not it's active: switching the modifier on
        // and off would rebuild the card under it and restart its motion.
        if #available(iOS 18, macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.1) { visible in
                if active { changed(visible) }
            }
        } else {
            content
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
        content.onEntrance {
            guard enabled, progress < 1 else { return }
            if reduceMotion { progress = 1; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { progress = 1 }
        }
    }
}

// MARK: - Rolling figure

private struct FiguresCountUpKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Figures on this screen count up when their card appears (`RollingFigure`). Set on the
    /// iPhone Insights screen and the Mac Dashboard's Insights page only. Off everywhere else,
    /// including widgets, where a figure just rolls to a new value as it always has.
    var figuresCountUp: Bool {
        get { self[FiguresCountUpKey.self] }
        set { self[FiguresCountUpKey.self] = newValue }
    }
}

/// A statistic's figure: the same digit roll as a reading (`.numericText(value:)`, as on the
/// widgets and the Live Activity) on the `.arrival` spring, so it rolls from the old value to the
/// new one when the value changes (a new period, new readings). Where `figuresCountUp` is on, it
/// also counts up from zero the first time it appears, alongside the rings and bars drawing in.
///
/// Plays once per change and never repeats. Under Reduce Motion it shows the value at once.
/// VoiceOver only ever hears the final value, never a figure on its way there. Style it like a
/// `Text` (font, weight, colour).
struct RollingFigure: View {
    let value: Double
    let text: (Double) -> String
    /// Steps after the first on the same card, so a row of figures settles left to right.
    var order: Int = 0

    @Environment(\.figuresCountUp) private var countsUp
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What's on screen while it counts; nil until the first count has started.
    @State private var shown: Double?

    init(_ value: Double, order: Int = 0, text: @escaping (Double) -> String) {
        self.value = value
        self.order = order
        self.text = text
    }

    private var animates: Bool { !reduceMotion }

    var body: some View {
        let display = countsUp && animates ? (shown ?? 0) : (shown ?? value)
        Text(text(display))
            .contentTransition(.numericText(value: display))
            .accessibilityLabel(text(value))
            .onEntrance {
                guard countsUp, animates, shown == nil else { return }
                // Next frame, so the zero is drawn before it rolls.
                DispatchQueue.main.async {
                    // A new value may have arrived meanwhile, and already rolled to it.
                    guard shown == nil else { return }
                    withAnimation(DSMotion.arrival.animation.delay(0.1 + Double(min(order, 8)) * 0.045)) {
                        shown = value
                    }
                }
            }
            .onChange(of: value) { _, new in
                guard animates else { shown = new; return }
                withAnimation(DSMotion.arrival.animation) { shown = new }
            }
    }
}

// MARK: - Forecast motion

/// Animates the forecast a chart is given: it draws in from the newest reading when the view
/// appears (and when a forecast turns up where there was none), and a new forecast bends and
/// slides from the old shape into the new one instead of jumping. `content` gets the forecast to
/// draw and how much of it is drawn so far (`GlucoseChart(forecast:forecastReveal:)`).
///
/// One movement per appearance or per new forecast, never looping (Redesign §4.6). Under Reduce
/// Motion, or with `enabled` off, the forecast just changes. App screens only: widgets never run
/// `onAppear`, so there it would only ever show the forecast as given.
struct ForecastMotion<Content: View>: View {
    let forecast: [ForecastSample]
    var enabled: Bool = true
    /// How long the draw-in on appearing waits, so it can start once the card around it has come
    /// in (the Mac popover's `PopoverStagger`). Later forecasts morph straight away.
    var drawInDelay: TimeInterval = 0
    @ViewBuilder let content: (_ forecast: [ForecastSample], _ reveal: Double) -> Content

    /// The forecast the morph starts from and the one it ends on.
    @State private var from: [ForecastSample] = []
    @State private var to: [ForecastSample]?
    @State private var phase: Double = 1
    @State private var reveal: Double = 1
    /// Counts changes, so a draw-in or morph that's still being set up never overrides a newer one.
    @State private var generation = 0
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { enabled && !reduceMotion && onScreen }

    var body: some View {
        ForecastFrame(from: from, to: to ?? forecast, phase: phase, reveal: reveal, content: content)
            .onAppear {
                onScreen = true
                settle(on: forecast)
                drawIn(after: drawInDelay)
            }
            .onDisappear {
                onScreen = false
                generation += 1
            }
            .onChange(of: forecast) { _, new in change(to: new) }
    }

    /// Shows `forecast` as it is, with nothing in flight.
    private func settle(on forecast: [ForecastSample]) {
        generation += 1
        withTransaction(Transaction(animation: nil)) {
            from = forecast
            to = forecast
            phase = 1
            reveal = 1
        }
    }

    /// Draws the forecast in from the newest reading.
    private func drawIn(after delay: TimeInterval = 0) {
        guard animates, (to ?? forecast).count > 1 else { return }
        withTransaction(Transaction(animation: nil)) { reveal = 0 }
        let generation = self.generation
        // On the next turn, so the empty first frame is drawn before the reveal starts.
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.sweep.animation.delay(max(0, delay))) { reveal = 1 }
        }
    }

    private func change(to new: [ForecastSample]) {
        let shown = to ?? []
        guard animates, !new.isEmpty else { settle(on: new); return }
        // Nothing drawn before (switched on, or the first forecast): draw it in.
        guard !shown.isEmpty, reveal == 1 else { settle(on: new); drawIn(); return }
        generation += 1
        let generation = self.generation
        withTransaction(Transaction(animation: nil)) {
            from = shown
            to = new
            phase = 0
        }
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.ambient.animation) { phase = 1 }
        }
    }
}

/// One frame of `ForecastMotion`: SwiftUI steps `phase` and `reveal` through every frame of the
/// animation, and the chart is handed the forecast for that frame.
private struct ForecastFrame<Content: View>: View, Animatable {
    let from: [ForecastSample]
    let to: [ForecastSample]
    var phase: Double
    var reveal: Double
    let content: (_ forecast: [ForecastSample], _ reveal: Double) -> Content

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, reveal) }
        set { phase = newValue.first; reveal = newValue.second }
    }

    var body: some View {
        content(ForecastMorph.blend(from: from, to: to, t: phase), reveal)
    }
}

// MARK: - Target range glide

/// The target range as a chart last drew it, so a new one (changed in Settings or arrived by sync)
/// is a change worth animating.
private struct TargetRangeKey: Equatable {
    let low: Double
    let high: Double
}

extension View {
    /// When the target range changes, the chart's band, its low and high lines and the glucose
    /// axis glide to their new place (Charts animates the marks and the explicit domains), on the
    /// same `.emphasized` curve as the Logbook's day bars. Readings recoloured by the new range
    /// change with it. One movement per change, never repeating; instant under Reduce Motion.
    /// Pass `enabled: false` where nothing should move, such as a widget's copy of the chart.
    func targetRangeGlide(lowMgdl: Double, highMgdl: Double, enabled: Bool = true) -> some View {
        dsAnimation(.emphasized, value: enabled ? TargetRangeKey(low: lowMgdl, high: highMgdl) : nil)
    }
}

// MARK: - One-shot symbol effects

/// Which way a wiggle leans: down for a low, up for a high, or side to side.
enum SymbolWiggleDirection {
    case down, up, sideways
}

extension View {
    /// Bounces the SF Symbols in this view once each time `trigger` changes: a toolbar or nav bar
    /// icon answering its own tap (round 48). Never repeats (Redesign §4.6), and does nothing
    /// under Reduce Motion.
    func symbolBounce<T: Equatable>(on trigger: T) -> some View {
        modifier(SymbolBounceOnce(trigger: trigger))
    }

    /// Wiggles the SF Symbols in this view once when it appears: the in-app alert banner's icon
    /// as the alert arrives (round 48). A bounce on macOS 14, which has no wiggle. Never repeats,
    /// and does nothing under Reduce Motion. Give the view a new `.id` to play it again.
    func symbolWiggleOnAppear(_ direction: SymbolWiggleDirection = .sideways) -> some View {
        modifier(SymbolWiggleOnce(direction: direction))
    }
}

private struct SymbolBounceOnce<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: trigger)
            .symbolEffectsRemoved(reduceMotion)
    }
}

private struct SymbolWiggleOnce: ViewModifier {
    let direction: SymbolWiggleDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped once, a frame after appearing, so the effect has a change to play on.
    @State private var plays = 0

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18, macOS 15, *) {
                content.symbolEffect(wiggle, options: .nonRepeating, value: plays)
            } else {
                content.symbolEffect(.bounce, options: .nonRepeating, value: plays)
            }
        }
        .symbolEffectsRemoved(reduceMotion)
        .onAppear {
            guard !reduceMotion, plays == 0 else { return }
            DispatchQueue.main.async { plays = 1 }
        }
    }

    @available(iOS 18, macOS 15, *)
    private var wiggle: WiggleSymbolEffect {
        switch direction {
        case .down: return .wiggle.down
        case .up: return .wiggle.up
        case .sideways: return .wiggle
        }
    }
}

// MARK: - Unit switch

private struct UnitMorph: ViewModifier {
    let unit: GlucoseUnit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // The figures that already roll (`readingChange`, `RollingFigure`) morph digit by digit,
        // other text cross-fades, and charts glide their points and axis labels to the new scale.
        // Under Reduce Motion the change carries no animation, so everything simply swaps.
        content.animation(reduceMotion ? nil : DSMotion.emphasized.animation, value: unit)
    }
}

extension View {
    /// Morphs this screen's figures and chart axes when the unit shown changes (`UnitSwitch`). Put
    /// it once at a screen's root, keyed on `GlucoseStore.shownUnit`. App screens only.
    func unitMorph(_ unit: GlucoseUnit) -> some View {
        modifier(UnitMorph(unit: unit))
    }
}
