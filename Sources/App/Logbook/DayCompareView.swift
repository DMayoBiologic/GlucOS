import Charts
import SwiftUI

/// Two Logbook days compared (`DayCompare`): both days' readings drawn over one midnight-to-midnight
/// chart on the target band, the first day as a solid line and the second dashed, so the two tell
/// apart without colour. Under the chart each day's time in range, average, lows and highs sit side
/// by side. The second day steps a day at a time with the chevrons beside its name.
///
/// Motion: the second day's line fades in when the comparison opens, and when it steps it fades out,
/// switches and fades back while the figures roll. Under Reduce Motion the line switches at once
/// and the figures cross-fade. Nothing loops.
///
/// VoiceOver reads the chart as one element naming both days, then one summary per day ("Today: 78%
/// in range, average 7.2 mmol/L, 1 low, 2 highs."), and hears "Comparing Today with Monday 11
/// November." when the second day changes. Shows what happened only: no day is called better.
struct DayCompareView: View {
    /// The day it was opened from.
    let first: Date
    let readings: [GlucoseReading]
    /// Days with enough readings to compare (`DayCompare.readingDays`), for the chevrons.
    let days: Set<Date>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var chartHeight: CGFloat = 180

    @State private var second: Date
    @State private var secondShown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let firstColor = Palette.brand
    static let secondColor = Palette.magenta

    init(first: Date, second: Date, readings: [GlucoseReading], days: Set<Date>, unit: GlucoseUnit,
         lowMgdl: Double, highMgdl: Double, chartHeight: CGFloat = 180) {
        self.first = Calendar.autoupdatingCurrent.startOfDay(for: first)
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
            chart(a, b)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayCompareText.chartSpoken(first: aName, second: bName, unit: unit,
                                                               low: lowMgdl, high: highMgdl))
            figures(a, b, aName: aName, bName: bName)
        }
        .onAppear {
            guard secondShown == 0 else { return }
            if reduceMotion { secondShown = 1 } else {
                withAnimation(DSMotion.ambient.animation.delay(0.1)) { secondShown = 1 }
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
                .accessibilityHidden(true)
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

    private func step(to target: Date?, now: Date) {
        guard let target else { return }
        #if os(iOS)
        Haptics.play(.choice)
        #endif
        let announce = { LoggedElsewhere.announce(DayCompareText.announcement(first: spokenDay(first, now: now),
                                                                              second: spokenDay(target, now: now))) }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { second = target }
            announce()
            return
        }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.12)) { secondShown = 0 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(DSMotion.standard.animation) { second = target }
            withAnimation(DSMotion.standard.animation.delay(0.05)) { secondShown = 1 }
            announce()
        }
    }

    // MARK: Chart

    private func yDomain(_ values: [Double]) -> ClosedRange<Double> {
        let all = values + [lowMgdl, highMgdl]
        let lo = min(all.min() ?? 60, 60) - 10
        let hi = max(all.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    private func chart(_ a: DayCompareDay, _ b: DayCompareDay) -> some View {
        let values = (a.runs + b.runs).joined().map(\.mgdl)
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

            runs(b.runs, key: "second", color: Self.secondColor.opacity(secondShown), dashed: true)
            runs(a.runs, key: "first", color: Self.firstColor, dashed: false)
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
        .frame(height: chartHeight)
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
                Text(value)
                    .dsFont(.body)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(minWidth: 72, alignment: .trailing)
    }

    private func dayTitle(_ d: Date) -> String { ClockLabel.dayTitle(ClockLabel.day(of: d, now: Date())) }
}
