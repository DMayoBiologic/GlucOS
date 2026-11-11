import SwiftUI

/// The last day's logbook, logged here or synced from the Mac (or anywhere else signed in to the
/// same LibreLinkUp account), with one-tap buttons to log and how sync is doing.
struct PhoneLogbookCard: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var sync: LogbookSyncService
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: PhoneLogRouter

    private static let window: TimeInterval = 24 * 3600
    private static let maxRows = 6

    var body: some View {
        let recent = logbook.entries.filter { $0.timestamp > Date().addingTimeInterval(-Self.window) }
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Eyebrow(title: "Logbook", systemImage: "list.bullet.rectangle", trailing: "Last 24 hours")
            quickButtons
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
                     ? "Tap a button above to log insulin, food or an event. Entries from GlucOS on your Mac show up here too."
                     : "Nothing logged in the last 24 hours.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(recent.prefix(Self.maxRows)) { entry in
                        Button { router.edit(entry) } label: {
                            PhoneLogRow(entry: entry, site: entry.dose.flatMap { logbook.site(of: $0) })
                                .padding(.vertical, DS.Space.xs + 1)
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

    private var parts: [PhoneLogPart] {
        var out: [PhoneLogPart] = []
        if settings.therapy.logsInsulin || settings.therapy == .notSet { out.append(.insulin) }
        out.append(.food)
        if settings.therapy == .pump { out.append(.site) }
        out.append(.event)
        return out
    }

    /// One tap to start logging each kind of entry.
    private var quickButtons: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(parts) { part in
                Button { router.open(part) } label: {
                    VStack(spacing: DS.Space.xxs + 1) {
                        Image(systemName: part.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(part.title(pump: settings.therapy == .pump))
                            .dsFont(.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(part.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.sm + 2)
                    .background(part.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Log \(part.title(pump: settings.therapy == .pump))")
            }
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
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
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
