import SwiftUI
import Charts

/// Line chart of readings with the target band shaded. Compiled into both the app and the widget.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var hours: Double = 12
    var showAxes: Bool = true
    /// Hover to inspect a reading (app only; widgets aren't interactive).
    var interactive: Bool = false
    /// A reading to highlight as if hovered, e.g. while stepping through readings with the arrow
    /// keys. The pointer wins while it's over the chart.
    var pinnedDate: Date? = nil
    /// Whether the newest reading is old. Its dot and the glow under the trace go neutral grey, so
    /// a stale value is never drawn in a reassuring colour. `nil` (the default) works it out from
    /// the newest reading's age, with the same threshold as `GlucoseSnapshot.isStale`. Pass `false`
    /// only when showing a past period on purpose.
    var latestIsStale: Bool? = nil
    /// An estimate of where glucose may go next, drawn as a dashed grey line with its likely
    /// range, never in a reading's colour. Pass only a current forecast (`OutlookSnapshot.isCurrent`);
    /// it's hidden anyway while the newest reading is stale.
    var forecast: [ForecastSample] = []
    /// Logged doses and food, drawn as small markers along the bottom of the chart.
    var events: [ChartLogMarker] = []
    /// How many time labels to aim for along the bottom.
    var timeLabelCount: Int = 4
    /// A faint "Now" line where readings end and the forecast begins.
    var marksNow: Bool = false

    @State private var hoverDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The real reading nearest the pointer. Only actual readings are ever shown, never an
    /// interpolated value between two of them. Over a gap in the data (sensor warm-up, phone out
    /// of signal) nothing is shown, rather than a reading from well before or after the pointer.
    private func nearest(to date: Date?, in window: [GlucoseReading]) -> GlucoseReading? {
        guard let date else { return nil }
        let distance = { (r: GlucoseReading) in abs(r.timestamp.timeIntervalSince(date)) }
        guard let best = window.min(by: { distance($0) < distance($1) }), distance(best) <= 10 * 60 else { return nil }
        return best
    }

    private var window: [GlucoseReading] {
        guard let last = readings.last else { return [] }
        let cutoff = last.timestamp.addingTimeInterval(-hours * 3600)
        return readings.filter { $0.timestamp >= cutoff }
    }

    private var yDomainMgdl: ClosedRange<Double> {
        let values = window.map(\.mgdl) + [lowMgdl, highMgdl] + forecast.map(\.mgdl)
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return lo...hi
    }

    private var yDomain: ClosedRange<Double> {
        unit.value(fromMgdl: yDomainMgdl.lowerBound)...unit.value(fromMgdl: yDomainMgdl.upperBound)
    }

    private func color(for mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    var body: some View {
        let window = self.window
        let floor = yDomain.lowerBound
        let hovered = interactive ? nearest(to: hoverDate ?? pinnedDate, in: window) : nil
        let lineStyle = ThresholdGradient.style(minMgdl: window.map(\.mgdl).min() ?? lowMgdl,
                                                maxMgdl: window.map(\.mgdl).max() ?? highMgdl,
                                                low: lowMgdl, high: highMgdl)
        let stale = latestIsStale
            ?? (window.last.map { Date().timeIntervalSince($0.timestamp) > GlucoseSnapshot.staleAfter } ?? true)
        let currentTint = stale ? Palette.stale : (window.last.map { color(for: $0.mgdl) } ?? Palette.stale)
        let projection = stale ? [] : forecast
        let yd = yDomain
        Chart {
            // Target band, with hairline edges so it still reads in Increase Contrast.
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

            // Soft glow under the trace, tinted with the current range.
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [currentTint.opacity(0.28), currentTint.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }

            // Time spent out of range, filled between the trace and the line it crossed, so a
            // high or a low reads as a shape before anyone looks at the numbers.
            outOfRangeMarks(window)

            // The trace changes colour as it crosses the thresholds.
            ForEach(window) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(lineStyle)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            // The forecast: a neutral band and dashed line, so it can't be mistaken for readings.
            ForEach(projection) { p in
                AreaMark(
                    x: .value("Time", p.date),
                    yStart: .value("Forecast low", min(max(unit.value(fromMgdl: p.lowerMgdl), yd.lowerBound), yd.upperBound)),
                    yEnd: .value("Forecast high", min(max(unit.value(fromMgdl: p.upperMgdl), yd.lowerBound), yd.upperBound)),
                    series: .value("Series", "Forecast range")
                )
                .interpolationMethod(.monotone)
                // Fades as it reaches further ahead: the further out, the less it should be trusted.
                .foregroundStyle(
                    LinearGradient(colors: [Palette.stale.opacity(0.30), Palette.stale.opacity(0.08)],
                                   startPoint: .leading, endPoint: .trailing)
                )
            }
            ForEach(projection) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Forecast", unit.value(fromMgdl: p.mgdl)),
                    series: .value("Series", "Forecast")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Palette.stale)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
            }

            nowMark(last: projection.isEmpty ? nil : window.last)
            midnightMarks(window)
            eventMarks(window, yd: yd)

            // Current reading: solid dot with a soft halo.
            if let last = window.last {
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(220)
                .foregroundStyle(currentTint.opacity(0.2))
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(70)
                .foregroundStyle(.white)
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(36)
                .foregroundStyle(currentTint)
            }

            if let h = hovered {
                RuleMark(x: .value("Time", h.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Time", h.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: h.mgdl))
                )
                .symbolSize(60)
                .foregroundStyle(color(for: h.mgdl))
                .annotation(position: .top, spacing: 6,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    ChartReadout(reading: h, previous: Self.previous(to: h, in: window), unit: unit,
                                 range: GlucoseRange.classify(mgdl: h.mgdl, low: lowMgdl, high: highMgdl))
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xs)
                    .background { DSSurface(style: .standard, radius: DS.Radius.control) }
                    .dsShadow(.medium)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if showAxes {
                AxisMarks(values: .automatic(desiredCount: timeLabelCount)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            // A midnight label names the day instead of "12 am".
                            Text(Self.timeAxisLabel(d))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0f", d))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            // A slow ring breathing out of the newest reading while readings are arriving. App
            // screens only: widgets and the Live Activity don't animate, and it holds still (it
            // isn't drawn) under Reduce Motion or once the reading is stale.
            if interactive, !stale, !reduceMotion, let last = window.last {
                TracePulse(proxy: proxy, date: last.timestamp, value: unit.value(fromMgdl: last.mgdl), tint: currentTint)
            }
        }
        .hoverSelection(interactive, $hoverDate)
        .scrubFeedback(interactive, trigger: hovered?.timestamp)
        // A new reading slides the trace along instead of jumping it.
        .dsAnimation(.standard, value: interactive ? window.last?.timestamp : nil)
        .accessibilityLabel(projection.isEmpty ? "Glucose, last \(Int(hours)) hours"
                                                : "Glucose, last \(Int(hours)) hours, with an estimated forecast")
    }
}

/// Something logged, shown as a marker on the chart.
struct ChartLogMarker: Identifiable {
    let id: UUID
    let date: Date
    let systemImage: String
    let tint: Color
    /// Which row of markers, from the bottom, so a dose and a meal logged together don't overlap.
    var lane: Int = 0
    /// For VoiceOver: "6 units Novorapid at 12:56 pm".
    let label: String
}

extension GlucoseChart {
    /// "3 pm", or the weekday at midnight instead of "12 am".
    static func timeAxisLabel(_ d: Date) -> String {
        Calendar.current.component(.hour, from: d) == 0
            ? d.formatted(.dateTime.weekday(.abbreviated))
            : d.formatted(.dateTime.hour())
    }

    /// The reading before `r`, when it's close enough (15 minutes) for a change to mean something.
    static func previous(to r: GlucoseReading, in window: [GlucoseReading]) -> GlucoseReading? {
        guard let prev = window.last(where: { $0.timestamp < r.timestamp }),
              r.timestamp.timeIntervalSince(prev.timestamp) <= 15 * 60 else { return nil }
        return prev
    }

    /// Fills above the high line and below the low line wherever the trace goes past them.
    @ChartContentBuilder
    func outOfRangeMarks(_ window: [GlucoseReading]) -> some ChartContent {
        let high = unit.value(fromMgdl: highMgdl)
        let low = unit.value(fromMgdl: lowMgdl)
        let goesHigh = window.contains { $0.mgdl > highMgdl }
        let goesLow = window.contains { $0.mgdl < lowMgdl }
        if goesHigh {
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("High", high),
                    yEnd: .value("Above", max(unit.value(fromMgdl: r.mgdl), high)),
                    series: .value("Series", "Above range")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [GlucoseRange.high.tint.opacity(0.30), GlucoseRange.high.tint.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        if goesLow {
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Below", min(unit.value(fromMgdl: r.mgdl), low)),
                    yEnd: .value("Low", low),
                    series: .value("Series", "Below range")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [GlucoseRange.low.tint.opacity(0.12), GlucoseRange.low.tint.opacity(0.34)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    /// Where readings end and the forecast begins.
    @ChartContentBuilder
    func nowMark(last: GlucoseReading?) -> some ChartContent {
        if marksNow, let last {
            RuleMark(x: .value("Now", last.timestamp))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("Now").dsFont(.caption).foregroundStyle(.secondary)
                }
        }
    }

    /// A faint line at each midnight, so times either side can't be mistaken for the same day.
    @ChartContentBuilder
    func midnightMarks(_ window: [GlucoseReading]) -> some ChartContent {
        let marks: [Date] = {
            guard let first = window.first, let last = window.last else { return [] }
            return ClockLabel.midnights(from: first.timestamp, to: last.timestamp)
        }()
        ForEach(marks, id: \.self) { m in
            RuleMark(x: .value("Midnight", m))
                .foregroundStyle(Color.primary.opacity(0.14))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// Logged insulin and food, along the bottom.
    @ChartContentBuilder
    func eventMarks(_ window: [GlucoseReading], yd: ClosedRange<Double>) -> some ChartContent {
        let start = window.first?.timestamp ?? .distantFuture
        let shown = events.filter { $0.date >= start }
        let span = yd.upperBound - yd.lowerBound
        ForEach(shown) { e in
            let y: Double = yd.lowerBound + span * (0.06 + 0.08 * Double(e.lane))
            PointMark(x: .value("Time", e.date), y: .value("Logged", y))
                .symbol { EventSymbol(event: e) }
                .accessibilityLabel(e.label)
        }
    }
}

private struct EventSymbol: View {
    let event: ChartLogMarker

    var body: some View {
        Image(systemName: event.systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(event.tint))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// The hover / scrub label: the reading with its range's dot, when it was, and how much it
/// changed since the reading before.
private struct ChartReadout: View {
    let reading: GlucoseReading
    let previous: GlucoseReading?
    let unit: GlucoseUnit
    let range: GlucoseRange

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(range.tint).frame(width: 7, height: 7)
                Text(unit.format(mgdl: reading.mgdl, withUnit: true))
                    .fontWeight(.semibold)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reading.mgdl))
                if let previous {
                    Text(unit.formatDelta(mgdl: reading.mgdl - previous.mgdl))
                        .dsFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(ClockLabel.dayTime(reading.timestamp, now: Date()))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The breathing ring at the end of the trace. Placed with the chart's proxy so it sits exactly on
/// the newest reading's dot whatever the chart's size.
private struct TracePulse: View {
    let proxy: ChartProxy
    let date: Date
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: date),
               let y = proxy.position(forY: value) {
                let origin = geo[plot].origin
                Circle()
                    .strokeBorder(tint, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .phaseAnimator([false, true]) { content, out in
                        content.scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.8)
                    } animation: { out in
                        out ? .easeOut(duration: 1.8) : .linear(duration: 0.01)
                    }
                    .position(x: origin.x + x, y: origin.y + y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// A light tick each time scrubbing lands on a different reading (iPhone).
    @ViewBuilder
    func scrubFeedback(_ enabled: Bool, trigger: Date?) -> some View {
        #if os(iOS)
        if enabled {
            sensoryFeedback(trigger: trigger) { old, new in
                old != nil && new != nil ? .selection : nil
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func hoverSelection(_ enabled: Bool, _ date: Binding<Date?>) -> some View {
        if enabled {
            chartXSelection(value: date)
        } else {
            self
        }
    }
}
