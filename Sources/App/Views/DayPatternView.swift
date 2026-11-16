import SwiftUI
import Charts
import Accessibility

/// The Insights "Your usual day" card on the Mac and iPhone: each time of day over the last 14 or
/// 30 days, as a middle line with the middle half and 8 in 10 readings shaded round it (an AGP).
/// The pattern is worked out off the main thread once per data change (`DayPatternCache`) and drawn
/// as a still picture: nothing on it animates. Callers give it their own card surface.
struct DayPatternView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @AppStorage("insights.dayPatternDays") private var windowDays = DayPattern.Window.fortnight.rawValue
    @State private var pattern: DayPattern?
    @State private var shownKey: DayPatternCache.Key?

    private var window: DayPattern.Window { DayPattern.Window(rawValue: windowDays) ?? .fortnight }
    private var key: DayPatternCache.Key { DayPatternCache.key(readings: readings, window: window) }

    var body: some View {
        let key = self.key
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: DayPatternText.title, systemImage: "clock", trailing: "Time of day")
            Picker("Period", selection: $windowDays) {
                ForEach(DayPattern.Window.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Period")

            if let pattern, shownKey?.window == window {
                DayPatternChart(pattern: pattern, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
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
                Text(DayPatternText.emptyLine(window))
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                pattern = await DayPatternCache.shared.pattern(for: key, readings: readings)
            }
            shownKey = key
        }
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

/// The chart itself: the target band, the two percentile bands and the middle line, coloured by
/// range the same way as the glucose trace (`ThresholdGradient`).
private struct DayPatternChart: View {
    let pattern: DayPattern
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @Environment(\.colorSchemeContrast) private var contrast

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
        for s in pattern.slots {
            if let s { run.append(Point(x: s.midMinute, slot: s)) } else if !run.isEmpty { out.append(run); run = [] }
        }
        if !run.isEmpty { out.append(run) }
        if let first = pattern.slots.first.flatMap({ $0 }), let last = pattern.slots.last.flatMap({ $0 }),
           !out.isEmpty {
            let mid = DayPattern.Slot(minute: 0, p10: (first.p10 + last.p10) / 2, p25: (first.p25 + last.p25) / 2,
                                      p50: (first.p50 + last.p50) / 2, p75: (first.p75 + last.p75) / 2,
                                      p90: (first.p90 + last.p90) / 2, count: 0)
            out[0].insert(Point(x: 0, slot: mid), at: 0)
            out[out.count - 1].append(Point(x: 1440, slot: mid))
        }
        return out
    }

    private var yDomainMgdl: ClosedRange<Double> {
        let f = pattern.filled
        let lo = min(f.map(\.p10).min() ?? 60, lowMgdl, 60) - 10
        let hi = max(f.map(\.p90).max() ?? 200, highMgdl, 200) + 10
        return lo...hi
    }

    private func v(_ mgdl: Double) -> Double { unit.value(fromMgdl: mgdl) }

    private func gradient(_ lo: Double?, _ hi: Double?) -> LinearGradient {
        ThresholdGradient.style(minMgdl: lo ?? lowMgdl, maxMgdl: hi ?? highMgdl, low: lowMgdl, high: highMgdl)
    }

    var body: some View {
        let f = pattern.filled
        let segments = self.segments
        let strong = contrast == .increased
        let outer = gradient(f.map(\.p10).min(), f.map(\.p90).max())
        let inner = gradient(f.map(\.p25).min(), f.map(\.p75).max())
        let line = gradient(f.map(\.p50).min(), f.map(\.p50).max())
        let yd = yDomainMgdl
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usual day chart")
        .accessibilityValue(DayPatternText.spoken(pattern, unit: unit, low: lowMgdl, high: highMgdl))
        .accessibilityChartDescriptor(DayPatternAudioGraph(pattern: pattern, unit: unit, lowMgdl: lowMgdl,
                                                           highMgdl: highMgdl,
                                                           yDomain: v(yd.lowerBound)...v(yd.upperBound)))
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
