import SwiftUI
import WidgetKit

/// Lock Screen and StandBy widgets: the reading, trend and age, from the app's shared snapshot.
/// They only change when the app has run (or the timeline's own age steps), so the Live
/// Activity is the one to rely on while locked.
struct GlucoseAccessoryWidget: Widget {
    let kind = "au.com.declanmayo.glucos.accessory"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccessoryProvider()) { entry in
            AccessoryGlucoseView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "glucos://open"))
        }
        .configurationDisplayName("Glucose")
        .description("Your latest reading and trend.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct AccessoryEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot
}

struct AccessoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> AccessoryEntry {
        var s = GlucoseSnapshot()
        s.current = GlucoseReading(timestamp: Date(), mgdl: 112, trend: .flat)
        return AccessoryEntry(date: Date(), snapshot: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (AccessoryEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : AccessoryEntry(date: Date(), snapshot: SharedStore.load() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccessoryEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedStore.load() ?? .empty
        let dates = FreshnessSchedule.dates(for: snapshot, from: now)
        completion(Timeline(entries: dates.map { AccessoryEntry(date: $0, snapshot: snapshot) },
                            policy: .after(FreshnessSchedule.reloadDate(after: dates, now: now))))
    }
}

struct AccessoryGlucoseView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AccessoryEntry

    private var s: GlucoseSnapshot { entry.snapshot }
    private var freshness: ReadingFreshness { ReadingFreshness(s, at: entry.date) }
    private var value: String {
        guard freshness.showsValue, let c = s.current else { return "––" }
        return s.unit.format(mgdl: c.mgdl)
    }
    private var symbol: String {
        guard freshness == .fresh, let c = s.current else { return "clock.badge.exclamationmark" }
        return c.trend.systemImage
    }
    private var age: String {
        s.current.map { Format.age($0.age(at: entry.date)) } ?? "No data"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .strikethrough(freshness == .stale)
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                }
                .padding(4)
            }
        case .accessoryInline:
            Text("\(value) \(freshness == .fresh ? (s.current?.trend.arrow ?? "") : "· \(age)")")
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .strikethrough(freshness == .stale)
                    Image(systemName: symbol).font(.system(size: 15, weight: .bold))
                    Text(s.unit.label).font(.caption2).foregroundStyle(.secondary)
                }
                if freshness == .fresh, let o = s.currentOutlook(at: entry.date), let h = OutlookFormat.headlineSample(o) {
                    Text("\(OutlookFormat.approx(h.sample.mgdl, unit: s.unit)) in \(h.minutes) min").font(.caption)
                } else if let range = s.range, freshness == .fresh {
                    Text(range.label).font(.caption)
                }
                Text(freshness == .fresh ? age : "Stale · \(age)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetAccentable()
        }
    }
}
