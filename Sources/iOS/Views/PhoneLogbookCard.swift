import SwiftUI

/// The last day's logbook, logged here or synced from the Mac (or anywhere else signed in to the
/// same LibreLinkUp account), grouped under Today and Yesterday so an earlier day's "10:46 am"
/// can't be read as later today. Logging starts from the bar at the bottom of the screen.
struct PhoneLogbookCard: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var sync: LogbookSyncService
    @EnvironmentObject var router: PhoneLogRouter

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
            Eyebrow(title: "Logbook", systemImage: "list.bullet.rectangle", trailing: "Last 24 hours")
            if !logbook.lastDeleted.isEmpty {
                HStack {
                    Label(logbook.lastDeleted.count == 1 ? "Entry deleted" : "\(logbook.lastDeleted.count) entries deleted",
                          systemImage: "trash")
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { logbook.undoDelete(); Haptics.tap() }
                        .dsFont(.headline)
                }
                .transition(.opacity)
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
                            if index > 0 { Divider().padding(.leading, 28) }
                            row(entry)
                        }
                    }
                }
                if recent.count > Self.maxRows {
                    Text("and \(recent.count - Self.maxRows) more")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            syncLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
        .animation(DSMotion.quick.animation, value: logbook.lastDeleted.count)
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

/// The bar along the bottom of the home screen: one tap to log each kind of entry. It sits in the
/// safe area under the scroll view, so content scrolls up past it instead of hiding behind it.
struct PhoneLogBar: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: PhoneLogRouter

    private var parts: [PhoneLogPart] {
        var out: [PhoneLogPart] = []
        if settings.therapy.logsInsulin || settings.therapy == .notSet { out.append(.insulin) }
        out.append(.food)
        if settings.therapy == .pump { out.append(.site) }
        out.append(.event)
        return out
    }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(parts) { part in
                Button { router.open(part) } label: {
                    Label(part.title(pump: settings.therapy == .pump), systemImage: part.systemImage)
                        .labelStyle(LogBarLabelStyle())
                        .foregroundStyle(part.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.sm + 2)
                        .background(part.tint.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Log \(part.title(pump: settings.therapy == .pump))")
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
        HStack(spacing: DS.Space.xs + 2) {
            configuration.icon.font(.system(size: 15, weight: .semibold))
            configuration.title.dsFont(.headline).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

private struct PhoneLogRow: View {
    let entry: LogEntry
    let site: InjectionSite?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).dsFont(.callout)
                if let detail { Text(detail).dsFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: DS.Space.sm)
            Text(ClockLabel.time(entry.timestamp))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
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

    private var title: String {
        switch entry {
        case .dose(let d): return "\(LogFormat.units(d.units)) \(d.displayName)"
        case .meal(let m):
            if m.carbs > 0 { return m.food.isEmpty ? "\(LogFormat.grams(m.carbs)) carbs" : "\(LogFormat.grams(m.carbs)) · \(m.food)" }
            return m.food.isEmpty ? "Food" : m.food
        case .siteChange(let s): return "New site: \(s.site.title)"
        case .context(let c): return c.sortedTags.map(\.title).joined(separator: ", ")
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if case .dose = entry, let site { parts.append(site.title) }
        let note: String
        switch entry {
        case .dose(let d): note = d.note
        case .meal(let m): note = m.note
        case .siteChange(let s): note = s.note
        case .context(let c): note = c.note
        }
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension LogEntry {
    var dose: InsulinDose? {
        if case .dose(let d) = self { return d }
        return nil
    }
}
