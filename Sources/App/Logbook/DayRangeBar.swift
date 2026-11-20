import SwiftUI

/// A day's time in range as a thin bar: below, in and above range in the range colours
/// (`GlucoseRange.low/inRange/high.tint`, each at least 3:1 on every Logbook background, see the
/// contrast table in docs/DesignSystem.md), on a quiet track. Used on the iPhone Logbook's day
/// headers and the Mac Logbook's Day column, always beside the in-range figure in words, so the
/// colours never carry the meaning alone.
///
/// Grows from the left once, the first time its day comes on screen (`DrawnOnce`,
/// `DayBarEntrance`), then just sits there; a share that changes (today's new readings, or a header
/// the list rebuilt after an entry was added, edited, deleted or undone) glides to its new split
/// from the one last shown (`DrawnOnce.lastFigures`). Nothing loops and nothing replays on a
/// refresh. On iPhone (`waitsForScroll`) the grow waits until half the header is inside the list,
/// so a header the list prepares just off screen doesn't spend it unseen; the Mac grows it as the
/// Logbook opens. Under Reduce Motion the bar fades in instead, and a changed split cross-fades.
/// Hidden from VoiceOver: the header it sits in says the figures.
struct DayRangeBar: View {
    let id: String
    let figures: DayInRange
    let drawn: DrawnOnce
    var height: CGFloat = 4
    var waitsForScroll: Bool = false

    @State private var progress: Double
    @State private var opacity: Double
    /// The split on screen: starts from the one this day's bar last showed, then glides to `figures`.
    @State private var shown: DayInRange
    @State private var started = false
    /// Whether the list has said anything about this header's visibility, so the fallback only
    /// draws a bar that isn't in a scroll view at all.
    @State private var heardVisibility = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(id: String, figures: DayInRange, drawn: DrawnOnce, height: CGFloat = 4,
         waitsForScroll: Bool = false) {
        self.id = id
        self.figures = figures
        self.drawn = drawn
        self.height = height
        self.waitsForScroll = waitsForScroll
        let done = drawn.has(id)
        _progress = State(initialValue: done ? 1 : 0)
        _opacity = State(initialValue: done ? 1 : 0)
        _shown = State(initialValue: drawn.lastFigures(id) ?? figures)
    }

    /// Always all three, in the same order, so a share that grows from nothing (a first low today)
    /// widens into place rather than shifting the other colours along.
    private var segments: [(fraction: Double, color: Color)] {
        [(shown.below, GlucoseRange.low.tint), (shown.inRange, GlucoseRange.inRange.tint),
         (shown.above, GlucoseRange.high.tint)]
    }

    var body: some View {
        let gap: CGFloat = contrast == .increased ? 2 : 1.5
        GeometryReader { geo in
            let visible = segments.map { $0.fraction > 0.001 }
            let lastShown = visible.lastIndex(of: true)
            let gaps = CGFloat(max(0, visible.filter { $0 }.count - 1)) * gap
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { i in
                        Rectangle()
                            .fill(segments[i].color)
                            .frame(width: visible[i] ? max(2, (geo.size.width - gaps) * segments[i].fraction) : 0)
                            .padding(.trailing, visible[i] && i != lastShown ? gap : 0)
                    }
                }
                // Under Reduce Motion each split is its own view, so a new one fades in over the
                // old rather than sliding; otherwise one view, so the widths glide.
                .id(reduceMotion ? AnyHashable(shown) : AnyHashable(0))
                .transition(.opacity)
            }
            .frame(width: geo.size.width * progress, alignment: .leading)
            .clipped()
            .opacity(opacity)
        }
        .frame(height: height)
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
        .onChange(of: figures) { glide() }
        .onAppear {
            glide()
            if !waitsForScroll { start() }
        }
        #if os(iOS)
        .onScrollVisibilityChange(threshold: DayBarEntrance.visibleThreshold) { onScreen in
            heardVisibility = true
            if onScreen { start() }
        }
        .task {
            guard waitsForScroll else { return }
            try? await Task.sleep(for: .seconds(DayBarEntrance.visibilityFallbackSeconds))
            if !heardVisibility { start() }
        }
        #endif
        .accessibilityHidden(true)
    }

    /// Plays the bar's arrival once: grows, fades under Reduce Motion, or is simply there when
    /// another copy of this day's bar already drew it.
    private func start() {
        guard !started else { return }
        started = true
        guard progress < 1 || opacity < 1 else { return }
        let quiet: Transaction = { var t = Transaction(); t.disablesAnimations = true; return t }()
        switch DayBarEntrance.on(firstTime: drawn.first(id), reduceMotion: reduceMotion) {
        case .none:
            withTransaction(quiet) { progress = 1; opacity = 1 }
        case .grow:
            withTransaction(quiet) { opacity = 1 }
            // The draw-in the Insights rings and bars use (`DrawIn`), once.
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { progress = 1 }
        case .fade:
            withTransaction(quiet) { progress = 1 }
            withAnimation(.easeInOut(duration: DayBarEntrance.fadeSeconds)) { opacity = 1 }
        }
    }

    /// Moves the split to `figures`: a glide on the emphasized spring, or a cross-fade under
    /// Reduce Motion, and remembers it for the next copy of this bar.
    private func glide() {
        drawn.remember(id, figures)
        switch DayBarEntrance.change(from: shown, to: figures, reduceMotion: reduceMotion) {
        case .none: return
        case .glide: withAnimation(DSMotion.emphasized.animation) { shown = figures }
        case .crossFade: withAnimation(.easeInOut(duration: DayBarEntrance.fadeSeconds)) { shown = figures }
        }
    }
}
