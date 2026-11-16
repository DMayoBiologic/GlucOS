import SwiftUI
import WidgetKit

/// Lock Screen widgets (circular, rectangular, inline): the reading, trend and age, from the app's
/// shared snapshot. StandBy shows the small Glucose widget in its own layout
/// (StandByGlucoseView.swift), not these. They only change when the app has run (or the timeline's
/// own age steps), so the Live Activity is the one to rely on while locked.
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
    private var fresh: Bool { freshness == .fresh }
    private var stale: Bool { freshness == .stale }
    private var value: String {
        guard freshness.showsValue, let c = s.current else { return "––" }
        return s.unit.format(mgdl: c.mgdl)
    }
    private var trend: Trend { s.current?.trend ?? .unknown }
    /// Lock Screen accessories are drawn monochrome, so the tone only times the figure's change
    /// (`readingChange`); the colour itself is the system's.
    private var tone: Tone {
        guard fresh, let range = s.range else { return .stale }
        return .glucose(range)
    }

    /// The same words as the Home Screen widget's VoiceOver label (`WidgetSpeech`): a stale
    /// reading is never read with its range or trend, a withdrawn one says when the last was.
    private var spoken: String {
        WidgetSpeech.reading(s, state: AccessoryGlance.state(s, at: entry.date), at: entry.date)
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: rectangular
        }
    }

    // MARK: Circular

    /// The figure with the trend under it while fresh, inside a ring that empties over the
    /// reading's life (docs/Redesign.md §9), live, with no timeline reload: a full ring is a fresh
    /// reading. Once stale the ring goes, the figure is struck through and its age ("12m") takes
    /// the arrow's place; once withdrawn there's no figure, only the age.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if fresh, let c = s.current {
                ProgressView(timerInterval: c.timestamp...c.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter),
                             countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .labelsHidden()
            }
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(fresh ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                           : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .readingChange(mgdl: s.current?.mgdl ?? 0, tone: tone)
                    .staleStrike(stale, thickness: 2)
                if let caption = AccessoryGlance.circularCaption(s, at: entry.date) {
                    HStack(spacing: 1) {
                        Image(systemName: "clock")
                        Text(caption).monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                } else {
                    TrendArrow(trend: trend, stale: !fresh, staleSymbol: "drop.degreesign.slash")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .padding(4)
        }
        .widgetAccentable()
    }

    // MARK: Inline

    /// One line beside the date: "6.1 ↗ · 2m", "Stale 6.1 · 12m", "No reading for 45m". The age
    /// steps with the timeline's per-minute entries (`FreshnessSchedule`).
    private var inline: some View {
        HStack(spacing: 4) {
            if !fresh { Image(systemName: freshness.showsValue ? "clock.badge.exclamationmark" : "drop.degreesign.slash") }
            Text(AccessoryGlance.inline(s, at: entry.date))
        }
    }

    // MARK: Rectangular

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(freshness.showsValue ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                                          : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    .readingChange(mgdl: s.current?.mgdl ?? 0, tone: tone)
                    // The same drawn line as the Home Screen widget and the Live Activity (§4.3).
                    .staleStrike(stale, thickness: 2.5)
                TrendArrow(trend: trend, stale: !fresh,
                           staleSymbol: freshness.showsValue ? "clock.badge.exclamationmark" : "drop.degreesign.slash")
                    .font(.system(size: 15, weight: .bold))
                if freshness.showsValue {
                    Text(s.unit.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if fresh, let back = s.backInRange(at: entry.date) {
                // From a high, once this iPhone's checks allow it (`GlucoseSnapshot.backInRange`).
                Text(BackInRangeText.short(minutes: back.minutes)).font(.caption).monospacedDigit()
            } else if fresh, let o = s.currentOutlook(at: entry.date), let h = OutlookFormat.headlineSample(o) {
                Text("\(OutlookFormat.approx(h.sample.mgdl, unit: s.unit)) in \(h.minutes) min").font(.caption)
            } else if fresh, let range = s.range {
                Text(range.label).font(.caption)
            } else if stale {
                // The Lock Screen has no colour to carry it, so stale says so in words.
                Text("Stale · trend paused").font(.caption)
            }
            HStack(spacing: 6) {
                if let c = s.current, freshness.showsValue {
                    RangeRail(mgdl: c.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: !fresh,
                              thickness: 3, monochrome: true, unit: s.unit)
                        .frame(maxWidth: 64)
                    // The age ticks live between timeline reloads (§9 "age timer").
                    ReadingAge(readingDate: c.timestamp, stale: !fresh, timerWidth: 34)
                        .font(.caption2)
                        .lineLimit(1)
                } else if let line = AccessoryGlance.withdrawnLine(s, at: entry.date) {
                    Text(line).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}

#Preview("Circular", as: .accessoryCircular) {
    GlucoseAccessoryWidget()
} timeline: {
    AccessoryEntry(date: .now, snapshot: .preview)
    AccessoryEntry(date: .now, snapshot: .stalePreview)
    AccessoryEntry(date: .now.addingTimeInterval(40 * 60), snapshot: .preview)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    GlucoseAccessoryWidget()
} timeline: {
    AccessoryEntry(date: .now, snapshot: .preview)
    AccessoryEntry(date: .now, snapshot: .stalePreview)
    AccessoryEntry(date: .now.addingTimeInterval(40 * 60), snapshot: .preview)
}

#Preview("Inline", as: .accessoryInline) {
    GlucoseAccessoryWidget()
} timeline: {
    AccessoryEntry(date: .now, snapshot: .preview)
    AccessoryEntry(date: .now, snapshot: .stalePreview)
}
