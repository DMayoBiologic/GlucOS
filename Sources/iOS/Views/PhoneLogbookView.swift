import SwiftUI

/// Where the home screen can push to. Values rather than destinations, so the links stay cheap and
/// the screens are only built when opened.
enum PhoneRoute: Hashable {
    case logbook
    case insights
    /// The Logbook opened from a card with a chip and period picked (the Insights Lows card).
    case logbookLink(LogbookLink)
    /// The Logbook opened on one entry, from the "last logged" line under Today's chart.
    case logbookEntry(UUID)
    /// Insights with the evening recap's Today card on top, from a tap on the recap notification
    /// (when it went out).
    case insightsToday(Date)

    /// The "last logged" line's zoom source, whichever entry it names.
    static let lastLoggedSource = "logbook-last-logged"

    /// What the zoom grows from and shrinks back into. A linked Logbook keys on its card, not its
    /// period, so it still finds the card on the way back after a new reading moved the period on.
    var zoomSource: AnyHashable {
        switch self {
        case .logbook, .insights: return AnyHashable(self)
        case .logbookLink(let link): return AnyHashable(link.sourceID)
        case .logbookEntry: return AnyHashable(Self.lastLoggedSource)
        // Grows from the home screen's Insights row, like Insights itself.
        case .insightsToday: return AnyHashable(PhoneRoute.insights)
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
    /// Taps on the toolbar icons, so each tap plays one bounce.
    @State private var exportTaps = 0
    @State private var logTaps = 0
    @State private var kind: LogbookFilter?
    /// A tag chip, if one is picked (`LogbookTags`): only entries carrying that tag show, within
    /// whatever the kind chip and the search say.
    @State private var tagFilter: String?
    /// The chips the list is showing. It follows `kind` and `tagFilter` a moment behind, so the
    /// old rows can fade out while the highlight slides to the new chip (`settleFilter`).
    @State private var listed: LogbookFilterPick
    /// The rows' opacity, dipped while the list switches to a new chip's rows.
    @State private var rowsFade = 1.0
    /// Where the chip highlights slide: one for the kind chips, one for the tag chips.
    @Namespace private var chipSpace
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
    /// The day opened into its chart from its bar (`DayMiniChart`), one at a time.
    @State private var openDay: String?
    /// The open day's trace, worked out once per day or readings change.
    @State private var dayCharts = DayChartCache()
    /// Where a day's bar and its chart meet, so the chart grows out of the bar and back into it.
    @Namespace private var dayChartSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The home stack's zoom namespace, which the edit sheet grows out of a row in.
    @Environment(\.phoneNavigator) private var navigator

    /// The entry to open once the screen is up (the "last logged" line under Today's chart).
    @State private var opening: UUID?
    /// Grouped rows (a meal and its insulin, `LogbookGrouping`) opened out into their entries.
    @State private var expandedGroups: Set<UUID> = []

    /// The day whose header has the jump-to-a-date calendar open over it.
    @State private var calendarFrom: String?
    /// A picked day the list is on its way to.
    @State private var jumping: LogbookJumpRequest?
    /// The day just landed on: its header lights once, then fades.
    @State private var landed: String?
    /// The list's opacity, dipped for the Reduce Motion cross-fade while it moves to a day.
    @State private var listFade = 1.0

    /// Opened from a card (`LogbookLink`): its chip picked and its period above the list. Opened on
    /// an entry (`opening`): that entry's row opens into its detail once the push has landed.
    init(link: LogbookLink? = nil, opening: UUID? = nil) {
        _kind = State(initialValue: link?.kindChip)
        _tagFilter = State(initialValue: link?.tag)
        _listed = State(initialValue: LogbookFilterPick(kind: link?.kindChip, tag: link?.tag))
        _linked = State(initialValue: link?.period)
        _opening = State(initialValue: opening)
    }

    var body: some View {
        let all = logbook.entries
        let alerts: [AlertLogRow] = showsAlerts ? AlertLog.rows(logbook.alerts) : []
        let kinds: [LogbookFilter] = LogbookFilter.available(entries: all, alerts: alerts)
        let search: LogbookQuery = LogbookQuery.parse(query, now: Date()).linked(linked)
        let lowIDs: Set<UUID> = LogbookSearch.lowTreatmentIDs(all)
        let shown: [PhoneLogbookItem] = PhoneLogbookItem.merge(all, alerts)
            .filter { $0.matches(listed.kind, search, lowIDs: lowIDs) && $0.matches(tag: listed.tag) }
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
                // Toolbar icons bounce once when tapped (round 48); still under Reduce Motion.
                Button { exportTaps += 1; showsExport = true } label: {
                    Image(systemName: "square.and.arrow.up").symbolBounce(on: exportTaps)
                }
                .accessibilityLabel("Export for a clinic visit")
            }
            ToolbarItem(placement: .topBarTrailing) { alertsMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { logTaps += 1; router.open(nil) } label: {
                    Image(systemName: "plus").symbolBounce(on: logTaps)
                }
                .accessibilityLabel("Log something")
            }
        }
        .sheet(isPresented: $showsExport) { exportSheet }
        // An opened row, drawn over the list it grew out of.
        .overlay { detail(all: all, terms: search.terms) }
        // Undo, just above the bottom edge. The countdown that sends it away runs on the home
        // screen's stack, so it keeps time across both screens.
        .overlay(alignment: .bottom) { PhoneUndoToast() }
        // New rows slide in and deleted rows fold away, whether from here, an undo or a sync.
        // Instant under Reduce Motion. A chip switch doesn't slide rows: it fades them over.
        .dsAnimation(.standard, value: shownIDs)
        .task(id: LogbookFilterPick(kind: kind, tag: tagFilter)) { await settleFilter() }
        .onChange(of: allIDs) { old, new in
            markFresh(Set(new).subtracting(old))
        }
        // The open entry went (deleted on the Mac, undone) or the search or a chip left its row
        // out: nothing to shrink back into, so the card just goes.
        .onChange(of: shownIDs) { _, now in
            if opener.isOpen, LogbookRowExpand.stillOpen(opener.openID, among: now) == nil { opener.dismiss() }
        }
        .onChange(of: kinds) { _, now in
            if let k = kind, k.isListed, !now.contains(k) { kind = nil }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            assembled = true
        }
        .task { await openRequestedEntry() }
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
        ScrollViewReader { proxy in
            listBody(all: all, kinds: kinds, shown: shown, search: search)
                .opacity(listFade)
                .task(id: jumping) { await land(jumping, proxy: proxy) }
        }
    }

    private func listBody(all: [LogEntry], kinds: [LogbookFilter], shown: [PhoneLogbookItem],
                          search: LogbookQuery) -> some View {
        List {
            if kinds.count > 1 || kind != nil || tagFilter != nil || !LogbookTags.used(all).isEmpty {
                Section {
                    filterBar(kinds, tags: LogbookTags.used(all))
                        .listRowInsets(EdgeInsets(top: DS.Space.xs, leading: 0, bottom: DS.Space.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            if !search.isEmpty && !all.isEmpty {
                Section {
                    searchSummary(search, found: shown.count)
                        .opacity(rowsFade)
                        .listRowBackground(Color.clear)
                }
            }
            if shown.isEmpty {
                Section {
                    emptyState(hasEntries: !all.isEmpty, search: search)
                        .opacity(rowsFade)
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
        let shownDays = Set(days.map(\.start))
        ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
            // A meal and its insulin logged within 15 minutes show as one row, opening out into the
            // entries (`LogbookGrouping`). Worked out on the rows the chips and search leave.
            let pieces = LogbookGrouping.listed(LogbookGrouping.runs(day.items, entry: \.entry), expanded: expandedGroups)
            Section {
                ForEach(Array(pieces.enumerated()), id: \.element.rowKey) { j, piece in
                    // The first screenful assembles top to bottom (docs/Redesign.md §7.2).
                    pieceRow(piece, order: starts[i] + j, terms: terms)
                        .opacity(rowsFade)
                }
            } header: {
                // Day headers stay pinned, on a blur, while their day scrolls under them.
                dayHeader(day, totals: totals[day.id] ?? day.totals, range: ranges[day.start], all: all, now: now,
                          shownDays: shownDays)
                    .opacity(rowsFade)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.xs + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The day a jump landed on lights once under its name.
                    .background(Palette.brand.opacity(landed == day.id ? 0.14 : 0))
                    .background(.bar)
                    .listRowInsets(EdgeInsets())
            }
            // What a jump to a date scrolls to (`LogbookJump.sectionID`).
            .id(day.id)
        }
    }

    @ViewBuilder
    private func pieceRow(_ piece: LogbookListed<PhoneLogbookItem>, order: Int, terms: [String]) -> some View {
        switch piece {
        case .row(let item): itemRow(item, order: order, terms: terms)
        case .group(let g, let open): groupRow(g, expanded: open, order: order, terms: terms)
        case .member(let entry, _): listRow(entry, order: order, terms: terms, indented: true)
        }
    }

    /// A meal and its insulin as one row: what they were and when, with a chevron that turns down
    /// as it opens out into the entries under it. Each entry keeps its own swipes, menu and card;
    /// the combined row's menu reaches each of them too. VoiceOver reads it as one item, with
    /// Expand or Collapse as its action.
    private func groupRow(_ g: LogbookGroup, expanded: Bool, order: Int, terms: [String]) -> some View {
        let lit: Double = g.ids.contains { fresh.contains($0) } ? 0.14 : 0
        let time = g.timeRange { ClockLabel.time($0) }
        return Button { toggleGroup(g) } label: {
            PhoneLogGroupRow(group: g, time: time, expanded: expanded, highlight: terms)
                .contentShape(Rectangle())
                .logbookEditSource(.group, g.id, navigator: navigator)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.spoken)
        .accessibilityValue("\(time), \(g.spokenState(expanded: expanded))")
        .accessibilityHint(expanded ? "Hides the entries" : "Shows the entries")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: g.actionName(expanded: expanded)) { toggleGroup(g) }
        .contextMenu {
            Button(expanded ? "Collapse" : "Show Entries", systemImage: expanded ? "chevron.up" : "chevron.down") {
                toggleGroup(g)
            }
            ForEach(g.newestFirst) { entry in
                Section(entry.shortTitle) {
                    Button("Edit", systemImage: "pencil") {
                        router.edit(entry, from: LogbookEditMorph.sourceID(.group, g.id))
                    }
                    Button("Log Again Now", systemImage: "arrow.clockwise") { logAgain(entry) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
                }
            }
        }
        .dsEntrance(min(order, 8), enabled: !assembled && order < 12)
        .listRowBackground(Color(uiColor: .systemBackground).overlay(Palette.food.opacity(lit)))
    }

    /// Opens a grouped row out into its entries, or folds them back, on the list's usual motion
    /// (instant under Reduce Motion). VoiceOver hears what happened once.
    private func toggleGroup(_ g: LogbookGroup) {
        Haptics.play(.choice)
        let open = !expandedGroups.contains(g.id)
        DS.animate(.standard, reduceMotion: reduceMotion) {
            if open { expandedGroups.insert(g.id) } else { expandedGroups.remove(g.id) }
        }
        AccessibilityNotification.Announcement(g.announcement(expanded: open)).post()
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

    /// `indented`: one of an opened group's entries, set in under its combined row.
    private func listRow(_ entry: LogEntry, order: Int, terms: [String], indented: Bool = false) -> some View {
        let tint: Color = entry.part.logbookTint
        let lit: Double = fresh.contains(entry.id) ? 0.14 : 0
        return row(entry, terms: terms, indented: indented)
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
                // The sheet zooms out of the open card and shrinks back into it.
                onEdit: { router.edit(entry, from: LogbookEditMorph.sourceID(.openCard, entry.id)) },
                // Both wait for the card to land back in its row, so the list moves after it does:
                // the copy slides in lit, or the row folds away with Undo, as from a swipe.
                onLogAgain: { opener.close { logAgain(entry) } },
                onDelete: { opener.close { delete(entry) } }
            )
        }
    }

    /// Opened on an entry: once the zoom in has landed and the row has been laid out, the row grows
    /// into its detail the same as a tap on it. Once only; Back closes the Logbook as usual. If the
    /// entry has gone meanwhile (deleted on the Mac), the Logbook just shows.
    private func openRequestedEntry() async {
        guard let id = opening else { return }
        opening = nil
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 0.45))
        guard logbook.entry(id: id) != nil else { return }
        // Folded into a grouped row: open the group first, so the entry has a row to grow from.
        let alerts: [AlertLogRow] = showsAlerts ? AlertLog.rows(logbook.alerts) : []
        let runs = LogbookGrouping.runs(PhoneLogbookItem.merge(logbook.entries, alerts), entry: \.entry)
        if let g = LogbookGrouping.group(containing: id, in: runs), !expandedGroups.contains(g.id) {
            expandedGroups.insert(g.id)
            try? await Task.sleep(for: .seconds(0.1))
        }
        opener.open(id, reduceMotion: reduceMotion)
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

    /// The chips changed (a tap, Clear Filters, a card's link): the old rows fade out, the list
    /// switches to the new chips' rows without sliding them, and those fade in. VoiceOver then says
    /// how many there are, once; a quick run of taps only speaks for the last. Under Reduce Motion
    /// the list just switches.
    private func settleFilter() async {
        let pick = LogbookFilterPick(kind: kind, tag: tagFilter)
        guard pick != listed else {
            // Back to the rows already listed (or nothing to do): just make sure they show.
            if rowsFade < 1 { withAnimation(.easeOut(duration: LogbookFilterPick.fadeIn)) { rowsFade = 1 } }
            return
        }
        if !reduceMotion {
            withAnimation(.easeIn(duration: LogbookFilterPick.fadeOut)) { rowsFade = 0 }
            try? await Task.sleep(for: .seconds(LogbookFilterPick.fadeOut))
            guard !Task.isCancelled else { return }
        }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { listed = pick }
        if !reduceMotion {
            withAnimation(.easeOut(duration: LogbookFilterPick.fadeIn)) { rowsFade = 1 }
        }
        AccessibilityNotification.Announcement(LogbookFilterPick.announcement(count: shownCount(pick))).post()
    }

    /// How many rows the chips leave showing, with the search as it stands.
    private func shownCount(_ pick: LogbookFilterPick) -> Int {
        let all = logbook.entries
        let alerts: [AlertLogRow] = showsAlerts ? AlertLog.rows(logbook.alerts) : []
        let search = LogbookQuery.parse(query, now: Date()).linked(linked)
        let lowIDs = LogbookSearch.lowTreatmentIDs(all)
        return PhoneLogbookItem.merge(all, alerts)
            .filter { $0.matches(pick.kind, search, lowIDs: lowIDs) && $0.matches(tag: pick.tag) }
            .count
    }

    private func clearFilters() {
        query = ""
        kind = nil
        tagFilter = nil
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

    private func filterBar(_ kinds: [LogbookFilter], tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                chip("All", systemImage: nil, tint: Palette.brand, selected: kind == nil, slide: "kind") { kind = nil }
                // The chip a card opened with stays offered even when it has nothing to show, so
                // the empty list says what it's filtered by (the Mac's bar does the same).
                ForEach(LogbookFilter.allCases.filter { kinds.contains($0) || $0 == kind }) { k in
                    chip(k.title, systemImage: k.symbol, tint: k.tint, selected: kind == k, slide: "kind") {
                        kind = kind == k ? nil : k
                    }
                }
                // Then a chip for each tag in use, most used first. One tag at a time, on top of the
                // kind chip: Meals and Exercise shows meals tagged Exercise.
                ForEach(tagChips(tags), id: \.self) { t in
                    tagChip(t)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            // The highlight slides from the old chip to the new one on a spring. Instant under
            // Reduce Motion.
            .animation(reduceMotion ? nil : DSMotion.emphasized.animation, value: kind)
            .animation(reduceMotion ? nil : DSMotion.emphasized.animation, value: tagFilter.map(LogbookTags.key))
        }
    }

    /// The tags in use, plus the picked one if its last entry just lost it, so the empty list
    /// still says what it's filtered by.
    private func tagChips(_ tags: [String]) -> [String] {
        guard let t = tagFilter, !LogbookTags.contains(tags, t) else { return tags }
        return tags + [t]
    }

    private func tagChip(_ t: String) -> some View {
        let selected = tagFilter.map { LogbookTags.key($0) == LogbookTags.key(t) } ?? false
        return chip(t, systemImage: LogbookTags.symbol(t), tint: Palette.context, selected: selected, slide: "tag") {
            tagFilter = selected ? nil : t
        }
        .accessibilityLabel("Tagged \(t)")
    }

    /// A chip. The picked one in each row (`slide`: the kind chips, or the tag chips) wears a
    /// filled highlight that's one view moving between chips (matched geometry), so a new pick
    /// slides it across rather than swapping two fills.
    private func chip(_ title: String, systemImage: String?, tint: Color, selected: Bool, slide: String,
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
            .background {
                if selected {
                    Capsule().fill(tint).matchedGeometryEffect(id: slide, in: chipSpace)
                }
            }
            .background(tint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The day's name and totals, with its time in range under them as a thin bar and a figure
    /// (`DayRangeBar`). Days without enough readings have no bar. VoiceOver reads one header:
    /// "Tuesday 12 November, 78% in range, 4% below", then the totals.
    ///
    /// Tapping a day with a bar opens it in place into that day's chart (`DayMiniChart`): the bar
    /// grows into the chart and the chart shrinks back into the bar on a second tap. Opening
    /// another day closes this one. Under Reduce Motion the two cross-fade instead. Nothing loops.
    ///
    /// Tapping the day's name (and its totals) opens a compact calendar over it instead
    /// (`LogbookCalendarView`): days with nothing logged are dimmed, and picking one springs the
    /// list to that day, or cross-fades it there under Reduce Motion (`land`).
    private func dayHeader(_ day: PhoneLogbookDay, totals: String, range: DayInRange?, all: [LogEntry],
                           now: Date, shownDays: Set<Date>) -> some View {
        let open = range != nil && openDay == day.id
        let snapshot = store.snapshot
        let segments: [[DayChartPoint]] = open
            ? dayCharts.segments(readings: store.archive, from: day.start, to: DayChart.end(of: day.start)) : []
        let markers: [ChartLogMarker] = open ? ChartLogMarker.day(all, start: day.start) : []
        let spokenDay = ClockLabel.day(of: day.start, now: now)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.title)
                    .dsFont(.headline)
                    .foregroundStyle(.primary)
                // Says the name opens the calendar, without shouting it.
                Image(systemName: "calendar")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: DS.Space.sm)
                Text(totals)
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { openCalendar(day.id) }
            .popover(isPresented: Binding(get: { calendarFrom == day.id },
                                          set: { if !$0, calendarFrom == day.id { calendarFrom = nil } }),
                     arrowEdge: .top) {
                LogbookCalendarView(counts: LogbookCalendar.counts(all.map(\.timestamp)), current: day.start) { picked in
                    jump(to: picked, all: all, shownDays: shownDays)
                }
                .presentationCompactAdaptation(.popover)
            }
            if let range {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if open {
                        DayMiniChart(start: day.start, segments: segments, markers: markers, unit: snapshot.unit,
                                     lowMgdl: snapshot.lowMgdl, highMgdl: snapshot.highMgdl)
                            .padding(.top, DS.Space.xs)
                            .dayChartMatch(day.id, in: dayChartSpace, enabled: !reduceMotion)
                            .transition(.opacity)
                    }
                    HStack(spacing: DS.Space.sm) {
                        if open {
                            Text(DayChartText.caption(segments, unit: snapshot.unit) ?? "No readings")
                                .dsFont(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        } else {
                            DayRangeBar(id: day.id, figures: range, drawn: drawnBars)
                                .frame(maxWidth: .infinity)
                                .dayChartMatch(day.id, in: dayChartSpace, enabled: !reduceMotion)
                                .transition(.opacity)
                        }
                        Text("\(DayInRangeText.percent(range)) in range")
                            .dsFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .dsAnimation(.standard, value: range.inRange)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleDay(day.id) }
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(open
            ? DayChartText.spoken(day: spokenDay, figures: range, segments: segments, unit: snapshot.unit,
                                  low: snapshot.lowMgdl, high: snapshot.highMgdl, logged: markers.count)
            : DayInRangeText.spoken(spokenDay, range))
        .accessibilityValue(totals)
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint(range == nil ? "Jumps to a date" : (open ? "Hides the day's chart" : "Shows the day's chart"))
        .accessibilityAction { if range != nil { toggleDay(day.id) } else { openCalendar(day.id) } }
        .accessibilityAction(named: "Jump to a Date") { openCalendar(day.id) }
    }

    private func openCalendar(_ id: String) {
        Haptics.play(.choice)
        calendarFrom = id
    }

    /// A day picked in the calendar: closes it, and moves the list there. If a search or chip is
    /// hiding that day's entries, those go first, so there's a day to land on.
    private func jump(to day: Date, all: [LogEntry], shownDays: Set<Date>) {
        calendarFrom = nil
        switch LogbookJump.plan(day: day, shownDays: shownDays, counts: LogbookCalendar.counts(all.map(\.timestamp))) {
        case .scroll(let d):
            jumping = LogbookJumpRequest(day: d)
        case .clearFiltersThenScroll(let d):
            query = ""
            kind = nil
            tagFilter = nil
            linked = nil
            // The list switches at once and quietly: the landing does the moving and the talking.
            listed = LogbookFilterPick(kind: nil, tag: nil)
            jumping = LogbookJumpRequest(day: d)
        case .none:
            break
        }
    }

    /// Once the calendar has gone (and any cleared search has rebuilt the list): springs the list
    /// so the day's header is at the top, or under Reduce Motion dips the list out, moves it, and
    /// fades it back. The header then lights once, and VoiceOver says where it landed.
    private func land(_ request: LogbookJumpRequest?, proxy: ScrollViewProxy) async {
        guard let request else { return }
        let id = LogbookJump.sectionID(request.day)
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 200))
        guard !Task.isCancelled else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { listFade = 0 }
            try? await Task.sleep(for: .milliseconds(160))
            proxy.scrollTo(id, anchor: .top)
            withAnimation(.easeIn(duration: 0.2)) { listFade = 1 }
        } else {
            withAnimation(DSMotion.emphasized.animation) { proxy.scrollTo(id, anchor: .top) }
        }
        Haptics.play(.choice)
        LoggedElsewhere.announce(LogbookJump.announcement(request.day, now: Date()))
        withAnimation(DSMotion.quick.animation) { landed = id }
        try? await Task.sleep(for: .seconds(1.2))
        DS.animate(.ambient, reduceMotion: reduceMotion) { if landed == id { landed = nil } }
    }

    /// Opens a day into its chart, or closes it: the bar grows into the chart (a spring the eye can
    /// follow) or, under Reduce Motion, the two cross-fade.
    private func toggleDay(_ id: String) {
        Haptics.play(.choice)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation) {
            openDay = DayChart.toggled(open: openDay, tapped: id)
        }
    }

    private func row(_ entry: LogEntry, terms: [String], indented: Bool = false) -> some View {
        // While its card is open (and growing out of it) the row itself steps aside, so there is
        // one of it on screen. Under Reduce Motion the card fades in over it, so it stays.
        let lifted = opener.openID == entry.id && opener.style == .matched
        return Button { opener.open(entry.id, reduceMotion: reduceMotion) } label: {
            PhoneLogRow(entry: entry, site: entry.dose.flatMap { logbook.site(of: $0) }, highlight: terms,
                        marksLoggedElsewhere: true)
                .padding(.leading, indented ? DS.Space.xl : 0)
                .contentShape(Rectangle())
                .logbookRowFrame(entry.id, in: opener)
                .opacity(lifted ? 0 : 1)
                // Edit from the menu zooms the sheet out of the row and back into it.
                .logbookEditSource(.row, entry.id, navigator: navigator)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Show details")
        // Swipe left to delete (a full swipe works, since the Undo toast can bring it back); swipe
        // right for "Log Again Now". That one needs a tap on the button, never a full swipe, so a
        // dose can't be logged twice by a flick. VoiceOver offers both as actions on the row.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { delete(entry) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { logAgain(entry) } label: {
                Label("Log Again Now", systemImage: "arrow.clockwise")
            }
            .tint(entry.part.logbookTint)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { router.edit(entry, from: LogbookEditMorph.sourceID(.row, entry.id)) }
            Button("Log Again Now", systemImage: "arrow.clockwise") { logAgain(entry) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
        }
    }

    /// The same entry logged again at the current time (`LogEntry.copied`: nothing about it changes
    /// but the time). The copy slides in at the top of today.
    private func logAgain(_ entry: LogEntry) {
        logbook.duplicate(entry)
        Haptics.play(.done)
    }

    /// Deletes one entry. The row folds away and the shared Undo toast offers it back (#111).
    private func delete(_ entry: LogEntry) {
        logbook.delete(ids: [entry.id])
        Haptics.play(.deleted)
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
                               message: LogbookSearch.noMatchMessage(search, filter: kind, tag: tagFilter),
                               actionTitle: LogbookSearch.clearTitle(search, filter: kind, tag: tagFilter),
                               action: clearFilters)
                // When the day was the problem, the same words across every date may still find it.
                if search.period != nil && (!search.terms.isEmpty || kind != nil || tagFilter != nil) {
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

    /// Whether the row shows under a tag chip (if one is picked). Alert rows carry no tags.
    func matches(tag: String?) -> Bool {
        guard let tag else { return true }
        return entry.map { LogbookTags.matches($0, tag: tag) } ?? false
    }

    /// Entries and alert rows together, newest first.
    static func merge(_ entries: [LogEntry], _ alerts: [AlertLogRow]) -> [PhoneLogbookItem] {
        (entries.map(PhoneLogbookItem.entry) + alerts.map(PhoneLogbookItem.alert))
            .sorted { $0.timestamp > $1.timestamp }
    }
}

extension LogbookListed where Row == PhoneLogbookItem {
    /// The list row's identity. An entry keeps its own id whether it stands alone or sits under an
    /// opened group, so the list moves it rather than swapping it.
    var rowKey: String {
        switch self {
        case .row(let item): return item.id.uuidString
        case .group(let g, _): return "group-\(g.id.uuidString)"
        case .member(let e, _): return e.id.uuidString
        }
    }
}

/// A grouped row (`LogbookGroup`): the meal and insulin icons together, "Meal and insulin", what
/// each part was, and the time. The chevron points right, and turns down while it's open.
struct PhoneLogGroupRow: View {
    let group: LogbookGroup
    let time: String
    let expanded: Bool
    var highlight: [String] = []
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "fork.knife").foregroundStyle(Palette.food)
                Image(systemName: "syringe")
                    .imageScale(.small)
                    .foregroundStyle(Palette.insulin)
                    .offset(x: 6, y: 6)
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.title).dsFont(.callout)
                Text(SearchHighlight.attributed(group.parts, terms: highlight, tint: Palette.food))
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                if typeSize.dsLargeText { timeLabel }
            }
            Spacer(minLength: DS.Space.sm)
            if !typeSize.dsLargeText { timeLabel }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
    }

    private var timeLabel: some View {
        Text(time)
            .dsFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
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

private extension View {
    /// The day bar and its chart share a frame, so one grows out of the other. Off under Reduce
    /// Motion, where they cross-fade in place.
    @ViewBuilder
    func dayChartMatch(_ id: String, in space: Namespace.ID, enabled: Bool) -> some View {
        if enabled { matchedGeometryEffect(id: "dayChart.\(id)", in: space) } else { self }
    }
}
