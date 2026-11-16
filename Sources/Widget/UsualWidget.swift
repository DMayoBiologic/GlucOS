import AppIntents
import SwiftUI
import WidgetKit

/// The Your usual widget (docs/UsualEntries.md), on the iPhone Home Screen and the Mac desktop: the
/// entries the log sheet would offer now, up to three, as buttons. A button opens GlucOS on the log
/// sheet (iPhone, `OpenUsualIntent`) or the log window (Mac, `UsualGlance.openURL`) filled in from
/// that entry; nothing is logged from the widget, so `RepeatCheck`, the calculator and its confirm
/// step all still run before Log. The app works the entries out (`GlucoseSnapshot.usuals`)
/// and reloads this kind only when they change (`WidgetReload.Group.usual`). Nothing moves here:
/// widgets run no timers, and the system cross-fades between timeline entries.
struct UsualWidget: Widget {
    let kind = "au.com.declanmayo.glucos.usual"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsualProvider()) { entry in
            UsualWidgetView(entry: entry)
                .containerBackground(for: .widget) { Palette.windowBackground }
                .widgetURL(URL(string: "glucos://log"))
        }
        .configurationDisplayName("Your Usual")
        #if os(iOS)
        .description("Your usual meal, correction or low treatment, one tap from the log sheet. You check it and log it there.")
        #else
        .description("Your usual meal, correction or low treatment, one click from the log window. You check it and log it there.")
        #endif
        .supportedFamilies([.systemMedium])
    }
}

struct UsualEntryTimeline: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot

    var usuals: [UsualGlance] {
        UsualGlance.visible(snapshot.usuals ?? [], readingFresh: !snapshot.isStale(at: date), at: date)
    }
}

struct UsualProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsualEntryTimeline {
        UsualEntryTimeline(date: Date(), snapshot: .usualPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsualEntryTimeline) -> Void) {
        let snap = context.isPreview ? .usualPreview : (SharedStore.load() ?? .empty)
        completion(UsualEntryTimeline(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsualEntryTimeline>) -> Void) {
        let now = Date()
        let snap = SharedStore.load() ?? .empty
        let staleAt = snap.current.map { $0.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter) }
        // One entry now, and one at each moment the entries change on their own (a meal's part of
        // the day ending, a correction's reading going stale). The app reloads on anything else.
        let dates = [now] + UsualGlance.changeDates(snap.usuals ?? [], staleAt: staleAt, after: now)
        completion(Timeline(entries: dates.map { UsualEntryTimeline(date: $0, snapshot: snap) }, policy: .never))
    }
}

struct UsualWidgetView: View {
    let entry: UsualEntryTimeline

    var body: some View {
        let usuals = entry.usuals
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetCaption(text: "Your usual", systemImage: "arrow.triangle.2.circlepath")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Link(destination: URL(string: "glucos://log")!) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.09), in: Circle())
                        .widgetAccentable()
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Log something else")
            }
            if usuals.isEmpty {
                empty
            } else {
                HStack(spacing: 8) {
                    ForEach(usuals) { UsualWidgetButton(usual: $0) }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            Text("Nothing usual yet")
                .font(.headline)
            Text("Log the same meal on a few days, and it shows here ready to log again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One entry: opens the log sheet filled in from it. Never logs.
struct UsualWidgetButton: View {
    let usual: UsualGlance
    @Environment(\.widgetRenderingMode) private var mode

    private var tint: Color {
        switch usual.kind {
        case .meal: return Palette.food
        case .correction: return Palette.insulin
        case .low: return Tone.critical.textColor
        }
    }

    /// The low treatment is filled, not only coloured, so it stands out without colour (as in the
    /// sheet). Plain in the tinted and vibrant modes, where colour is gone.
    private var fill: Color {
        guard mode.isFullColor else { return Color.primary.opacity(0.08) }
        return tint.opacity(usual.kind == .low ? 0.22 : 0.12)
    }

    /// The detail line ("Toast and banana · 45 g") on the tile. `.secondary` measured 2.95:1 on the
    /// filled low tile in light mode and about 3.5:1 on the Mac desktop, under the 4.5:1 that text
    /// this small needs; the primary colour at 72 % keeps at least 5.6:1 on every tile, light and
    /// dark (docs/DesignSystem.md). The tinted and vibrant modes keep the system's own style.
    private var detailStyle: AnyShapeStyle {
        mode.isFullColor ? AnyShapeStyle(Color.primary.opacity(0.72)) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    var body: some View {
        action {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: usual.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mode.isFullColor ? tint : .primary)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text(usual.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if !usual.detail.isEmpty {
                    Text(usual.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(detailStyle)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel(usual.spoken)
        .accessibilityHint("Opens GlucOS with it filled in. Check it, then log.")
    }

    /// iPhone: an App Intent that opens the app, handing the entry over through the app group.
    /// Mac: the widget extension has no app group and only reads the app's folder, so an intent
    /// can't reach the app; a link does, and AppDelegate opens the log window on the entry.
    @ViewBuilder
    private func action<Content: View>(@ViewBuilder label: () -> Content) -> some View {
        #if os(iOS)
        Button(intent: OpenUsualIntent(usualID: usual.id), label: label)
            .buttonStyle(.plain)
        #else
        Link(destination: usual.openURL, label: label)
            .buttonStyle(.plain)
        #endif
    }
}

extension GlucoseSnapshot {
    /// The widget gallery's example.
    static var usualPreview: GlucoseSnapshot {
        var s = GlucoseSnapshot.preview
        s.usuals = [
            UsualGlance(id: "meal-breakfast", kind: .meal, title: "Usual breakfast", detail: "Toast and banana · 45 g",
                        systemImage: "sunrise", spoken: "Usual breakfast: toast and banana, 45 grams of carbs"),
            UsualGlance(id: "low", kind: .low, title: "Treat a low", detail: "Jelly beans · 15 g",
                        systemImage: "cube", spoken: "Treat a low: jelly beans, 15 grams of carbs"),
        ]
        return s
    }
}
