import SwiftUI

/// Where the home screen can push to. Values rather than destinations, so the links stay cheap and
/// the screens are only built when opened.
enum PhoneRoute: Hashable {
    case logbook
    case insights
    /// The Logbook opened from a card with a chip and period picked (the Insights Lows card).
    case logbookLink(LogbookLink)

    /// What the zoom grows from and shrinks back into. A linked Logbook keys on its card, not its
    /// period, so it still finds the card on the way back after a new reading moved the period on.
    var zoomSource: AnyHashable {
        switch self {
        case .logbook, .insights: return AnyHashable(self)
        case .logbookLink(let link): return AnyHashable(link.sourceID)
        }
    }
}

/// Pushes a screen onto the home screen's stack from a card further in (Insights → Logbook), with
/// the namespace its zoom source registers in.
struct PhoneNavigator {
    let push: (PhoneRoute) -> Void
    let zoom: Namespace.ID
}

private struct PhoneNavigatorKey: EnvironmentKey {
    static let defaultValue: PhoneNavigator? = nil
}

extension EnvironmentValues {
    var phoneNavigator: PhoneNavigator? {
        get { self[PhoneNavigatorKey.self] }
        set { self[PhoneNavigatorKey.self] = newValue }
    }
}

/// The whole logbook, not just the last day: grouped by day with each day's insulin and carbs in
/// its header, searchable ("pizza last week", docs/LogbookSearch.md) with the words it found picked
/// out, quick filter chips (Meals, Insulin, Lows, Notes…), and swipe to delete or log again. Tapping
/// an entry opens it in place into everything it holds (`PhoneLogbookDetail`), growing out of the
/// row and shrinking back into it. Opened from the home screen's Logbook card ("See All", or "and N
/// more"). Search only reads what's on the phone, so it works offline.
struct PhoneLogbookView: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var router: PhoneLogRouter
    @EnvironmentObject var sync: LogbookSyncService
    @EnvironmentObject var store: GlucoseStore
    @State private var query = ""
    /// The period the Logbook was opened with (the Lows card's days), until ✕ or Clear Filters.
    @State private var linked: LogbookQuery.Period?
    /// The clinic-visit export sheet (`PhoneExportView`).
    @State private var showsExport = false
    @State private var kind: LogbookFilter?
    /// Low and high alerts show as quiet rows between the entries unless turned off here.
    @AppStorage(AlertLogRow.showsKey) private var showsAlerts = true
    /// The first rows have played their entrance; rows built after this (scrolled to, filtered in)
    /// are just there.
    @State private var assembled = false
    /// Entries that just arrived (logged, undone, or synced from the Mac), lit with their colour
    /// for a moment so the eye finds them. Fades once; nothing loops.
    @State private var fresh: Set<UUID> = []
    /// The entry opened into its detail, if any, and how far open it is.
    @State private var opener = LogbookRowOpener()
    /// Each day's time in range for the header bars, worked out once per data change.
    @State private var dayRanges = DayInRangeCache()
    /// Day bars that have drawn in, so each plays once.
    @State private var drawnBars = DrawnOnce()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opened from a card (`LogbookLink`): its chip picked and its period above the list.
    init(link: LogbookLink? = nil) {
        _kind = State(initialValue: link?.filter)
        _linked = State(initialValue: link?.period)
    }

    var body: some View {
        let all = logbook.entries
        let alerts: [AlertLogRow] = showsAlerts ? AlertLog.rows(logbook.alerts) : []
        let kinds: [LogbookFilter] = LogbookFilter.available(entries: all, alerts: alerts)
        let search: LogbookQuery = LogbookQuery.parse(query, now: Date()).linked(linked)
        let lowIDs: Set<UUID> = LogbookSearch.lowTreatmentIDs(all)
        let shown: [PhoneLogbookItem] = PhoneLogbookItem.merge(all, alerts)
            .filter { $0.matches(kind, search, lowIDs: lowIDs) }
        let shownIDs: [UUID] = shown.map(\.id)
        let allIDs: [UUID] = all.map(\.id)
        list(all: all, kinds: kinds, shown: shown, search: search)
        // Plain, so day headers stick to the top as their day scrolls.
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Food, insulin, notes, or a day")
        .autocorrectionDisabled()
        .navigationTitle("Logbook")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export for a clinic visit")
            }
            ToolbarItem(placement: .topBarTrailing) { alertsMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.open(nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log something")
            }
        }
        .sheet(isPresented: $showsExport) { exportSheet }
        // An opened row, drawn over the list it grew out of.
        .overlay { detail(all: all, terms: search.terms) }
        // Undo, just above the bottom edge. The countdown that sends it away runs on the home
        // screen's stack, so it keeps time across both screens.
        .overlay(alignment: .bottom) { PhoneUndoToast() }
        .animation(DSMotion.quick.animation, value: kind)
        // New rows slide in and deleted rows fold away, whether from here, an undo or a sync.
        // Instant under Reduce Motion.
        .dsAnimation(.standard, value: shownIDs)
        .onChange(of: allIDs) { old, new in
            markFresh(Set(new).subtracting(old))
        }
        // The open entry went (deleted on the Mac, undone) or the search or a chip left its row
        // out: nothing to shrink back into, so the card just goes.
        .onChange(of: shownIDs) { _, now in
            if opener.isOpen, LogbookRowExpand.stillOpen(opener.openID, among: now) == nil { opener.dismiss() }
        }
        .onChange(of: kinds) { _, now in
            if let k = kind, !now.contains(k) { kind = nil }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            assembled = true
        }
    }

    /// The export takes a copy of what's on the phone now: the owner's own readings and entries.
    private var exportSheet: some View {
        let snapshot = store.snapshot
        return NavigationStack {
            PhoneExportView(readings: store.archive, entries: logbook.entries, unit: snapshot.unit,
                            lowMgdl: snapshot.lowMgdl, highMgdl: snapshot.highMgdl)
        }
    }

    /// Show or hide alert rows. Remembered on this phone.
    private var alertsMenu: some View {
        Menu {
            Toggle(isOn: $showsAlerts) { Label("Show Alerts", systemImage: "bell") }
        } label: {
            Image(systemName: showsAlerts ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Logbook options")
        .onChange(of: showsAlerts) { _, on in
            if !on, kind == .alerts { kind = nil }
        }
    }

    private func list(all: [LogEntry], kinds: [LogbookFilter], shown: [PhoneLogbookItem],
                      search: LogbookQuery) -> some View {
        List {
            if kinds.count > 1 || kind != nil {
                Section {
                    filterBar(kinds)
                        .listRowInsets(EdgeInsets(top: DS.Space.xs, leading: 0, bottom: DS.Space.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            if !search.isEmpty && !all.isEmpty {
                Section {
                    searchSummary(search, found: shown.count)
                        .listRowBackground(Color.clear)
                }
            }
            if shown.isEmpty {
                Section {
                    emptyState(hasEntries: !all.isEmpty, search: search)
                        .listRowBackground(Color.clear)
                }
            } else {
                daySections(all: all, shown: shown, now: Date(), terms: search.terms)
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
    }

    @ViewBuilder
    private func daySections(all: [LogEntry], shown: [PhoneLogbookItem], now: Date, terms: [String]) -> some View {
        // Headers total the whole day, not just what the filter or search left showing.
        let totals: [String: String] = Dictionary(PhoneLogbookDay.group(all.map(PhoneLogbookItem.entry), now: now)
                                                    .map { ($0.id, $0.totals) },
                                                  uniquingKeysWith: { a, _ in a })
        let days = PhoneLogbookDay.group(shown, now: now)
        let starts = PhoneLogbookDay.rowStarts(days)
        let snapshot = store.snapshot
        let ranges = dayRanges.figures(readings: store.archive, days: days.map(\.start),
                                       low: snapshot.lowMgdl, high: snapshot.highMgdl, now: now)
        ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
            Section {
                ForEach(Array(day.items.enumerated()), id: \.element.id) { j, item in
                    // The first screenful assembles top to bottom (docs/Redesign.md §7.2).
                    itemRow(item, order: starts[i] + j, terms: terms)
                }
            } header: {
                // Day headers stay pinned, on a blur, while their day scrolls under them.
                dayHeader(day, totals: totals[day.id] ?? day.totals, range: ranges[day.start], now: now)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.xs + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: PhoneLogbookItem, order: Int, terms: [String]) -> some View {
        switch item {
        case .entry(let entry): listRow(entry, order: order, terms: terms)
        case .alert(let alert): alertRow(alert, order: order, terms: terms)
        }
    }

    /// A low or high alert: just a record of what the phone or Mac said, so nothing to edit,
    /// delete or log again.
    private func alertRow(_ alert: AlertLogRow, order: Int, terms: [String]) -> some View {
        AlertLogRowView(row: alert, highlight: terms)
            .dsEntrance(min(order, 8), enabled: !assembled && order < 12)
            .listRowBackground(Color(uiColor: .systemBackground))
    }

    private func listRow(_ entry: LogEntry, order: Int, terms: [String]) -> some View {
        let tint: Color = entry.part.logbookTint
        let lit: Double = fresh.contains(entry.id) ? 0.14 : 0
        return row(entry, terms: terms)
            .dsEntrance(min(order, 8), enabled: !assembled && order < 12)
            .listRowBackground(Color(uiColor: .systemBackground).overlay(tint.opacity(lit)))
    }

    @ViewBuilder
    private func detail(all: [LogEntry], terms: [String]) -> some View {
        if let id = opener.openID, let entry = all.first(where: { $0.id == id }) {
            PhoneLogbookDetail(
                entry: entry,
                site: entry.dose.flatMap { logbook.site(of: $0) },
                terms: terms,
                opener: opener,
                onEdit: { router.edit(entry) },
                // Both wait for the card to land back in its row, so the list moves after it does:
                // the copy slides in lit, or the row folds away with Undo, as from a swipe.
                onLogAgain: { opener.close { logbook.duplicate(entry); Haptics.play(.done) } },
                onDelete: { opener.close { logbook.delete(ids: [entry.id]) } }
            )
        }
    }

    /// Lights the rows that just arrived, then lets the colour fade out once.
    private func markFresh(_ added: Set<UUID>) {
        guard !added.isEmpty, assembled else { return }
        fresh.formUnion(added)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            DS.animate(.ambient, reduceMotion: reduceMotion) { fresh.subtract(added) }
        }
    }

    private func clearFilters() {
        query = ""
        kind = nil
        linked = nil
        Haptics.play(.choice)
    }

    /// ✕ on the period chip, or Search All Dates: drops a day typed into the field, keeping the
    /// words, or else the period the Logbook was opened with.
    private func dropPeriod() {
        let typed = LogbookQuery.parse(query, now: Date())
        if typed.period != nil { query = typed.withoutPeriod } else { linked = nil }
    }

    // MARK: Pieces

    private func filterBar(_ kinds: [LogbookFilter]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                chip("All", systemImage: nil, tint: Palette.brand, selected: kind == nil) { kind = nil }
                // The chip a card opened with stays offered even when it has nothing to show, so
                // the empty list says what it's filtered by (the Mac's bar does the same).
                ForEach(LogbookFilter.allCases.filter { kinds.contains($0) || $0 == kind }) { k in
                    chip(k.title, systemImage: k.symbol, tint: k.tint, selected: kind == k) {
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
            Haptics.play(.choice)
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

    /// The day's name and totals, with its time in range under them as a thin bar and a figure
    /// (`DayRangeBar`). Days without enough readings have no bar. VoiceOver reads one header:
    /// "Tuesday 12 November, 78% in range, 4% below", then the totals.
    private func dayHeader(_ day: PhoneLogbookDay, totals: String, range: DayInRange?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.title)
                    .dsFont(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: DS.Space.sm)
                Text(totals)
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let range {
                HStack(spacing: DS.Space.sm) {
                    DayRangeBar(id: day.id, figures: range, drawn: drawnBars)
                        .frame(maxWidth: .infinity)
                    Text("\(DayInRangeText.percent(range)) in range")
                        .dsFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .dsAnimation(.standard, value: range.inRange)
                }
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayInRangeText.spoken(ClockLabel.day(of: day.start, now: now), range))
        .accessibilityValue(totals)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: LogEntry, terms: [String]) -> some View {
        // While its card is open (and growing out of it) the row itself steps aside, so there is
        // one of it on screen. Under Reduce Motion the card fades in over it, so it stays.
        let lifted = opener.openID == entry.id && opener.style == .matched
        return Button { opener.open(entry.id, reduceMotion: reduceMotion) } label: {
            PhoneLogRow(entry: entry, site: entry.dose.flatMap { logbook.site(of: $0) }, highlight: terms)
                .contentShape(Rectangle())
                .logbookRowFrame(entry.id, in: opener)
                .opacity(lifted ? 0 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Show details")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { logbook.delete(ids: [entry.id]) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { logbook.duplicate(entry); Haptics.play(.done) } label: {
                Label("Log Again", systemImage: "arrow.clockwise")
            }
            .tint(entry.part.logbookTint)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { router.edit(entry) }
            Button("Log Again Now", systemImage: "arrow.clockwise") { logbook.duplicate(entry); Haptics.play(.done) }
            Button("Delete", systemImage: "trash", role: .destructive) { logbook.delete(ids: [entry.id]) }
        }
    }

    /// What the search understood, and how much it found: "Since last week · 3 found", with a way to
    /// drop the time part when it read a day the user didn't mean.
    private func searchSummary(_ search: LogbookQuery, found: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            if let period = search.period {
                Button {
                    dropPeriod()
                    Haptics.play(.choice)
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "calendar").imageScale(.small)
                        Text(period.label)
                        Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
                    }
                    .dsFont(.label)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.xs + 2)
                    .foregroundStyle(Palette.brand)
                    .background(Palette.brand.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(period.label). Search all dates")
            }
            Spacer(minLength: DS.Space.sm)
            // Left to the empty state when nothing is found.
            if found > 0 {
                Text(found == 1 ? "1 found" : "\(found) found")
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .animation(DSMotion.quick.animation, value: found)
    }

    @ViewBuilder
    private func emptyState(hasEntries: Bool, search: LogbookQuery) -> some View {
        if hasEntries {
            VStack(spacing: DS.Space.md) {
                EmptyStateView(systemImage: "magnifyingglass", title: "No matches",
                               message: LogbookSearch.noMatchMessage(search, filter: kind),
                               actionTitle: "Clear Filters", action: clearFilters)
                // When the day was the problem, the same words across every date may still find it.
                if search.period != nil && (!search.terms.isEmpty || kind != nil) {
                    Button("Search All Dates") { dropPeriod(); Haptics.play(.choice) }
                        .dsFont(.label)
                }
            }
        } else {
            EmptyStateView(systemImage: "list.bullet.rectangle", title: "Nothing logged yet",
                           message: "Log insulin, food and moments like waking up. Entries from GlucOS on your Mac show up here too.",
                           actionTitle: "Log Something", action: { router.open(nil) })
        }
    }
}

/// One row of the Logbook: something logged, or an alert that went off.
enum PhoneLogbookItem: Identifiable {
    case entry(LogEntry)
    case alert(AlertLogRow)

    var id: UUID {
        switch self {
        case .entry(let e): return e.id
        case .alert(let a): return a.id
        }
    }

    var timestamp: Date {
        switch self {
        case .entry(let e): return e.timestamp
        case .alert(let a): return a.timestamp
        }
    }

    /// Whether the row shows under the chosen chip (if any) and the search.
    func matches(_ filter: LogbookFilter?, _ query: LogbookQuery, lowIDs: Set<UUID>) -> Bool {
        switch self {
        case .entry(let e):
            return (filter?.matches(e, lowIDs: lowIDs) ?? true) && LogbookSearch.matches(e, query, lowIDs: lowIDs)
        case .alert(let a):
            return (filter?.matches(a) ?? true) && LogbookSearch.matches(a, query)
        }
    }

    var entry: LogEntry? {
        if case .entry(let e) = self { return e }
        return nil
    }

    /// Entries and alert rows together, newest first.
    static func merge(_ entries: [LogEntry], _ alerts: [AlertLogRow]) -> [PhoneLogbookItem] {
        (entries.map(PhoneLogbookItem.entry) + alerts.map(PhoneLogbookItem.alert))
            .sorted { $0.timestamp > $1.timestamp }
    }
}

/// One day of the logbook, newest first, with what was taken and eaten that day.
struct PhoneLogbookDay: Identifiable {
    let id: String
    /// Local midnight the day starts at.
    let start: Date
    let title: String
    let items: [PhoneLogbookItem]

    /// What was logged that day, without the alerts.
    var entries: [LogEntry] { items.compactMap(\.entry) }

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

    /// The overall row number each day's first row has, so rows can be ordered across days.
    static func rowStarts(_ days: [PhoneLogbookDay]) -> [Int] {
        var out: [Int] = []
        var n = 0
        for day in days {
            out.append(n)
            n += day.items.count
        }
        return out
    }

    /// Consecutive rows by calendar day, titled "Today", "Yesterday" or the date.
    static func group(_ items: [PhoneLogbookItem], now: Date, calendar: Calendar = .autoupdatingCurrent) -> [PhoneLogbookDay] {
        var out: [PhoneLogbookDay] = []
        for e in items {
            let start = calendar.startOfDay(for: e.timestamp)
            let id = "\(Int(start.timeIntervalSince1970))"
            if let last = out.last, last.id == id {
                out[out.count - 1] = PhoneLogbookDay(id: id, start: start, title: last.title, items: last.items + [e])
            } else {
                out.append(PhoneLogbookDay(id: id, start: start, title: ClockLabel.dayTitle(ClockLabel.day(of: e.timestamp, now: now)),
                                           items: [e]))
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

    /// The row's main line: "4 u NovoRapid", "45 g · Toast", "New site: Abdomen", "Woke up".
    var phoneTitle: String { shortTitle }

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
