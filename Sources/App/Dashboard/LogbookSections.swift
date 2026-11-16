import SwiftUI
import Charts

// MARK: - Logbook

/// Every logged dose, meal and site change in the selected range, with quick filters, search
/// ("pizza last week", the shared rules in docs/LogbookSearch.md) with the words it found picked out,
/// quick re-logging and undoable deletes.
struct LogbookSection: View {
    let data: DashboardData
    /// Set by ⌘F anywhere in the dashboard: put the cursor in the search field, then cleared.
    @Binding var focusSearch: Bool
    /// Set by the Insights Lows, Highs or Overnight card: open on its chip and period, then cleared.
    @Binding var link: LogbookLink?
    /// Set by the popover's "last logged" line: select that entry and light it, then cleared.
    @Binding var reveal: UUID?
    /// While the Logbook was opened from an Insights card: back to that card.
    let backToInsights: (() -> Void)?
    /// The card it was opened from ("Lows", "Highs", "Overnight", "Weekdays and weekends", "Week in review"), for the back button's tooltip.
    let backCardTitle: String
    let open: (LogSheetTarget) -> Void

    init(data: DashboardData, focusSearch: Binding<Bool> = .constant(false),
         link: Binding<LogbookLink?> = .constant(nil), reveal: Binding<UUID?> = .constant(nil),
         backToInsights: (() -> Void)? = nil,
         backCardTitle: String = LogbookFilter.lows.title,
         open: @escaping (LogSheetTarget) -> Void) {
        self.data = data
        self._focusSearch = focusSearch
        self._link = link
        self._reveal = reveal
        self.backToInsights = backToInsights
        self.backCardTitle = backCardTitle
        self.open = open
    }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @State private var selection = Set<UUID>()
    /// The quick filter chip, if one is picked (All when nil).
    @State private var filter: LogbookFilter?
    @State private var search = ""
    /// The period the Logbook was opened with (the Lows card's days), until ✕ or Clear Filters.
    @State private var linked: LogbookQuery.Period?
    /// "Search All Dates" was pressed: look past the toolbar's period until the search is cleared.
    @State private var allDates = false
    @FocusState private var searchFocused: Bool
    /// Low and high alerts show as quiet rows between the entries unless turned off.
    @AppStorage(AlertLogRow.showsKey) private var showsAlerts = true
    /// Entries that just arrived, tinted with their colour for a moment so the eye finds them.
    @State private var fresh: Set<UUID> = []
    /// Entries this Mac logged from outside the Logbook (its widget, an alert, the keyboard
    /// shortcut), with "Logged with your shortcut" in their Details for a moment (`LoggedElsewhere`).
    @State private var elsewhere: [UUID: String] = [:]
    /// Each day's time in range for the Day column's bars, worked out once per data change.
    @State private var dayRanges = DayInRangeCache()
    /// Day bars that have drawn in, so each plays once.
    @State private var drawnBars = DrawnOnce()
    /// The day whose chart is showing in a popover from its Day cell (`DayMiniChart`).
    @State private var openDay: Date?
    @Environment(\.dashboardPadding) private var padding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let query = LogbookQuery.parse(search, now: Date()).linked(linked)
        let pastPeriod = LogbookSearch.looksPastToolbarPeriod(query, allDates: allDates)
        let allAlerts: [AlertLogRow] = showsAlerts ? AlertLog.rows(logbook.alerts) : []
        let inRange = logbook.entries.filter { data.domain.contains($0.timestamp) }
        let alertsInRange = allAlerts.filter { data.domain.contains($0.timestamp) }
        let lowIDs = LogbookSearch.lowTreatmentIDs(logbook.entries)
        let kinds = LogbookFilter.available(entries: logbook.entries, alerts: allAlerts)
        let scope = pastPeriod ? LogbookTableRow.merge(logbook.entries, allAlerts)
                               : LogbookTableRow.merge(inRange, alertsInRange)
        let rows = scope.filter { $0.matches(filter, query, lowIDs: lowIDs) }
        let terms = query.terms
        VStack(alignment: .leading, spacing: 0) {
            if settings.therapy == .notSet {
                TherapySetupView()
                    .frame(maxWidth: 560, alignment: .leading)
                    .dsCard(.standard)
                    .padding(padding)
                DSDivider()
            }
            // Opened from an Insights card (Lows, Highs or Overnight): the way back to it.
            if let backToInsights {
                Button(action: backToInsights) {
                    Label("Insights", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .dsFont(.label)
                .help("Back to the \(backCardTitle) card in Insights")
                .accessibilityLabel("Back to Insights")
                .padding(.horizontal, padding)
                .padding(.top, DS.Space.md)
            }
            if logbook.isEmpty && allAlerts.isEmpty {
                if !showsAlerts && !logbook.alerts.isEmpty {
                    // Alerts are hidden: keep the way back to them.
                    alertsToggle
                        .padding(.horizontal, padding)
                        .padding(.top, DS.Space.md + 2)
                }
                EmptyStateView(systemImage: "book", title: "Nothing Logged Yet",
                               message: "Log insulin, food and site changes with the + button or ⌘L. Save the things you log often as presets for one-tap entry next time.",
                               actionTitle: "Log…", action: { open(.new) })
                    .frame(maxHeight: .infinity)
            } else {
                totals(inRange)
                    .padding(.horizontal, padding)
                    .padding(.top, DS.Space.md + 2)
                    .padding(.bottom, DS.Space.sm + 2)
                searchBar(query, found: rows.count, searching: pastPeriod)
                    .padding(.horizontal, padding)
                    .padding(.bottom, DS.Space.sm)
                filterBar(kinds)
                    .padding(.horizontal, padding)
                    .padding(.bottom, DS.Space.sm + 2)
                DSDivider()
                if rows.isEmpty {
                    emptyState(query, pastPeriod: pastPeriod)
                        .frame(maxHeight: .infinity)
                } else {
                    table(rows, terms: terms)
                }
            }
        }
        // ⌘F (a dashboard shortcut, so it also brings this section up) puts the cursor in the search.
        .onAppear {
            takeFocusRequest(); takeLink(); takeReveal()
            takeLoggedElsewhere(logbook.entries.filter { data.domain.contains($0.timestamp) }.prefix(40).map(\.id))
        }
        .onChange(of: focusSearch) { _, _ in takeFocusRequest() }
        .onChange(of: link) { _, _ in takeLink() }
        .onChange(of: reveal) { _, _ in takeReveal() }
        // After a delete: what went and Undo, rising from the bottom edge (`LogbookUndoToast`).
        .overlay(alignment: .bottom) { LogbookUndoToast() }
        // Entries that arrive (logged, undone, synced from the iPhone) light up once.
        .onChange(of: logbook.entries.map(\.id)) { old, new in
            let added = Set(new).subtracting(old)
            markFresh(added)
            takeLoggedElsewhere(new.filter(added.contains))
        }
        // Rows hidden by the filter, search or range must not stay selected, or Delete would
        // remove entries the user can't see.
        .onChange(of: Set(rows.map(\.id))) { _, visible in
            selection.formIntersection(visible)
        }
        .onChange(of: kinds) { _, now in
            if let f = filter, f.isListed, !now.contains(f) { filter = nil }
        }
        .onChange(of: search) { _, now in
            // "Search All Dates" lasts as long as the search it was pressed for.
            if now.trimmingCharacters(in: .whitespaces).isEmpty, filter == nil { allDates = false }
        }
        .onChange(of: filter) { _, now in
            if now == nil, search.trimmingCharacters(in: .whitespaces).isEmpty { allDates = false }
        }
        .onChange(of: showsAlerts) { _, on in
            if !on, filter == .alerts { filter = nil }
        }
    }

    private var alertsToggle: some View {
        Toggle(isOn: $showsAlerts) { Label("Alerts", systemImage: "bell") }
            .toggleStyle(.checkbox)
            .help("Show low and high alerts, and what was tapped on them, between the entries")
    }

    /// The selected rows that are entries. Alert rows are records of what the Mac or iPhone said,
    /// so they can't be edited, logged again or deleted.
    private var selectedEntries: Set<UUID> {
        selection.filter { logbook.entry(id: $0) != nil }
    }

    /// The search field, what it understood ("Since last week ✕") and how much it found, then the
    /// actions for the selected rows.
    private func searchBar(_ query: LogbookQuery, found: Int, searching: Bool) -> some View {
        HStack(spacing: DS.Space.sm + 2) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search, prompt: Text("Food, insulin, notes, or a day (⌘F)"))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onExitCommand { clearFilters() }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear the search")
                        .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs + 1)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: 320)
            if let period = query.period {
                scopeChip(period.label, help: "Search all dates") { dropPeriod() }
                    .accessibilityLabel("\(period.label). Search all dates")
            } else if searching {
                scopeChip("All dates", help: "Back to the toolbar's period") { allDates = false; search = "" }
                    .accessibilityLabel("All dates. Back to the toolbar's period")
            }
            if searching && found > 0 {
                Text(found == 1 ? "1 found" : "\(found) found")
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            let chosen = selectedEntries
            if chosen.count == 1, let id = chosen.first, let entry = logbook.entry(id: id) {
                Button("Edit…") { open(.edit(entry)) }
                Button("Log Again Now") { logbook.duplicate(entry) }
                    .help("Log a copy of this entry at the current time")
            }
            if !chosen.isEmpty {
                Button(role: .destructive) { deleteSelection() } label: {
                    Label(chosen.count == 1 ? "Delete" : "Delete \(chosen.count)", systemImage: "trash")
                }
            }
        }
        .controlSize(.small)
        .dsAnimation(.quick, value: found)
    }

    /// The stretch of time being searched, with ✕ to widen it.
    private func scopeChip(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "calendar").imageScale(.small)
                Text(label)
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
            }
            .dsFont(.label)
            .padding(.horizontal, DS.Space.sm + 2)
            .padding(.vertical, DS.Space.xs)
            .foregroundStyle(Palette.brand)
            .background(Palette.brand.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// All, then the quick filter chips that would show something (Meals, Insulin, Lows, Notes…).
    private func filterBar(_ kinds: [LogbookFilter]) -> some View {
        // The chosen chip always stays, so the picker never loses its selection.
        let options: [LogbookFilter?] = [nil] + LogbookFilter.allCases.filter { kinds.contains($0) || $0 == filter }
        return HStack(spacing: DS.Space.sm + 2) {
            // The selection slides between filters (docs/Redesign.md §4.5), like the chart hours.
            SlidingSegments(selection: $filter, options: options) { $0?.title ?? "All" }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Show")
            alertsToggle
            Spacer()
        }
        .controlSize(.small)
    }

    /// Nothing to show: says what was searched, with Clear Filters, and Search All Dates when the
    /// day or the toolbar's period was what narrowed it.
    @ViewBuilder
    private func emptyState(_ query: LogbookQuery, pastPeriod: Bool) -> some View {
        let filtered = filter != nil || !query.isEmpty
        if !filtered {
            EmptyStateView(systemImage: "book", title: "Nothing Logged in This Period",
                           message: "Pick a longer period in the toolbar, search for something, or log something new.",
                           actionTitle: "Log…", action: { open(.new) })
        } else {
            VStack(spacing: DS.Space.md) {
                EmptyStateView(systemImage: "magnifyingglass", title: "No Matches",
                               message: pastPeriod
                                   ? LogbookSearch.noMatchMessage(query, filter: filter)
                                   : "Nothing in \(filter?.title ?? "the Logbook") in this period.",
                               actionTitle: "Clear Filters", action: clearFilters)
                if LogbookSearch.offersAllDates(query, filter: filter, allDates: allDates) {
                    Button("Search All Dates") { dropPeriod() }
                    .dsFont(.label)
                }
            }
        }
    }

    private func clearFilters() {
        search = ""
        filter = nil
        linked = nil
        allDates = false
    }

    /// ✕ on the period chip, or Search All Dates: drops a day typed into the field, keeping the
    /// words, or else the period the Logbook was opened with, and looks across every date.
    private func dropPeriod() {
        let typed = LogbookQuery.parse(search, now: Date())
        if typed.period != nil { search = typed.withoutPeriod } else { linked = nil }
        allDates = true
    }

    /// Opened from the Lows card: its chip and period, over whatever was typed before.
    private func takeLink() {
        guard let l = link else { return }
        link = nil
        search = ""
        allDates = false
        filter = l.filter
        linked = l.period
    }

    /// Opened on one entry (the popover's "last logged" line): nothing filtered out, so its row is
    /// listed, and that row selected and lit once with its colour like a new entry. It's the newest
    /// entry, so it sits at the top of the table.
    private func takeReveal() {
        guard let id = reveal else { return }
        reveal = nil
        search = ""
        allDates = false
        filter = nil
        linked = nil
        selection = [id]
        Task { @MainActor in
            // After the section's cross-fade, so the light is seen.
            try? await Task.sleep(for: .seconds(0.3))
            markFresh([id])
        }
    }

    /// The dashboard asked for the search field (⌘F): focus it, once it's on screen.
    private func takeFocusRequest() {
        guard focusSearch else { return }
        focusSearch = false
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    private func deleteSelection() {
        let ids = selectedEntries
        guard !ids.isEmpty else { return }
        DS.animate(.standard, reduceMotion: reduceMotion) { logbook.delete(ids: ids) }
        selection = []
    }

    /// Lights the rows that just arrived, then lets the colour fade out once.
    private func markFresh(_ added: Set<UUID>) {
        guard !added.isEmpty else { return }
        fresh.formUnion(added)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            DS.animate(.ambient, reduceMotion: reduceMotion) { fresh.subtract(added) }
        }
    }

    /// Rows logged from elsewhere, lit once with their caption in place of the details, then back
    /// to normal. VoiceOver hears it once for what was saved together. Fades only, so it's the same
    /// under Reduce Motion.
    private func takeLoggedElsewhere(_ ids: [UUID]) {
        let found = ids.compactMap { id in LoggedElsewhere.shared.take(id, on: .logbook).map { (id: id, highlight: $0) } }
        guard !found.isEmpty else { return }
        let delay = found.map(\.highlight.delay).max() ?? 0
        let foundIDs = found.map(\.id)
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            withAnimation(LoggedElsewhere.fade) {
                for f in found { elsewhere[f.id] = f.highlight.origin.caption }
            }
            markFresh(Set(foundIDs))
            if let first = found.first(where: { $0.highlight.announces }) {
                LoggedElsewhere.announce(LoggedElsewhereMarks.spoken(first.highlight.origin,
                                                                      entry: logbook.entry(id: first.id)?.shortTitle))
            }
            try? await Task.sleep(for: .seconds(LoggedElsewhere.hold))
            withAnimation(LoggedElsewhere.fade) {
                for id in foundIDs { elsewhere[id] = nil }
            }
        }
    }

    private func totals(_ entries: [LogEntry]) -> some View {
        var bolus = 0.0, basal = 0.0, carbs = 0.0
        for e in entries {
            switch e {
            case .dose(let d): if d.kind.isBolus { bolus += d.units } else { basal += d.units }
            case .meal(let m): carbs += m.carbs
            case .siteChange, .context: break
            }
        }
        return HStack(alignment: .top, spacing: DS.Space.xl) {
            if settings.therapy.logsInsulin || bolus + basal > 0 {
                Metric(settings.therapy == .pump ? "Boluses logged" : "Mealtime insulin logged", LogFormat.number(bolus), sub: "units",
                       rolling: .init(bolus, order: 0) { LogFormat.number($0) })
                if settings.therapy == .injections || basal > 0 {
                    Metric("Long-acting logged", LogFormat.number(basal), sub: "units",
                           rolling: .init(basal, order: 1) { LogFormat.number($0) })
                }
            }
            Metric("Carbs logged", LogFormat.number(carbs), sub: "grams",
                   rolling: .init(carbs, order: 2) { LogFormat.number($0) })
            Metric("Entries", "\(entries.count)", sub: data.isLive ? data.range.title.lowercased() : "in this period",
                   rolling: .init(Double(entries.count), order: 3) { "\(Int($0.rounded()))" })
        }
    }

    private func table(_ entries: [LogbookTableRow], terms: [String]) -> some View {
        let now = Date()
        let firsts = LogbookDays.firstRows(entries.map { (id: $0.id, timestamp: $0.timestamp) })
        let ranges = dayRanges.figures(readings: data.readings, days: Array(Set(firsts.values)).sorted(),
                                       low: data.lowMgdl, high: data.highMgdl, now: now)
        return Table(entries, selection: $selection) {
            // The day's name and time in range on its first (newest) row, like the iPhone's day
            // headers; the rows under it leave the column empty.
            TableColumn("Day") { (r: LogbookTableRow) in
                if let start = firsts[r.id] {
                    dayCell(start, range: ranges[start], now: now)
                } else {
                    Text("").accessibilityHidden(true)
                }
            }
            .width(min: 150, ideal: 190)
            TableColumn("Time") { (r: LogbookTableRow) in
                Text(ClockLabel.time(r.timestamp))
                    .monospacedDigit()
                    .foregroundStyle(r.isAlert ? Color.secondary : Color.primary)
                    .accessibilityLabel(ClockLabel.dayTime(r.timestamp, now: now))
            }
            .width(min: 60, ideal: 75)
            TableColumn("Entry") { (r: LogbookTableRow) in entryCell(r, terms: terms) }
                .width(min: 110, ideal: 140)
            TableColumn("Amount") { (r: LogbookTableRow) in
                Text(r.entry.map { amount($0) } ?? "").monospacedDigit().fontWeight(.semibold)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Details") { (r: LogbookTableRow) in detailsCell(r, terms: terms) }
            TableColumn("Site") { (r: LogbookTableRow) in siteCell(r, terms: terms) }
                .width(min: 90, ideal: 130)
            TableColumn("Glucose") { (r: LogbookTableRow) in glucoseCell(r) }
                .width(min: 60, ideal: 70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { picked in
            let ids = picked.filter { logbook.entry(id: $0) != nil }
            if ids.count == 1, let id = ids.first, let entry = logbook.entry(id: id) {
                Button("Edit…") { open(.edit(entry)) }
                Button("Log Again Now") { logbook.duplicate(entry) }
                Divider()
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Entries", role: .destructive) {
                    DS.animate(.standard, reduceMotion: reduceMotion) { logbook.delete(ids: ids) }
                    selection.subtract(ids)
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let entry = logbook.entry(id: id) { open(.edit(entry)) }
        }
        .onDeleteCommand { deleteSelection() }
        // New rows slide into place and deleted rows fold away, whether from here, an undo or a
        // sync. Instant under Reduce Motion.
        .dsAnimation(.standard, value: entries.map(\.id))
    }

    /// "Tue 12 Nov ▬▬▬ 78%": the day, its time in range as a thin bar (`DayRangeBar`, drawn in
    /// once when the row first shows) and the figure. Days without enough readings show the name.
    /// Clicking a day with a bar shows that day's chart in a popover (`DayMiniChart`), the iPhone's
    /// opened day header in Mac form.
    @ViewBuilder
    private func dayCell(_ start: Date, range: DayInRange?, now: Date) -> some View {
        let day = ClockLabel.day(of: start, now: now)
        let content = HStack(spacing: DS.Space.sm) {
            Text(ClockLabel.dayTitle(day))
                .fontWeight(.semibold)
                .lineLimit(1)
            if let range {
                DayRangeBar(id: "\(Int(start.timeIntervalSince1970))", figures: range, drawn: drawnBars)
                    .frame(width: 44)
                Text(DayInRangeText.percent(range))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .dsAnimation(.standard, value: range.inRange)
            }
        }
        if range != nil {
            Button { openDay = start } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show this day's chart")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayInRangeText.spoken(day, range))
                .accessibilityHint("Shows the day's chart")
                .popover(isPresented: Binding(get: { openDay == start },
                                              set: { if !$0, openDay == start { openDay = nil } }),
                         arrowEdge: .trailing) {
                    dayChartPopover(start, range: range, day: day)
                }
        } else {
            content
                .help("Not enough readings for this day's time in range")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayInRangeText.spoken(day, range))
        }
    }

    /// The day's trace on its target band with what was logged, then its lowest and highest. Like
    /// the day bars, the trace only covers the toolbar's period (`data.readings`).
    private func dayChartPopover(_ start: Date, range: DayInRange?, day: ClockLabel.Day) -> some View {
        let segments = DayChart.segments(data.readings, from: start, to: DayChart.end(of: start))
        let markers = ChartLogMarker.day(logbook.entries, start: start)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(DayInRangeText.spokenDay(day)).dsFont(.headline)
                Spacer(minLength: DS.Space.md)
                if let range {
                    Text("\(DayInRangeText.percent(range)) in range")
                        .dsFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            DayMiniChart(start: start, segments: segments, markers: markers, unit: data.unit,
                         lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, height: 140)
            Text(DayChartText.caption(segments, unit: data.unit) ?? "No readings")
                .dsFont(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(DS.Space.lg)
        .frame(width: 380)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayChartText.spoken(day: day, figures: range, segments: segments, unit: data.unit,
                                                low: data.lowMgdl, high: data.highMgdl, logged: markers.count))
    }

    @ViewBuilder
    private func entryCell(_ r: LogbookTableRow, terms: [String]) -> some View {
        switch r {
        case .entry(let e):
            let k = kind(e)
            Label { Text(SearchHighlight.attributed(title(e), terms: terms, tint: k.color)) } icon: {
                Image(systemName: k.systemImage)
            }
                .foregroundStyle(k.color)
                .padding(.horizontal, DS.Space.xs + 2)
                .padding(.vertical, 1)
                .background(k.color.opacity(fresh.contains(e.id) ? 0.18 : 0), in: Capsule())
                .padding(.horizontal, -(DS.Space.xs + 2))
        case .alert(let a):
            // Quiet: only the bell carries the range's colour.
            Label {
                Text(SearchHighlight.attributed(a.title, terms: terms, tint: a.tint)).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: a.systemImage).foregroundStyle(a.tint)
            }
            .help(a.title)
        }
    }

    @ViewBuilder
    private func detailsCell(_ r: LogbookTableRow, terms: [String]) -> some View {
        switch r {
        case .entry(let e):
            if let caption = elsewhere[e.id] {
                Text(caption)
                    .foregroundStyle(kind(e).color)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                Text(SearchHighlight.attributed(details(e), terms: terms, tint: kind(e).color))
                    .foregroundStyle(.secondary).help(details(e))
                    .transition(.opacity)
            }
        case .alert(let a):
            Text(SearchHighlight.attributed(a.detail, terms: terms, tint: a.tint))
                .foregroundStyle(.tertiary).help(a.detail)
        }
    }

    @ViewBuilder
    private func siteCell(_ r: LogbookTableRow, terms: [String]) -> some View {
        if let e = r.entry {
            let s = site(e)
            Text(SearchHighlight.attributed(s ?? "–", terms: s == nil ? [] : terms, tint: kind(e).color)).foregroundStyle(s == nil ? Color.secondary : Color.primary)
        } else {
            Text("")
        }
    }

    @ViewBuilder
    private func glucoseCell(_ r: LogbookTableRow) -> some View {
        if let reading = GlucoseAnalytics.nearest(to: r.timestamp, in: data.readings, tolerance: 10 * 60) {
            Text(data.unit.format(mgdl: reading.mgdl)).monospacedDigit()
                .foregroundStyle(GlucoseRange.classify(mgdl: reading.mgdl, low: data.lowMgdl, high: data.highMgdl).valueColor)
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    private func kind(_ e: LogEntry) -> ChartEvent.Kind {
        switch e {
        case .dose(let d): return d.kind.isBolus ? .bolus : .basal
        case .meal: return .food
        case .siteChange: return .siteChange
        case .context(let c): return c.isWake ? .wake : .context
        }
    }

    private func title(_ e: LogEntry) -> String {
        switch e {
        case .dose(let d): return d.viaPump ? "Bolus" : (d.kind.isBolus ? "Insulin" : "Long-acting")
        case .meal: return "Food"
        case .siteChange: return "Site change"
        case .context: return "Context"
        }
    }

    private func amount(_ e: LogEntry) -> String {
        switch e {
        case .dose(let d): return LogFormat.units(d.units)
        case .meal(let m): return m.carbs > 0 ? LogFormat.grams(m.carbs) : "–"
        case .siteChange, .context: return ""
        }
    }

    private func details(_ e: LogEntry) -> String {
        var parts: [String] = []
        switch e {
        case .dose(let d): parts.append(d.displayName); parts.append(d.purpose?.label ?? ""); parts.append(d.note)
        case .meal(let m): parts.append(m.food); parts.append(m.note)
        case .siteChange(let c): parts.append(c.note)
        case .context(let c): parts.append(c.sortedTags.map(\.title).joined(separator: ", ")); parts.append(c.note)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func site(_ e: LogEntry) -> String? {
        switch e {
        case .dose(let d): return logbook.site(of: d)?.title
        case .meal: return nil
        case .siteChange(let c): return c.site.title
        case .context: return nil
        }
    }
}

// MARK: - Insights

/// Observed patterns from the user's logs and every stored reading. Descriptive only.
struct InsightsSection: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// Set when coming back from the Logbook a card opened (Lows, Highs, Overnight or a weekday side, by its chip): scroll to
    /// that card, then cleared.
    @Binding var returnTo: LogbookFilter?
    /// The Lows, Highs, Overnight, Weekdays and weekends or Week in review card was tapped: open the Logbook on its chip and days.
    let openLogbook: (LogbookLink) -> Void
    let onLog: () -> Void

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var outlookStore: OutlookStore

    /// The person's order and hidden cards, kept on this Mac (docs/InsightsLayout.md). Held in state
    /// so a change animates, and written back on every change.
    @State private var cardLayout = InsightsLayout(stored: UserDefaults.standard.string(forKey: InsightsLayout.macKey) ?? "")
    @State private var customising = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let defaults = InsightsCard.macDefault

    var body: some View {
        // Worked out here rather than inside the page, which re-runs its content when the window
        // changes size.
        let insights: LogInsights? = settings.therapy == .notSet ? nil
            : LogInsights.compute(readings: readings, doses: logbook.doses, meals: logbook.meals,
                                  siteChanges: logbook.siteChanges, contexts: logbook.contexts,
                                  low: lowMgdl, high: highMgdl,
                                  siteOf: { logbook.site(of: $0) })
        DashboardPage(maxContentWidth: DashboardMetrics.readableWidth) { layout in
            if let insights {
                SafetyNote().dsEntrance(0)
                if logbook.isEmpty {
                    // The sentence wraps; the button keeps its size.
                    HStack(alignment: .center, spacing: DS.Space.lg) {
                        startLogging
                        Spacer(minLength: 12)
                        logButton
                    }
                    .dashboardCard()
                    .dsEntrance(1)
                }
                if settings.therapy.logsInsulin {
                    InsulinActionCard(insights: insights, unit: unit).dsEntrance(2)
                }
                MealResponseCard(insights: insights, unit: unit, showsInsulin: settings.therapy.logsInsulin)
                    .dsEntrance(3)
                if settings.therapy == .pump {
                    SiteAgeCard(buckets: insights.siteAge, unit: unit, hasSiteChanges: !logbook.siteChanges.isEmpty)
                        .dsEntrance(4)
                }
                if settings.therapy == .injections {
                    SiteRotationCard().dsEntrance(4)
                }
                Text(periodText)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TherapySetupView().dashboardCard().dsEntrance(0)
            }
            customiseRow
            ScrollViewReader { proxy in
                let visible = cardLayout.visible(Self.defaults)
                VStack(alignment: .leading, spacing: layout.gutter) {
                    ForEach(Array(visible.enumerated()), id: \.element) { i, card in
                        view(for: card)
                            .dsEntrance(5 + i)
                            .contextMenu { menu(card, index: i, count: visible.count) }
                    }
                }
                // Under Reduce Motion the cards cross-fade to the new order instead of springing.
                .id(reduceMotion ? visible.map(\.rawValue).joined(separator: ",") : "")
                .transition(.opacity)
                .onAppear {
                    guard let card = returnTo else { return }
                    returnTo = nil
                    // Once the page is laid out, so the card is where it'll be.
                    DispatchQueue.main.async { proxy.scrollTo(Self.cardID(card), anchor: .center) }
                }
            }
            Disclaimer()
        }
        // As on iPhone Insights: each card's figures count up as it assembles, with its bars
        // drawing in, and roll from the old figure to the new one when the data changes. Once per
        // appearance, never a loop; still under Reduce Motion; VoiceOver hears the final value.
        .environment(\.figuresCountUp, true)
        .sheet(isPresented: $customising) {
            InsightsCustomiseSheet(layout: $cardLayout, defaults: Self.defaults, change: change)
        }
        .onChange(of: cardLayout) { _, new in
            UserDefaults.standard.set(new.stored, forKey: InsightsLayout.macKey)
        }
    }

    @ViewBuilder
    private func view(for card: InsightsCard) -> some View {
        switch card {
        case .weekInReview:
            WeekInReviewView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl,
                             openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.thisWeek))
        case .lows:
            LowsCardView(readings: readings, meals: logbook.meals, contexts: logbook.contexts,
                         answers: logbook.lowAnswers, unit: unit, lowMgdl: lowMgdl,
                         openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.lows))
        case .highs:
            HighsCardView(readings: readings, unit: unit, highMgdl: highMgdl, openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.highs))
        case .overnight:
            OvernightCardView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl,
                              openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.overnight))
        case .weekdayWeekend:
            WeekdayWeekendCardView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl,
                                   openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.weekdays))
        case .streaks:
            InRangeStreaksCardView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl,
                                   openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.bestStreak))
        case .bestDays:
            BestToughestDaysCardView(readings: readings, entries: logbook.entries, unit: unit, lowMgdl: lowMgdl,
                                     highMgdl: highMgdl, openLogbook: openLogbook)
                .dashboardCard()
                .id(Self.cardID(.bestDay))
        case .dayPattern:
            DayPatternView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
                .dashboardCard()
        case .forecastAccuracy:
            ForecastScorecardCard(outlook: outlookStore)
        case .glance, .days, .mornings:
            // iPhone-only cards; never in the Mac's list.
            EmptyView()
        }
    }

    /// Above the movable cards: what's hidden, and the way into the customise sheet.
    private var customiseRow: some View {
        let hiddenCount = cardLayout.hiddenCards(Self.defaults).count
        return HStack(spacing: DS.Space.md) {
            Text(hiddenCount == 0 ? "Drag cards into your own order, or hide the ones you don't use."
                 : hiddenCount == 1 ? "1 card hidden." : "\(hiddenCount) cards hidden.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.md)
            Button { customising = true } label: {
                Label("Customise Cards…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.ds(.secondary, size: .small))
            .help("Reorder or hide the Insights cards")
        }
    }

    /// Right-click a card: move it a place, hide it, or open the customise sheet.
    @ViewBuilder
    private func menu(_ card: InsightsCard, index: Int, count: Int) -> some View {
        Button("Move Up") { change { $0.move(card, by: -1, defaults: Self.defaults) } }
            .disabled(index == 0)
        Button("Move Down") { change { $0.move(card, by: 1, defaults: Self.defaults) } }
            .disabled(index >= count - 1)
        Button("Hide \(card.title)") { change { $0.hide(card, defaults: Self.defaults) } }
        Divider()
        Button("Customise Cards…") { customising = true }
    }

    /// Springs the cards into their new places; a cross-fade under Reduce Motion.
    private func change(_ edit: (inout InsightsLayout) -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation) { edit(&cardLayout) }
    }

    /// "insights.lows", "insights.highs", "insights.overnight", "insights.weekdays",
    /// "insights.thisWeek", "insights.bestStreak", "insights.bestDay": where Back from the Logbook
    /// scrolls to. Weekends comes back to the Weekdays and weekends card too, Last week to Week in
    /// review, and Toughest day to Best and toughest days.
    private static func cardID(_ card: LogbookFilter) -> String { "insights.\(card.insightsCard.rawValue)" }

    private var startLogging: some View {
        Label("Start by logging your insulin and food. Patterns appear here once GlucOS has a few clean examples.",
              systemImage: "book")
            .dsFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var logButton: some View {
        Button("Log…", action: onLog)
            .buttonStyle(.ds(.primary))
            .fixedSize()
    }

    private var periodText: String {
        var s = "Uses every reading GlucOS has stored"
        if let first = readings.first?.timestamp {
            s += " (since \(first.formatted(date: .abbreviated, time: .omitted)))"
        }
        s += ". Middle values are medians; ranges in brackets hold the middle half of examples."
        if settings.therapy == .injections {
            s += " Long-acting doses are logged and charted but not analysed."
        }
        return s
    }
}

/// How close the forecasts shown on this Mac came in the last week. Hidden until there are enough
/// checks; the Outlook page has the full breakdown.
private struct ForecastScorecardCard: View {
    @ObservedObject var outlook: OutlookStore
    @ObservedObject var ledger: ForecastLedgerStore
    @EnvironmentObject var store: GlucoseStore

    init(outlook: OutlookStore) {
        self.outlook = outlook
        self.ledger = outlook.ledger
    }

    var body: some View {
        if let card = ledger.scorecard {
            ForecastScorecardView(card: card, unit: store.snapshot.unit, sinceUpdate: ledger.sinceUpdate,
                                  tuned: outlook.model.tuning.isTuned)
                .dashboardCard()
        }
    }
}

/// Styled like a status banner, but never truncated: every word of this one matters.
private struct SafetyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(Tone.warning.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Observations, not advice")
                    .dsFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("These are patterns GlucOS has seen in your own logs and readings. They're rough estimates from limited data and are easily thrown off by missed logs, exercise, illness, stress, alcohol, hormones and what you ate. GlucOS never suggests a dose. Don't change your insulin, ratios or pump settings based on these. Talk to your diabetes care team first.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard(.tinted(.warning))
    }
}

/// "Needs N more examples" in place of a figure.
private struct NeedsMore: View {
    let have: Int
    let need: Int
    let explanation: String

    @Environment(\.figuresCountUp) private var countsUp
    /// How much of the bar is drawn; fills with the count where figures count up.
    @State private var drawn: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm + 2) {
                ProgressView(value: Double(min(have, need)) * (countsUp ? drawn : 1), total: Double(need))
                    .frame(width: 120)
                    .modifier(DrawIn(enabled: countsUp, progress: $drawn))
                    .accessibilityValue("\(min(have, need)) of \(need)")
                HStack(spacing: 0) {
                    RollingFigure(Double(have)) { "\(Int($0.rounded()))" }
                    Text(" of \(need) examples so far")
                }
                .fontWeight(.medium).dsFont(.callout)
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(have) of \(need) examples so far")
            }
            Text(explanation)
                .dsFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func spreadText(_ s: Spread?, need: Int, have: Int, format: (Double) -> String) -> String {
    guard let s else { return "needs \(max(1, need - have)) more" }
    return "\(format(s.median)) (\(format(s.lower))–\(format(s.upper)))"
}

/// A spread written as `spreadText` does ("2.1 (1.6–2.8) mmol/L"), with each figure a
/// `RollingFigure`, so it counts up on Insights and rolls to new values. VoiceOver hears the
/// finished text as one phrase.
private struct SpreadFigure: View {
    let spread: Spread?
    let need: Int
    let have: Int
    var unitLabel: String? = nil
    /// Where this row sits on its card, so figures settle top to bottom.
    var order: Int = 0
    let format: (Double) -> String

    var body: some View {
        if let s = spread {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                RollingFigure(s.median, order: order, text: format)
                Text(" (")
                RollingFigure(s.lower, order: order, text: format)
                Text("–")
                RollingFigure(s.upper, order: order, text: format)
                Text(")")
                if let unitLabel { Text(" " + unitLabel) }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spreadText(s, need: need, have: have, format: format)
                                + (unitLabel.map { " " + $0 } ?? ""))
        } else {
            Text(spreadText(nil, need: need, have: have, format: format))
        }
    }
}

/// A count of examples in a table cell, rolling like the figures beside it.
private struct CountFigure: View {
    let count: Int
    var order: Int = 0

    var body: some View {
        RollingFigure(Double(count), order: order) { "\(Int($0.rounded()))" }
    }
}

// MARK: Insulin action

private struct InsulinActionCard: View {
    let insights: LogInsights
    let unit: GlucoseUnit

    private var need: Int { InsightRules.minimumEvents }

    var body: some View {
        let overall = insights.overall
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("How Long Insulin Seems to Work",
                          subtitle: "\(overall.examples) usable of \(insights.bolusCount) boluses")
            if overall.examples < need {
                NeedsMore(have: overall.examples, need: need,
                          explanation: "GlucOS reads this from boluses taken without food: nothing eaten from 90 minutes before to 3 hours after, no other bolus in the 3 hours before, and steady sensor data. Logging every dose and meal, including snacks and hypo treatments, lets GlucOS tell which doses had nothing else going on.")
            } else {
                let series = ([overall] + insights.byArea)
                    .filter { !$0.curve.isEmpty }
                    .map { ResponseCurveChart.Series(name: $0.title, points: $0.curve) }
                if !series.isEmpty {
                    ResponseCurveChart(series: series, unit: unit, xLabel: "Hours after the bolus")
                        .frame(height: 220)
                }
                HorizontalOverflow {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Site")
                            Text("Examples")
                            Text("Starts working")
                            Text("Stops falling after")
                            Text("Drop per unit")
                        }
                        .fontWeight(.medium).dsFont(.caption)
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        let all = [overall] + insights.byArea + insights.byTag
                        ForEach(Array(all.enumerated()), id: \.element.id) { i, s in
                            GridRow {
                                Text(s.title).fontWeight(s.area == nil ? .semibold : .regular)
                                CountFigure(count: s.examples, order: i)
                                SpreadFigure(spread: s.onset, need: need, have: s.measurable, order: i,
                                             format: LogFormat.duration)
                                SpreadFigure(spread: s.timeToLowest, need: need, have: s.measurable, order: i,
                                             format: LogFormat.duration)
                                SpreadFigure(spread: s.dropPerUnit, need: need, have: s.examples,
                                             unitLabel: unit.label, order: i) { unit.format(mgdl: $0) }
                            }
                            .dsFont(.callout)
                            .monospacedDigit()
                        }
                    }
                }
            }
            if insights.correctionsSetAside > 0 {
                setAsideNote(insights.correctionsSetAside, noun: "bolus", plural: "boluses",
                             hasRows: !insights.byTag.isEmpty && overall.examples >= need)
            }
            Text("“Starts working” is when glucose was 0.5 mmol/L below where it started. “Stops falling after” is when it reached its lowest point: a rough guide to how long the insulin kept acting. “Drop per unit” is how far glucose fell per unit in those doses. It is an observation, not your correction factor (ISF), which your care team sets.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard()
    }
}

/// "3 examples with exercise, illness… set aside" line.
private func setAsideNote(_ count: Int, noun: String, plural: String, hasRows: Bool) -> some View {
    Label("\(count) \(count == 1 ? noun : plural) logged around exercise, illness, alcohol, stress, a period or a site problem \(count == 1 ? "is" : "are") kept out of the typical figures\(hasRows ? " and shown in the “With …” rows" : "").",
          systemImage: "tag")
        .dsFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: Meals

private struct MealRow: Identifiable {
    let name: String
    let summary: MealSummary
    var id: String { name }
}

private struct MealResponseCard: View {
    let insights: LogInsights
    let unit: GlucoseUnit
    let showsInsulin: Bool

    private var need: Int { InsightRules.minimumEvents }

    var body: some View {
        let rows: [MealRow] = showsInsulin
            ? [MealRow(name: "With insulin", summary: insights.mealsWithInsulin),
               MealRow(name: "Without insulin", summary: insights.mealsWithoutInsulin)]
            : [MealRow(name: "Meals", summary: insights.mealsWithoutInsulin)]
        let usable = insights.mealResponses.count
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("After Meals", subtitle: "\(usable) usable of \(insights.mealCount) logged")
            if rows.allSatisfy({ $0.summary.examples < need }) {
                NeedsMore(have: rows.map(\.summary.examples).max() ?? 0, need: need,
                          explanation: "GlucOS reads this from meals with carbs logged, no other food in the 2 hours before, and steady sensor data for at least 2 hours after.")
            } else {
                let series = rows.filter { !$0.summary.curve.isEmpty }
                    .map { ResponseCurveChart.Series(name: $0.name, points: $0.summary.curve) }
                if !series.isEmpty {
                    ResponseCurveChart(series: series, unit: unit, xLabel: "Hours after eating")
                        .frame(height: 200)
                }
                HorizontalOverflow {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("")
                            Text("Examples")
                            Text("Typical rise")
                            Text("Peak after")
                            Text("Rise per 10 g carbs")
                        }
                        .fontWeight(.medium).dsFont(.caption)
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            let s = row.summary
                            GridRow {
                                Text(row.name).fontWeight(.semibold)
                                CountFigure(count: s.examples, order: i)
                                SpreadFigure(spread: s.rise, need: need, have: s.examples,
                                             unitLabel: unit.label, order: i) { unit.format(mgdl: $0) }
                                SpreadFigure(spread: s.timeToPeak, need: need, have: s.examples, order: i,
                                             format: LogFormat.duration)
                                SpreadFigure(spread: s.risePer10g, need: need, have: s.examples,
                                             unitLabel: unit.label, order: i) { unit.format(mgdl: $0) }
                            }
                            .dsFont(.callout)
                            .monospacedDigit()
                        }
                    }
                }
            }
            if insights.mealsSetAside > 0 {
                setAsideNote(insights.mealsSetAside, noun: "meal", plural: "meals", hasRows: false)
            }
            Text(showsInsulin
                 ? "Rise is from your glucose when you logged the meal to the highest point in the next 3 hours. “With insulin” means a bolus was logged within 30 minutes of eating, so the rise reflects both the food and the insulin."
                 : "Rise is from your glucose when you logged the meal to the highest point in the next 3 hours.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard()
    }
}

// MARK: Pump site age

private struct SiteAgeCard: View {
    let buckets: [SiteAgeBucket]
    let unit: GlucoseUnit
    let hasSiteChanges: Bool

    @Environment(\.figuresCountUp) private var countsUp
    /// How far the bars have grown from the baseline; they grow once, with the figures counting up.
    @State private var grown: Double = 0

    /// Fixed while the bars grow, so they rise against the finished scale rather than filling a
    /// shrunken one. Headroom for the labels above each bar.
    private var yTop: Double {
        max(1, (buckets.map { unit.value(fromMgdl: $0.meanMgdl) }.max() ?? 1) * 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Glucose by Day of Site Wear")
            if buckets.isEmpty {
                NeedsMore(have: 0, need: 2,
                          explanation: hasSiteChanges
                          ? "Each day of wear needs at least two sites' worth of readings. Keep logging site changes."
                          : "Log each infusion site change (+ button → Changed infusion site) to see whether your glucose changes as a site ages.")
            } else {
                let shown = countsUp ? grown : 1
                Chart(buckets) { b in
                    BarMark(x: .value("Day", b.title), y: .value("Average", unit.value(fromMgdl: b.meanMgdl) * shown))
                        .foregroundStyle(Palette.site.gradient)
                        .annotation(position: .top, spacing: 4) {
                            // The labels ride the same growth: they roll from zero to the figure as
                            // the bar rises (no state of their own, which an annotation can lose).
                            let mean = b.meanMgdl * shown
                            let inRange = b.timeInRange * shown
                            VStack(spacing: 0) {
                                Text(unit.format(mgdl: mean))
                                    .contentTransition(.numericText(value: mean))
                                    .fontWeight(.semibold).dsFont(.caption)
                                Text("\(Format.percent(inRange)) in range")
                                    .contentTransition(.numericText(value: inRange))
                                    .dsFont(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                            .accessibilityHidden(true)
                        }
                        // The finished figures, never a bar on its way up.
                        .accessibilityLabel(b.title)
                        .accessibilityValue("Average \(unit.format(mgdl: b.meanMgdl)) \(unit.label), \(Format.percent(b.timeInRange)) in range")
                }
                .chartYScale(domain: 0...yTop)
                .chartYAxisLabel { Text("Average (\(unit.label))") }
                .frame(height: 200)
                .modifier(DrawIn(enabled: countsUp, progress: $grown))
                Text("Average glucose on each day a site was worn, across \(buckets.map(\.sites).max() ?? 0) sites.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }
}

// MARK: Injection site rotation

private struct SiteRotationCard: View {
    @EnvironmentObject var logbook: LogbookStore

    var body: some View {
        let last = logbook.lastInjectionBySite
        let since = Date().addingTimeInterval(-14 * 86_400)
        let recent = Dictionary(grouping: logbook.doses.filter { !$0.viaPump && $0.timestamp >= since && $0.site != nil }) { $0.site! }
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Injection Sites", subtitle: "Last 14 days")
            if last.isEmpty {
                Text("Choose an injection site when you log a dose to see how you've been rotating.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Area")
                        Text("Left")
                        Text("Right")
                    }
                    .fontWeight(.medium).dsFont(.caption)
                    .foregroundStyle(.secondary)
                    ForEach([BodyArea.abdomen, .arm, .thigh, .hip]) { area in
                        let sites = InjectionSite.allCases.filter { $0.area == area }
                        GridRow {
                            Text(area.title)
                            ForEach(sites) { s in
                                cell(last: last[s], count: recent[s]?.count ?? 0)
                            }
                        }
                        .dsFont(.callout)
                    }
                }
                Text("Rotating injection sites helps avoid lumpy areas under the skin, which can make insulin absorb unpredictably.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardCard()
    }

    private func cell(last: Date?, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(count == 0 ? "–" : "\(count) dose\(count == 1 ? "" : "s")").monospacedDigit()
            if let last {
                Text(last.formatted(.relative(presentation: .named)))
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Response curves

/// Median change in glucose after a dose or meal, one line per group.
struct ResponseCurveChart: View {
    struct Series: Identifiable {
        let name: String
        let points: [CurvePoint]
        var id: String { name }
    }

    let series: [Series]
    let unit: GlucoseUnit
    let xLabel: String

    var body: some View {
        Chart {
            RuleMark(y: .value("No change", 0.0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(series) { s in
                ForEach(s.points, id: \.minutes) { p in
                    LineMark(x: .value("Hours", Double(p.minutes) / 60),
                             y: .value("Change", unit.value(fromMgdl: p.change)),
                             series: .value("Group", s.name))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Group", s.name))
                        .lineStyle(StrokeStyle(lineWidth: s.id == series.first?.id ? 2.5 : 1.5, lineCap: .round))
                }
            }
        }
        .chartXAxisLabel { Text(xLabel) }
        .chartYAxisLabel { Text("Change (\(unit.label))") }
        .chartXAxis {
            AxisMarks(values: .stride(by: 1)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .accessibilityLabel("Median change in glucose over time")
    }
}

/// One row of the Mac Logbook table: something logged, or a low or high alert (`AlertLogRow`).
enum LogbookTableRow: Identifiable {
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

    var entry: LogEntry? {
        if case .entry(let e) = self { return e }
        return nil
    }

    var isAlert: Bool { entry == nil }

    /// Whether the row shows under the chosen chip (if any) and the search, by the rules the iPhone
    /// Logbook uses (`LogbookSearch`).
    func matches(_ filter: LogbookFilter?, _ query: LogbookQuery, lowIDs: Set<UUID>) -> Bool {
        switch self {
        case .entry(let e):
            return (filter?.matches(e, lowIDs: lowIDs) ?? true) && LogbookSearch.matches(e, query, lowIDs: lowIDs)
        case .alert(let a):
            return (filter?.matches(a) ?? true) && LogbookSearch.matches(a, query)
        }
    }

    /// Entries and alert rows together, newest first.
    static func merge(_ entries: [LogEntry], _ alerts: [AlertLogRow]) -> [LogbookTableRow] {
        (entries.map(LogbookTableRow.entry) + alerts.map(LogbookTableRow.alert)).sorted { $0.timestamp > $1.timestamp }
    }
}
