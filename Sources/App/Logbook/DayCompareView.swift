import Charts
import SwiftUI

/// Two Logbook days compared (`DayCompare`): both days' readings drawn over one midnight-to-midnight
/// chart on the target band, the first day as a solid line and the second dashed, so the two tell
/// apart without colour. Under the chart each day's time in range, average, lows and highs sit side
/// by side. The second day steps a day at a time with the chevrons beside its name, and the swap
/// button between the names trades the two days' places.
///
/// Motion (`DayCompareMotion`): the second day's line draws in from the left when the comparison
/// opens. When a day is replaced or the two swap, each changed line cross-slides (the old one slides
/// away and fades as the new one slides in from the other side, a later day from the right) while
/// the side-by-side figures roll with `rollingDigits`. Under Reduce Motion the lines and figures
/// switch at once. Nothing loops.
///
/// VoiceOver reads the chart as one element naming both days, then one summary per day ("Today: 78%
/// in range, average 7.2 mmol/L, 1 low, 2 highs."), and hears "Comparing Today with Monday 11
/// November." once when the comparison opens and once per change. Shows what happened only: no day
/// is called better.
///
/// Shared cursor (`DayCompareScrub`): dragging along the chart on iPhone, or pointing at it on the
/// Mac, puts one line across both days at a clock time, snapped to the nearest reading. The row
/// above the chart then reads that time, each day's value there and how far apart they are, with
/// the higher line's swatch. iPhone ticks `scrubSnapped` on landing and `scrubRangeEdge` when
/// either line crosses the low or high line; readings themselves don't tick. VoiceOver hears each
/// stop once per touch, and can swipe up or down to move the cursor an hour at a time.
struct DayCompareView: View {
    let readings: [GlucoseReading]
    /// Days with enough readings to compare (`DayCompare.readingDays`), for the chevrons.
    let days: Set<Date>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var chartHeight: CGFloat = 180

    /// The solid line's day: the day it was opened from, until the days swap.
    @State private var first: Date
    @State private var second: Date
    /// How much of the second day's line has drawn in (0...1).
    @State private var reveal = 0.0
    @State private var opened = false
    /// True while the opening draw-in runs: a step then lets the new line keep drawing in
    /// rather than sliding a half-drawn one away.
    @State private var drawingIn = false
    /// Each change bumps `slideTarget` at once and animates `slidePhase` up to it, so the chart's
    /// slide progress always runs 0 to 1 even when a change lands mid-slide.
    @State private var slideTarget = 0.0
    @State private var slidePhase = 0.0
    @State private var outgoingFirst: Date?
    @State private var outgoingSecond: Date?
    @State private var firstDirection = 1.0
    @State private var secondDirection = 1.0
    /// The shared scrub cursor's clock minute, snapped to a reading, or nil when it isn't showing.
    @State private var cursor: Double?
    /// The stops VoiceOver has been told about in this touch, so each is said once.
    @State private var spokenStops: Set<Double> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let firstColor = Palette.brand
    static let secondColor = Palette.magenta

    init(first: Date, second: Date, readings: [GlucoseReading], days: Set<Date>, unit: GlucoseUnit,
         lowMgdl: Double, highMgdl: Double, chartHeight: CGFloat = 180) {
        _first = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: first))
        self.readings = readings
        self.days = days
        self.unit = unit
        self.lowMgdl = lowMgdl
        self.highMgdl = highMgdl
        self.chartHeight = chartHeight
        _second = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: second))
    }

    var body: some View {
        let now = Date()
        let a = DayCompare.day(first, readings: readings, low: lowMgdl, high: highMgdl, now: now)
        let b = DayCompare.day(second, readings: readings, low: lowMgdl, high: highMgdl, now: now)
        let aName = spokenDay(first, now: now)
        let bName = spokenDay(second, now: now)
        let stops = DayCompareScrub.stops(a.runs, b.runs)
        let readout = cursor.map { DayCompareScrub.readout(at: $0, first: a.runs, second: b.runs) }
        VStack(alignment: .leading, spacing: DS.Space.md) {
            legend(now: now)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                readoutRow(readout)
                chart(a, b, readout: readout,
                      selection: scrubSelection(a, b, stops: stops, aName: aName, bName: bName), now: now)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(DayCompareText.chartSpoken(first: aName, second: bName, unit: unit,
                                                                   low: lowMgdl, high: highMgdl))
                    .accessibilityValue(readout.map {
                        DayCompareScrubText.spoken($0, first: aName, second: bName, unit: unit)
                    } ?? "")
                    .accessibilityHint("Swipe up or down to move through the day an hour at a time.")
                    .accessibilityAdjustableAction { direction in
                        let by = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                        guard let next = DayCompareScrub.stepped(cursor, by: by, stops: stops) else { return }
                        // VoiceOver reads the new value itself, so it isn't announced as well.
                        cursor = next
                        spokenStops.insert(next)
                    }
            }
            figures(a, b, aName: aName, bName: bName)
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            switch DayCompareMotion.opening(reduceMotion: reduceMotion) {
            case .drawIn:
                drawingIn = true
                withAnimation(.easeInOut(duration: DayCompareMotion.drawInDuration).delay(0.1),
                              completionCriteria: .logicallyComplete) { reveal = 1 } completion: { drawingIn = false }
            case .slide, .instant:
                reveal = 1
            }
            LoggedElsewhere.announce(DayCompareText.announcement(first: aName, second: bName))
        }
    }

    private func spokenDay(_ d: Date, now: Date) -> String {
        DayInRangeText.spokenDay(ClockLabel.day(of: d, now: now))
    }

    // MARK: Legend

    private func legend(now: Date) -> some View {
        HStack(spacing: DS.Space.md) {
            swatchLabel(ClockLabel.dayTitle(ClockLabel.day(of: first, now: now)), color: Self.firstColor, dashed: false)
                .contentTransition(.opacity)
                .accessibilityHidden(true)
            swapButton(now: now)
            Spacer(minLength: DS.Space.sm)
            HStack(spacing: DS.Space.xs) {
                stepButton(-1, now: now)
                swatchLabel(ClockLabel.dayTitle(ClockLabel.day(of: second, now: now)), color: Self.secondColor, dashed: true)
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
                stepButton(1, now: now)
            }
        }
    }

    private func swatch(color: Color, dashed: Bool) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 4))
            p.addLine(to: CGPoint(x: 18, y: 4))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [4, 3] : []))
        .frame(width: 18, height: 8)
    }

    private func swatchLabel(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            swatch(color: color, dashed: dashed)
            Text(title)
                .dsFont(.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func stepButton(_ by: Int, now: Date) -> some View {
        let target = DayCompare.stepped(second, by: by, first: first, days: days, now: now)
        return Button { step(to: target, now: now) } label: {
            Image(systemName: by < 0 ? "chevron.left" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.brand)
        .disabled(target == nil)
        .accessibilityLabel(by < 0 ? "Earlier day" : "Later day")
        .accessibilityValue(target.map { spokenDay($0, now: now) } ?? "")
        .help(by < 0 ? "Compare with the day before" : "Compare with the day after")
    }

    private func swapButton(now: Date) -> some View {
        Button { change(first: second, second: first, now: now) } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.brand)
        .accessibilityLabel("Swap days")
        .help("Swap the two days")
    }

    private func step(to target: Date?, now: Date) {
        guard let target else { return }
        change(first: first, second: target, now: now)
    }

    /// Replaces one or both days. Each line whose day changed cross-slides (`DayCompareMotion`);
    /// under Reduce Motion everything switches at once. One VoiceOver announcement per change.
    private func change(first newFirst: Date, second newSecond: Date, now: Date) {
        guard newFirst != first || newSecond != second else { return }
        #if os(iOS)
        Haptics.play(.choice)
        #endif
        let firstMotion = DayCompareMotion.change(from: first, to: newFirst, reduceMotion: reduceMotion)
        // Mid draw-in the second line isn't fully there yet, so the new day just carries on drawing in.
        let secondMotion: DayCompareMotion = drawingIn ? .instant
            : DayCompareMotion.change(from: second, to: newSecond, reduceMotion: reduceMotion)
        var slides = false
        if case .slide(let d) = firstMotion { outgoingFirst = first; firstDirection = d; slides = true } else { outgoingFirst = nil }
        if case .slide(let d) = secondMotion { outgoingSecond = second; secondDirection = d; slides = true } else { outgoingSecond = nil }
        if slides {
            slideTarget += 1
            let target = slideTarget
            withAnimation(.smooth(duration: DayCompareMotion.slideDuration), completionCriteria: .logicallyComplete) {
                first = newFirst
                second = newSecond
                if !drawingIn { reveal = 1 }
                slidePhase = target
            } completion: {
                // A later change owns the outgoing lines now.
                guard slideTarget == target else { return }
                outgoingFirst = nil
                outgoingSecond = nil
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                first = newFirst
                second = newSecond
                // Only the dates change here: neither animatable value is touched, so a running
                // draw-in carries on undisturbed with the new day's line. With no outgoing
                // lines the slide progress isn't read, so it needn't move.
                if !drawingIn { reveal = 1 }
            }
        }
        LoggedElsewhere.announce(DayCompareText.announcement(first: spokenDay(newFirst, now: now),
                                                             second: spokenDay(newSecond, now: now)))
    }

    // MARK: Shared cursor

    /// The row above the chart: a hint until a scrub, then the cursor's time, each day's value
    /// there by its swatch, and how far apart they are beside the higher line's swatch. Hidden from
    /// VoiceOver, which reads the same as the chart's value.
    private func readoutRow(_ r: DayCompareReadout?) -> some View {
        HStack(spacing: DS.Space.sm) {
            if let r {
                Text(DayCompareScrubText.time(r.minute))
                    .dsFont(.label)
                    .monospacedDigit()
                valueChip(r.first, color: Self.firstColor, dashed: false)
                valueChip(r.second, color: Self.secondColor, dashed: true)
                Spacer(minLength: 0)
                if let difference = DayCompareScrubText.difference(r, unit: unit) {
                    HStack(spacing: DS.Space.xs) {
                        if let firstHigher = DayCompareScrubText.firstHigher(r, unit: unit) {
                            swatch(color: firstHigher ? Self.firstColor : Self.secondColor, dashed: !firstHigher)
                        }
                        Text(difference)
                            .dsFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(Self.hint)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minHeight: 22)
        .accessibilityHidden(true)
    }

    private static var hint: String {
        #if os(macOS)
        return DayCompareScrubText.macHint
        #else
        return DayCompareScrubText.hint
        #endif
    }

    private func valueChip(_ mgdl: Double?, color: Color, dashed: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            swatch(color: color, dashed: dashed)
            Text(DayCompareScrubText.value(mgdl, unit: unit))
                .dsFont(.label)
                .monospacedDigit()
        }
    }

    /// What Charts' selection reads and writes: a drag on iPhone, the pointer on the Mac. The
    /// cursor snaps to the nearest reading of either day, and goes when the finger or pointer
    /// leaves the chart.
    private func scrubSelection(_ a: DayCompareDay, _ b: DayCompareDay, stops: [Double],
                                aName: String, bName: String) -> Binding<Double?> {
        Binding(get: { cursor }, set: { finger in
            guard let finger else {
                cursor = nil
                spokenStops = []
                return
            }
            moveCursor(to: DayCompareScrub.snap(finger: finger, stops: stops), a, b, aName: aName, bName: bName)
        })
    }

    /// Moves the cursor from one reading to the next (instantly: the stops are a few points apart).
    /// Ticks on iPhone when it lands or a line crosses the low or high line, and tells VoiceOver
    /// each stop once per touch.
    private func moveCursor(to next: Double?, _ a: DayCompareDay, _ b: DayCompareDay, aName: String, bName: String) {
        guard next != cursor else { return }
        #if os(iOS)
        let tick = DayCompareScrubTick.tick(from: cursor, to: next, first: a.runs, second: b.runs,
                                            low: lowMgdl, high: highMgdl)
        #endif
        withTransaction(Transaction(animation: nil)) { cursor = next }
        #if os(iOS)
        switch tick {
        case .landed: Haptics.play(.scrubSnapped)
        case .rangeEdge: Haptics.play(.scrubRangeEdge)
        case nil: break
        }
        #endif
        guard let next, !spokenStops.contains(next) else { return }
        spokenStops.insert(next)
        let r = DayCompareScrub.readout(at: next, first: a.runs, second: b.runs)
        let spoken = AttributedString(DayCompareScrubText.spoken(r, first: aName, second: bName, unit: unit))
        AccessibilityNotification.Announcement(spoken).post()
    }

    // MARK: Chart

    private func chart(_ a: DayCompareDay, _ b: DayCompareDay, readout: DayCompareReadout?,
                       selection: Binding<Double?>, now: Date) -> some View {
        let day = { (d: Date?) in d.map { DayCompare.day($0, readings: readings, low: lowMgdl, high: highMgdl, now: now).runs } }
        return DayCompareChart(
            first: a.runs, second: b.runs,
            outgoingFirst: day(outgoingFirst), outgoingSecond: day(outgoingSecond),
            firstDirection: firstDirection, secondDirection: secondDirection,
            reveal: reveal, slidePhase: slidePhase, slideTarget: slideTarget,
            cursor: readout, selection: selection,
            unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl, height: chartHeight
        )
    }

    // MARK: Figures

    private static let rowLabels = ["In range", "Average", "Lows", "Highs"]

    /// Three columns: what each row is, then each day's figures. Each day's column is one VoiceOver
    /// element reading that day's summary; the row names are hidden from it.
    private func figures(_ a: DayCompareDay, _ b: DayCompareDay, aName: String, bName: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(" ").dsFont(.caption)
                ForEach(Self.rowLabels, id: \.self) { label in
                    Text(label == "Average" ? "Average (\(unit.label))" : label)
                        .dsFont(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            column(a, title: dayTitle(first), color: Self.firstColor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayCompareText.spoken(a, spokenDay: aName, unit: unit))
            column(b, title: dayTitle(second), color: Self.secondColor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayCompareText.spoken(b, spokenDay: bName, unit: unit))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ d: DayCompareDay, title: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            Text(title)
                .dsFont(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .contentTransition(.opacity)
            ForEach(Array([DayCompareText.inRange(d), DayCompareText.average(d, unit: unit),
                           DayCompareText.count(d.lows), DayCompareText.count(d.highs)].enumerated()), id: \.offset) { _, value in
                // Rolls to the new day's figure (instant under Reduce Motion); the column's own
                // label is what VoiceOver reads.
                Text(value)
                    .rollingDigits(value, style: .primary, alignment: .trailing)
                    .dsFont(.body)
                    .monospacedDigit()
            }
        }
        .frame(minWidth: 72, alignment: .trailing)
    }

    private func dayTitle(_ d: Date) -> String { ClockLabel.dayTitle(ClockLabel.day(of: d, now: Date())) }
}

/// The overlay chart, redrawn on every frame of a draw-in or cross-slide: `reveal` and the slide
/// progress are its animatable data, and the lines are cut and shifted by `DayCompareMotion`, so
/// Swift Charts itself never animates (its own transitions are switched off below).
private struct DayCompareChart: View, Animatable {
    let first: [[DayComparePoint]]
    let second: [[DayComparePoint]]
    let outgoingFirst: [[DayComparePoint]]?
    let outgoingSecond: [[DayComparePoint]]?
    let firstDirection: Double
    let secondDirection: Double
    var reveal: Double
    var slidePhase: Double
    let slideTarget: Double
    /// The shared scrub cursor, drawn as one line with a dot on each day's value.
    let cursor: DayCompareReadout?
    let selection: Binding<Double?>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let height: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(reveal, slidePhase) }
        set { reveal = newValue.first; slidePhase = newValue.second }
    }

    private var progress: Double { min(max(1 - (slideTarget - slidePhase), 0), 1) }

    private func yDomain(_ values: [Double]) -> ClosedRange<Double> {
        let all = values + [lowMgdl, highMgdl]
        let lo = min(all.min() ?? 60, 60) - 10
        let hi = max(all.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    var body: some View {
        let p = progress
        let fa = DayCompareMotion.frame(progress: p, direction: firstDirection)
        let fb = DayCompareMotion.frame(progress: p, direction: secondDirection)
        let shownSecond = DayCompareMotion.revealed(second, fraction: reveal)
        // Only lines that are sliding move; the other stays put.
        let firstIn = outgoingFirst == nil ? first : DayCompareMotion.slid(first, by: fa.incomingOffset)
        let secondIn = outgoingSecond == nil ? shownSecond : DayCompareMotion.slid(shownSecond, by: fb.incomingOffset)
        let firstOut = outgoingFirst.map { DayCompareMotion.slid($0, by: fa.outgoingOffset) } ?? []
        let secondOut = outgoingSecond.map { DayCompareMotion.slid($0, by: fb.outgoingOffset) } ?? []
        // The scale starts as the one that was on screen (the leaving lines and the line that
        // stays) and glides to the new days' scale as the leaving lines fade, so nothing jumps
        // when a slide starts. The plot is clipped, so a fading peak that's left the scale while
        // it glides is cut at the plot's edge rather than drawn over the axis.
        let newDomain = yDomain((first + second).joined().map(\.mgdl))
        let oldDomain = outgoingFirst == nil && outgoingSecond == nil ? newDomain
            : yDomain(((outgoingFirst ?? first) + (outgoingSecond ?? second)).joined().map(\.mgdl))
        let domain = DayCompareMotion.blend(oldDomain, newDomain, progress: DayCompareMotion.scaleProgress(p))
        return Chart {
            RectangleMark(
                xStart: .value("Start", 0.0), xEnd: .value("End", DayCompare.minutesPerDay),
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.12))
            RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.5))
            RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.5))

            runs(secondOut, key: "second-out", color: DayCompareView.secondColor.opacity(fb.outgoingOpacity), dashed: true)
            runs(secondIn, key: "second",
                 color: DayCompareView.secondColor.opacity(outgoingSecond == nil ? 1 : fb.incomingOpacity), dashed: true)
            runs(firstOut, key: "first-out", color: DayCompareView.firstColor.opacity(fa.outgoingOpacity), dashed: false)
            runs(firstIn, key: "first",
                 color: DayCompareView.firstColor.opacity(outgoingFirst == nil ? 1 : fa.incomingOpacity), dashed: false)

            if let c = cursor {
                RuleMark(x: .value("Cursor", c.minute))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.35))
                // A circle on the solid line and a diamond on the dashed one, so they tell apart
                // without colour too.
                if let v = c.first {
                    PointMark(x: .value("Cursor", c.minute), y: .value("Glucose", unit.value(fromMgdl: v)))
                        .symbol(.circle)
                        .symbolSize(48)
                        .foregroundStyle(DayCompareView.firstColor)
                }
                if let v = c.second {
                    PointMark(x: .value("Cursor", c.minute), y: .value("Glucose", unit.value(fromMgdl: v)))
                        .symbol(.diamond)
                        .symbolSize(56)
                        .foregroundStyle(DayCompareView.secondColor)
                }
            }
        }
        .chartXScale(domain: 0...DayCompare.minutesPerDay)
        .chartYScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartXSelection(value: selection)
        .chartYAxis {
            AxisMarks(position: .leading, values: [unit.value(fromMgdl: lowMgdl), unit.value(fromMgdl: highMgdl)]) { v in
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(unit == .mmol ? String(format: "%.1f", d) : String(format: "%.0f", d)) }
                }
                .font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: DayCompare.tickMinutes) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                AxisValueLabel(centered: false) {
                    if let m = v.as(Double.self) { Text(DayCompareText.tick(m)) }
                }
                .font(.caption2)
            }
        }
        .frame(height: height)
        // Every frame is drawn exactly as computed above, and under Reduce Motion nothing animates.
        .transaction { $0.animation = nil }
    }

    @ChartContentBuilder
    private func runs(_ runs: [[DayComparePoint]], key: String, color: Color, dashed: Bool) -> some ChartContent {
        ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
            ForEach(run, id: \.minute) { p in
                LineMark(
                    x: .value("Time", p.minute),
                    y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                    series: .value("Run", "\(key)-\(i)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: dashed ? 1.75 : 2, lineCap: .round, lineJoin: .round,
                                       dash: dashed ? [4, 3] : []))
            }
            // A run of one reading still shows, as a dot.
            if run.count == 1, let p = run.first {
                PointMark(x: .value("Time", p.minute), y: .value("Glucose", unit.value(fromMgdl: p.mgdl)))
                    .symbolSize(12)
                    .foregroundStyle(color)
            }
        }
    }
}
