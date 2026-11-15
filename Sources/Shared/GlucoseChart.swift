import SwiftUI
import Charts
import Accessibility

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
    /// How much of the forecast is drawn, from its starting reading (0) to its end (1), while it
    /// draws in (`ForecastMotion`). The axes always make room for all of it, so they hold still.
    var forecastReveal: Double = 1
    /// Logged doses and food, drawn as small markers along the bottom of the chart.
    var events: [ChartLogMarker] = []
    /// How many time labels to aim for along the bottom.
    var timeLabelCount: Int = 4
    /// A faint "Now" line where readings end and the forecast begins.
    var marksNow: Bool = false

    @State private var hoverDate: Date?
    /// Whether a finger (or the pointer) is on the chart, as opposed to the readout gliding back
    /// to the newest reading after a scrub, which mustn't tick.
    @State private var touching = false
    /// The reading the scrub was last on while touching, so the next one knows what it passed.
    @State private var scrubbedFrom: Date?
    @State private var scrubTick = ScrubTickTrigger()
    /// Counts touches, so a snap-back still finishing never clears a scrub that started after it.
    @State private var touchGeneration = 0
    /// The span on screen while `hours` changes (app screens only; `nil` follows `hours`, which is
    /// all a widget ever does since it never runs `onAppear`). See `ChartSpanTransition`.
    @State private var range: ChartSpanTransition?
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

    /// Readings kept past the left edge so they slide off it. Only charts that move need them.
    private var lead: TimeInterval { interactive ? ChartSpan.lead : 0 }

    /// What's on screen and what's drawn, for the span currently shown.
    private var chartWindow: ChartSpan? {
        let r = range ?? ChartSpanTransition(hours: hours)
        return ChartSpan(readings: readings, domainHours: r.domainHours, dataHours: r.dataHours,
                           forecastEnd: forecast.last?.date, lead: lead)
    }

    /// The glucose axis fits what's on screen at the span being shown (and the few readings just
    /// past the left edge, so they never poke out of the top or bottom as they leave). Extra data
    /// plotted only while the range changes doesn't count, so the axis rescales in the same
    /// movement as the time axis.
    private func yDomainMgdl(_ onScreen: ArraySlice<GlucoseReading>) -> ClosedRange<Double> {
        let values = onScreen.map(\.mgdl) + [lowMgdl, highMgdl] + forecast.map(\.mgdl)
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return lo...hi
    }

    private func yDomain(_ onScreen: ArraySlice<GlucoseReading>) -> ClosedRange<Double> {
        let mg = yDomainMgdl(onScreen)
        return unit.value(fromMgdl: mg.lowerBound)...unit.value(fromMgdl: mg.upperBound)
    }

    /// A new span: plot what both ends of the move need, move the axis, then drop what's off
    /// screen. Under Reduce Motion it just switches.
    private func changeRange(from old: Double, to new: Double) {
        var r = range ?? ChartSpanTransition(hours: old)
        guard interactive, !reduceMotion else {
            r.jump(to: new)
            withTransaction(Transaction(animation: nil)) { range = r }
            return
        }
        r.prepare(for: new)
        let generation = r.generation
        withTransaction(Transaction(animation: nil)) { range = r }
        // On the next turn, so the extra readings are already in place (unseen, past the left
        // edge) when the axis starts moving, and slide in rather than fading in.
        DispatchQueue.main.async {
            withAnimation(DSMotion.standard.animation, completionCriteria: .logicallyComplete) {
                range?.move(to: new)
            } completion: {
                withTransaction(Transaction(animation: nil)) { range?.settle(generation: generation) }
            }
        }
    }

    /// What Charts' selection reads and writes. Lifting the finger glides the readout back to the
    /// newest reading and fades it there, rather than dropping it wherever the finger was.
    private func selection(newest: Date?) -> Binding<Date?> {
        Binding(get: { hoverDate }, set: { new in
            if let new {
                if !touching { touching = true; scrubbedFrom = nil }
                touchGeneration += 1
                hoverDate = new
            } else {
                release(newest: newest)
            }
        })
    }

    /// The finger's off the chart. iPhone glides the readout to the newest reading, then fades it;
    /// under Reduce Motion, on the Mac (the pointer leaving), or when it's already there, it goes.
    private func release(newest: Date?) {
        touching = false
        scrubbedFrom = nil
        touchGeneration += 1
        let generation = touchGeneration
        #if os(iOS)
        let glides = !reduceMotion && newest != nil && hoverDate != nil
        #else
        let glides = false
        #endif
        guard glides, let newest else {
            withTransaction(Transaction(animation: nil)) { hoverDate = nil }
            return
        }
        withAnimation(DSMotion.standard.animation, completionCriteria: .logicallyComplete) {
            hoverDate = newest
        } completion: {
            guard touchGeneration == generation else { return }
            withAnimation(DSMotion.quick.animation) { hoverDate = nil }
        }
    }

    /// The scrub landed on another reading: tick if it crossed a range edge or something logged.
    private func scrubbed(to date: Date?, readings window: [GlucoseReading]) {
        guard touching, let date else { return }
        if let from = scrubbedFrom,
           let tick = ChartScrub.tick(from: from, to: date, readings: window, lowMgdl: lowMgdl,
                                      highMgdl: highMgdl, logged: events.map(\.date)) {
            scrubTick.fire(tick)
        }
        scrubbedFrom = date
    }

    private func color(for mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    var body: some View {
        let cw = chartWindow
        let window = Array(cw?.visible ?? [])
        let plotted = Array(cw?.plotted ?? [])
        // On screen at the span being shown, plus the lead past the left edge: not the extra
        // data plotted only while the span changes.
        let onScreen = ChartSpan(readings: readings, domainHours: (range ?? .init(hours: hours)).domainHours,
                                   dataHours: 0, forecastEnd: forecast.last?.date, lead: lead)?.plotted ?? []
        let yd = yDomain(onScreen)
        let floor = yd.lowerBound
        let hovered = interactive ? nearest(to: hoverDate ?? pinnedDate, in: window) : nil
        // The gradient is stretched over the drawn line, so its stops follow what's plotted.
        let lineStyle = ThresholdGradient.style(minMgdl: plotted.map(\.mgdl).min() ?? lowMgdl,
                                                maxMgdl: plotted.map(\.mgdl).max() ?? highMgdl,
                                                low: lowMgdl, high: highMgdl)
        let stale = latestIsStale
            ?? (window.last.map { Date().timeIntervalSince($0.timestamp) > GlucoseSnapshot.staleAfter } ?? true)
        let currentTint = stale ? Palette.stale : (window.last.map { color(for: $0.mgdl) } ?? Palette.stale)
        let projection = stale ? [] : forecast
        // What's drawn of it so far. Indexed rather than keyed by time, so the marks keep their
        // identity while a new forecast slides and bends into place (`ForecastMotion`).
        let drawn = Array(ForecastMorph.revealed(projection, progress: forecastReveal).enumerated())
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
            ForEach(plotted) { r in
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
            outOfRangeMarks(plotted)

            // The trace changes colour as it crosses the thresholds.
            ForEach(plotted) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(lineStyle)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            // The forecast: a neutral band and dashed line, so it can't be mistaken for readings.
            ForEach(drawn, id: \.offset) { _, p in
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
            ForEach(drawn, id: \.offset) { _, p in
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
            midnightMarks(plotted)
            eventMarks(plotted, yd: yd)

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
        // Both axes are set rather than worked out by Charts, so a change of span or a new
        // reading moves them (and the marks with them) instead of redrawing the chart.
        .chartXScale(domain: cw?.domain ?? Date().addingTimeInterval(-hours * 3600)...Date())
        .chartYScale(domain: yd)
        // Readings past the left edge (sliding in or out) are hidden; everything else keeps
        // room to overhang, as before: the newest reading's halo, the "Now" label, the readout.
        // (Charts that never move keep room on the left too, so nothing about them changes.)
        .chartPlotStyle { plot in
            plot.mask {
                Rectangle()
                    .padding(.top, -48)
                    .padding(.bottom, -12)
                    .padding(.trailing, -48)
                    .padding(.leading, interactive ? 0 : -48)
            }
        }
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
        .onAppear { if interactive, range == nil { range = ChartSpanTransition(hours: hours) } }
        .onChange(of: hours) { old, new in changeRange(from: old, to: new) }
        .hoverSelection(interactive, selection(newest: window.last?.timestamp))
        .onChange(of: hovered?.timestamp) { _, new in scrubbed(to: new, readings: window) }
        .scrubFeedback(interactive, trigger: scrubTick)
        // A new reading slides the trace (and the time axis) along by one reading instead of
        // jumping it. One short movement per reading; nothing here repeats.
        .dsAnimation(.standard, value: interactive ? readings.last?.timestamp : nil)
        // One VoiceOver element rather than hundreds of marks: a spoken summary, and the trace (with
        // the forecast as a second series) as an audio graph under "Chart Details" in the rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projection.isEmpty ? "Glucose chart" : "Glucose chart, with an estimated forecast")
        .accessibilityValue(ChartSummary.sentence(.init(
            readings: window, lowMgdl: lowMgdl, highMgdl: highMgdl, unit: unit, hours: hours, stale: stale,
            forecastEnd: projection.last,
            loggedCount: events.filter { $0.date >= (window.first?.timestamp ?? .distantFuture) }.count)))
        .accessibilityChartDescriptor(GlucoseAudioGraph(readings: window, forecast: projection, unit: unit,
                                                        lowMgdl: lowMgdl, highMgdl: highMgdl, yDomain: yd))
    }
}

// MARK: - Audio graph

/// The chart for VoiceOver's audio graph and data table: readings as one series, the forecast (if
/// shown) as another, with the target's edges as gridlines. Shared by every target that draws a
/// `GlucoseChart`; the Mac dashboard's own chart has `GlucoseChartDescriptor`.
struct GlucoseAudioGraph: AXChartDescriptorRepresentable {
    let readings: [GlucoseReading]
    let forecast: [ForecastSample]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let yDomain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = self.unit
        // A few hundred points keep audio-graph navigation quick.
        let step = max(1, readings.count / 300)
        let sampled = stride(from: 0, to: readings.count, by: step).map { readings[$0] }
        let first = readings.first?.timestamp ?? Date()
        let last = forecast.last?.date ?? readings.last?.timestamp ?? first.addingTimeInterval(3600)
        let x = AXNumericDataAxisDescriptor(
            title: "Time",
            range: first.timeIntervalSince1970...max(last.timeIntervalSince1970, first.timeIntervalSince1970 + 60),
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        let y = AXNumericDataAxisDescriptor(
            title: "Glucose, \(unit.spokenLabel)",
            range: yDomain,
            gridlinePositions: [unit.value(fromMgdl: lowMgdl), unit.value(fromMgdl: highMgdl)]
        ) { value in
            unit == .mmol ? String(format: "%.1f", value) : String(format: "%.0f", value)
        }
        var series = [AXDataSeriesDescriptor(
            name: "Readings",
            isContinuous: true,
            dataPoints: sampled.map {
                AXDataPoint(x: $0.timestamp.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl),
                            label: GlucoseRange.classify(mgdl: $0.mgdl, low: lowMgdl, high: highMgdl).label)
            }
        )]
        if !forecast.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: "Forecast, an estimate",
                isContinuous: true,
                dataPoints: forecast.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl)) }
            ))
        }
        return AXChartDescriptor(
            title: "Glucose",
            summary: "Target \(unit.format(mgdl: lowMgdl)) to \(unit.format(mgdl: highMgdl)) \(unit.spokenLabel).",
            xAxis: x, yAxis: y, additionalAxes: [], series: series)
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
                // One breath every few seconds rather than a loop (see `PulseBeat`).
                PulseBeat(every: PulseInterval.trace) { beat in
                    Circle()
                        .strokeBorder(tint, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                        .pulse(beat: beat, scale: 2.6, opacity: 0.8, duration: 1.8)
                }
                .position(x: origin.x + x, y: origin.y + y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Changes each time a scrub tick is due, so `sensoryFeedback` fires even for two of a kind in a row.
private struct ScrubTickTrigger: Equatable {
    private(set) var count = 0
    private(set) var tick: ChartScrub.Tick?

    mutating func fire(_ tick: ChartScrub.Tick) {
        count += 1
        self.tick = tick
    }
}

private extension View {
    /// A light tick when scrubbing crosses the low or high line, a lighter one on something logged
    /// (iPhone). Moving from one reading to the next doesn't tick by itself.
    @ViewBuilder
    func scrubFeedback(_ enabled: Bool, trigger: ScrubTickTrigger) -> some View {
        #if os(iOS)
        if enabled {
            sensoryFeedback(trigger: trigger) { _, new -> SensoryFeedback? in
                switch new.tick {
                case .rangeEdge: return .impact(weight: .light, intensity: 0.9)
                case .logged: return .impact(weight: .light, intensity: 0.6)
                case nil: return nil
                }
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
