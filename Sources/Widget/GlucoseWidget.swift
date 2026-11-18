import WidgetKit
import SwiftUI

#if os(macOS)
@main
struct GlucOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
        TimeInRangeWidget()
        SensorWidget()
        UsualWidget()
    }
}
#endif
// The iPhone has its own bundle (Sources/iOSWidget) that adds the Live Activity.

// MARK: - Widget

struct GlucoseWidget: Widget {
    /// Unchanged from the first release, so widgets people already placed keep working.
    let kind = "au.com.declanmayo.glucos.glucose"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: GlucoseWidgetIntent.self, provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
                .modifier(UrgentLowBorder(entry: entry))
                .containerBackground(for: .widget) { SignalWidgetBackdrop(entry: entry) }
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
    @Environment(\.widgetRenderingMode) private var renderingMode
    #if os(iOS)
    /// False in StandBy (and on the iPad Lock Screen), where the system drops the background and
    /// draws the small widget large: the bedside layout is `StandByGlucoseView`.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    #endif
    let entry: GlucoseEntry

    private var s: GlucoseSnapshot { entry.snapshot }
    private var config: GlucoseWidgetIntent { entry.configuration }
    private var hours: Double { config.window.hours(for: family) }

    var body: some View {
        switch family {
        case .systemSmall: smallOrStandBy
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

    /// Where the reading sits between urgent low and very high (docs/Redesign.md §9), with the
    /// forecast's ghost marker while the reading is fresh. One ink in accented / vibrant modes.
    @ViewBuilder
    private func rail(_ thickness: CGFloat, forecast: Bool = true) -> some View {
        if let cur = s.current, entry.freshness.showsValue {
            let stale = entry.freshness != .fresh
            RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: stale,
                      forecastMgdl: forecast && !stale
                          ? s.currentOutlook(at: entry.date).flatMap(OutlookFormat.headlineSample)?.sample.mgdl : nil,
                      thickness: thickness, monochrome: renderingMode != .fullColor, unit: s.unit)
        }
    }

    private func chart(axes: Bool, lineWidth: CGFloat = 2.25) -> some View {
        WidgetChart(snapshot: s, now: entry.date, hours: hours, tint: entry.tint, showsAxes: axes, lineWidth: lineWidth)
            // The same spoken summary as the app's charts: where it is now, lowest and highest,
            // time in range, and "Stale" first when the newest reading is old.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Glucose chart")
            .accessibilityValue(chartSummary)
    }

    private var chartSummary: String {
        let start = entry.date.addingTimeInterval(-hours * 3600)
        var points = s.history
        if let cur = s.current, !points.contains(where: { $0.timestamp == cur.timestamp }) { points.append(cur) }
        let fresh = entry.freshness == .fresh
        return ChartSummary.sentence(.init(
            readings: points.filter { $0.timestamp >= start && $0.timestamp <= entry.date.addingTimeInterval(60) },
            lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, unit: s.unit, hours: hours, stale: !fresh,
            forecastEnd: fresh ? s.currentOutlook(at: entry.date)?.forecast.last : nil))
    }

    /// The reading as VoiceOver says it, matched to what's drawn for this freshness: a stale
    /// reading is never read with its range or trend, an expired one says when the last was.
    private var spokenReading: String {
        let state: WidgetSpeech.State
        switch entry.freshness {
        case .fresh: state = .fresh
        case .stale: state = .stale
        case .expired: state = .expired
        case .none: state = .none
        }
        return WidgetSpeech.reading(s, state: state, at: entry.date)
    }

    private func hero(_ size: CGFloat) -> some View {
        HeroValue(entry: entry, size: size)
            .accessibilityLabel(spokenReading)
    }

    /// The refresh button is offered whenever the reading isn't fresh, even if hidden in settings,
    /// because that's exactly when someone wants it.
    private var showsRefresh: Bool { config.showsRefresh || entry.freshness != .fresh }

    // MARK: Small

    @ViewBuilder private var smallOrStandBy: some View {
        #if os(iOS)
        if showsBackground { small } else { StandByGlucoseView(entry: entry, spoken: spokenReading) }
        #else
        small
        #endif
    }

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
            hero(46)
            DetailLine(entry: entry, showsTrendWord: false)
                .padding(.top, 1)
            rail(4, forecast: false)
                .padding(.top, 6)
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
                hero(40)
                DetailLine(entry: entry)
                    .padding(.top, 1)
                rail(4)
                    .padding(.top, 6)
            }
            .frame(minWidth: 112, maxWidth: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    WidgetCaption(text: chartCaption)
                    Spacer(minLength: 0)
                    if showsRefresh { RefreshButton(size: 20) }
                }
                chart(axes: false)
                WidgetSignalFooter(entry: entry, meterWidth: 32)
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
                    hero(50)
                    DetailLine(entry: entry)
                    rail(5)
                        .frame(maxWidth: 200)
                        .padding(.top, 4)
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
                HStack(spacing: 6) {
                    WidgetCaption(text: chartCaption)
                    Spacer(minLength: 0)
                    meter
                }
                chart(axes: true)
            }
            .frame(maxHeight: .infinity)

            outlookRow

            if config.showsStats {
                daySummary
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
                hero(60)
                rail(6)
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
                    daySummary
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
                HStack(spacing: 6) {
                    WidgetCaption(text: chartCaption, systemImage: "waveform.path.ecg")
                    Spacer(minLength: 0)
                    meter
                }
                chart(axes: true, lineWidth: 2.75)
            }
        }
    }

    /// The freshness meter on its own, beside the chart's caption on the larger sizes, where the
    /// forecast already has its own row (`outlookRow`).
    @ViewBuilder private var meter: some View {
        if let cur = s.current, entry.freshness.showsValue {
            FreshnessMeter(readingDate: cur.timestamp, stale: entry.freshness != .fresh, tint: entry.tint, width: 40)
                .widgetAccentable()
        }
    }

    private var trendHeadline: String {
        guard let cur = s.current else { return "No reading" }
        guard entry.freshness == .fresh else { return entry.freshness == .stale ? "Trend paused" : "No readings" }
        return cur.trend == .unknown ? "Trend unknown" : cur.trend.description
    }

    // MARK: Summary

    /// Today so far against your usual day (#105) once today has an hour of readings, otherwise the
    /// last 12 hours. The figures run to the newest reading and the strip names that time, so it
    /// stays true when the reading goes stale; it's dropped at midnight until the app has worked
    /// out the new day.
    @ViewBuilder private var daySummary: some View {
        if let today = s.today, today.isCurrent(at: entry.date) {
            TodayStrip(today: today, unit: s.unit)
        } else {
            summaryStrip(caption: "Last 12h")
        }
    }

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
                        .contentTransition(.numericText(value: st.meanMgdl))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TimeInRangeBar(stats: st, height: 7)
                HStack(spacing: 8) {
                    WidgetStat(title: "Below", value: Format.percent(st.timeBelowRange), dot: GlucoseRange.low.tint, valueSize: 13,
                               numeric: st.timeBelowRange)
                    WidgetStat(title: "In range", value: Format.percent(st.timeInRange), dot: GlucoseRange.inRange.tint, valueSize: 13,
                               numeric: st.timeInRange)
                    WidgetStat(title: "Above", value: Format.percent(st.timeAboveRange), dot: GlucoseRange.high.tint, valueSize: 13,
                               numeric: st.timeAboveRange)
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
        s.today = TodayGlance(day: Calendar.current.startOfDay(for: now), period: "Midnight to 2:30 pm",
                              headline: "More time in range than your usual day by now.",
                              timeInRange: 0.81, meanMgdl: 128, lows: 0,
                              rangeCaption: "Usually 72%", meanCaption: "Usually 7.6",
                              lowsCaption: "Usually none by now",
                              spoken: "Today so far, midnight to 2:30 pm. More time in range than your usual day by now.")
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
    GlucoseEntry(date: .now, snapshot: .stalePreview)
}

#Preview("Extra large", as: .systemExtraLarge) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
}

// MARK: - Today so far strip

/// The large widget's version of the Today so far card: the one-line answer, then time in range,
/// average and lows, each with your usual day under it. Neutral colours only: like the card, it
/// observes and never judges, and it never borrows a reading's range colour.
private struct TodayStrip: View {
    let today: TodayGlance
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WidgetCaption(text: "Today so far", systemImage: "sun.max")
                Spacer(minLength: 0)
                Text(today.period)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(today.headline)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(alignment: .top, spacing: 8) {
                cell("In range", Format.percent(today.timeInRange), today.rangeCaption,
                     dot: GlucoseRange.inRange.tint, numeric: today.timeInRange)
                cell("Average", unit.format(mgdl: today.meanMgdl), today.meanCaption, numeric: today.meanMgdl)
                cell("Lows", today.lows == 0 ? "None" : "\(today.lows)", today.lowsCaption, numeric: Double(today.lows))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(today.spoken)
    }

    private func cell(_ title: String, _ value: String, _ caption: String?, dot: Color? = nil,
                      numeric: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetStat(title: title, value: value, dot: dot, valueSize: 13, numeric: numeric)
            if let caption {
                Text(caption)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
