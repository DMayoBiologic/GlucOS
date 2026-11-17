import SwiftUI

/// The small line under an Insights card's figure (`InsightsSparkline`): one point per day of the
/// card's period, oldest on the left, with a dot on the newest day and a caption saying which way
/// it has gone ("Lows each day · rising over 14 days").
///
/// Motion (docs/Redesign.md §7.2, Insights): where `figuresCountUp` is on (iPhone and Mac
/// Insights) the line draws in from the left the first time it appears, alongside the figures
/// counting up. A new period or new readings bend the line from its old shape into the new one.
/// Under Reduce Motion it never travels: the old line cross-fades into the new. Once per
/// appearance or change, never looping (§4.6). Elsewhere, widgets included, it's drawn at once.
///
/// VoiceOver hears one element: the label and the direction. Cards that read as one element
/// (`.accessibilityElement(children: .ignore)`) add `InsightsSparkline.spokenLine(label:)` to their own value instead.
struct InsightsSparklineView: View {
    let series: InsightsSparkline
    let tint: Color
    /// What each point is: "Lows each day".
    let label: String

    /// Points the line is drawn through, whatever the period, so a 7-day line morphs into a 30-day one.
    static let points = 31
    static let height: CGFloat = 28

    @Environment(\.figuresCountUp) private var drawsIn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The shape the morph starts from and the one it ends on.
    @State private var from: [Double] = []
    @State private var to: [Double]?
    @State private var phase: Double = 1
    @State private var reveal: Double = 1
    /// Counts changes, so a draw-in or morph still being set up never overrides a newer one.
    @State private var generation = 0
    @State private var appeared = false

    var body: some View {
        let target = series.heights(count: Self.points)
        if !target.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ZStack {
                    SparklineFrame(from: from, to: to ?? target, phase: phase, reveal: reveal, tint: tint)
                        // Under Reduce Motion a new line is a new view, so it cross-fades.
                        .id(reduceMotion ? AnyHashable(target) : AnyHashable(0))
                        .transition(.opacity)
                }
                .frame(height: Self.height)
                .animation(reduceMotion ? .easeInOut(duration: 0.25) : nil, value: target)
                Text(caption)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(series.summary ?? "Not enough days yet")
            .onAppear { appear(target) }
            .onDisappear { generation += 1 }
            .onChange(of: target) { _, new in change(to: new) }
        }
    }

    private var caption: String {
        series.summary.map { "\(label) · \($0)" } ?? label
    }

    private func appear(_ target: [Double]) {
        settle(on: target)
        guard !appeared else { return }
        appeared = true
        guard drawsIn, !reduceMotion else { return }
        withTransaction(Transaction(animation: nil)) { reveal = 0 }
        let generation = self.generation
        // Next turn, so the empty first frame is drawn before the line sweeps in.
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.sweep.animation.delay(0.15)) { reveal = 1 }
        }
    }

    /// Shows `target` as it is, with nothing in flight.
    private func settle(on target: [Double]) {
        generation += 1
        withTransaction(Transaction(animation: nil)) {
            from = target
            to = target
            phase = 1
            reveal = 1
        }
    }

    private func change(to new: [Double]) {
        let shown = to ?? []
        guard !reduceMotion, appeared, reveal == 1, !shown.isEmpty, !new.isEmpty else {
            settle(on: new)
            return
        }
        generation += 1
        let generation = self.generation
        withTransaction(Transaction(animation: nil)) {
            from = SparklineFrame.blend(from: from, to: shown, t: phase)
            to = new
            phase = 0
        }
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.emphasized.animation) { phase = 1 }
        }
    }
}

/// One frame of the sparkline: SwiftUI steps `phase` (the morph) and `reveal` (the draw-in) through
/// every frame, and the line is drawn for that frame.
private struct SparklineFrame: View, Animatable {
    let from: [Double]
    let to: [Double]
    var phase: Double
    var reveal: Double
    let tint: Color

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, reveal) }
        set { phase = newValue.first; reveal = newValue.second }
    }

    static func blend(from: [Double], to: [Double], t: Double) -> [Double] {
        guard from.count == to.count, t < 1 else { return to }
        return zip(from, to).map { a, b in a + (b - a) * t }
    }

    var body: some View {
        let heights = Self.blend(from: from, to: to, t: phase)
        GeometryReader { geo in
            let pts = Self.points(heights, in: geo.size)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .trim(from: 0, to: reveal)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    // The newest day, once the line reaches it.
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .position(last)
                        .opacity(min(1, max(0, (reveal - 0.9) * 10)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Left to right across the width; 0 at the bottom, inset so the dot and caps aren't clipped.
    private static func points(_ heights: [Double], in size: CGSize) -> [CGPoint] {
        guard heights.count > 1 else { return [] }
        let inset: CGFloat = 3
        let w = max(0, size.width - inset * 2), h = max(0, size.height - inset * 2)
        return heights.enumerated().map { i, y in
            CGPoint(x: inset + w * CGFloat(i) / CGFloat(heights.count - 1),
                    y: inset + h * (1 - CGFloat(y)))
        }
    }
}
