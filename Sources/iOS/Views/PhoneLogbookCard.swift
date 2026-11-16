import SwiftUI

/// The last day's logbook, logged here or synced from the Mac (or anywhere else signed in to the
/// same LibreLinkUp account), grouped under Today and Yesterday so an earlier day's "10:46 am"
/// can't be read as later today. Logging starts from the bar at the bottom of the screen.
struct PhoneLogbookCard: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var sync: LogbookSyncService
    @EnvironmentObject var router: PhoneLogRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let window: TimeInterval = 24 * 3600
    private static let maxRows = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            let recent = logbook.entries.filter { $0.timestamp > now.addingTimeInterval(-Self.window) }
            content(recent: recent, now: now)
        }
    }

    private func content(recent: [LogEntry], now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title: "Logbook", systemImage: "list.bullet.rectangle", trailing: "Last 24 hours")
                if !logbook.isEmpty {
                    NavigationLink(value: PhoneRoute.logbook) {
                        Text("See All").dsFont(.label)
                    }
                    .accessibilityLabel("See the whole logbook")
                }
            }
            if recent.isEmpty {
                Text(logbook.isEmpty
                     ? "Use the buttons at the bottom of the screen to log insulin, food or an event. Entries from GlucOS on your Mac show up here too."
                     : "Nothing logged in the last 24 hours.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shown = Array(recent.prefix(Self.maxRows))
                ForEach(groups(shown, now: now), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .dsFont(.label)
                            .foregroundStyle(.secondary)
                            .padding(.top, DS.Space.xs)
                            .padding(.bottom, DS.Space.xxs)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            VStack(spacing: 0) {
                                if index > 0 { Divider().padding(.leading, 28) }
                                row(entry)
                            }
                            // New entries slide down into place; deletes fold away.
                            .transition(Self.rowTransition(reduceMotion: reduceMotion))
                        }
                    }
                }
                if recent.count > Self.maxRows {
                    NavigationLink(value: PhoneRoute.logbook) {
                        HStack(spacing: DS.Space.xs) {
                            Text("\(recent.count - Self.maxRows) more in the last 24 hours")
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .dsFont(.caption)
                    }
                    .padding(.top, DS.Space.xxs)
                }
            }
            syncLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
        // Rows in and out (an undo, a sync from the Mac, a new entry). Instant under Reduce Motion.
        .dsAnimation(.standard, value: recent.prefix(Self.maxRows).map(\.id))
    }

    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                               removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private struct DayGroup {
        let title: String
        let entries: [LogEntry]
    }

    /// Consecutive entries by day, newest first, titled "Today", "Yesterday" or the date.
    private func groups(_ entries: [LogEntry], now: Date) -> [DayGroup] {
        var out: [DayGroup] = []
        for e in entries {
            let title = ClockLabel.dayTitle(ClockLabel.day(of: e.timestamp, now: now))
            if let last = out.last, last.title == title {
                out[out.count - 1] = DayGroup(title: title, entries: last.entries + [e])
            } else {
                out.append(DayGroup(title: title, entries: [e]))
            }
        }
        return out
    }

    private func row(_ entry: LogEntry) -> some View {
        Button { router.edit(entry) } label: {
            PhoneLogRow(entry: entry, site: entry.dose.flatMap { logbook.site(of: $0) })
                .padding(.vertical, DS.Space.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
        .contextMenu {
            Button("Edit", systemImage: "pencil") { router.edit(entry) }
            Button("Log Again Now", systemImage: "arrow.clockwise") { logbook.duplicate(entry); Haptics.success() }
            Button("Delete", systemImage: "trash", role: .destructive) { logbook.delete(ids: [entry.id]) }
        }
    }

    @ViewBuilder
    private var syncLine: some View {
        if sync.status != .off {
            Label(sync.summary, systemImage: sync.isProblem ? "exclamationmark.icloud" : "arrow.triangle.2.circlepath.icloud")
                .dsFont(.caption)
                .foregroundStyle(sync.isProblem ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
    }
}

/// The bar along the bottom of the home screen: one tap for the two things logged most (eating,
/// a bolus), and More for everything else (a basal dose, waking up, going to sleep, exercise…),
/// which opens the log sheet on "What's happening?". It sits in the safe area under the scroll
/// view, so content scrolls up past it instead of hiding behind it.
struct PhoneLogBar: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: PhoneLogRouter
    /// Taps per button, so each icon gives one small bounce when pressed.
    @State private var taps: [String: Int] = [:]
    /// Saves, so the plus bounces once as the sheet closes after one (docs/Redesign.md §7.1).
    @State private var saves = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let tint: Color
        /// The part the sheet opens on, or nil to ask what's happening.
        let part: LogPart?
    }

    private var items: [Item] {
        var out = [Item(id: "eating", title: LogMoment.eating.title, systemImage: LogMoment.eating.systemImage,
                        tint: Palette.food, part: .food)]
        if settings.therapy.logsInsulin || settings.therapy == .notSet {
            out.append(Item(id: "bolus", title: LogMoment.bolus.title, systemImage: LogMoment.bolus.systemImage,
                            tint: Palette.insulin, part: .insulin))
        }
        out.append(Item(id: "more", title: "More", systemImage: "plus", tint: Palette.context, part: nil))
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // "4 u at 9:12 am. Was it for a meal?" after a bolus with no food near it, once per dose.
            PhoneDoseStrip()
            // "You went low at 9:12 pm… Did you treat it?" once a low with nothing logged is over.
            PhoneLowStrip()
            // "Woke up at 6:41?" in the morning, until it's logged or dismissed.
            PhoneWakeStrip()
            HStack(spacing: DS.Space.sm) {
                ForEach(items) { item in
                    Button {
                        // Counted only with motion allowed, so nothing bounces under Reduce Motion.
                        if !reduceMotion { taps[item.id, default: 0] += 1 }
                        router.open(item.part)
                    } label: {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.systemImage)
                                // One trigger: a tap, or (for the plus) a save.
                                .symbolEffect(.bounce, value: taps[item.id, default: 0] + (item.part == nil ? saves : 0))
                        }
                            .labelStyle(LogBarLabelStyle())
                            .foregroundStyle(item.tint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Space.sm + 2)
                            .background(item.tint.opacity(0.14), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(item.part == nil ? "Log something else" : "Log \(item.title)")
                    .accessibilityShowsLargeContentViewer()
                }
            }
        }
        .onChange(of: router.request == nil) { _, closed in
            guard closed, router.savedSinceOpen else { return }
            router.savedSinceOpen = false
            guard !reduceMotion else { return }
            Task { @MainActor in
                // After the sheet has slid away, so the bounce is seen.
                try? await Task.sleep(for: .milliseconds(380))
                saves += 1
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm + 2)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct LogBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        LogBarLabel(icon: configuration.icon, title: configuration.title)
    }
}

/// At the accessibility sizes the icon sits over the word, so three buttons still fit across a
/// small phone; touch and hold shows the large content viewer.
private struct LogBarLabel<Icon: View, Title: View>: View {
    let icon: Icon
    let title: Title
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.dsLargeText ? AnyLayout(VStackLayout(spacing: DS.Space.xxs))
                                          : AnyLayout(HStackLayout(spacing: DS.Space.xs + 2))
        layout {
            icon.font(.system(size: 15, weight: .semibold))
            title.dsFont(.headline).lineLimit(1)
                .minimumScaleFactor(typeSize.dsLargeText ? 0.6 : 0.8)
        }
    }
}

struct PhoneLogRow: View {
    let entry: LogEntry
    let site: InjectionSite?
    /// Off where the row can't be opened (someone else's logbook).
    var showsChevron = true
    /// The Logbook search's words, picked out where they appear in the row.
    var highlight: [String] = []
    /// How far the chevron has turned to point down, 0…1, as the row opens into its detail.
    var chevronTurn: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(SearchHighlight.attributed(title, terms: highlight, tint: tint)).dsFont(.callout)
                if let detail {
                    Text(SearchHighlight.attributed(detail, terms: highlight, tint: tint))
                        .dsFont(.caption).foregroundStyle(.secondary)
                }
                // The time goes under the entry at the accessibility sizes, so the title keeps the width.
                if typeSize.dsLargeText { time }
            }
            Spacer(minLength: DS.Space.sm)
            if !typeSize.dsLargeText { time }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(90 * LogbookRowExpand.clamped(chevronTurn)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(ClockLabel.time(entry.timestamp))
            .dsFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var icon: String {
        switch entry {
        case .dose(let d): return d.viaPump ? "cross.vial" : "syringe"
        case .meal: return "fork.knife"
        case .siteChange: return "bandage"
        case .context(let c): return c.sortedTags.first?.systemImage ?? "tag"
        }
    }

    private var tint: Color {
        switch entry {
        case .dose: return Palette.insulin
        case .meal: return Palette.food
        case .siteChange: return Palette.site
        case .context: return Palette.context
        }
    }

    private var title: String { entry.phoneTitle }

    private var detail: String? {
        var parts: [String] = []
        if case .dose = entry, let site { parts.append(site.title) }
        if case .dose(let d) = entry, let purpose = d.purpose?.label { parts.append(purpose) }
        let note = entry.phoneNote
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

