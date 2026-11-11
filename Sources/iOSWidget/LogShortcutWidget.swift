import SwiftUI
import WidgetKit

/// A Lock Screen button that opens GlucOS straight to the log sheet (`glucos://log`).
struct LogShortcutWidget: Widget {
    let kind = "au.com.declanmayo.glucos.log"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LogShortcutProvider()) { _ in
            LogShortcutView()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "glucos://log"))
        }
        .configurationDisplayName("Log")
        .description("Log insulin, food or an event in one tap.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct LogShortcutEntry: TimelineEntry {
    let date: Date
}

struct LogShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> LogShortcutEntry { LogShortcutEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (LogShortcutEntry) -> Void) {
        completion(LogShortcutEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LogShortcutEntry>) -> Void) {
        completion(Timeline(entries: [LogShortcutEntry(date: Date())], policy: .never))
    }
}

struct LogShortcutView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                    Text("Log")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .widgetAccentable()
            .accessibilityLabel("Log in GlucOS")
        default:
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Log").font(.headline)
                    Text("Insulin, food, events").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .widgetAccentable()
            .accessibilityElement(children: .combine)
        }
    }
}

/// A Lock Screen button that logs "Woke up" in one tap (`glucos://log/wake`). GlucOS opens, logs
/// it (or says it's already logged) and offers Undo and Change.
struct WakeShortcutWidget: Widget {
    let kind = "au.com.declanmayo.glucos.wake"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LogShortcutProvider()) { _ in
            WakeShortcutView()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "glucos://log/wake"))
        }
        .configurationDisplayName("Woke Up")
        .description("Log when you wake up, so GlucOS can learn your mornings.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct WakeShortcutView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Up")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .widgetAccentable()
            .accessibilityLabel("Log wake-up in GlucOS")
        default:
            HStack(spacing: 8) {
                Image(systemName: "sunrise.fill")
                    .font(.system(size: 24, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Woke up").font(.headline)
                    Text("Tap to log it").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .widgetAccentable()
            .accessibilityElement(children: .combine)
        }
    }
}
