import SwiftUI
import Charts
import Accessibility

/// The Insights "Your usual day" card on the Mac and iPhone: each time of day over the last 14 or
/// 30 days, as a middle line with the middle half and 8 in 10 readings shaded round it (an AGP).
/// The pattern is worked out off the main thread once per data change (`DayPatternCache`). When the
/// chart first shows, its bands grow out of the middle line; switching between 14 and 30 days
/// glides each band and the glucose axis to the new period (`DayPatternMotion`). Both play once,
/// never loop, and Reduce Motion shows the new picture at once. Callers give it their own card
/// surface.
///
/// Scrub (`DayPatternScrub`, round 88): hold and drag along the chart on iPhone, or point at it on
/// the Mac, and a cursor sits on one half-hour with a small card giving its middle reading and
/// middle half, while the rest of the chart dims back. The cursor snaps onto the usual day's
/// highest and lowest points; iPhone ticks `scrubSnapped` on landing and snapping and
/// `scrubRangeEdge` when the middle line crosses the low or high line. VoiceOver steps the cursor
/// an hour at a time with swipe up or down, and hears each stop once per touch.
struct DayPatternView: View {
    let readings: [GlucoseReading]
    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @AppStorage("insights.dayPatternDays") private var windowDays = DayPattern.Window.fortnight.rawValue
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    @State private var pattern: DayPattern?
    @State private var shownKey: DayPatternCache.Key?
    /// The scrub cursor: the middle minute of the slot it sits on, or nil when it isn't showing.
    @State private var cursor: Double?
    /// Stops VoiceOver has already heard this touch.
    @State private var spokenStops: Set<Double> = []
    /// The plot's width in points, to turn the snap's points into minutes.
    @State private var plotWidth: Double = 0

    private var window: DayPattern.Window { DayPattern.Window(rawValue: windowDays) ?? .fortnight }
    /// The readings up to where the period ends once Insights is stepped back; all of them on
    /// the latest.
    private var shown: [GlucoseReading] {
        InsightsPeriodStep.readings(readings, days: window.days, back: step.back)
    }
    private var key: DayPatternCache.Key { DayPatternCache.key(readings: shown, window: window) }

    var body: some View {
        let key = self.key
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: DayPatternText.title, systemImage: "clock", trailing: "Time of day")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $windowDays) {
                    ForEach(DayPattern.Window.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Period")
            }
            // Which dates the card shows once Insights is stepped back (docs/InsightsPeriodStep.md).
            InsightsStepCaption(days: window.days, latest: readings.last?.timestamp)

            // While the other period is worked out, the last one stays up so the chart can glide
            // from it rather than blanking.
            if let pattern {
                DayPatternMotion(pattern: pattern, lowMgdl: lowMgdl, highMgdl: highMgdl) { drawn, tint, yDomain in
                    DayPatternChart(drawn: drawn, tint: tint, pattern: pattern, yDomainMgdl: yDomain,
                                    unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl,
                                    cursor: shareSnapshot ? nil : cursor,
                                    selection: scrubSelection(pattern), plotWidth: $plotWidth,
                                    adjust: { by in
                                        guard let next = DayPatternScrub.stepped(cursor, by: by, pattern: pattern) else { return }
                                        // VoiceOver reads the new value itself, so it isn't announced as well.
                                        cursor = next
                                        spokenStops.insert(next)
                                    })
                }
                // A new period is a new picture: the cursor goes rather than jumping.
                .onChange(of: pattern.window) { cursor = nil; spokenStops = [] }
                .frame(height: 190)
                legend
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(DayPatternText.lines(pattern, unit: unit, low: lowMgdl, high: highMgdl), id: \.self) {
                        Text($0)
                            .dsFont(.callout)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityHidden(true) // The chart's value says the same.
                Text(DayPatternText.footnote)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shownKey == key {
                emptyNote(key)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            if let hit = DayPatternCache.shared.cached(key) {
                pattern = hit
            } else {
                pattern = await DayPatternCache.shared.pattern(for: key, readings: shown)
            }
            shownKey = key
        }
    }

    // MARK: Scrub

    /// What Charts' selection reads and writes: a hold-and-drag on iPhone, the pointer on the Mac.
    /// The cursor settles on a slot (snapping onto the usual high and low), and goes when the
    /// finger lifts or the pointer leaves.
    private func scrubSelection(_ pattern: DayPattern) -> Binding<Double?> {
        Binding(get: { cursor }, set: { finger in
            guard let finger else {
                cursor = nil
                spokenStops = []
                return
            }
            let minutesPerPoint = plotWidth > 0 ? 1440 / plotWidth : 0
            moveCursor(to: DayPatternScrub.settle(finger: finger, pattern: pattern, current: cursor,
                                                  minutesPerPoint: minutesPerPoint), pattern: pattern)
        })
    }

    /// Moves the cursor from slot to slot at once (they're a few points apart, and a glide would
    /// lag the finger). Ticks on iPhone, and tells VoiceOver each stop once per touch.
    private func moveCursor(to next: Double?, pattern: DayPattern) {
        guard next != cursor else { return }
        #if os(iOS)
        let tick = DayPatternScrubTick.tick(from: cursor, to: next, pattern: pattern, low: lowMgdl, high: highMgdl)
        #endif
        withTransaction(Transaction(animation: nil)) { cursor = next }
        #if os(iOS)
        switch tick {
        case .snapped: Haptics.play(.scrubSnapped)
        case .rangeEdge: Haptics.play(.scrubRangeEdge)
        case nil: break
        }
        #endif
        guard let next, !spokenStops.contains(next), let slot = DayPatternScrub.slot(at: next, in: pattern) else { return }
        spokenStops.insert(next)
        let spoken = DayPatternScrubText.spoken(slot, kind: DayPatternScrub.landmark(at: next, in: pattern), unit: unit)
        AccessibilityNotification.Announcement(AttributedString(spoken)).post()
    }

    private var legend: some View {
        DSAccessibleStack(spacing: DS.Space.lg) {
            DayPatternSwatch(style: .line, label: DayPatternText.legendMedian)
            DayPatternSwatch(style: .inner, label: DayPatternText.legendInner)
            DayPatternSwatch(style: .outer, label: DayPatternText.legendOuter)
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// Plays the chart's two movements: the bands drawing in when it first shows, and the glide when
/// the period changes. A new pattern for the same period (fresh readings) is drawn as it is.
private struct DayPatternMotion<Content: View>: View {
    let pattern: DayPattern
    let lowMgdl: Double
    let highMgdl: Double
    /// The pattern to draw this frame, the one to colour it by (the bands at full width, so the
    /// colours don't shift while they grow), and the glucose axis in mg/dL.
    @ViewBuilder let content: (_ drawn: DayPattern, _ tint: DayPattern, _ yDomainMgdl: ClosedRange<Double>) -> Content

    @State private var from: DayPattern?
    @State private var to: DayPattern?
    @State private var phase: Double = 1
    @State private var reveal: Double = 1
    @State private var drewIn = false
    /// Counts changes, so a movement still being set up never overrides a newer one.
    @State private var generation = 0
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { !reduceMotion && onScreen }

    var body: some View {
        DayPatternFrame(from: from ?? pattern, to: to ?? pattern, phase: phase, reveal: reveal,
                        lowMgdl: lowMgdl, highMgdl: highMgdl, content: content)
            .onEntrance {
                onScreen = true
                settle(on: pattern)
                guard !drewIn else { return }
                drewIn = true
                drawIn()
            }
            .onDisappear {
                onScreen = false
                generation += 1
            }
            .onChange(of: pattern) { old, new in
                if old.window != new.window { glide(from: to ?? old, to: new) } else { settle(on: new) }
            }
    }

    private func settle(on pattern: DayPattern) {
        generation += 1
        withTransaction(Transaction(animation: nil)) {
            from = pattern
            to = pattern
            phase = 1
            reveal = 1
        }
    }

    /// The bands grow out of the middle line, once the card around them has come in.
    private func drawIn() {
        guard animates else { return }
        withTransaction(Transaction(animation: nil)) { reveal = 0 }
        let generation = self.generation
        // On the next turn, so the collapsed first frame is drawn before the bands grow.
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.sweep.animation.delay(0.15)) { reveal = 1 }
        }
    }

    private func glide(from old: DayPattern, to new: DayPattern) {
        guard animates, reveal == 1 else { settle(on: new); return }
        generation += 1
        let generation = self.generation
        withTransaction(Transaction(animation: nil)) {
            from = old
            to = new
            phase = 0
        }
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            withAnimation(DSMotion.ambient.animation) { phase = 1 }
        }
    }
}

/// One frame of `DayPatternMotion`: SwiftUI steps `phase` and `reveal` through every frame, and the
/// chart is handed that frame's pattern and axis.
private struct DayPatternFrame<Content: View>: View, Animatable {
    let from: DayPattern
    let to: DayPattern
    var phase: Double
    var reveal: Double
    let lowMgdl: Double
    let highMgdl: Double
    let content: (_ drawn: DayPattern, _ tint: DayPattern, _ yDomainMgdl: ClosedRange<Double>) -> Content

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, reveal) }
        set { phase = newValue.first; reveal = newValue.second }
    }

    var body: some View {
        let blended = DayPatternMorph.blend(from: from, to: to, t: phase)
        content(DayPatternMorph.spread(blended, reveal: reveal), blended,
                DayPatternMorph.yDomain(from: from, to: to, t: phase, low: lowMgdl, high: highMgdl))
    }
}

/// The chart itself: the target band, the two percentile bands and the middle line, coloured by
/// range the same way as the glucose trace (`ThresholdGradient`).
private struct DayPatternChart: View {
    /// What's drawn this frame (part way through a draw-in or glide).
    let drawn: DayPattern
    /// What the bands are coloured by: `drawn` at full width.
    let tint: DayPattern
    /// The settled pattern, for VoiceOver.
    let pattern: DayPattern
    /// The glucose axis in mg/dL.
    let yDomainMgdl: ClosedRange<Double>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// The scrub cursor's minute (a slot's middle), nil when it isn't showing.
    let cursor: Double?
    let selection: Binding<Double?>
    @Binding var plotWidth: Double
    /// VoiceOver's swipe up (1) or down (-1).
    let adjust: (Int) -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The settled slot under the cursor.
    private var cursorSlot: DayPattern.Slot? { cursor.flatMap { DayPatternScrub.slot(at: $0, in: pattern) } }

    /// A slot drawn at its middle, plus copies at midnight on both edges so the line meets the
    /// axis (the day wraps, so midnight is the average of the first and last slots).
    private struct Point: Identifiable {
        let x: Double
        let slot: DayPattern.Slot
        var id: Double { x }
    }

    /// Runs of consecutive slots, so a gap in the data is a gap in the chart rather than a
    /// straight line across it.
    private var segments: [[Point]] {
        var out: [[Point]] = []
        var run: [Point] = []
        for s in drawn.slots {
            if let s { run.append(Point(x: s.midMinute, slot: s)) } else if !run.isEmpty { out.append(run); run = [] }
        }
        if !run.isEmpty { out.append(run) }
        if let first = drawn.slots.first.flatMap({ $0 }), let last = drawn.slots.last.flatMap({ $0 }),
           !out.isEmpty {
            let mid = DayPattern.Slot(minute: 0, p10: (first.p10 + last.p10) / 2, p25: (first.p25 + last.p25) / 2,
                                      p50: (first.p50 + last.p50) / 2, p75: (first.p75 + last.p75) / 2,
                                      p90: (first.p90 + last.p90) / 2, count: 0)
            out[0].insert(Point(x: 0, slot: mid), at: 0)
            out[out.count - 1].append(Point(x: 1440, slot: mid))
        }
        return out
    }

    private func v(_ mgdl: Double) -> Double { unit.value(fromMgdl: mgdl) }

    private func gradient(_ lo: Double?, _ hi: Double?) -> LinearGradient {
        ThresholdGradient.style(minMgdl: lo ?? lowMgdl, maxMgdl: hi ?? highMgdl, low: lowMgdl, high: highMgdl)
    }

    var body: some View {
        let f = tint.filled
        let segments = self.segments
        let strong = contrast == .increased
        let outer = gradient(f.map(\.p10).min(), f.map(\.p90).max())
        let inner = gradient(f.map(\.p25).min(), f.map(\.p75).max())
        let line = gradient(f.map(\.p50).min(), f.map(\.p50).max())
        let yd = yDomainMgdl
        let settled = DayPatternMorph.yDomain(pattern, low: lowMgdl, high: highMgdl)
        let picked = cursorSlot
        let kind = picked.flatMap { DayPatternScrub.landmark(at: $0.midMinute, in: pattern) }
        Chart {
            RectangleMark(yStart: .value("Low", v(lowMgdl)), yEnd: .value("High", v(highMgdl)))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.07))
            RuleMark(y: .value("Low", v(lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))
            RuleMark(y: .value("High", v(highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))

            ForEach(Array(segments.enumerated()), id: \.offset) { i, run in
                ForEach(run) { p in
                    AreaMark(x: .value("Time", p.x),
                             yStart: .value("10th", v(p.slot.p10)),
                             yEnd: .value("90th", v(p.slot.p90)),
                             series: .value("Band", "outer \(i)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(outer)
                        .opacity(strong ? 0.28 : 0.18)
                }
                ForEach(run) { p in
                    AreaMark(x: .value("Time", p.x),
                             yStart: .value("25th", v(p.slot.p25)),
                             yEnd: .value("75th", v(p.slot.p75)),
                             series: .value("Band", "inner \(i)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(inner)
                        .opacity(strong ? 0.5 : 0.36)
                }
                ForEach(run) { p in
                    LineMark(x: .value("Time", p.x), y: .value("Middle", v(p.slot.p50)),
                             series: .value("Band", "middle \(i)"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: strong ? 3 : 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(line)
                }
            }

            if let c = picked {
                RuleMark(x: .value("Cursor", c.midMinute))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.35))
                // The middle half at this time, as a short bar on the cursor.
                RuleMark(x: .value("Cursor", c.midMinute),
                         yStart: .value("25th", v(c.p25)), yEnd: .value("75th", v(c.p75)))
                    .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(GlucoseRange.classify(mgdl: c.p50, low: lowMgdl, high: highMgdl).tint.opacity(0.45))
                PointMark(x: .value("Cursor", c.midMinute), y: .value("Middle", v(c.p50)))
                    .symbolSize(56)
                    .foregroundStyle(GlucoseRange.classify(mgdl: c.p50, low: lowMgdl, high: highMgdl).tint)
            }
        }
        .chartXScale(domain: 0...1440)
        .chartYScale(domain: v(yd.lowerBound)...v(yd.upperBound))
        .chartXAxis {
            AxisMarks(values: [0.0, 360, 720, 1080, 1440]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let m = value.as(Double.self) { Text(Self.axisLabel(Int(m))) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartXSelection(value: selection)
        // Away from the cursor the chart fades back, so its half-hour stands out.
        .chartPlotStyle { plot in
            plot.mask { DayPatternDim(strip: picked.map { Double($0.minute)...Double($0.minute + DayPattern.slotMinutes) }) }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .onAppear { plotWidth = proxy.plotSize.width }
                    .onChange(of: proxy.plotSize.width) { _, w in plotWidth = w }
                if let c = picked, let plot = proxy.plotFrame {
                    DayPatternScrubCard(slot: c, kind: kind, unit: unit, range: GlucoseRange.classify(mgdl: c.p50, low: lowMgdl, high: highMgdl))
                        .modifier(DayPatternCardPlacement(proxy: proxy, plot: geo[plot], slot: c, unit: unit))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : DSMotion.quick.animation, value: picked == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usual day chart")
        .accessibilityValue(picked.map { DayPatternScrubText.spoken($0, kind: kind, unit: unit) }
                            ?? DayPatternText.spoken(pattern, unit: unit, low: lowMgdl, high: highMgdl))
        .accessibilityHint(DayPatternScrubText.hint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
        .accessibilityChartDescriptor(DayPatternAudioGraph(pattern: pattern, unit: unit, lowMgdl: lowMgdl,
                                                           highMgdl: highMgdl,
                                                           yDomain: v(settled.lowerBound)...v(settled.upperBound)))
        .targetRangeGlide(lowMgdl: lowMgdl, highMgdl: highMgdl)
    }

    /// "12 am", "6 am", "12 pm": the axis keeps its labels short.
    static func axisLabel(_ minute: Int) -> String {
        let h = (minute / 60) % 24
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "am" : "pm")"
    }
}

/// The pattern for VoiceOver's audio graph and data table: the middle line and the edges of the
/// 8-in-10 band as three series, with the target's edges as gridlines.
private struct DayPatternAudioGraph: AXChartDescriptorRepresentable {
    let pattern: DayPattern
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let yDomain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = self.unit
        let x = AXNumericDataAxisDescriptor(title: "Time of day", range: 0...1440, gridlinePositions: []) {
            DayPatternText.clock(Int($0))
        }
        let y = AXNumericDataAxisDescriptor(
            title: "Glucose, \(unit.label)", range: yDomain,
            gridlinePositions: [unit.value(fromMgdl: lowMgdl), unit.value(fromMgdl: highMgdl)]
        ) { unit == .mmol ? String(format: "%.1f", $0) : String(format: "%.0f", $0) }
        let f = pattern.filled
        func series(_ name: String, _ k: KeyPath<DayPattern.Slot, Double>) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true, dataPoints: f.map {
                AXDataPoint(x: $0.midMinute, y: unit.value(fromMgdl: $0[keyPath: k]))
            })
        }
        return AXChartDescriptor(
            title: DayPatternText.title,
            summary: DayPatternText.spoken(pattern, unit: unit, low: lowMgdl, high: highMgdl),
            xAxis: x, yAxis: y, additionalAxes: [],
            series: [series("Middle reading", \.p50), series("Lowest tenth", \.p10), series("Highest tenth", \.p90)])
    }
}

/// The scrub's mask over the plot: full strength in a strip round the cursor's half-hour, faded
/// back everywhere else. With no cursor the whole plot is at full strength.
private struct DayPatternDim: View {
    /// The cursor's half-hour, in minutes of the day.
    let strip: ClosedRange<Double>?
    /// The strip is at least this wide, so the cursor's dot and bar are never cut.
    static let minimumWidth: CGFloat = 18
    static let overhang: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Room for marks that overhang the plot (the line's round caps, the cursor's dot).
            let overhang = Self.overhang
            ZStack(alignment: .topLeading) {
                Rectangle().opacity(strip == nil ? 1 : DayPatternScrub.dimmedOpacity)
                if let strip {
                    let x0 = CGFloat(strip.lowerBound / 1440) * w, x1 = CGFloat(strip.upperBound / 1440) * w
                    let width = max(x1 - x0, Self.minimumWidth)
                    Rectangle()
                        .frame(width: width)
                        .offset(x: overhang + (x0 + x1) / 2 - width / 2)
                        .transaction { $0.animation = nil } // The strip follows the finger at once.
                }
            }
            .frame(width: w + 2 * overhang, height: geo.size.height + 2 * overhang)
            .offset(x: -overhang, y: -overhang)
        }
    }
}

/// The small card beside the cursor: the half-hour, its middle reading and its middle half.
private struct DayPatternScrubCard: View {
    let slot: DayPattern.Slot
    let kind: ScrubSnap.Kind?
    let unit: GlucoseUnit
    let range: GlucoseRange

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DayPatternScrubText.time(slot))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Circle().fill(range.tint).frame(width: 7, height: 7)
                Text(unit.format(mgdl: slot.p50, withUnit: true))
                    .fontWeight(.semibold)
                    .dsFont(.callout)
                Text(DayPatternText.legendMedian.lowercased())
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(DayPatternText.legendInner) \(DayPatternScrubText.middleHalf(slot, unit: unit))")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
            if let landmark = DayPatternScrubText.landmark(kind) {
                Text(landmark)
                    .dsFont(.caption)
                    .fontWeight(.medium)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background { DSSurface(style: .standard, radius: DS.Radius.control) }
        .dsShadow(.medium)
    }
}

/// Places the scrub card above the cursor's 8-in-10 band when there's room, below it otherwise,
/// and keeps it inside the plot side to side.
private struct DayPatternCardPlacement: ViewModifier {
    let proxy: ChartProxy
    let plot: CGRect
    let slot: DayPattern.Slot
    let unit: GlucoseUnit
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let gap: CGFloat = 8
        let x = (proxy.position(forX: slot.midMinute) ?? 0) + plot.minX
        let top = (proxy.position(forY: unit.value(fromMgdl: slot.p90)) ?? 0) + plot.minY
        let bottom = (proxy.position(forY: unit.value(fromMgdl: slot.p10)) ?? 0) + plot.minY
        let half = size.width / 2
        let cx = min(max(x, plot.minX + half), max(plot.maxX - half, plot.minX + half))
        let above = top - gap - size.height >= plot.minY
        let cy = above ? top - gap - size.height / 2
            : min(bottom + gap + size.height / 2, plot.maxY - size.height / 2)
        return content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(x: cx, y: cy)
            .opacity(size == .zero ? 0 : 1)
    }
}

private struct DayPatternSwatch: View {
    enum Style { case line, inner, outer }
    let style: Style
    let label: String

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            switch style {
            case .line:
                Capsule().fill(GlucoseRange.inRange.tint).frame(width: 14, height: 3)
            case .inner:
                RoundedRectangle(cornerRadius: 2).fill(GlucoseRange.inRange.tint.opacity(0.36)).frame(width: 14, height: 9)
            case .outer:
                RoundedRectangle(cornerRadius: 2).fill(GlucoseRange.inRange.tint.opacity(0.18)).frame(width: 14, height: 9)
            }
            Text(label).lineLimit(1)
        }
    }
}

extension DayPatternView {
    /// Nothing to show: why, and 30 days when that has enough (`InsightsEmptyState`,
    /// docs/EmptyStates.md). Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: DayPatternCache.Key) -> some View {
        let shown = self.shown, window = window
        return InsightsEmptyNote(id: AnyHashable(key), waiting: DayPatternText.emptyLine(window), decide: {
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: window.days, in: DayPattern.Window.allCases.map(\.days))) { days in
                    guard let w = DayPattern.Window(rawValue: days) else { return false }
                    return DayPattern.compute(readings: shown, window: w) != nil
                }
            return InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(shown),
                                               needed: DayPattern.minimumDays,
                                               waiting: DayPatternText.emptyLine(window), currentDays: window.days,
                                               longerWithData: longer)
        }, act: { action in
            if case .showPeriod(let days) = action { windowDays = days }
        })
    }
}
