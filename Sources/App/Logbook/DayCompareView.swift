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
    /// Each change bumps `slideTarget` at once and animates `slidePhase` up to it, so the chart's
    /// slide progress always runs 0 to 1 even when a change lands mid-slide.
    @State private var slideTarget = 0.0
    @State private var slidePhase = 0.0
    @State private var outgoingFirst: Date?
    @State private var outgoingSecond: Date?
    @State private var firstDirection = 1.0
    @State private var secondDirection = 1.0
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
        VStack(alignment: .leading, spacing: DS.Space.md) {
            legend(now: now)
            chart(a, b, now: now)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayCompareText.chartSpoken(first: aName, second: bName, unit: unit,
                                                               low: lowMgdl, high: highMgdl))
            figures(a, b, aName: aName, bName: bName)
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            switch DayCompareMotion.opening(reduceMotion: reduceMotion) {
            case .drawIn:
                withAnimation(.easeInOut(duration: DayCompareMotion.drawInDuration).delay(0.1)) { reveal = 1 }
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

    private func swatchLabel(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 4))
                p.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 8)
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
        let secondMotion = DayCompareMotion.change(from: second, to: newSecond, reduceMotion: reduceMotion)
        var slides = false
        if case .slide(let d) = firstMotion { outgoingFirst = first; firstDirection = d; slides = true } else { outgoingFirst = nil }
        if case .slide(let d) = secondMotion { outgoingSecond = second; secondDirection = d; slides = true } else { outgoingSecond = nil }
        if slides {
            slideTarget += 1
            let target = slideTarget
            withAnimation(.smooth(duration: DayCompareMotion.slideDuration), completionCriteria: .logicallyComplete) {
                first = newFirst
                second = newSecond
                reveal = 1
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
                reveal = 1
                slideTarget += 1
                slidePhase = slideTarget
            }
        }
        LoggedElsewhere.announce(DayCompareText.announcement(first: spokenDay(newFirst, now: now),
                                                             second: spokenDay(newSecond, now: now)))
    }

    // MARK: Chart

    private func chart(_ a: DayCompareDay, _ b: DayCompareDay, now: Date) -> some View {
        let day = { (d: Date?) in d.map { DayCompare.day($0, readings: readings, low: lowMgdl, high: highMgdl, now: now).runs } }
        return DayCompareChart(
            first: a.runs, second: b.runs,
            outgoingFirst: day(outgoingFirst), outgoingSecond: day(outgoingSecond),
            firstDirection: firstDirection, secondDirection: secondDirection,
            reveal: reveal, slidePhase: slidePhase, slideTarget: slideTarget,
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
        // The scale fits the days being compared, not the ones leaving.
        let values = (first + second).joined().map(\.mgdl)
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
        }
        .chartXScale(domain: 0...DayCompare.minutesPerDay)
        .chartYScale(domain: yDomain(values))
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
