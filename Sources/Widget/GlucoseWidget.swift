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

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                StatusPill(entry: entry, compact: true)
                Spacer(minLength: 2)
                HeroValue(entry: entry, size: 42)
                DetailLine(entry: entry)
                    .padding(.top, 1)
            }
            .frame(width: 126, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    WidgetCaption(text: chartCaption)
                    Spacer(minLength: 0)
                    if showsRefresh { RefreshButton(size: 20) }
                    WidgetTrend(entry: entry, size: 22)
                }
                chart(axes: false)
            }
        }
    }

    // MARK: Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    StatusPill(entry: entry)
                    HeroValue(entry: entry, size: 52)
                    DetailLine(entry: entry)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    WidgetTrend(entry: entry, size: 52)
                    HStack(spacing: 6) {
                        if showsRefresh { RefreshButton() }
                        DashboardLink()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                WidgetCaption(text: chartCaption)
                chart(axes: true)
            }

            if config.showsStats {
                statsRow(ringSize: 62)
            }
        }
    }

    // MARK: Extra large

    private var extraLarge: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                StatusPill(entry: entry)
                HeroValue(entry: entry, size: 72)
                DetailLine(entry: entry)
                HStack(spacing: 10) {
                    WidgetTrend(entry: entry, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.current.map { entry.freshness == .fresh ? $0.trend.description : "Trend unavailable" } ?? "No trend")
                            .font(.callout.weight(.semibold))
                        if let cur = s.current {
                            Text("Read at \(cur.timestamp.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                if config.showsStats, let st = stats12h {
                    VStack(alignment: .leading, spacing: 6) {
                        WidgetCaption(text: "Last 12h in range")
                        TimeInRangeBar(stats: st, height: 8)
                        HStack {
                            WidgetStat(title: "Below", value: Format.percent(st.timeBelowRange), dot: GlucoseRange.low.tint, valueSize: 13)
                            WidgetStat(title: "In range", value: Format.percent(st.timeInRange), dot: GlucoseRange.inRange.tint, valueSize: 13)
                            WidgetStat(title: "Above", value: Format.percent(st.timeAboveRange), dot: GlucoseRange.high.tint, valueSize: 13)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if showsRefresh { RefreshButton(size: 28) }
                    DashboardLink(size: 28)
                    Spacer(minLength: 0)
                    if s.fetchedAt > .distantPast {
                        Text("Updated \(Format.age(entry.date.timeIntervalSince(s.fetchedAt)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 230, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                WidgetCaption(text: chartCaption, systemImage: "waveform.path.ecg")
                chart(axes: true, lineWidth: 2.75)
                if config.showsStats {
                    statsGrid
                }
            }
        }
    }

    // MARK: Stats

    private func statsRow(ringSize: CGFloat) -> some View {
        let st = stats12h
        return HStack(spacing: 12) {
            if let st {
                TimeInRangeRing(stats: st, lineWidth: 6)
                    .frame(width: ringSize, height: ringSize)
            }
            statsGrid
        }
    }

    private var statsGrid: some View {
        let st = stats12h
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                WidgetStat(title: "Average", value: st.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–")
                WidgetStat(title: "Low · High", value: st.map { "\(s.unit.format(mgdl: $0.minMgdl))–\(s.unit.format(mgdl: $0.maxMgdl))" } ?? "–")
                WidgetStat(title: "CV", value: st.map { Format.percent($0.coefficientOfVariation) } ?? "–",
                           dot: st.map { $0.coefficientOfVariation > 0.36 ? GlucoseRange.high.tint : GlucoseRange.inRange.tint })
            }
            GridRow {
                WidgetStat(title: "Below", value: st.map { Format.percent($0.timeBelowRange) } ?? "–", dot: GlucoseRange.low.tint)
                WidgetStat(title: "Above", value: st.map { Format.percent($0.timeAboveRange) } ?? "–", dot: GlucoseRange.high.tint)
                WidgetStat(title: "Sensor", value: s.sensor.map { Format.days($0.daysRemaining(at: entry.date)) } ?? "–")
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
