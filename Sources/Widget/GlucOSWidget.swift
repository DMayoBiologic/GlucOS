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
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Glucose")
        .description("Current reading, trend and recent history from LibreLinkUp.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseEntry

    private var s: GlucoseSnapshot { entry.snapshot }
    private var stale: Bool { s.isStale(at: entry.date) }

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var rangeColor: Color {
        switch s.range {
        case .urgentLow, .low, .veryHigh: return .red
        case .high: return .orange
        case .inRange, .none: return .primary
        }
    }

    private var value: some View {
        Group {
            if let cur = s.current {
                Text(s.unit.format(mgdl: cur.mgdl))
                    .foregroundStyle(stale ? Color.secondary : rangeColor)
            } else {
                Text("––").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 40, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }

    private var trendLine: some View {
        HStack(spacing: 6) {
            if let cur = s.current {
                Text(cur.trend.arrow).font(.title3.weight(.bold))
                if let d = s.deltaMgdl {
                    Text(s.unit.formatDelta(mgdl: d)).font(.subheadline).monospacedDigit()
                }
            }
        }
    }

    private var ageLine: some View {
        HStack(spacing: 3) {
            if stale { Image(systemName: "exclamationmark.triangle.fill") }
            Text(s.current.map { Format.age($0.age(at: entry.date)) } ?? (s.lastError == nil ? "no data" : "error"))
        }
        .font(.caption2)
        .foregroundStyle(stale ? Color.orange : Color.secondary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Image(systemName: "drop.fill").font(.caption).foregroundStyle(.secondary); Spacer(); ageLine }
            Spacer(minLength: 0)
            value
            trendLine
            Text(s.unit.label).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                ageLine
                Spacer(minLength: 0)
                value
                trendLine
                Text(s.unit.label).font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 110, alignment: .leading)
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, hours: 3, showAxes: false)
        }
    }

    private var large: some View {
        let st = s.stats(hours: 12)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                value
                VStack(alignment: .leading, spacing: 1) {
                    trendLine
                    ageLine
                }
                Spacer()
                if let sensor = s.sensor {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Sensor").font(.caption2).foregroundStyle(.secondary)
                        Text(Format.days(sensor.daysRemaining(at: entry.date))).font(.caption.weight(.semibold))
                    }
                }
            }
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, hours: 12)
            HStack {
                stat("In range", st.map { Format.percent($0.timeInRange) } ?? "–")
                stat("Below", st.map { Format.percent($0.timeBelowRange) } ?? "–")
                stat("Above", st.map { Format.percent($0.timeAboveRange) } ?? "–")
                stat("Avg", st.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–")
                stat("CV", st.map { Format.percent($0.coefficientOfVariation) } ?? "–")
            }
        }
    }

    private func stat(_ title: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
