import SwiftUI

// MARK: - Patterns

struct PatternsSection: View {
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
                    Group {
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
                    .transition(.opacity)
                }
                .dashboardCard()
                .animation(.smooth(duration: 0.25), value: style)

                Text(style == 0
                     ? "The line is the median reading at each time of day; the darker band holds the middle 50% of readings and the lighter band 90%. A wide band means that time of day varies a lot. Patterns are most useful over 7 days or more."
                     : "Each line is one day, plotted by time of day. Today is drawn thicker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    BreakdownTable(title: "By Time of Day", trailing: "local time",
                                   rows: GlucoseAnalytics.timeOfDay(data.readings, low: data.lowMgdl, high: data.highMgdl),
                                   unit: data.unit)
                    if data.range.duration >= 7 * 86_400 {
                        BreakdownTable(title: "By Weekday", trailing: nil,
                                       rows: GlucoseAnalytics.weekdays(data.readings, low: data.lowMgdl, high: data.highMgdl),
                                       unit: data.unit)
                    }
                }

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

/// One labelled group of readings (a time of day, a weekday) and how it went.
struct BreakdownRow: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let breakdown: RangeBreakdown?
    let meanMgdl: Double?
    let count: Int
}

/// Rows of range bars, so the worst time of day or weekday stands out.
private struct BreakdownTable: View {
    let title: String
    let trailing: String?
    let rows: [BreakdownRow]
    let unit: GlucoseUnit

    var body: some View {
        let worst = rows.compactMap { r in r.breakdown.map { (r.id, $0.below) } }.max { $0.1 < $1.1 }
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title, trailing: trailing)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Range").gridColumnAlignment(.leading)
                    Text("In range").gridColumnAlignment(.trailing)
                    Text("Below").gridColumnAlignment(.trailing)
                    Text("Avg").gridColumnAlignment(.trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.label).font(.callout.weight(.semibold))
                            if let detail = row.detail {
                                Text(detail).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let b = row.breakdown, let mean = row.meanMgdl {
                            MiniRangeBar(breakdown: b)
                                .frame(minWidth: 80, maxWidth: .infinity)
                                .frame(height: 8)
                            Text(Format.percent(b.inRange)).monospacedDigit().font(.callout.weight(.semibold))
                            Text(Format.percent(b.below)).monospacedDigit().font(.callout)
                                .foregroundStyle(b.below > 0.04 ? GlucoseRange.low.tint : Color.primary)
                                .fontWeight(worst?.0 == row.id && b.below > 0.04 ? .bold : .regular)
                            Text(unit.format(mgdl: mean)).monospacedDigit().font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Not enough data").font(.caption).foregroundStyle(.tertiary)
                                .gridCellColumns(4)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility(row))
                }
            }
        }
        .dashboardCard()
    }

    private func accessibility(_ row: BreakdownRow) -> String {
        guard let b = row.breakdown, let mean = row.meanMgdl else { return "\(row.label): not enough data" }
        return "\(row.label): \(Format.percent(b.inRange)) in range, \(Format.percent(b.below)) below, average \(unit.format(mgdl: mean)) \(unit.spokenLabel)"
    }
}

extension GlucoseAnalytics {
    /// Overnight, morning, afternoon and evening.
    static func timeOfDay(_ readings: [GlucoseReading], low: Double, high: Double,
                          calendar: Calendar = .current) -> [BreakdownRow] {
        let blocks: [(label: String, from: Int, to: Int)] = [
            ("Overnight", 0, 6), ("Morning", 6, 12), ("Afternoon", 12, 18), ("Evening", 18, 24),
        ]
        let byBlock = Dictionary(grouping: readings) { r -> Int in
            let hour = calendar.component(.hour, from: r.timestamp)
            return blocks.firstIndex { hour >= $0.from && hour < $0.to } ?? 0
        }
        return blocks.enumerated().map { i, b in
            row(id: b.label, label: b.label, detail: String(format: "%02d:00–%02d:00", b.from, b.to % 24),
                readings: byBlock[i] ?? [], low: low, high: high)
        }
    }

    /// Monday to Sunday (in the user's calendar order).
    static func weekdays(_ readings: [GlucoseReading], low: Double, high: Double,
                         calendar: Calendar = .current) -> [BreakdownRow] {
        let byDay = Dictionary(grouping: readings) { calendar.component(.weekday, from: $0.timestamp) }
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday
        return (0..<7).map { offset in
            let weekday = (first - 1 + offset) % 7 + 1
            return row(id: "wd\(weekday)", label: symbols[weekday - 1], detail: nil,
                       readings: byDay[weekday] ?? [], low: low, high: high)
        }
    }

    private static func row(id: String, label: String, detail: String?, readings: [GlucoseReading],
                            low: Double, high: Double) -> BreakdownRow {
        // A dozen readings is an hour: less than that says little about a block.
        let enough = readings.count >= 12
        let mean = readings.isEmpty ? nil : readings.reduce(0) { $0 + $1.mgdl } / Double(readings.count)
        return BreakdownRow(id: id, label: label, detail: detail,
                            breakdown: enough ? RangeBreakdown.compute(readings, low: low, high: high) : nil,
                            meanMgdl: enough ? mean : nil, count: readings.count)
    }
}

// MARK: - Days

struct DaysSection: View {
    let data: DashboardData
    let onShowDay: (Date) -> Void

    @State private var selection = Set<Date>()

    var body: some View {
        let days = GlucoseAnalytics.days(data.readings, low: data.lowMgdl, high: data.highMgdl)
        let byDay = Dictionary(grouping: data.readings) { Calendar.current.startOfDay(for: $0.timestamp) }
        let u = data.unit
        VStack(alignment: .leading, spacing: 12) {
            if days.count > 1 {
                DailyRangeChart(days: days)
                    .frame(height: 170)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            Table(days, selection: $selection) {
                TableColumn("Day") { (d: DaySummary) in
                    Text(d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
                .width(min: 90, ideal: 110)
                TableColumn("Trace") { (d: DaySummary) in
                    GlucoseSparkline(readings: byDay[d.day] ?? [], domain: d.day...d.day.addingTimeInterval(86_400),
                                     lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, lineWidth: 1.2)
                        .frame(height: 22)
                }
                .width(min: 100, ideal: 160)
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
            .contextMenu(forSelectionType: Date.self) { ids in
                if let day = ids.first {
                    Button("Show on Chart") { onShowDay(day) }
                }
            } primaryAction: { ids in
                if let day = ids.first { onShowDay(day) }
            }
            .help("Double-click a day to open it on the chart")
        }
    }
}

// MARK: - Readings

struct ReadingsSection: View {
    let data: DashboardData
    let onShow: (Date) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, below, inRange, above
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .below: return "Below"
            case .inRange: return "In Range"
            case .above: return "Above"
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var selection = Set<Date>()

    var body: some View {
        let all = Array(data.readings.reversed())
        let rows = all.filter(matches)
        let u = data.unit
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(rows.count == all.count ? "\(all.count) readings" : "\(rows.count) of \(all.count) readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Table(rows, selection: $selection) {
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
            .contextMenu(forSelectionType: Date.self) { ids in
                if let t = ids.first {
                    Button("Show on Chart") { onShow(t) }
                }
            } primaryAction: { ids in
                if let t = ids.first { onShow(t) }
            }
            .help("Double-click a reading to see it on the chart")
        }
    }

    private func matches(_ r: GlucoseReading) -> Bool {
        switch filter {
        case .all: return true
        case .below: return r.mgdl < data.lowMgdl
        case .inRange: return r.mgdl >= data.lowMgdl && r.mgdl <= data.highMgdl
        case .above: return r.mgdl > data.highMgdl
        }
    }
}
