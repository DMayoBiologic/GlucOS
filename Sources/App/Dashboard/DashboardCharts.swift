import SwiftUI
import Charts

// MARK: - Trend chart (zoom, pan, hover)

/// The dashboard's main chart. Pinch or use the zoom buttons to zoom, scroll sideways to pan,
/// hover to read any individual reading.
struct TrendChart: View {
    /// Oldest → newest, already limited to `domain`.
    let readings: [GlucoseReading]
    let domain: ClosedRange<Date>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @State private var visibleLength: TimeInterval
    @State private var scrollStart: Date
    @State private var hoverDate: Date?
    @State private var pinchBase: TimeInterval?

    static let minimumVisible: TimeInterval = 30 * 60

    init(readings: [GlucoseReading], domain: ClosedRange<Date>, unit: GlucoseUnit, lowMgdl: Double, highMgdl: Double) {
        self.readings = readings
        self.domain = domain
        self.unit = unit
        self.lowMgdl = lowMgdl
        self.highMgdl = highMgdl
        _visibleLength = State(initialValue: domain.upperBound.timeIntervalSince(domain.lowerBound))
        _scrollStart = State(initialValue: domain.lowerBound)
    }

    private var fullLength: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }
    private var visible: TimeInterval { min(max(visibleLength, Self.minimumVisible), fullLength) }
    private var isZoomed: Bool { visible < fullLength - 1 }
    private var atLatest: Bool { scrollStart.addingTimeInterval(visible) >= domain.upperBound.addingTimeInterval(-60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            chart
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = pinchBase ?? visible
                            pinchBase = base
                            zoom(to: base / max(0.1, value.magnification))
                        }
                        .onEnded { _ in pinchBase = nil }
                )
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text(visibleCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if isZoomed && !atLatest {
                Button("Latest") { scrollStart = domain.upperBound.addingTimeInterval(-visible) }
                    .controlSize(.small)
                    .help("Jump to the most recent readings")
            }
            ControlGroup {
                Button { zoom(to: visible * 2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)")
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!isZoomed)
                Button { zoom(to: visible / 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)")
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(visible <= Self.minimumVisible)
                Button { zoom(to: fullLength) } label: { Image(systemName: "arrow.left.and.right") }
                    .help("Show the whole range (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!isZoomed)
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var visibleCaption: String {
        let end = isZoomed ? scrollStart.addingTimeInterval(visible) : domain.upperBound
        let start = isZoomed ? scrollStart : domain.lowerBound
        let style: Date.FormatStyle = fullLength > 86_400
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            : .dateTime.hour().minute()
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    /// Zooms around the centre of what's on screen.
    private func zoom(to length: TimeInterval) {
        let newLength = min(max(length, Self.minimumVisible), fullLength)
        let center = scrollStart.addingTimeInterval(visible / 2)
        var start = center.addingTimeInterval(-newLength / 2)
        start = max(domain.lowerBound, min(start, domain.upperBound.addingTimeInterval(-newLength)))
        visibleLength = newLength
        scrollStart = start
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.map(\.mgdl) + [lowMgdl, highMgdl]
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    private func color(_ mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    private var chart: some View {
        let visible = self.visible
        // Roughly a point per pixel on screen, and never more than a few thousand overall.
        let bucket = max(visible / 700, fullLength / 3000)
        let points = GlucoseAnalytics.plotPoints(readings, bucket: bucket, maxGap: max(30 * 60, bucket * 3))
        let hovered = hoverDate.flatMap {
            GlucoseAnalytics.nearest(to: $0, in: readings, tolerance: max(10 * 60, visible / 300))
        }
        let showOutliers = Double(points.count) * visible / fullLength < 900
        let multiDay = fullLength > 86_400

        return Chart {
            RectangleMark(
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(Color.green.opacity(0.10))
            RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Color.green.opacity(0.5))
            RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Color.green.opacity(0.5))

            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                    series: .value("Segment", p.segment)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if showOutliers {
                ForEach(points.filter { $0.mgdl < lowMgdl || $0.mgdl > highMgdl }) { p in
                    PointMark(
                        x: .value("Time", p.date),
                        y: .value("Glucose", unit.value(fromMgdl: p.mgdl))
                    )
                    .symbolSize(14)
                    .foregroundStyle(color(p.mgdl))
                }
            }

            if let last = readings.last {
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.value(fromMgdl: last.mgdl)))
                    .symbolSize(160)
                    .foregroundStyle(color(last.mgdl).opacity(0.22))
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.value(fromMgdl: last.mgdl)))
                    .symbolSize(40)
                    .foregroundStyle(color(last.mgdl))
            }

            if let h = hovered {
                RuleMark(x: .value("Time", h.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", h.timestamp), y: .value("Glucose", unit.value(fromMgdl: h.mgdl)))
                    .symbolSize(70)
                    .foregroundStyle(color(h.mgdl))
                    .annotation(position: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReadingCallout(reading: h, unit: unit, range: GlucoseRange.classify(mgdl: h.mgdl, low: lowMgdl, high: highMgdl),
                                       showDate: multiDay)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visible)
        .chartScrollPosition(x: $scrollStart)
        .chartXSelection(value: $hoverDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                if visible > 36 * 3600 {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(String(format: "%.0f", d)).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityLabel("Glucose chart")
        .help("Hover to read a reading. Pinch or use the zoom buttons to zoom, scroll sideways to pan.")
    }
}

/// Floating readout for a hovered reading.
struct ReadingCallout: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let range: GlucoseRange
    var showDate: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(range.color).frame(width: 7, height: 7)
                Text(unit.format(mgdl: reading.mgdl, withUnit: true))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if reading.trend != .unknown {
                    TrendSymbol(trend: reading.trend).font(.caption)
                }
            }
            Text(showDate
                 ? reading.timestamp.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                 : reading.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Daily pattern (AGP)

struct PatternChart: View {
    let bins: [PatternBin]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @State private var hoverDate: Date?

    let reference = Calendar.current.startOfDay(for: Date())
    private func x(_ minute: Int) -> Date { reference.addingTimeInterval(Double(minute) * 60) }
    private func y(_ mgdl: Double) -> Double { unit.value(fromMgdl: mgdl) }

    static let binMinutes = 30

    /// Bins plotted at their midpoint. When the profile covers the whole day, it is closed at
    /// midnight with the average of the last and first bins, so it spans the full axis without
    /// drawing outside it.
    private var plotted: [(x: Date, bin: PatternBin)] {
        let w = Self.binMinutes
        var out = bins.map { (x: x($0.minute + w / 2), bin: $0) }
        if let first = bins.first, let last = bins.last, first.minute == 0, last.minute == 24 * 60 - w {
            let mid = { (a: Double, b: Double) in (a + b) / 2 }
            let edge = PatternBin(minute: 0,
                                  p5: mid(first.p5, last.p5), p25: mid(first.p25, last.p25), p50: mid(first.p50, last.p50),
                                  p75: mid(first.p75, last.p75), p95: mid(first.p95, last.p95),
                                  count: first.count + last.count)
            out.insert((x: x(0), bin: edge), at: 0)
            out.append((x: x(24 * 60), bin: edge))
        }
        return out
    }

    private var yDomain: ClosedRange<Double> {
        let values = bins.flatMap { [$0.p5, $0.p95] } + [lowMgdl, highMgdl]
        return y(min(values.min() ?? 60, 60) - 10)...y(max(values.max() ?? 200, 200) + 10)
    }

    var body: some View {
        let plotted = self.plotted
        let hovered: PatternBin? = hoverDate.flatMap { d in
            let minute = Int(d.timeIntervalSince(reference) / 60)
            return bins.last { $0.minute <= minute }
        }
        Chart {
            RectangleMark(yStart: .value("Low", y(lowMgdl)), yEnd: .value("High", y(highMgdl)))
                .foregroundStyle(Color.green.opacity(0.10))

            ForEach(plotted.indices, id: \.self) { i in
                AreaMark(x: .value("Time", plotted[i].x),
                         yStart: .value("5th", y(plotted[i].bin.p5)),
                         yEnd: .value("95th", y(plotted[i].bin.p95)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Band", "5–95%"))
            }
            ForEach(plotted.indices, id: \.self) { i in
                AreaMark(x: .value("Time", plotted[i].x),
                         yStart: .value("25th", y(plotted[i].bin.p25)),
                         yEnd: .value("75th", y(plotted[i].bin.p75)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Band", "25–75%"))
            }
            ForEach(plotted.indices, id: \.self) { i in
                LineMark(x: .value("Time", plotted[i].x), y: .value("Median", y(plotted[i].bin.p50)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Band", "Median"))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            if let h = hovered {
                RuleMark(x: .value("Time", x(h.minute + Self.binMinutes / 2)))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(x(h.minute).formatted(date: .omitted, time: .shortened))–\(x(h.minute + Self.binMinutes).formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Median \(unit.format(mgdl: h.p50, withUnit: true))")
                                .font(.callout.weight(.semibold)).monospacedDigit()
                            Text("Middle 50%: \(unit.format(mgdl: h.p25))–\(unit.format(mgdl: h.p75))")
                                .font(.caption).monospacedDigit()
                            Text("\(h.count) readings").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }
        }
        .chartForegroundStyleScale([
            "5–95%": Color.accentColor.opacity(0.14),
            "25–75%": Color.accentColor.opacity(0.32),
            "Median": Color.accentColor,
        ])
        .chartXScale(domain: reference...reference.addingTimeInterval(86_400))
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $hoverDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .accessibilityLabel("Glucose by time of day")
    }
}

// MARK: - Day overlay

struct OverlayPoint: Identifiable {
    let id: Int
    let x: Date            // on the reference day
    let mgdl: Double
    let series: String     // day + segment, so lines break over gaps
    let day: String
}

struct OverlayChart: View {
    let points: [OverlayPoint]
    let dayLabels: [String]   // oldest → newest
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let reference: Date

    private func y(_ mgdl: Double) -> Double { unit.value(fromMgdl: mgdl) }

    var body: some View {
        let values = points.map(\.mgdl) + [lowMgdl, highMgdl]
        let yDomain = y(min(values.min() ?? 60, 60) - 10)...y(max(values.max() ?? 200, 200) + 10)
        Chart {
            RectangleMark(yStart: .value("Low", y(lowMgdl)), yEnd: .value("High", y(highMgdl)))
                .foregroundStyle(Color.green.opacity(0.10))
            ForEach(points) { p in
                LineMark(x: .value("Time", p.x), y: .value("Glucose", y(p.mgdl)), series: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Day", p.day))
                    .lineStyle(StrokeStyle(lineWidth: p.day == dayLabels.last ? 2.5 : 1.5, lineCap: .round))
            }
        }
        .chartForegroundStyleScale(domain: dayLabels)
        .chartXScale(domain: reference...reference.addingTimeInterval(86_400))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .accessibilityLabel("Each day overlaid by time of day")
    }
}

// MARK: - Daily time in range bars

struct DailyRangeChart: View {
    let days: [DaySummary]   // any order

    private struct Bar: Identifiable {
        let id: String
        let day: Date
        let label: String
        let fraction: Double
    }

    private var bars: [Bar] {
        days.flatMap { d in
            d.breakdown.rows.reversed().map { row in
                Bar(id: "\(d.day.timeIntervalSince1970)-\(row.range.label)", day: d.day,
                    label: row.range.label, fraction: row.fraction)
            }
        }
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(x: .value("Day", b.day, unit: .day), y: .value("Share", b.fraction))
                .foregroundStyle(by: .value("Range", b.label))
        }
        .chartForegroundStyleScale([
            GlucoseRange.urgentLow.label: GlucoseRange.urgentLow.reportColor,
            GlucoseRange.low.label: GlucoseRange.low.reportColor,
            GlucoseRange.inRange.label: GlucoseRange.inRange.reportColor,
            GlucoseRange.high.label: GlucoseRange.high.reportColor,
            GlucoseRange.veryHigh.label: GlucoseRange.veryHigh.reportColor,
        ])
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 0.25, 0.5, 0.75, 1]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(Format.percent(d)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: days.count > 14 ? AxisMarkValues.automatic(desiredCount: 10) : AxisMarkValues.stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).day(), centered: true)
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .accessibilityLabel("Time in range by day")
    }
}
