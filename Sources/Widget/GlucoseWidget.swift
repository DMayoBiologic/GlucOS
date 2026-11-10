import WidgetKit
import SwiftUI

@main
struct GlucOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
        TimeInRangeWidget()
        SensorWidget()
    }
}

// MARK: - Widget

struct GlucoseWidget: Widget {
    /// Unchanged from the first release, so widgets people already placed keep working.
    let kind = "au.com.declanmayo.glucos.glucose"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: GlucoseWidgetIntent.self, provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(tint: entry.tint) }
                // Click anywhere else on the widget to open the popover (handled in AppDelegate).
                .widgetURL(URL(string: "glucos://open"))
        }
        .configurationDisplayName("Glucose")
        .description("Your current reading, trend and recent history, with a refresh button.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Views

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseEntry

    private var s: GlucoseSnapshot { entry.snapshot }
    private var config: GlucoseWidgetIntent { entry.configuration }
    private var hours: Double { config.window.hours(for: family) }

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .systemExtraLarge: extraLarge
        default: large
        }
    }

    /// `stats(hours:)` is anchored on the newest reading, not on now, so once that reading has
    /// expired the numbers describe an old window. Don't present them as current.
    private var stats12h: GlucoseStats? {
        entry.freshness.showsValue ? s.stats(hours: 12) : nil
    }

    private var chartCaption: String { "Last \(Int(hours))h" }

    private func chart(axes: Bool, lineWidth: CGFloat = 2.25) -> some View {
        WidgetChart(snapshot: s, now: entry.date, hours: hours, tint: entry.tint, showsAxes: axes, lineWidth: lineWidth)
    }

    /// The refresh button is offered whenever the reading isn't fresh, even if hidden in settings,
    /// because that's exactly when someone wants it.
    private var showsRefresh: Bool { config.showsRefresh || entry.freshness != .fresh }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                StatusPill(entry: entry, compact: true)
                Spacer(minLength: 0)
                if entry.freshness == .fresh {
                    WidgetTrend(entry: entry, size: 30)
                } else if showsRefresh {
                    RefreshButton(size: 26)
                }
            }
            Spacer(minLength: 2)
            HeroValue(entry: entry, size: 46)
            DetailLine(entry: entry, showsTrendWord: false)
                .padding(.top, 1)
        }
    }

    // MARK: Medium

    /// Reading on the left, chart on the right. The trend dial sits with the reading it describes,
    /// so the chart header only carries its window and, when needed, the refresh button.
    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    StatusPill(entry: entry, compact: true)
                    Spacer(minLength: 0)
                    WidgetTrend(entry: entry, size: 24)
                }
                Spacer(minLength: 2)
                HeroValue(entry: entry, size: 40)
                DetailLine(entry: entry)
                    .padding(.top, 1)
            }
            .frame(minWidth: 112, maxWidth: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    WidgetCaption(text: chartCaption)
                    Spacer(minLength: 0)
                    if showsRefresh { RefreshButton(size: 20) }
                }
                chart(axes: false)
            }
        }
    }

    // MARK: Large

    /// Reading, chart, then one quiet summary strip. Two controls at most, top right.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    StatusPill(entry: entry)
                    HeroValue(entry: entry, size: 50)
                    DetailLine(entry: entry)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        if showsRefresh { RefreshButton(size: 22) }
                        DashboardLink(size: 22)
                    }
                    WidgetTrend(entry: entry, size: 44)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                WidgetCaption(text: chartCaption)
                chart(axes: true)
            }
            .frame(maxHeight: .infinity)

            outlookRow

            if config.showsStats {
                summaryStrip(caption: "Last 12h")
            }
        }
    }

    /// Forecast and insulin still acting, only while the reading they came from is current.
    @ViewBuilder private var outlookRow: some View {
        if let o = s.currentOutlook(at: entry.date), o.showsInsulin || !o.forecast.isEmpty {
            OutlookSummaryRow(outlook: o, unit: s.unit, lowMgdl: s.lowMgdl)
        }
    }

    // MARK: Extra large

    /// Left: the reading and what it means. Right: the chart, full height. The 12-hour summary
    /// appears once, under the reading, instead of in both columns.
    private var extraLarge: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                StatusPill(entry: entry)
                HeroValue(entry: entry, size: 60)
                HStack(spacing: 10) {
                    WidgetTrend(entry: entry, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trendHeadline)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        DetailLine(entry: entry, showsTrendWord: false)
                    }
                }
                outlookRow
                Spacer(minLength: 0)
                if config.showsStats {
                    summaryStrip(caption: "Last 12h")
                }
                HStack(spacing: 8) {
                    if showsRefresh { RefreshButton(size: 26) }
                    DashboardLink(size: 26)
                    Spacer(minLength: 0)
                    if s.fetchedAt > .distantPast {
                        Text("Updated \(Format.age(entry.date.timeIntervalSince(s.fetchedAt)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 210, maxWidth: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                WidgetCaption(text: chartCaption, systemImage: "waveform.path.ecg")
                chart(axes: true, lineWidth: 2.75)
            }
        }
    }

    private var trendHeadline: String {
        guard let cur = s.current else { return "No reading" }
        guard entry.freshness == .fresh else { return entry.freshness == .stale ? "Trend paused" : "No recent data" }
        return cur.trend == .unknown ? "Trend unknown" : cur.trend.description
    }

    // MARK: Summary

    /// Time in range as one bar, with the three numbers people actually check. Hidden entirely
    /// once the reading has expired, because the window it describes is no longer "the last 12h".
    @ViewBuilder
    private func summaryStrip(caption: String) -> some View {
        if let st = stats12h {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetCaption(text: caption)
                    Spacer(minLength: 0)
                    Text("Avg \(s.unit.format(mgdl: st.meanMgdl))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TimeInRangeBar(stats: st, height: 7)
                HStack(spacing: 8) {
                    WidgetStat(title: "Below", value: Format.percent(st.timeBelowRange), dot: GlucoseRange.low.tint, valueSize: 13)
                    WidgetStat(title: "In range", value: Format.percent(st.timeInRange), dot: GlucoseRange.inRange.tint, valueSize: 13)
                    WidgetStat(title: "Above", value: Format.percent(st.timeAboveRange), dot: GlucoseRange.high.tint, valueSize: 13)
                }
            }
        }
    }
}

// MARK: - Preview data

extension GlucoseSnapshot {
    static var preview: GlucoseSnapshot {
        let now = Date()
        var hist: [GlucoseReading] = []
        for i in stride(from: 144, through: 1, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 300)
            let v = 120 + 55 * sin(Double(i) / 18) + 12 * cos(Double(i) / 5)
            hist.append(GlucoseReading(timestamp: t, mgdl: v, trend: .flat))
        }
        var s = GlucoseSnapshot()
        s.history = hist
        s.current = GlucoseReading(timestamp: now.addingTimeInterval(-90), mgdl: 112, trend: .rising)
        s.sensor = SensorInfo(serial: "0M0001ABCDE", activated: now.addingTimeInterval(-9 * 86_400), lifetimeDays: 15)
        s.fetchedAt = now
        return s
    }

    /// Same data, last read 18 minutes ago: for checking the stale styling.
    static var stalePreview: GlucoseSnapshot {
        var s = preview
        s.current = GlucoseReading(timestamp: Date().addingTimeInterval(-18 * 60), mgdl: 112, trend: .rising)
        s.history = s.history.filter { $0.timestamp < Date().addingTimeInterval(-18 * 60) }
        return s
    }
}

#Preview("Small", as: .systemSmall) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
    GlucoseEntry(date: .now, snapshot: .stalePreview)
}

#Preview("Medium", as: .systemMedium) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
    GlucoseEntry(date: .now, snapshot: .stalePreview)
}

#Preview("Large", as: .systemLarge) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
}

#Preview("Extra large", as: .systemExtraLarge) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
}
