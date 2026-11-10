import WidgetKit
import SwiftUI
import AppKit

@main
struct GlucOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
    }
}

// MARK: - Timeline

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot
}

struct GlucoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(GlucoseEntry(date: Date(), snapshot: context.isPreview ? .preview : (SharedStore.load() ?? .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        let snap = SharedStore.load() ?? .empty
        let now = Date()
        // The app calls reloadAllTimelines() after every fetch; these entries only keep the
        // "x min ago" text and stale styling honest if the app is quiet.
        var entries: [GlucoseEntry] = []
        for m in stride(from: 0, through: 10, by: 2) {
            entries.append(GlucoseEntry(date: now.addingTimeInterval(Double(m) * 60), snapshot: snap))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(12 * 60))))
    }
}

// MARK: - Widget

struct GlucoseWidget: Widget {
    let kind = "au.com.declanmayo.glucos.glucose"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(entry: entry) }
                // Click the widget to open the GlucOS popover (handled in AppDelegate).
                .widgetURL(URL(string: "glucos://open"))
        }
        .configurationDisplayName("Glucose")
        .description("Current reading, trend and recent history from LibreLinkUp.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

/// Window background washed with the current range colour. Neutral when the data is stale.
struct WidgetBackdrop: View {
    let entry: GlucoseEntry

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            AmbientGlow(tint: entry.snapshot.displayTint(at: entry.date), intensity: 0.9)
        }
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseEntry

    private var s: GlucoseSnapshot { entry.snapshot }
    private var stale: Bool { s.isStale(at: entry.date) }
    private var tint: Color { s.displayTint(at: entry.date) }

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var rangeColor: Color { s.range?.valueColor ?? .primary }

    private func value(size: CGFloat) -> some View {
        Group {
            if let cur = s.current {
                Text(s.unit.format(mgdl: cur.mgdl))
                    .foregroundStyle(stale ? Color.secondary : rangeColor)
                    .contentTransition(.numericText(value: cur.mgdl))
                    .widgetAccentable()
            } else {
                Text("––").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .accessibilityLabel(s.accessibilitySummary(at: entry.date))
    }

    private var rangeLabel: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7).widgetAccentable()
            Text(stale ? "Stale" : (s.range?.label ?? "No data"))
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(stale ? Color.secondary : tint)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    private var deltaText: some View {
        Group {
            if let cur = s.current {
                HStack(spacing: 4) {
                    Text(cur.trend.description)
                        .font(.caption.weight(.semibold))
                    if let d = s.deltaMgdl {
                        Text(s.unit.formatDelta(mgdl: d))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .accessibilityHidden(true)
    }

    private var ageLine: some View {
        HStack(spacing: 3) {
            if stale { Image(systemName: "exclamationmark.triangle.fill") }
            Text(s.current.map { Format.age($0.age(at: entry.date)) } ?? (s.lastError == nil ? "no data" : "error"))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(stale ? Color.orange : Color.secondary)
        .accessibilityHidden(s.current != nil)
    }

    @ViewBuilder
    private func dial(size: CGFloat) -> some View {
        if let cur = s.current {
            TrendDial(trend: cur.trend, tint: tint, size: size)
                .accessibilityHidden(true)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                rangeLabel
                Spacer(minLength: 4)
                dial(size: 34)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                value(size: 46)
                Text(s.unit.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            deltaText
            ageLine
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                rangeLabel
                Spacer(minLength: 0)
                value(size: 44)
                Text(s.unit.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                deltaText
                ageLine
            }
            .frame(width: 112, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                dial(size: 28)
                GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, hours: 3, showAxes: false)
            }
        }
    }

    private var large: some View {
        let st = s.stats(hours: 12)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    rangeLabel
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        value(size: 50)
                        Text(s.unit.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        deltaText
                        Text("·").foregroundStyle(.tertiary)
                        ageLine
                    }
                }
                Spacer()
                dial(size: 58)
            }
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, hours: 12)
            HStack(spacing: 12) {
                if let st {
                    TimeInRangeRing(stats: st, lineWidth: 7)
                        .frame(width: 70, height: 70)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        stat("Below", st.map { Format.percent($0.timeBelowRange) } ?? "–", GlucoseRange.low.tint)
                        stat("Above", st.map { Format.percent($0.timeAboveRange) } ?? "–", GlucoseRange.high.tint)
                        stat("Avg", st.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–", nil)
                    }
                    GridRow {
                        stat("CV", st.map { Format.percent($0.coefficientOfVariation) } ?? "–", nil)
                        stat("Sensor", s.sensor.map { Format.days($0.daysRemaining(at: entry.date)) } ?? "–", nil)
                        stat("Range", st.map { "\(s.unit.format(mgdl: $0.minMgdl))–\(s.unit.format(mgdl: $0.maxMgdl))" } ?? "–", nil)
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ v: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if let color { Circle().fill(color).frame(width: 5, height: 5) }
                Text(title)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            Text(v)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview data

extension GlucoseSnapshot {
    static var preview: GlucoseSnapshot {
        let now = Date()
        var hist: [GlucoseReading] = []
        for i in stride(from: 144, through: 1, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 300)
            let v = 110 + 35 * sin(Double(i) / 18) + 10 * cos(Double(i) / 5)
            hist.append(GlucoseReading(timestamp: t, mgdl: v, trend: .flat))
        }
        var s = GlucoseSnapshot()
        s.history = hist
        s.current = GlucoseReading(timestamp: now.addingTimeInterval(-90), mgdl: 101, trend: .rising)
        s.sensor = SensorInfo(serial: "0M0001ABCDE", activated: now.addingTimeInterval(-9 * 86_400), lifetimeDays: 15)
        s.fetchedAt = now
        return s
    }
}

#Preview(as: .systemMedium) {
    GlucoseWidget()
} timeline: {
    GlucoseEntry(date: .now, snapshot: .preview)
}
