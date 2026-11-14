import SwiftUI

/// Where the home screen can push to. Values rather than destinations, so the links stay cheap and
/// the screens are only built when opened.
enum PhoneRoute: Hashable {
    case logbook
    case insights
}

/// The whole logbook, not just the last day: grouped by day with each day's insulin and carbs in
/// its header, searchable, filterable by kind, with swipe to delete or log again. Opened from the
/// home screen's Logbook card ("See All", or "and N more").
struct PhoneLogbookView: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var router: PhoneLogRouter
    @EnvironmentObject var sync: LogbookSyncService
    @State private var query = ""
    @State private var kind: LogPart?

    var body: some View {
        let all = logbook.entries
        let kinds = LogPart.allCases.filter { k in all.contains { $0.part == k } }
        let shown = filtered(all)
        let now = Date()
        List {
            if !logbook.lastDeleted.isEmpty {
                Section {
                    HStack {
                        Label(logbook.lastDeleted.count == 1 ? "Entry deleted" : "\(logbook.lastDeleted.count) entries deleted",
                              systemImage: "trash")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { logbook.undoDelete(); Haptics.tap() }
                            .dsFont(.headline)
                    }
                    .dsFont(.callout)
                }
            }
            if kinds.count > 1 {
                Section {
                    filterBar(kinds)
                        .listRowInsets(EdgeInsets(top: DS.Space.xs, leading: 0, bottom: DS.Space.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            if shown.isEmpty {
                Section {
                    emptyState(hasEntries: !all.isEmpty)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(PhoneLogbookDay.group(shown, now: now)) { day in
                    Section {
                        ForEach(day.entries, id: \.id) { row($0) }
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            if sync.status != .off {
                Section {
                    Label(sync.summary, systemImage: sync.isProblem ? "exclamationmark.icloud" : "arrow.triangle.2.circlepath.icloud")
                        .dsFont(.caption)
                        .foregroundStyle(sync.isProblem ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Food, insulin, notes")
        .navigationTitle("Logbook")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.open(nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log something")
            }
        }
        .animation(DSMotion.quick.animation, value: kind)
        .animation(DSMotion.quick.animation, value: logbook.lastDeleted.count)
        .onChange(of: kinds) { _, now in
            if let k = kind, !now.contains(k) { kind = nil }
        }
    }

    private func filtered(_ entries: [LogEntry]) -> [LogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { e in
            (kind == nil || e.part == kind) && (q.isEmpty || e.phoneSearchText.localizedStandardContains(q))
        }
    }

    // MARK: Pieces

    private func filterBar(_ kinds: [LogPart]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                chip("All", systemImage: nil, tint: Palette.brand, selected: kind == nil) { kind = nil }
                ForEach(kinds) { k in
                    chip(k.logbookTitle, systemImage: k.logbookSymbol, tint: k.logbookTint, selected: kind == k) {
                        kind = kind == k ? nil : k
                    }
                }
            }
            .padding(.horizontal, DS.Space.lg)
        }
    }

    private func chip(_ title: String, systemImage: String?, tint: Color, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            HStack(spacing: DS.Space.xs) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
            }
            .dsFont(.label)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs + 2)
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(tint))
            .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dayHeader(_ day: PhoneLogbookDay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(day.title)
            Spacer(minLength: DS.Space.sm)
            Text(day.totals)
                .textCase(nil)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ entry: LogEntry) -> some View {
        Button { router.edit(entry) } label: {
            PhoneLogRow(entry: entry, site: entry.dose.flatMap { logbook.site(of: $0) })
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { logbook.delete(ids: [entry.id]) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { logbook.duplicate(entry); Haptics.success() } label: {
                Label("Log Again", systemImage: "arrow.clockwise")
            }
            .tint(entry.part.logbookTint)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { router.edit(entry) }
            Button("Log Again Now", systemImage: "arrow.clockwise") { logbook.duplicate(entry); Haptics.success() }
            Button("Delete", systemImage: "trash", role: .destructive) { logbook.delete(ids: [entry.id]) }
        }
    }

    @ViewBuilder
    private func emptyState(hasEntries: Bool) -> some View {
        if hasEntries {
            EmptyStateView(systemImage: "magnifyingglass", title: "No matches",
                           message: query.isEmpty ? "Nothing of this kind logged yet." : "Nothing logged matches “\(query)”.",
                           actionTitle: "Show Everything", action: { query = ""; kind = nil })
        } else {
            EmptyStateView(systemImage: "list.bullet.rectangle", title: "Nothing logged yet",
                           message: "Log insulin, food and moments like waking up. Entries from GlucOS on your Mac show up here too.",
                           actionTitle: "Log Something", action: { router.open(nil) })
        }
    }
}

/// One day of the logbook, newest first, with what was taken and eaten that day.
struct PhoneLogbookDay: Identifiable {
    let id: String
    let title: String
    let entries: [LogEntry]

    /// "14 u · 120 g carbs", only the parts that were logged.
    var totals: String {
        var units = 0.0, carbs = 0.0
        for e in entries {
            switch e {
            case .dose(let d): units += d.units
            case .meal(let m): carbs += m.carbs
            default: break
            }
        }
        var parts: [String] = []
        if units > 0 { parts.append(LogFormat.units(units)) }
        if carbs > 0 { parts.append("\(LogFormat.grams(carbs)) carbs") }
        return parts.joined(separator: " · ")
    }

    /// Consecutive entries by calendar day, titled "Today", "Yesterday" or the date.
    static func group(_ entries: [LogEntry], now: Date, calendar: Calendar = .autoupdatingCurrent) -> [PhoneLogbookDay] {
        var out: [PhoneLogbookDay] = []
        for e in entries {
            let start = calendar.startOfDay(for: e.timestamp)
            let id = "\(Int(start.timeIntervalSince1970))"
            if let last = out.last, last.id == id {
                out[out.count - 1] = PhoneLogbookDay(id: id, title: last.title, entries: last.entries + [e])
            } else {
                out.append(PhoneLogbookDay(id: id, title: ClockLabel.dayTitle(ClockLabel.day(of: e.timestamp, now: now)),
                                           entries: [e]))
            }
        }
        return out
    }
}

extension LogEntry {
    /// The part of the log sheet this entry belongs to, for filtering.
    var part: LogPart {
        switch self {
        case .dose: return .insulin
        case .meal: return .food
        case .siteChange: return .site
        case .context: return .event
        }
    }

    /// What a search matches: the row's title and the note.
    var phoneSearchText: String {
        "\(phoneTitle) \(phoneNote)"
    }

    /// The row's main line: "4 u NovoRapid", "45 g · Toast", "New site: Abdomen", "Woke up".
    var phoneTitle: String {
        switch self {
        case .dose(let d): return "\(LogFormat.units(d.units)) \(d.displayName)"
        case .meal(let m):
            if m.carbs > 0 { return m.food.isEmpty ? "\(LogFormat.grams(m.carbs)) carbs" : "\(LogFormat.grams(m.carbs)) · \(m.food)" }
            return m.food.isEmpty ? "Food" : m.food
        case .siteChange(let s): return "New site: \(s.site.title)"
        case .context(let c): return c.sortedTags.map(\.title).joined(separator: ", ")
        }
    }

    var phoneNote: String {
        switch self {
        case .dose(let d): return d.note
        case .meal(let m): return m.note
        case .siteChange(let s): return s.note
        case .context(let c): return c.note
        }
    }

    var dose: InsulinDose? {
        if case .dose(let d) = self { return d }
        return nil
    }
}

extension LogPart {
    var logbookTitle: String {
        switch self {
        case .food: return "Food"
        case .insulin: return "Insulin"
        case .site: return "Sites"
        case .event: return "Moments"
        }
    }

    var logbookSymbol: String {
        switch self {
        case .food: return "fork.knife"
        case .insulin: return "syringe"
        case .site: return "bandage"
        case .event: return "tag"
        }
    }

    var logbookTint: Color {
        switch self {
        case .food: return Palette.food
        case .insulin: return Palette.insulin
        case .site: return Palette.site
        case .event: return Palette.context
        }
    }
}
