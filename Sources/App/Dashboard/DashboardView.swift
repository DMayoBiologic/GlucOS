import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The pop-out dashboard: a regular, resizable window with the full picture. Opened from the
/// menu bar popover. Reads only what `GlucoseStore` already has.
struct DashboardView: View {
    static let windowID = "dashboard"

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    @State private var logSheet: LogSheetTarget?

    @AppStorage("dashboardRange") private var range: DashboardRange = .h24
    @AppStorage("dashboardSection") private var section: DashboardSection = .overview
    @AppStorage("dashboardKeepOnTop") private var keepOnTop = false

    var body: some View {
        let data = DashboardData(archive: store.archive, range: range, snapshot: store.snapshot)
        NavigationSplitView {
            List(selection: Binding<DashboardSection?>(get: { section }, set: { if let s = $0 { section = s } })) {
                ForEach(DashboardSection.allCases) { s in
                    Label(s.title, systemImage: s.systemImage).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { CurrentReadingTile(snapshot: store.snapshot).padding(10) }
        } detail: {
            Group {
                if section == .logbook {
                    LogbookSection(data: data) { logSheet = $0 }
                } else if section == .insights {
                    InsightsSection(readings: store.archive, unit: data.unit, lowMgdl: data.lowMgdl, highMgdl: data.highMgdl) {
                        logSheet = .new
                    }
                } else if store.archive.isEmpty {
                    ContentUnavailableView {
                        Label("No Readings Yet", systemImage: "drop")
                    } description: {
                        Text(settings.hasCredentials
                             ? "Readings appear here as soon as GlucOS fetches them from LibreLinkUp."
                             : "Sign in with your LibreLinkUp follower account in Settings to start.")
                    }
                } else {
                    switch section {
                    case .overview: OverviewSection(data: data, events: logbook.chartEvents(in: data.domain))
                    case .patterns: PatternsSection(data: data)
                    case .days: DaysSection(data: data)
                    case .readings: ReadingsSection(data: data)
                    case .logbook, .insights: EmptyView()
                    }
                }
            }
            .navigationTitle(section.title)
            .navigationSubtitle(section == .insights ? "All stored history" : range.title)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(DashboardRange.allCases) { r in Text(r.shortLabel).tag(r) }
                }
                .pickerStyle(.segmented)
                .help("Time range")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { logSheet = .new } label: {
                    Label("Log Insulin or Food…", systemImage: "plus")
                }
                .keyboardShortcut("l")
                .help("Log insulin, food or a site change (⌘L)")

                Button { Task { await store.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r")
                .help("Refresh now (⌘R)")

                Button { exportCSV(data.readings) } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .disabled(data.readings.isEmpty)
                .help("Export the readings in this range as CSV")

                Toggle(isOn: $keepOnTop) {
                    Label("Keep on Top", systemImage: keepOnTop ? "pin.fill" : "pin")
                }
                .help("Keep this window above other windows")
            }
        }
        .sheet(item: $logSheet) { target in
            LogSheet(target: target)
                .environmentObject(logbook)
                .environmentObject(settings)
        }
        .onChange(of: logbook.logSheetRequested) { _, requested in
            if requested { openRequestedLogSheet() }
        }
        .background(WindowConfigurator(floating: keepOnTop))
        .frame(minWidth: 760, minHeight: 520)
        // A menu bar app has no Dock icon, so a window it opens can get lost behind others and
        // can't be reached with ⌘-Tab. Behave like a normal app while the dashboard is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            if logbook.logSheetRequested { openRequestedLogSheet() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    /// The menu bar popover asked for the log sheet.
    private func openRequestedLogSheet() {
        logbook.logSheetRequested = false
        if logSheet == nil { logSheet = .new }
    }

    private func exportCSV(_ readings: [GlucoseReading]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "GlucOS \(range.shortLabel) \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? GlucoseAnalytics.csv(readings).write(to: url, atomically: true, encoding: .utf8)
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, patterns, days, readings, logbook, insights
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .patterns: return "Daily Patterns"
        case .days: return "Days"
        case .readings: return "Readings"
        case .logbook: return "Logbook"
        case .insights: return "Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .patterns: return "clock"
        case .days: return "calendar"
        case .readings: return "list.bullet"
        case .logbook: return "book"
        case .insights: return "lightbulb"
        }
    }
}

// MARK: - Data for the selected range

/// Everything the sections need for one range, computed once per render.
struct DashboardData {
    let range: DashboardRange
    let domain: ClosedRange<Date>
    let readings: [GlucoseReading]      // oldest → newest, within `domain`
    let stats: GlucoseStats?
    let breakdown: RangeBreakdown?
    let coverage: Double
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// Oldest reading GlucOS has stored at all.
    let archiveStart: Date?

    init(archive: [GlucoseReading], range: DashboardRange, snapshot: GlucoseSnapshot, now: Date = Date()) {
        // End on the next 5-minute boundary so the axis doesn't creep every few seconds.
        let step: TimeInterval = 5 * 60
        let latest = max(now, archive.last?.timestamp ?? now)
        let end = Date(timeIntervalSince1970: (latest.timeIntervalSince1970 / step).rounded(.up) * step)
        let start = end.addingTimeInterval(-range.duration)
        self.range = range
        domain = start...end
        readings = GlucoseAnalytics.slice(archive, from: start, to: end)
        unit = snapshot.unit
        lowMgdl = snapshot.lowMgdl
        highMgdl = snapshot.highMgdl
        stats = GlucoseStats.compute(readings, low: lowMgdl, high: highMgdl)
        breakdown = RangeBreakdown.compute(readings, low: lowMgdl, high: highMgdl)
        coverage = GlucoseAnalytics.coverage(readings, from: start, to: end)
        archiveStart = archive.first?.timestamp
    }

    /// True when GlucOS hasn't been collecting for the whole range yet.
    var historyIsShort: Bool {
        guard let archiveStart else { return true }
        return archiveStart > domain.lowerBound.addingTimeInterval(3600)
    }

    var historyNote: String? {
        guard historyIsShort, let archiveStart else { return nil }
        return "History starts \(archiveStart.formatted(date: .abbreviated, time: .shortened)). LibreLinkUp only provides the last 12 hours, so GlucOS builds up longer history while it runs."
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    let data: DashboardData
    let events: [ChartEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if data.readings.isEmpty {
                    ContentUnavailableView("No Readings in This Range", systemImage: "chart.xyaxis.line",
                                           description: Text("Pick a longer range in the toolbar."))
                        .frame(height: 360)
                } else {
                    TrendChart(readings: data.readings, domain: data.domain, unit: data.unit,
                               lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, events: events)
                        .id("\(data.range.rawValue)")
                        .frame(height: 360)
                        .dashboardCard()
                }
                if let note = data.historyNote { HistoryNote(text: note) }
                if let st = data.stats, let b = data.breakdown {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        TimeInRangeCard(breakdown: b, data: data)
                        SummaryCard(stats: st, data: data)
                    }
                }
                Disclaimer()
            }
            .padding(20)
        }
    }
}

private struct TimeInRangeCard: View {
    let breakdown: RangeBreakdown
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("Time in Range", trailing: "target \(data.unit.format(mgdl: data.lowMgdl))–\(data.unit.format(mgdl: data.highMgdl))")
            HStack(alignment: .center, spacing: 16) {
                RangeStack(breakdown: breakdown)
                    .frame(width: 26, height: 150)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(breakdown.rows) { row in
                        HStack(spacing: 6) {
                            Circle().fill(row.range.reportColor)
                                .frame(width: 8, height: 8)
                            Text(row.range.label)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text(GlucoseAnalytics.perDay(row.fraction))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .help("Average time per day")
                            Text(Format.percent(row.fraction))
                                .font(.callout.weight(row.range == .inRange ? .bold : .semibold))
                                .monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Consensus targets: over 70% in range, under 4% below, under 1% urgent low.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .dashboardCard()
    }
}

/// Vertical stacked bar, very high on top, urgent low at the bottom.
private struct RangeStack: View {
    let breakdown: RangeBreakdown

    var body: some View {
        GeometryReader { geo in
            let rows = breakdown.rows.filter { $0.fraction > 0.001 }
            let gaps = CGFloat(max(0, rows.count - 1)) * 2
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    Rectangle()
                        .fill(row.range.reportColor.gradient)
                        .frame(height: max(2, (geo.size.height - gaps) * row.fraction))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct SummaryCard: View {
    let stats: GlucoseStats
    let data: DashboardData

    var body: some View {
        let u = data.unit
        let cv = stats.coefficientOfVariation
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("Summary", trailing: "\(stats.count) readings")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Metric("Average", u.format(mgdl: stats.meanMgdl), sub: u.label)
                    Metric("GMI", String(format: "%.1f%%", stats.gmiPercent),
                           sub: stats.spanHours >= 14 * 24 - 1 ? "estimated A1c" : "needs 14 days",
                           help: "Glucose Management Indicator: an A1c estimate from average glucose. Only reliable over 14+ days of data.")
                }
                GridRow {
                    Metric("Std deviation", u.format(mgdl: stats.sdMgdl), sub: u.label)
                    Metric("Variability (CV)", Format.percent(cv),
                           sub: cv <= 0.36 ? "stable (≤ 36%)" : "above 36% target",
                           tint: cv <= 0.36 ? nil : Color.orange,
                           help: "Coefficient of variation: standard deviation ÷ average. 36% or less is considered stable.")
                }
                GridRow {
                    Metric("Lowest", u.format(mgdl: stats.minMgdl), sub: u.label)
                    Metric("Highest", u.format(mgdl: stats.maxMgdl), sub: u.label)
                }
                GridRow {
                    Metric("Data captured", Format.percent(data.coverage),
                           sub: "of 15-min periods",
                           tint: data.coverage < 0.7 ? Color.orange : nil,
                           help: "Share of 15-minute periods in this range that have a reading. Under 70% makes the numbers less reliable.")
                    Metric("Span", spanText(stats.spanHours), sub: "first to last reading")
                }
            }
        }
        .dashboardCard()
    }

    private func spanText(_ hours: Double) -> String {
        hours >= 48 ? String(format: "%.1f days", hours / 24) : String(format: "%.0f h", hours)
    }
}

// MARK: - Patterns

private struct PatternsSection: View {
    let data: DashboardData
    @AppStorage("dashboardPatternStyle") private var style = 0   // 0 percentiles, 1 overlay

    var body: some View {
        let o = overlay
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CardTitle(style == 0 ? "Glucose by Time of Day" : "Days Overlaid",
                                  trailing: style == 0 ? "median and spread across \(dayCount) days" : "last \(o.labels.count) days")
                        Picker("Style", selection: $style) {
                            Text("Percentiles").tag(0)
                            Text("Overlay").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if style == 0 {
                        let bins = GlucoseAnalytics.dailyPattern(data.readings, binMinutes: PatternChart.binMinutes)
                        if bins.isEmpty {
                            notEnough
                        } else {
                            PatternChart(bins: bins, unit: data.unit, lowMgdl: data.lowMgdl, highMgdl: data.highMgdl)
                                .frame(height: 380)
                        }
                    } else {
                        if o.points.isEmpty {
                            notEnough
                        } else {
                            OverlayChart(points: o.points, dayLabels: o.labels, unit: data.unit,
                                         lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, reference: o.reference)
                                .frame(height: 380)
                        }
                    }
                }
                .dashboardCard()

                Text(style == 0
                     ? "The line is the median reading at each time of day; the darker band holds the middle 50% of readings and the lighter band 90%. A wide band means that time of day varies a lot. Patterns are most useful over 7 days or more."
                     : "Each line is one day, plotted by time of day. Today is drawn thicker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = data.historyNote { HistoryNote(text: note) }
                Disclaimer()
            }
            .padding(20)
        }
    }

    private var dayCount: Int {
        Set(data.readings.map { Calendar.current.startOfDay(for: $0.timestamp) }).count
    }

    private var notEnough: some View {
        ContentUnavailableView("Not Enough Data", systemImage: "clock",
                               description: Text("Pick a longer range, or check back once GlucOS has collected more readings."))
            .frame(height: 380)
    }

    /// The most recent 7 days, each on the same 24-hour axis.
    private var overlay: (points: [OverlayPoint], labels: [String], reference: Date) {
        let cal = Calendar.current
        let reference = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: data.readings) { cal.startOfDay(for: $0.timestamp) }
        let days = byDay.keys.sorted().suffix(7)
        var points: [OverlayPoint] = []
        var labels: [String] = []
        var id = 0
        for day in days {
            let label = day.formatted(.dateTime.weekday(.abbreviated).day())
            labels.append(label)
            let rs = (byDay[day] ?? []).sorted { $0.timestamp < $1.timestamp }
            for p in GlucoseAnalytics.plotPoints(rs, bucket: 0, maxGap: 30 * 60) {
                points.append(OverlayPoint(id: id, x: reference.addingTimeInterval(p.date.timeIntervalSince(day)),
                                           mgdl: p.mgdl, series: "\(label)-\(p.segment)", day: label))
                id += 1
            }
        }
        return (points, labels, reference)
    }
}

// MARK: - Days

private struct DaysSection: View {
    let data: DashboardData

    var body: some View {
        let days = GlucoseAnalytics.days(data.readings, low: data.lowMgdl, high: data.highMgdl)
        let u = data.unit
        VStack(alignment: .leading, spacing: 12) {
            if days.count > 1 {
                DailyRangeChart(days: days)
                    .frame(height: 170)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            Table(days) {
                TableColumn("Day") { (d: DaySummary) in
                    Text(d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
                TableColumn("In range") { (d: DaySummary) in
                    HStack(spacing: 6) {
                        Text(Format.percent(d.breakdown.inRange)).monospacedDigit().frame(width: 38, alignment: .trailing)
                        MiniRangeBar(breakdown: d.breakdown).frame(height: 6)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Below") { (d: DaySummary) in
                    Text(Format.percent(d.breakdown.below)).monospacedDigit()
                        .foregroundStyle(d.breakdown.below > 0.04 ? Color.red : Color.primary)
                }
                TableColumn("Above") { (d: DaySummary) in
                    Text(Format.percent(d.breakdown.above)).monospacedDigit()
                }
                TableColumn("Average") { (d: DaySummary) in
                    Text(u.format(mgdl: d.stats.meanMgdl)).monospacedDigit()
                }
                TableColumn("Low – High") { (d: DaySummary) in
                    Text("\(u.format(mgdl: d.stats.minMgdl)) – \(u.format(mgdl: d.stats.maxMgdl))").monospacedDigit()
                }
                TableColumn("CV") { (d: DaySummary) in
                    Text(Format.percent(d.stats.coefficientOfVariation)).monospacedDigit()
                        .foregroundStyle(d.stats.coefficientOfVariation > 0.36 ? Color.orange : Color.primary)
                }
                TableColumn("Lows") { (d: DaySummary) in
                    Text("\(d.lowEpisodes)").monospacedDigit()
                        .foregroundStyle(d.lowEpisodes > 0 ? Color.red : Color.secondary)
                        .help("Episodes below \(u.format(mgdl: data.lowMgdl, withUnit: true)) lasting 15 minutes or more")
                }
                TableColumn("Readings") { (d: DaySummary) in
                    Text("\(d.stats.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MiniRangeBar: View {
    let breakdown: RangeBreakdown

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(breakdown.rows.reversed().filter { $0.fraction > 0.001 }) { row in
                    Rectangle()
                        .fill(row.range.reportColor)
                        .frame(width: max(1, geo.size.width * row.fraction))
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - Readings

private struct ReadingsSection: View {
    let data: DashboardData

    var body: some View {
        let rows = Array(data.readings.reversed())
        let u = data.unit
        Table(rows) {
            TableColumn("Time") { (r: GlucoseReading) in
                Text(r.timestamp.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .monospacedDigit()
            }
            .width(min: 140, ideal: 180)
            TableColumn("Glucose (\(u.label))") { (r: GlucoseReading) in
                let range = GlucoseRange.classify(mgdl: r.mgdl, low: data.lowMgdl, high: data.highMgdl)
                Text(u.format(mgdl: r.mgdl))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(range.valueColor)
            }
            TableColumn("Trend") { (r: GlucoseReading) in
                if r.trend == .unknown {
                    Text("–").foregroundStyle(.tertiary)
                } else {
                    Label { Text(r.trend.description) } icon: { TrendSymbol(trend: r.trend) }
                }
            }
            TableColumn("Range") { (r: GlucoseReading) in
                let range = GlucoseRange.classify(mgdl: r.mgdl, low: data.lowMgdl, high: data.highMgdl)
                HStack(spacing: 6) {
                    Circle().fill(range.color).frame(width: 7, height: 7)
                    Text(range.label)
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// Current reading in the sidebar, so it stays visible whichever section is open.
private struct CurrentReadingTile: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if let cur = snapshot.current {
            let stale = snapshot.isStale()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.unit.format(mgdl: cur.mgdl))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(stale ? Color.secondary : (snapshot.range?.valueColor ?? .primary))
                        .contentTransition(.numericText(value: cur.mgdl))
                    TrendSymbol(trend: cur.trend).font(.title3)
                }
                HStack(spacing: 4) {
                    Text(snapshot.unit.label)
                    if let d = snapshot.deltaMgdl { Text("· \(snapshot.unit.formatDelta(mgdl: d))").monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(Format.age(cur.age()))
                    .font(.caption2)
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                if let range = snapshot.range { RangeBadge(range: range, stale: stale) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.accessibilitySummary())
        }
    }
}

struct CardTitle: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let sub: String?
    let tint: Color?
    let helpText: String?

    init(_ title: String, _ value: String, sub: String? = nil, tint: Color? = nil, help: String? = nil) {
        self.title = title
        self.value = value
        self.sub = sub
        self.tint = tint
        self.helpText = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub { Text(sub).font(.caption2).foregroundStyle(tint ?? Color.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct HistoryNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Disclaimer: View {
    var body: some View {
        Text("Not a medical device. Confirm on your phone before treating.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// Reaches the hosting NSWindow for what SwiftUI can't set on macOS 14 (floating level).
private struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async { view.window?.level = level }
    }
}

extension View {
    func dashboardCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
