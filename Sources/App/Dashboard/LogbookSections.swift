import SwiftUI
import Charts

// MARK: - Logbook

/// Every logged dose, meal and site change in the selected range, with filtering, search, quick
/// re-logging and undoable deletes.
struct LogbookSection: View {
    let data: DashboardData
    let open: (LogSheetTarget) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, insulin, food, site, context, alerts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .insulin: return "Insulin"
            case .food: return "Food"
            case .site: return "Sites"
            case .context: return "Context"
            case .alerts: return "Alerts"
            }
        }

        func includes(_ e: LogEntry) -> Bool {
            switch (self, e) {
            case (.all, _), (.insulin, .dose), (.food, .meal), (.site, .siteChange), (.context, .context): return true
            default: return false
            }
        }

        func includes(_ row: LogbookTableRow) -> Bool {
            switch row {
            case .entry(let e): return includes(e)
            case .alert: return self == .all || self == .alerts
            }
        }
    }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @State private var selection = Set<UUID>()
    @State private var filter: Filter = .all
    @State private var search = ""
    /// Low and high alerts show as quiet rows between the entries unless turned off.
    @AppStorage(AlertLogRow.showsKey) private var showsAlerts = true
    /// Entries that just arrived, tinted with their colour for a moment so the eye finds them.
    @State private var fresh: Set<UUID> = []
    @Environment(\.dashboardPadding) private var padding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let inRange = logbook.entries.filter { data.domain.contains($0.timestamp) }
        let alerts: [AlertLogRow] = showsAlerts
            ? AlertLog.rows(logbook.alerts).filter { data.domain.contains($0.timestamp) } : []
        let entries = LogbookTableRow.merge(inRange, alerts).filter { filter.includes($0) && matches($0) }
        VStack(alignment: .leading, spacing: 0) {
            if settings.therapy == .notSet {
                TherapySetupView()
                    .frame(maxWidth: 560, alignment: .leading)
                    .dsCard(.standard)
                    .padding(padding)
                DSDivider()
            }
            if inRange.isEmpty && alerts.isEmpty {
                if !showsAlerts && logbook.alerts.contains(where: { data.domain.contains($0.firedAt) }) {
                    // Alerts are hidden: keep the way back to them.
                    alertsToggle
                        .padding(.horizontal, padding)
                        .padding(.top, DS.Space.md + 2)
                }
                EmptyStateView(systemImage: "book", title: "Nothing Logged in This Period",
                               message: logbook.isEmpty
                                   ? "Log insulin, food and site changes with the + button or ⌘L. Save the things you log often as presets for one-tap entry next time."
                                   : "Pick a longer period in the toolbar to see older entries, or log something new.",
                               actionTitle: "Log…", action: { open(.new) })
                    .frame(maxHeight: .infinity)
            } else {
                totals(inRange)
                    .padding(.horizontal, padding)
                    .padding(.top, DS.Space.md + 2)
                    .padding(.bottom, DS.Space.sm + 2)
                filterBar
                    .padding(.horizontal, padding)
                    .padding(.bottom, DS.Space.sm + 2)
                DSDivider()
                if entries.isEmpty {
                    if search.trimmingCharacters(in: .whitespaces).isEmpty {
                        // The filter, not a search, emptied the list: say so.
                        EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                       title: "No \(filter.title) in This Period",
                                       message: "Choose another filter, or a longer period in the toolbar.",
                                       actionTitle: "Show All", action: { filter = .all })
                            .frame(maxHeight: .infinity)
                    } else {
                        EmptyStateView(systemImage: "magnifyingglass",
                                       title: "No Results for \u{201C}\(search)\u{201D}",
                                       message: "Check the spelling or try another word.",
                                       actionTitle: "Clear Search", action: { search = "" })
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    table(entries)
                }
            }
        }
        // After a delete: what went and Undo, rising from the bottom edge (`LogbookUndoToast`).
        .overlay(alignment: .bottom) { LogbookUndoToast() }
        // Entries that arrive (logged, undone, synced from the iPhone) light up once.
        .onChange(of: logbook.entries.map(\.id)) { old, new in
            markFresh(Set(new).subtracting(old))
        }
        // Rows hidden by the filter, search or range must not stay selected, or Delete would
        // remove entries the user can't see.
        .onChange(of: Set(entries.map(\.id))) { _, visible in
            selection.formIntersection(visible)
        }
        .onChange(of: showsAlerts) { _, on in
            if !on, filter == .alerts { filter = .all }
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

    private var filterBar: some View {
        HStack(spacing: DS.Space.sm + 2) {
            // The selection slides between filters (docs/Redesign.md §4.5), like the chart hours.
            SlidingSegments(selection: $filter, options: Filter.allCases.filter(showsFilter)) { $0.title }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Show")
            TextField("Search", text: $search, prompt: Text("Search food, insulin or notes"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            alertsToggle
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
    }

    private func showsFilter(_ f: Filter) -> Bool {
        // The selected option always stays, so the picker never loses its selection (e.g. after
        // deleting the last site change, or a therapy change).
        if f == filter { return true }
        switch f {
        case .site: return settings.therapy == .pump || !logbook.siteChanges.isEmpty
        case .insulin: return settings.therapy.logsInsulin || !logbook.doses.isEmpty
        case .alerts: return showsAlerts && !logbook.alerts.isEmpty
        default: return true
        }
    }

    private func matches(_ row: LogbookTableRow) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        switch row {
        case .entry(let e):
            return [title(e), details(e), amount(e), site(e) ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        case .alert(let a):
            return a.searchText.localizedCaseInsensitiveContains(q)
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
                Metric(settings.therapy == .pump ? "Boluses logged" : "Mealtime insulin logged", LogFormat.number(bolus), sub: "units")
                if settings.therapy == .injections || basal > 0 {
                    Metric("Long-acting logged", LogFormat.number(basal), sub: "units")
                }
            }
            Metric("Carbs logged", LogFormat.number(carbs), sub: "grams")
            Metric("Entries", "\(entries.count)", sub: data.isLive ? data.range.title.lowercased() : "in this period")
        }
    }

    private func table(_ entries: [LogbookTableRow]) -> some View {
        Table(entries, selection: $selection) {
            TableColumn("Time") { (r: LogbookTableRow) in
                Text(r.timestamp.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .monospacedDigit()
                    .foregroundStyle(r.isAlert ? Color.secondary : Color.primary)
            }
            .width(min: 140, ideal: 170)
            TableColumn("Entry") { (r: LogbookTableRow) in entryCell(r) }
                .width(min: 110, ideal: 140)
            TableColumn("Amount") { (r: LogbookTableRow) in
                Text(r.entry.map { amount($0) } ?? "").monospacedDigit().fontWeight(.semibold)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Details") { (r: LogbookTableRow) in detailsCell(r) }
            TableColumn("Site") { (r: LogbookTableRow) in siteCell(r) }
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

    @ViewBuilder
    private func entryCell(_ r: LogbookTableRow) -> some View {
        switch r {
        case .entry(let e):
            let k = kind(e)
            Label(title(e), systemImage: k.systemImage)
                .foregroundStyle(k.color)
                .padding(.horizontal, DS.Space.xs + 2)
                .padding(.vertical, 1)
                .background(k.color.opacity(fresh.contains(e.id) ? 0.18 : 0), in: Capsule())
                .padding(.horizontal, -(DS.Space.xs + 2))
        case .alert(let a):
            // Quiet: only the bell carries the range's colour.
            Label {
                Text(a.title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: a.systemImage).foregroundStyle(a.tint)
            }
            .help(a.title)
        }
    }

    @ViewBuilder
    private func detailsCell(_ r: LogbookTableRow) -> some View {
        switch r {
        case .entry(let e): Text(details(e)).foregroundStyle(.secondary).help(details(e))
        case .alert(let a): Text(a.detail).foregroundStyle(.tertiary).help(a.detail)
        }
    }

    @ViewBuilder
    private func siteCell(_ r: LogbookTableRow) -> some View {
        if let e = r.entry {
            let s = site(e)
            Text(s ?? "–").foregroundStyle(s == nil ? Color.secondary : Color.primary)
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
    let onLog: () -> Void

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var outlookStore: OutlookStore

    var body: some View {
        // Worked out here rather than inside the page, which re-runs its content when the window
        // changes size.
        let insights: LogInsights? = settings.therapy == .notSet ? nil
            : LogInsights.compute(readings: readings, doses: logbook.doses, meals: logbook.meals,
                                  siteChanges: logbook.siteChanges, contexts: logbook.contexts,
                                  low: lowMgdl, high: highMgdl,
                                  siteOf: { logbook.site(of: $0) })
        DashboardPage(maxContentWidth: DashboardMetrics.readableWidth) { _ in
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
            WeekInReviewView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
                .dashboardCard()
                .dsEntrance(5)
            DayPatternView(readings: readings, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
                .dashboardCard()
                .dsEntrance(6)
            ForecastScorecardCard(outlook: outlookStore).dsEntrance(7)
            Disclaimer()
        }
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm + 2) {
                ProgressView(value: Double(min(have, need)), total: Double(need))
                    .frame(width: 120)
                Text("\(have) of \(need) examples so far")
                    .fontWeight(.medium).dsFont(.callout)
                    .monospacedDigit()
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

private func durationSpread(_ s: Spread?, need: Int, have: Int) -> String {
    spreadText(s, need: need, have: have, format: LogFormat.duration)
}

/// A glucose spread with the unit after it, e.g. "2.1 (1.6–2.8) mmol/L".
private func glucoseSpread(_ s: Spread?, need: Int, have: Int, unit: GlucoseUnit) -> String {
    let text = spreadText(s, need: need, have: have, format: { unit.format(mgdl: $0) })
    return s == nil ? text : "\(text) \(unit.label)"
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
                        ForEach([overall] + insights.byArea + insights.byTag) { s in
                            GridRow {
                                Text(s.title).fontWeight(s.area == nil ? .semibold : .regular)
                                Text("\(s.examples)").monospacedDigit()
                                Text(durationSpread(s.onset, need: need, have: s.measurable))
                                Text(durationSpread(s.timeToLowest, need: need, have: s.measurable))
                                Text(glucoseSpread(s.dropPerUnit, need: need, have: s.examples, unit: unit))
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
                        ForEach(rows) { row in
                            let s = row.summary
                            GridRow {
                                Text(row.name).fontWeight(.semibold)
                                Text("\(s.examples)").monospacedDigit()
                                Text(glucoseSpread(s.rise, need: need, have: s.examples, unit: unit))
                                Text(durationSpread(s.timeToPeak, need: need, have: s.examples))
                                Text(glucoseSpread(s.risePer10g, need: need, have: s.examples, unit: unit))
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Glucose by Day of Site Wear")
            if buckets.isEmpty {
                NeedsMore(have: 0, need: 2,
                          explanation: hasSiteChanges
                          ? "Each day of wear needs at least two sites' worth of readings. Keep logging site changes."
                          : "Log each infusion site change (+ button → Changed infusion site) to see whether your glucose changes as a site ages.")
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Day", b.title), y: .value("Average", unit.value(fromMgdl: b.meanMgdl)))
                        .foregroundStyle(Palette.site.gradient)
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 0) {
                                Text(unit.format(mgdl: b.meanMgdl)).fontWeight(.semibold).dsFont(.caption)
                                Text("\(Format.percent(b.timeInRange)) in range").dsFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                }
                .chartYAxisLabel { Text("Average (\(unit.label))") }
                .frame(height: 200)
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

    /// Entries and alert rows together, newest first.
    static func merge(_ entries: [LogEntry], _ alerts: [AlertLogRow]) -> [LogbookTableRow] {
        (entries.map(LogbookTableRow.entry) + alerts.map(LogbookTableRow.alert)).sorted { $0.timestamp > $1.timestamp }
    }
}
