import SwiftUI

/// A day's time in range as a thin bar: below, in and above range in the range colours
/// (`GlucoseRange.low/inRange/high.tint`, each at least 3:1 on every Logbook background, see the
/// contrast table in docs/DesignSystem.md), on a quiet track. Used on the iPhone Logbook's day
/// headers and the Mac Logbook's Day column, always beside the in-range figure in words, so the
/// colours never carry the meaning alone.
///
/// Grows from the left once, the first time its day comes on screen (`DrawnOnce`), then just sits
/// there; a share that changes (today's new readings, or a header the list rebuilt after an entry
/// was added, edited, deleted or undone) glides to its new split from the one last shown
/// (`DrawnOnce.lastFigures`). Nothing loops. Instant under Reduce Motion. Hidden from VoiceOver: the
/// header it sits in says the figures.
struct DayRangeBar: View {
    let id: String
    let figures: DayInRange
    let drawn: DrawnOnce
    var height: CGFloat = 4

    @State private var progress: Double
    /// The split on screen: starts from the one this day's bar last showed, then glides to `figures`.
    @State private var shown: DayInRange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(id: String, figures: DayInRange, drawn: DrawnOnce, height: CGFloat = 4) {
        self.id = id
        self.figures = figures
        self.drawn = drawn
        self.height = height
        _progress = State(initialValue: drawn.has(id) ? 1 : 0)
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
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color)
                        .frame(width: visible[i] ? max(2, (geo.size.width - gaps) * segments[i].fraction) : 0)
                        .padding(.trailing, visible[i] && i != lastShown ? gap : 0)
                }
            }
            .frame(width: geo.size.width * progress, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
        .onChange(of: figures) { glide() }
        .onAppear {
            glide()
            guard progress < 1 else { return }
            // Already drawn by another copy of this header (the list rebuilt it): just be there.
            if !drawn.first(id) || reduceMotion { progress = 1; return }
            // The draw-in the Insights rings and bars use (`DrawIn`), once.
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { progress = 1 }
        }
        .accessibilityHidden(true)
    }

    /// Moves the split to `figures` on the emphasized spring, or at once under Reduce Motion, and
    /// remembers it for the next copy of this bar.
    private func glide() {
        drawn.remember(id, figures)
        guard shown != figures else { return }
        if reduceMotion {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { shown = figures }
        } else {
            withAnimation(DSMotion.emphasized.animation) { shown = figures }
        }
    }
}
