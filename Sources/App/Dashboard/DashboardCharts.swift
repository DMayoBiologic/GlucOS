import SwiftUI
import Charts
import Accessibility

// MARK: - Trend chart (zoom, pan, scrub, select)

/// The dashboard's main chart. Hover to read any reading, drag across it to select a stretch and
/// see its numbers, pinch or use the zoom buttons to zoom, scroll sideways (or ⌥← ⌥→) to pan.
struct TrendChart: View {
    /// Oldest → newest, already limited to `domain`.
    let readings: [GlucoseReading]
    let domain: ClosedRange<Date>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// Logged insulin, food and site changes to mark on the chart.
    let events: [ChartEvent]
    /// The previous period on its own timestamps, drawn shifted forward by `comparisonShift`.
    let comparison: [GlucoseReading]
    let comparisonShift: TimeInterval
    /// The newest reading is too old to rely on: its marker goes grey and the time since is shaded.
    let latestIsStale: Bool
    /// When set, the period is live and a "now" line is drawn.
    let now: Date?

    @State private var visibleLength: TimeInterval
    @State private var scrollStart: Date
    @State private var hoverDate: Date?
    @State private var pinchBase: TimeInterval?
    @State private var selection: ClosedRange<Date>?

    @AppStorage("chartShowInsulin") private var showInsulin = true
    @AppStorage("chartShowFood") private var showFood = true
    @AppStorage("chartShowContext") private var showContext = true
    @AppStorage("chartShowSites") private var showSites = true
    @AppStorage("chartShowGaps") private var showGaps = true
    @AppStorage("chartComparePrevious") private var comparePrevious = false
    @AppStorage("chartShowOverviewStrip") private var showStrip = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let minimumVisible: TimeInterval = 30 * 60

    init(readings: [GlucoseReading], domain: ClosedRange<Date>, unit: GlucoseUnit, lowMgdl: Double, highMgdl: Double,
         events: [ChartEvent] = [], comparison: [GlucoseReading] = [], comparisonShift: TimeInterval = 0,
         latestIsStale: Bool = false, now: Date? = nil) {
        self.readings = readings
        self.events = events
        self.domain = domain
        self.unit = unit
        self.lowMgdl = lowMgdl
        self.highMgdl = highMgdl
        self.comparison = comparison
        self.comparisonShift = comparisonShift
        self.latestIsStale = latestIsStale
        self.now = now
        _visibleLength = State(initialValue: domain.upperBound.timeIntervalSince(domain.lowerBound))
        _scrollStart = State(initialValue: domain.lowerBound)
    }

    private var fullLength: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }
    private var visible: TimeInterval { min(max(visibleLength, Self.minimumVisible), fullLength) }
    private var isZoomed: Bool { visible < fullLength - 1 }
    private var viewStart: Date { isZoomed ? scrollStart : domain.lowerBound }
    private var viewEnd: Date { viewStart.addingTimeInterval(visible) }
    private var atLatest: Bool { viewEnd >= domain.upperBound.addingTimeInterval(-60) }
    private var atEarliest: Bool { viewStart <= domain.lowerBound.addingTimeInterval(60) }

    /// A selection long enough to mean something (a click without a drag selects nothing).
    private var activeSelection: ClosedRange<Date>? {
        guard let s = selection, s.upperBound.timeIntervalSince(s.lowerBound) >= 10 * 60 else { return nil }
        return s
    }

    private var visibleEvents: [ChartEvent] {
        events.filter { e in
            switch e.kind {
            case .bolus, .basal: return showInsulin
            case .food: return showFood
            case .context: return showContext
            case .siteChange: return showSites
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if let sel = activeSelection {
                SelectionSummary(range: sel, readings: readings, events: visibleEvents, unit: unit,
                                 lowMgdl: lowMgdl, highMgdl: highMgdl,
                                 onZoom: { zoomToSelection(sel) },
                                 onClear: { selection = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
            if isZoomed && showStrip {
                ChartOverviewStrip(readings: readings, domain: domain, unit: unit,
                                   window: viewStart...viewEnd, selection: activeSelection) { center in
                    scrollStart = clampStart(center.addingTimeInterval(-visible / 2), length: visible)
                }
                .frame(height: 40)
                .transition(.opacity)
            }
            legend
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: activeSelection != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isZoomed)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Text(visibleCaption)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel("Showing \(visibleCaption)")
            Spacer(minLength: 8)
            if isZoomed && !atLatest {
                Button("Latest") { scrollStart = domain.upperBound.addingTimeInterval(-visible) }
                    .help("Jump to the most recent readings in this period")
            }
            overlaysMenu
            ControlGroup {
                Button { pan(-0.5) } label: { Image(systemName: "chevron.left") }
                    .help("Pan earlier (⌥←)")
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    .disabled(!isZoomed || atEarliest)
                    .accessibilityLabel("Pan earlier")
                Button { zoom(to: visible * 2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)")
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!isZoomed)
                    .accessibilityLabel("Zoom out")
                Button { zoom(to: visible / 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)")
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(visible <= Self.minimumVisible)
                    .accessibilityLabel("Zoom in")
                Button { zoom(to: fullLength) } label: { Image(systemName: "arrow.left.and.right") }
                    .help("Show the whole period (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!isZoomed)
                    .accessibilityLabel("Show the whole period")
                Button { pan(0.5) } label: { Image(systemName: "chevron.right") }
                    .help("Pan later (⌥→)")
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                    .disabled(!isZoomed || atLatest)
                    .accessibilityLabel("Pan later")
            }
            .fixedSize()
        }
        // Full-size controls: these are the main way to move around the chart.
        .controlSize(.regular)
    }

    private var overlaysMenu: some View {
        Menu {
            Section("Logged") {
                Toggle("Insulin", isOn: $showInsulin)
                Toggle("Food", isOn: $showFood)
                Toggle("Context Tags", isOn: $showContext)
                Toggle("Site Changes", isOn: $showSites)
            }
            Section("Glucose") {
                Toggle("Compare with Previous Period", isOn: $comparePrevious)
                Toggle("Shade Gaps in Data", isOn: $showGaps)
                Toggle("Overview Strip When Zoomed", isOn: $showStrip)
            }
        } label: {
            Label("Overlays", systemImage: "square.3.layers.3d")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Choose what's drawn on the chart")
    }

    @ViewBuilder
    private var legend: some View {
        let kinds = Set(visibleEvents.map(\.kind))
        let comparing = comparePrevious && !comparison.isEmpty
        if !kinds.isEmpty || comparing {
            HStack(spacing: 14) {
                ChartEventLegend(kinds: kinds)
                if comparing {
                    HStack(spacing: 5) {
                        Capsule()
                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .frame(width: 18, height: 3)
                        Text("Previous period")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var visibleCaption: String {
        let style: Date.FormatStyle = fullLength > 86_400
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            : .dateTime.hour().minute()
        return "\(viewStart.formatted(style)) – \(viewEnd.formatted(style))"
    }

    // MARK: Zoom and pan

    private func clampStart(_ start: Date, length: TimeInterval) -> Date {
        max(domain.lowerBound, min(start, domain.upperBound.addingTimeInterval(-length)))
    }

    /// Zooms around the centre of what's on screen.
    private func zoom(to length: TimeInterval) {
        let newLength = min(max(length, Self.minimumVisible), fullLength)
        let center = viewStart.addingTimeInterval(visible / 2)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            visibleLength = newLength
            scrollStart = clampStart(center.addingTimeInterval(-newLength / 2), length: newLength)
        }
    }

    private func pan(_ fraction: Double) {
        guard isZoomed else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            scrollStart = clampStart(viewStart.addingTimeInterval(visible * fraction), length: visible)
        }
    }

    private func zoomToSelection(_ sel: ClosedRange<Date>) {
        let length = min(max(sel.upperBound.timeIntervalSince(sel.lowerBound), Self.minimumVisible), fullLength)
        let center = sel.lowerBound.addingTimeInterval(sel.upperBound.timeIntervalSince(sel.lowerBound) / 2)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            visibleLength = length
            scrollStart = clampStart(center.addingTimeInterval(-length / 2), length: length)
            selection = nil
        }
    }

    // MARK: Chart

    private var yDomain: ClosedRange<Double> {
        var values = readings.map(\.mgdl) + [lowMgdl, highMgdl]
        if comparePrevious { values += comparison.map(\.mgdl) }
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
        let maxGap = max(30 * 60, bucket * 3)
        let points = GlucoseAnalytics.plotPoints(readings, bucket: bucket, maxGap: maxGap)
        let ghost = comparePrevious ? GlucoseAnalytics.plotPoints(comparison, bucket: bucket, maxGap: maxGap) : []
        let hovered = hoverDate.flatMap {
            GlucoseAnalytics.nearest(to: $0, in: readings, tolerance: max(10 * 60, visible / 300))
        }
        let showOutliers = Double(points.count) * visible / fullLength < 900
        let multiDay = fullLength > 86_400

        // Insulin sits along the bottom of the chart, food along the top.
        let yd = yDomain
        let inset = (yd.upperBound - yd.lowerBound) * 0.045
        let shown = visibleEvents
        let inView = shown.filter { $0.date >= viewStart && $0.date <= viewEnd }
        // One threshold gradient per continuous run, since each run is its own series.
        let segmentStyles: [Int: LinearGradient] = Dictionary(grouping: points, by: \.segment).mapValues { run in
            ThresholdGradient.style(minMgdl: run.map(\.mgdl).min() ?? lowMgdl, maxMgdl: run.map(\.mgdl).max() ?? highMgdl,
                                    low: lowMgdl, high: highMgdl)
        }
        let fallbackStyle = ThresholdGradient.style(minMgdl: lowMgdl, maxMgdl: lowMgdl, low: lowMgdl, high: highMgdl)
        let hoveredEvents: [ChartEvent] = hoverDate.map { d in
            let tolerance = max(10 * 60, visible / 150)
            return shown.filter { abs($0.date.timeIntervalSince(d)) <= tolerance }
        } ?? []
        let change15: Double? = hovered.flatMap { h in
            GlucoseAnalytics.nearest(to: h.timestamp.addingTimeInterval(-15 * 60), in: readings, tolerance: 5 * 60)
                .map { h.mgdl - $0.mgdl }
        }
        let gaps = showGaps ? GlucoseAnalytics.gaps(readings, longerThan: 30 * 60) : []
        let trailingGap: GapSpan? = {
            guard latestIsStale, let now, let last = readings.last, now > last.timestamp else { return nil }
            return GapSpan(start: last.timestamp, end: min(now, domain.upperBound))
        }()

        return Chart {
            TargetBandMarks(unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
            GapMarks(gaps: gaps, trailing: trailingGap)
            if let sel = activeSelection { SelectionMarks(range: sel) }
            ComparisonMarks(points: ghost, unit: unit, shift: comparisonShift)
            TraceMarks(points: points, unit: unit, styles: segmentStyles, fallback: fallbackStyle,
                       outliers: showOutliers ? points.filter { $0.mgdl < lowMgdl || $0.mgdl > highMgdl } : [],
                       lowMgdl: lowMgdl, highMgdl: highMgdl)
            EventMarks(events: shown, insulinY: yd.lowerBound + inset, foodY: yd.upperBound - inset,
                       showLabels: inView.count <= 40)
            if let now { NowMarks(date: now) }
            if let last = readings.last {
                LatestMarks(reading: last, unit: unit, color: latestIsStale ? Palette.stale : color(last.mgdl))
            }
            if let h = hovered {
                HoverMarks(reading: h, unit: unit, color: color(h.mgdl),
                           range: GlucoseRange.classify(mgdl: h.mgdl, low: lowMgdl, high: highMgdl),
                           showDate: multiDay, events: hoveredEvents, change15: change15)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yd)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visible)
        .chartScrollPosition(x: $scrollStart)
        .chartXSelection(value: $hoverDate)
        .chartXSelection(range: $selection)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
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
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(String(format: "%.0f", d)).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityLabel("Glucose chart")
        .accessibilityChartDescriptor(GlucoseChartDescriptor(points: points, domain: domain, yDomain: yd, unit: unit,
                                                             lowMgdl: lowMgdl, highMgdl: highMgdl))
        .help("Hover to read a reading. Drag across the chart to select a stretch. Pinch or use the zoom buttons to zoom, scroll sideways to pan.")
    }
}

// MARK: Chart layers

private struct TargetBandMarks: ChartContent {
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    var body: some ChartContent {
        RectangleMark(
            yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
            yEnd: .value("High", unit.value(fromMgdl: highMgdl))
        )
        .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.09))
        RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))
        RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))
    }
}

/// A stretch with no readings.
struct GapSpan: Identifiable, Hashable {
    let start: Date
    let end: Date
    var id: Date { start }
}

/// Faint shading over gaps, and a grey "no new data" block from the last reading to now when
/// the data is stale, so missing time never looks like a flat, calm line.
private struct GapMarks: ChartContent {
    let gaps: [GapSpan]
    let trailing: GapSpan?

    var body: some ChartContent {
        ForEach(gaps) { g in
            RectangleMark(xStart: .value("Gap start", g.start), xEnd: .value("Gap end", g.end))
                .foregroundStyle(Color.primary.opacity(0.045))
        }
        if let t = trailing {
            RectangleMark(xStart: .value("Stale from", t.start), xEnd: .value("Stale to", t.end))
                .foregroundStyle(Palette.stale.opacity(0.16))
                .annotation(position: .overlay, alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("No new readings since \(t.start.formatted(date: .omitted, time: .shortened))")
                        .accessibilityLabel("No new readings since \(t.start.formatted(date: .omitted, time: .shortened))")
                }
        }
    }
}

private struct SelectionMarks: ChartContent {
    let range: ClosedRange<Date>

    var body: some ChartContent {
        RectangleMark(xStart: .value("Selection start", range.lowerBound), xEnd: .value("Selection end", range.upperBound))
            .foregroundStyle(Palette.brand.opacity(0.12))
        RuleMark(x: .value("Selection start", range.lowerBound))
            .foregroundStyle(Palette.brand.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1))
        RuleMark(x: .value("Selection end", range.upperBound))
            .foregroundStyle(Palette.brand.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }
}

/// The previous period, moved forward onto this one's axis, as a dashed grey line.
private struct ComparisonMarks: ChartContent {
    let points: [PlotPoint]
    let unit: GlucoseUnit
    let shift: TimeInterval

    var body: some ChartContent {
        ForEach(points) { p in
            LineMark(
                x: .value("Time", p.date.addingTimeInterval(shift)),
                y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                series: .value("Segment", -1 - p.segment)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Color.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
        }
    }
}

private struct TraceMarks: ChartContent {
    let points: [PlotPoint]
    let unit: GlucoseUnit
    let styles: [Int: LinearGradient]
    let fallback: LinearGradient
    let outliers: [PlotPoint]
    let lowMgdl: Double
    let highMgdl: Double

    var body: some ChartContent {
        ForEach(points) { p in
            LineMark(
                x: .value("Time", p.date),
                y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                series: .value("Segment", p.segment)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(styles[p.segment] ?? fallback)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        ForEach(outliers) { p in
            PointMark(
                x: .value("Time", p.date),
                y: .value("Glucose", unit.value(fromMgdl: p.mgdl))
            )
            .symbolSize(14)
            .foregroundStyle(GlucoseRange.classify(mgdl: p.mgdl, low: lowMgdl, high: highMgdl).color)
        }
    }
}

private struct EventMarks: ChartContent {
    let events: [ChartEvent]
    let insulinY: Double
    let foodY: Double
    let showLabels: Bool

    var body: some ChartContent {
        let insulin = events.filter { $0.kind == .bolus || $0.kind == .basal }
        let food = events.filter { $0.kind == .food || $0.kind == .context }
        let siteChanges = events.filter { $0.kind == .siteChange }
        ForEach(siteChanges) { e in
            RuleMark(x: .value("Time", e.date))
                .foregroundStyle(ChartEvent.Kind.siteChange.color.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        ForEach(insulin) { e in
            PointMark(x: .value("Time", e.date), y: .value("Glucose", insulinY))
                .symbol(.triangle)
                .symbolSize(70)
                .foregroundStyle(e.kind.color)
                .annotation(position: .top, spacing: 2) {
                    if showLabels {
                        Text(e.label).font(.caption2.weight(.semibold)).foregroundStyle(e.kind.color)
                    }
                }
        }
        ForEach(food) { e in
            PointMark(x: .value("Time", e.date), y: .value("Glucose", foodY))
                .symbol(e.kind == .context ? BasicChartSymbolShape.diamond : BasicChartSymbolShape.circle)
                .symbolSize(60)
                .foregroundStyle(e.kind.color)
                .annotation(position: .bottom, spacing: 2) {
                    if showLabels {
                        Text(e.label).font(.caption2.weight(.semibold)).foregroundStyle(e.kind.color)
                    }
                }
        }
    }
}

private struct NowMarks: ChartContent {
    let date: Date

    var body: some ChartContent {
        RuleMark(x: .value("Now", date))
            .foregroundStyle(Color.secondary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }
}

/// The newest reading, ringed. Grey when stale.
private struct LatestMarks: ChartContent {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let color: Color

    var body: some ChartContent {
        PointMark(x: .value("Time", reading.timestamp), y: .value("Glucose", unit.value(fromMgdl: reading.mgdl)))
            .symbolSize(160)
            .foregroundStyle(color.opacity(0.22))
        PointMark(x: .value("Time", reading.timestamp), y: .value("Glucose", unit.value(fromMgdl: reading.mgdl)))
            .symbolSize(80)
            .foregroundStyle(.white)
        PointMark(x: .value("Time", reading.timestamp), y: .value("Glucose", unit.value(fromMgdl: reading.mgdl)))
            .symbolSize(40)
            .foregroundStyle(color)
    }
}

private struct HoverMarks: ChartContent {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let color: Color
    let range: GlucoseRange
    let showDate: Bool
    let events: [ChartEvent]
    let change15: Double?

    var body: some ChartContent {
        RuleMark(x: .value("Time", reading.timestamp))
            .foregroundStyle(Color.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1))
        PointMark(x: .value("Time", reading.timestamp), y: .value("Glucose", unit.value(fromMgdl: reading.mgdl)))
            .symbolSize(70)
            .foregroundStyle(color)
            .annotation(position: .top, spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                ReadingCallout(reading: reading, unit: unit, range: range,
                               showDate: showDate, events: events, change15: change15)
            }
    }
}

// MARK: - Selection summary

/// The numbers for a stretch dragged out on the chart.
private struct SelectionSummary: View {
    let range: ClosedRange<Date>
    let readings: [GlucoseReading]
    let events: [ChartEvent]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let onZoom: () -> Void
    let onClear: () -> Void

    var body: some View {
        let rs = GlucoseAnalytics.slice(readings, from: range.lowerBound, to: range.upperBound)
        let stats = GlucoseStats.compute(rs, low: lowMgdl, high: highMgdl)
        let inSel = events.filter { range.contains($0.date) }
        let sameDay = Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound)
        let startText = sameDay ? range.lowerBound.formatted(date: .omitted, time: .shortened)
                                : range.lowerBound.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
        let endText = sameDay ? range.upperBound.formatted(date: .omitted, time: .shortened)
                              : range.upperBound.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(startText) – \(endText)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(LogFormat.duration(range.upperBound.timeIntervalSince(range.lowerBound)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stats, let first = rs.first, let last = rs.last {
                Divider().frame(height: 28)
                item("Average", unit.format(mgdl: stats.meanMgdl))
                item("In range", Format.percent(stats.timeInRange), tint: GlucoseRange.inRange.tint)
                item("Low – High", "\(unit.format(mgdl: stats.minMgdl))–\(unit.format(mgdl: stats.maxMgdl))")
                item("Change", unit.formatDelta(mgdl: last.mgdl - first.mgdl))
                if !inSel.isEmpty {
                    item("Logged", inSel.count == 1 ? "1 entry" : "\(inSel.count) entries")
                }
            } else {
                Text("No readings in this stretch").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Zoom to Selection", action: onZoom)
            Button(action: onClear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Clear the selection (Esc)")
                .accessibilityLabel("Clear selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.brand.opacity(0.25), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected stretch")
    }

    private func item(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overview strip

/// The whole period in miniature, under a zoomed chart, with the visible window highlighted.
/// Click or drag on it to move the window.
private struct ChartOverviewStrip: View {
    let readings: [GlucoseReading]
    let domain: ClosedRange<Date>
    let unit: GlucoseUnit
    let window: ClosedRange<Date>
    let selection: ClosedRange<Date>?
    let onCenter: (Date) -> Void

    var body: some View {
        let full = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let points = GlucoseAnalytics.plotPoints(readings, bucket: max(HistoryArchive.slot, full / 400), maxGap: max(30 * 60, full / 100))
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                         series: .value("Segment", p.segment))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let selection {
                RectangleMark(xStart: .value("Start", selection.lowerBound), xEnd: .value("End", selection.upperBound))
                    .foregroundStyle(Palette.brand.opacity(0.12))
            }
            RectangleMark(xStart: .value("Start", window.lowerBound), xEnd: .value("End", window.upperBound))
                .foregroundStyle(Palette.brand.opacity(0.18))
                .cornerRadius(3)
        }
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame else { return }
                                let x = value.location.x - geo[plot].origin.x
                                if let date: Date = proxy.value(atX: x) { onCenter(date) }
                            }
                    )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("The whole period. Click or drag to move the zoomed view.")
        .accessibilityHidden(true)
    }
}

// MARK: - Callout

/// Floating readout for a hovered reading.
struct ReadingCallout: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let range: GlucoseRange
    var showDate: Bool = false
    var events: [ChartEvent] = []
    /// Change from the reading 15 minutes earlier, in mg/dL.
    var change15: Double?

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
            if let change15 {
                Text("\(unit.formatDelta(mgdl: change15)) in 15 min")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { e in
                HStack(spacing: 4) {
                    Image(systemName: e.kind.systemImage).foregroundStyle(e.kind.color)
                    Text(e.detail)
                    Text(e.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(range.color.opacity(0.35), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - VoiceOver

/// Lets VoiceOver describe the chart and play it as an audio graph.
struct GlucoseChartDescriptor: AXChartDescriptorRepresentable {
    let points: [PlotPoint]
    let domain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        // Audio graphs don't need every point; a few hundred keeps navigation quick.
        let step = max(1, points.count / 300)
        let sampled = stride(from: 0, to: points.count, by: step).map { points[$0] }
        let unit = self.unit
        let x = AXNumericDataAxisDescriptor(
            title: "Time",
            range: domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        let y = AXNumericDataAxisDescriptor(
            title: "Glucose (\(unit.spokenLabel))",
            range: yDomain,
            gridlinePositions: [unit.value(fromMgdl: lowMgdl), unit.value(fromMgdl: highMgdl)]
        ) { value in
            unit == .mmol ? String(format: "%.1f", value) : String(format: "%.0f", value)
        }
        let series = AXDataSeriesDescriptor(
            name: "Glucose",
            isContinuous: true,
            dataPoints: sampled.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl)) }
        )
        let values = points.map(\.mgdl)
        var summary = "Target \(unit.format(mgdl: lowMgdl)) to \(unit.format(mgdl: highMgdl)) \(unit.spokenLabel)."
        if let lo = values.min(), let hi = values.max() {
            summary += " Ranges from \(unit.format(mgdl: lo)) to \(unit.format(mgdl: hi))."
        }
        return AXChartDescriptor(title: "Glucose", summary: summary, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

extension GlucoseAnalytics {
    /// Stretches longer than `minimum` with no reading. `sorted` must be oldest → newest.
    static func gaps(_ sorted: [GlucoseReading], longerThan minimum: TimeInterval) -> [GapSpan] {
        guard sorted.count > 1 else { return [] }
        var out: [GapSpan] = []
        for i in 1..<sorted.count {
            let a = sorted[i - 1].timestamp, b = sorted[i].timestamp
            if b.timeIntervalSince(a) > minimum { out.append(GapSpan(start: a, end: b)) }
        }
        return out
    }
}

// MARK: - Logged events on the chart

/// A logged dose, meal or site change, ready to plot.
struct ChartEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case bolus, basal, food, siteChange, context

        var color: Color {
            switch self {
            case .bolus: return .blue
            case .basal: return .indigo
            case .food: return .orange
            case .siteChange: return .purple
            case .context: return .teal
            }
        }

        var systemImage: String {
            switch self {
            case .bolus, .basal: return "syringe"
            case .food: return "fork.knife"
            case .siteChange: return "arrow.triangle.2.circlepath"
            case .context: return "tag"
            }
        }

        var title: String {
            switch self {
            case .bolus: return "Bolus insulin"
            case .basal: return "Long-acting insulin"
            case .food: return "Food"
            case .siteChange: return "Site change"
            case .context: return "Context"
            }
        }
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Short text on the chart, e.g. "4u" or "45g".
    let label: String
    /// Longer text for the hover callout.
    let detail: String
}

struct ChartEventLegend: View {
    let kinds: Set<ChartEvent.Kind>

    var body: some View {
        HStack(spacing: 14) {
            ForEach([ChartEvent.Kind.bolus, .basal, .food, .siteChange, .context].filter { kinds.contains($0) }, id: \.self) { k in
                Label(k.title, systemImage: k.systemImage)
                    .foregroundStyle(k.color)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
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
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.09))

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
            "5–95%": Palette.brand.opacity(0.14),
            "25–75%": Palette.brand.opacity(0.32),
            "Median": Palette.brand,
        ])
        .chartXScale(domain: reference...reference.addingTimeInterval(86_400))
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $hoverDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
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
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.09))
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
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
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
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
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
