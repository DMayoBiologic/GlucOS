import SwiftUI
import AppKit

// A one-page summary of a period, laid out like the CGM reports clinics use (metrics against
// consensus targets, time in range, the daily profile and each day's trace), viewable in the
// dashboard and exportable as a PDF to share.

struct ReportModel {
    let data: DashboardData
    let previousStats: GlucoseStats?
    let previousBreakdown: RangeBreakdown?
    /// Oldest first.
    let days: [DaySummary]
    let dayReadings: [Date: [GlucoseReading]]
    let pattern: [PatternBin]
    let highlights: PeriodHighlights
    let totals: LoggedTotals?
    let generated: Date

    struct LoggedTotals {
        let bolus: Double
        let basal: Double
        let carbs: Double
        let doseCount: Int
        let mealCount: Int
        /// Days the period covers, for per-day averages. Under 1 for ranges shorter than a day.
        let days: Double
    }

    init(data: DashboardData, archive: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], now: Date = Date()) {
        self.data = data
        generated = now
        let prevStart = data.domain.lowerBound.addingTimeInterval(-data.range.duration)
        let prev = GlucoseAnalytics.slice(archive, from: prevStart, to: data.domain.lowerBound)
        // Comparing against a mostly empty period would mislead.
        if GlucoseAnalytics.coverage(prev, from: prevStart, to: data.domain.lowerBound) >= 0.5 {
            previousStats = GlucoseStats.compute(prev, low: data.lowMgdl, high: data.highMgdl)
            previousBreakdown = RangeBreakdown.compute(prev, low: data.lowMgdl, high: data.highMgdl)
        } else {
            previousStats = nil
            previousBreakdown = nil
        }
        days = GlucoseAnalytics.days(data.readings, low: data.lowMgdl, high: data.highMgdl).reversed()
        dayReadings = Dictionary(grouping: data.readings) { Calendar.current.startOfDay(for: $0.timestamp) }
        pattern = GlucoseAnalytics.dailyPattern(data.readings, binMinutes: PatternChart.binMinutes)
        highlights = PeriodHighlights.compute(data.readings, low: data.lowMgdl, high: data.highMgdl)

        let inDoses = doses.filter { data.domain.contains($0.timestamp) }
        let inMeals = meals.filter { data.domain.contains($0.timestamp) }
        if inDoses.isEmpty && inMeals.isEmpty {
            totals = nil
        } else {
            totals = LoggedTotals(
                bolus: inDoses.filter { $0.kind.isBolus }.reduce(0) { $0 + $1.units },
                basal: inDoses.filter { !$0.kind.isBolus }.reduce(0) { $0 + $1.units },
                carbs: inMeals.reduce(0) { $0 + $1.carbs },
                doseCount: inDoses.count, mealCount: inMeals.count,
                days: data.range.duration / 86_400)
        }
    }
}

// MARK: - Section

struct ReportSection: View {
    let model: ReportModel
    let onExport: () -> Void

    var body: some View {
        DashboardPage(maxContentWidth: DashboardMetrics.readableWidth) { _ in
            // The sentence wraps; the button keeps its size.
            HStack(alignment: .center, spacing: 16) {
                Label("A summary of this period to keep or share with your diabetes team. Pick the period with the range control and the arrows in the toolbar.",
                      systemImage: "doc.richtext")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(action: onExport) {
                    Label("Export PDF…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.ds(.primary))
                .fixedSize()
                .disabled(model.data.readings.isEmpty)
                .help("Save this report as a PDF (⇧⌘P)")
            }
            if model.data.readings.isEmpty {
                EmptyStateView(systemImage: "doc.richtext", title: "No Readings in This Period",
                               message: "Pick a period with stored readings to build a report.")
                    .frame(height: 320)
                    .dashboardCard()
            } else {
                ReportView(model: model, printing: false)
            }
        }
    }
}

enum ReportExporter {
    /// Renders the report as a single-page PDF at a printable width. False when the file
    /// couldn't be created.
    @MainActor
    @discardableResult
    static func writePDF(model: ReportModel, to url: URL) -> Bool {
        let content = ReportView(model: model, printing: true)
            .padding(32)
            .frame(width: 820)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        var written = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            written = true
        }
        return written
    }
}

// MARK: - The report

/// Two report cards side by side. On screen they stack when the window is too narrow for both;
/// the PDF always has the room.
private struct ReportPair<Leading: View, Trailing: View>: View {
    let printing: Bool
    let leading: Leading
    let trailing: Trailing

    init(printing: Bool, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.printing = printing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if printing {
            sideBySide
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                VStack(alignment: .leading, spacing: 16) {
                    leading
                    trailing
                }
            }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 16) {
            leading
            trailing
        }
    }
}

struct ReportView: View {
    let model: ReportModel
    /// Flat, light styling for the PDF (materials don't render off screen).
    let printing: Bool

    private var data: DashboardData { model.data }
    private var u: GlucoseUnit { data.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let st = data.stats, let b = data.breakdown {
                ReportPair(printing: printing) {
                    metrics(st, b)
                        .reportCard(printing)
                } trailing: {
                    // The width is for the column's content, inside the card's padding.
                    rangeColumn(b)
                        .frame(width: 250)
                        .reportCard(printing)
                }
            }
            if !model.pattern.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Daily Profile", trailing: "median, 25–75% and 5–95% by time of day")
                    PatternChart(bins: model.pattern, unit: u, lowMgdl: data.lowMgdl, highMgdl: data.highMgdl)
                        .frame(height: 240)
                }
                .reportCard(printing)
            }
            if model.days.count > 1 {
                dailyTraces
                    .reportCard(printing)
            }
            if let t = model.totals {
                ReportPair(printing: printing) {
                    highlights
                        .reportCard(printing)
                } trailing: {
                    logged(t)
                        .reportCard(printing)
                }
            } else {
                highlights
                    .reportCard(printing)
            }
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glucose Report")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(periodText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(model.days.count) \(model.days.count == 1 ? "day" : "days") with data · \(Format.percent(data.coverage)) captured")
                    .foregroundStyle(data.coverage < 0.7 ? Color.orange : Color.secondary)
                Text("Target \(u.format(mgdl: data.lowMgdl))–\(u.format(mgdl: data.highMgdl)) \(u.label)")
                Text("Generated \(model.generated.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var periodText: String {
        let f: Date.FormatStyle = data.range.duration >= 86_400 ? .dateTime.day().month(.abbreviated).year()
                                                                 : .dateTime.day().month(.abbreviated).hour().minute()
        return "\(data.domain.lowerBound.formatted(f)) – \(data.domain.upperBound.formatted(f))"
    }

    // MARK: Metrics against targets

    private struct Row: Identifiable {
        let id: String
        let title: String
        let value: String
        let target: String
        let met: Bool?
        let delta: Double?
        let deltaText: String?
        let goodWhenUp: Bool?
    }

    private func metrics(_ st: GlucoseStats, _ b: RangeBreakdown) -> some View {
        let p = model.previousStats
        let pb = model.previousBreakdown
        let rows: [Row] = [
            Row(id: "tir", title: "Time in range", value: Format.percent(b.inRange), target: "over 70%",
                met: b.inRange > 0.70, delta: pb.map { b.inRange - $0.inRange },
                deltaText: pb.map { DeltaFormat.points(b.inRange - $0.inRange) }, goodWhenUp: true),
            Row(id: "tbr", title: "Below range", value: Format.percent(b.below), target: "under 4%",
                met: b.below < 0.04, delta: pb.map { b.below - $0.below },
                deltaText: pb.map { DeltaFormat.points(b.below - $0.below) }, goodWhenUp: false),
            Row(id: "tbr54", title: "Urgent low (under \(u.format(mgdl: 54)))", value: Format.percent(b.urgentLow), target: "under 1%",
                met: b.urgentLow < 0.01, delta: pb.map { b.urgentLow - $0.urgentLow },
                deltaText: pb.map { DeltaFormat.points(b.urgentLow - $0.urgentLow) }, goodWhenUp: false),
            Row(id: "tar", title: "Above range", value: Format.percent(b.above), target: "under 25%",
                met: b.above < 0.25, delta: pb.map { b.above - $0.above },
                deltaText: pb.map { DeltaFormat.points(b.above - $0.above) }, goodWhenUp: false),
            Row(id: "tar250", title: "Very high (over \(u.format(mgdl: 250)))", value: Format.percent(b.veryHigh), target: "under 5%",
                met: b.veryHigh < 0.05, delta: pb.map { b.veryHigh - $0.veryHigh },
                deltaText: pb.map { DeltaFormat.points(b.veryHigh - $0.veryHigh) }, goodWhenUp: false),
            Row(id: "mean", title: "Average glucose", value: u.format(mgdl: st.meanMgdl, withUnit: true), target: "–",
                met: nil, delta: p.map { st.meanMgdl - $0.meanMgdl },
                deltaText: p.map { DeltaFormat.glucose(st.meanMgdl - $0.meanMgdl, unit: u) }, goodWhenUp: nil),
            Row(id: "gmi", title: "GMI (estimated A1c)", value: String(format: "%.1f%%", st.gmiPercent),
                target: st.spanHours >= 14 * 24 - 1 ? "individual" : "needs 14 days",
                met: nil, delta: nil, deltaText: nil, goodWhenUp: nil),
            Row(id: "cv", title: "Variability (CV)", value: Format.percent(st.coefficientOfVariation), target: "36% or less",
                met: st.coefficientOfVariation <= 0.36, delta: p.map { st.coefficientOfVariation - $0.coefficientOfVariation },
                deltaText: p.map { DeltaFormat.points(st.coefficientOfVariation - $0.coefficientOfVariation) }, goodWhenUp: false),
            Row(id: "cov", title: "Data captured", value: Format.percent(data.coverage), target: "70% or more",
                met: data.coverage >= 0.7, delta: nil, deltaText: nil, goodWhenUp: nil),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle("Glucose Metrics", trailing: p == nil ? "international consensus targets" : "change vs previous \(data.range.periodNoun)")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("")
                    Text("Value").gridColumnAlignment(.trailing)
                    Text("Target")
                    Text("")
                    Text(p == nil ? "" : "Change").gridColumnAlignment(.trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(rows) { r in
                    GridRow {
                        Text(r.title).font(.callout)
                        Text(r.value).font(.callout.weight(.bold)).monospacedDigit()
                        Text(r.target).font(.caption).foregroundStyle(.secondary)
                        targetMark(r.met)
                        if let d = r.delta, let t = r.deltaText {
                            DeltaLabel(text: t, delta: d, goodWhenUp: r.goodWhenUp)
                        } else {
                            Text("")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                }
            }
        }
    }

    @ViewBuilder
    private func targetMark(_ met: Bool?) -> some View {
        switch met {
        case .some(true):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(GlucoseRange.inRange.tint)
                .accessibilityLabel("Target met")
        case .some(false):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Target not met")
        case .none:
            Text("")
        }
    }

    // MARK: Time in range column

    private func rangeColumn(_ b: RangeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("Time in Ranges")
            HStack(alignment: .top, spacing: 12) {
                // Stacked like the AGP report: very high at the top, urgent low at the bottom.
                GeometryReader { geo in
                    VStack(spacing: 2) {
                        ForEach(b.rows.filter { $0.fraction > 0.001 }) { row in
                            Rectangle()
                                .fill(row.range.reportColor)
                                .frame(height: max(3, (geo.size.height - 10) * row.fraction))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(width: 26, height: 210)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(b.rows) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Circle().fill(row.range.reportColor).frame(width: 7, height: 7)
                                Text(row.range.label).font(.callout)
                                Spacer(minLength: 4)
                                Text(Format.percent(row.fraction)).font(.callout.weight(.bold)).monospacedDigit()
                            }
                            Text("\(GlucoseAnalytics.perDay(row.fraction)) a day")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 13)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Daily traces

    private var dailyTraces: some View {
        let shown = Array(model.days.suffix(14))
        let columns = 7
        let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle("Daily Traces", trailing: model.days.count > 14 ? "last 14 days" : "midnight to midnight")
            // Grid rather than a lazy grid, so every cell renders into the PDF.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        ForEach(rows[i]) { d in dayCell(d) }
                        if rows[i].count < columns {
                            ForEach(0..<(columns - rows[i].count), id: \.self) { _ in Color.clear.frame(height: 1) }
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ d: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(d.day.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 2)
                Text(Format.percent(d.breakdown.inRange))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(d.breakdown.inRange >= 0.7 ? GlucoseRange.inRange.tint : Color.secondary)
            }
            GlucoseSparkline(readings: model.dayReadings[d.day] ?? [], domain: d.day...d.day.addingTimeInterval(86_400),
                             lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, lineWidth: 1.2)
                .frame(height: 44)
            if d.lowEpisodes > 0 {
                Text(d.lowEpisodes == 1 ? "1 low" : "\(d.lowEpisodes) lows")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GlucoseRange.low.tint)
            } else {
                Text(" ").font(.system(size: 9))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(d.day.formatted(date: .complete, time: .omitted)): \(Format.percent(d.breakdown.inRange)) in range, \(d.lowEpisodes) low episodes")
    }

    // MARK: Highlights and logs

    private var highlights: some View {
        let h = model.highlights
        let multiDay = data.range.duration > 86_400
        func when(_ d: Date) -> String {
            multiDay ? d.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()) : d.formatted(date: .omitted, time: .shortened)
        }
        let perWeek = data.range.duration >= 7 * 86_400
            ? String(format: " (%.1f a week)", Double(h.lowEpisodes) / (data.range.duration / (7 * 86_400)))
            : ""
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle("Events")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Low episodes").foregroundStyle(.secondary)
                    Text("\(h.lowEpisodes)\(perWeek)").monospacedDigit()
                        .foregroundStyle(h.lowEpisodes > 0 ? GlucoseRange.low.tint : Color.primary)
                }
                GridRow {
                    Text("High episodes").foregroundStyle(.secondary)
                    Text("\(h.highEpisodes)").monospacedDigit()
                }
                if let lo = h.lowest {
                    GridRow {
                        Text("Lowest").foregroundStyle(.secondary)
                        Text("\(u.format(mgdl: lo.mgdl, withUnit: true)) · \(when(lo.timestamp))").monospacedDigit()
                    }
                }
                if let hi = h.highest {
                    GridRow {
                        Text("Highest").foregroundStyle(.secondary)
                        Text("\(u.format(mgdl: hi.mgdl, withUnit: true)) · \(when(hi.timestamp))").monospacedDigit()
                    }
                }
                GridRow {
                    Text("Longest in range").foregroundStyle(.secondary)
                    Text(h.longestInRange > 0 ? LogFormat.duration(h.longestInRange) : "–")
                }
            }
            .font(.callout)
            Text("An episode is 15 minutes or more past the threshold.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func logged(_ t: ReportModel.LoggedTotals) -> some View {
        // Under a day, show the totals as they are rather than as a misleading daily figure.
        let divisor = max(1, t.days)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle("Logged", trailing: t.days >= 1 ? "per day on average" : "in this period")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if t.bolus > 0 {
                    GridRow {
                        Text("Mealtime / bolus insulin").foregroundStyle(.secondary)
                        Text(LogFormat.units(t.bolus / divisor)).monospacedDigit()
                    }
                }
                if t.basal > 0 {
                    GridRow {
                        Text("Long-acting insulin").foregroundStyle(.secondary)
                        Text(LogFormat.units(t.basal / divisor)).monospacedDigit()
                    }
                }
                if t.carbs > 0 {
                    GridRow {
                        Text("Carbohydrate").foregroundStyle(.secondary)
                        Text(LogFormat.grams((t.carbs / divisor).rounded())).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Entries").foregroundStyle(.secondary)
                    Text("\(t.doseCount) doses, \(t.mealCount) meals").monospacedDigit()
                }
            }
            .font(.callout)
            Text("Only what was logged in GlucOS. Missed entries make these lower than reality.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = data.historyNote { HistoryNote(text: note) }
            Text("Targets follow the international consensus on time in range (Battelino et al., 2019) for most adults with type 1 or type 2 diabetes; your own targets may differ. Generated by GlucOS from LibreLinkUp data. Not a medical device.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    @ViewBuilder
    func reportCard(_ printing: Bool) -> some View {
        if printing {
            self
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        } else {
            self.dashboardCard()
        }
    }
}
