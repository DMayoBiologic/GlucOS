import SwiftUI
import Charts

// MARK: - Logbook

/// Every logged dose, meal and site change in the selected range, with filtering, search, quick
/// re-logging and undoable deletes.
struct LogbookSection: View {
    let data: DashboardData
    let open: (LogSheetTarget) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, insulin, food, site, context
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .insulin: return "Insulin"
            case .food: return "Food"
            case .site: return "Sites"
            case .context: return "Context"
            }
        }

        func includes(_ e: LogEntry) -> Bool {
            switch (self, e) {
            case (.all, _), (.insulin, .dose), (.food, .meal), (.site, .siteChange), (.context, .context): return true
            default: return false
            }
        }
    }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @State private var selection = Set<UUID>()
    @State private var filter: Filter = .all
    @State private var search = ""

    var body: some View {
        let inRange = logbook.entries.filter { data.domain.contains($0.timestamp) }
        let entries = inRange.filter { filter.includes($0) && matches($0) }
        VStack(alignment: .leading, spacing: 0) {
            if settings.therapy == .notSet {
                TherapySetupView()
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(20)
                Divider()
            }
            if inRange.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Logged in This Range", systemImage: "book")
                } description: {
                    Text(logbook.isEmpty
                         ? "Log insulin, food and site changes with the + button or ⌘L. Save the things you log often as presets for one-tap entry next time."
                         : "Pick a longer range in the toolbar to see older entries, or log something new.")
                } actions: {
                    Button("Log Insulin or Food…") { open(.new) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                totals(inRange)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                filterBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                if entries.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    table(entries)
                }
            }
            if !logbook.lastDeleted.isEmpty { undoBanner }
        }
        .animation(.smooth(duration: 0.2), value: logbook.lastDeleted.isEmpty)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases.filter(showsFilter)) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField("Search", text: $search, prompt: Text("Search food, insulin or notes"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
            if selection.count == 1, let id = selection.first, let entry = logbook.entry(id: id) {
                Button("Edit…") { open(.edit(entry)) }
                Button("Log Again Now") { logbook.duplicate(entry) }
                    .help("Log a copy of this entry at the current time")
            }
            if !selection.isEmpty {
                Button(role: .destructive) { deleteSelection() } label: {
                    Label(selection.count == 1 ? "Delete" : "Delete \(selection.count)", systemImage: "trash")
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
        default: return true
        }
    }

    private func matches(_ e: LogEntry) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [title(e), details(e), amount(e), site(e) ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func deleteSelection() {
        logbook.delete(ids: selection)
        selection = []
    }

    private var undoBanner: some View {
        let n = logbook.lastDeleted.count
        return HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text(n == 1 ? "Entry deleted" : "\(n) entries deleted")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Undo") { logbook.undoDelete() }
                .keyboardShortcut("z", modifiers: .command)
            Button {
                logbook.clearUndo()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        return HStack(alignment: .top, spacing: 16) {
            if settings.therapy.logsInsulin || bolus + basal > 0 {
                Metric(settings.therapy == .pump ? "Boluses logged" : "Mealtime insulin logged", LogFormat.number(bolus), sub: "units")
                if settings.therapy == .injections || basal > 0 {
                    Metric("Long-acting logged", LogFormat.number(basal), sub: "units")
                }
            }
            Metric("Carbs logged", LogFormat.number(carbs), sub: "grams")
            Metric("Entries", "\(entries.count)", sub: data.range.title.lowercased())
        }
    }

    private func table(_ entries: [LogEntry]) -> some View {
        let u = data.unit
        return Table(entries, selection: $selection) {
            TableColumn("Time") { (e: LogEntry) in
                Text(e.timestamp.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .monospacedDigit()
            }
            .width(min: 140, ideal: 170)
            TableColumn("Entry") { (e: LogEntry) in
                let k = kind(e)
                Label(title(e), systemImage: k.systemImage)
                    .foregroundStyle(k.color)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Amount") { (e: LogEntry) in
                Text(amount(e)).monospacedDigit().fontWeight(.semibold)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Details") { (e: LogEntry) in
                Text(details(e)).foregroundStyle(.secondary).help(details(e))
            }
            TableColumn("Site") { (e: LogEntry) in
                Text(site(e) ?? "–").foregroundStyle(site(e) == nil ? Color.secondary : Color.primary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Glucose") { (e: LogEntry) in
                if let r = GlucoseAnalytics.nearest(to: e.timestamp, in: data.readings, tolerance: 10 * 60) {
                    Text(u.format(mgdl: r.mgdl)).monospacedDigit()
                        .foregroundStyle(GlucoseRange.classify(mgdl: r.mgdl, low: data.lowMgdl, high: data.highMgdl).valueColor)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let entry = logbook.entry(id: id) {
                Button("Edit…") { open(.edit(entry)) }
                Button("Log Again Now") { logbook.duplicate(entry) }
                Divider()
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Entries", role: .destructive) {
                    logbook.delete(ids: ids)
                    selection.subtract(ids)
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let entry = logbook.entry(id: id) { open(.edit(entry)) }
        }
        .onDeleteCommand { deleteSelection() }
    }

    private func kind(_ e: LogEntry) -> ChartEvent.Kind {
        switch e {
        case .dose(let d): return d.kind.isBolus ? .bolus : .basal
        case .meal: return .food
        case .siteChange: return .siteChange
        case .context: return .context
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
        case .dose(let d): parts.append(d.displayName); parts.append(d.note)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if settings.therapy == .notSet {
                    TherapySetupView().dashboardCard()
                } else {
                    let insights = LogInsights.compute(readings: readings, doses: logbook.doses, meals: logbook.meals,
                                                       siteChanges: logbook.siteChanges, contexts: logbook.contexts,
                                                       low: lowMgdl, high: highMgdl,
                                                       siteOf: { logbook.site(of: $0) })
                    SafetyNote()
                    if logbook.isEmpty {
                        HStack {
                            Label("Start by logging your insulin and food. Patterns appear here once GlucOS has a few clean examples.",
                                  systemImage: "book")
                                .font(.callout)
                            Spacer()
                            Button("Log Insulin or Food…", action: onLog)
                        }
                        .dashboardCard()
                    }
                    if settings.therapy.logsInsulin {
                        InsulinActionCard(insights: insights, unit: unit)
                    }
                    MealResponseCard(insights: insights, unit: unit, showsInsulin: settings.therapy.logsInsulin)
                    if settings.therapy == .pump {
                        SiteAgeCard(buckets: insights.siteAge, unit: unit, hasSiteChanges: !logbook.siteChanges.isEmpty)
                    }
                    if settings.therapy == .injections {
                        SiteRotationCard()
                    }
                    Text(periodText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Disclaimer()
            }
            .padding(20)
        }
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

private struct SafetyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Observations, not advice")
                    .font(.headline)
                Text("These are patterns GlucOS has seen in your own logs and readings. They're rough estimates from limited data and are easily thrown off by missed logs, exercise, illness, stress, alcohol, hormones and what you ate. GlucOS never suggests a dose. Don't change your insulin, ratios or pump settings based on these. Talk to your diabetes care team first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Needs N more examples" in place of a figure.
private struct NeedsMore: View {
    let have: Int
    let need: Int
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView(value: Double(min(have, need)), total: Double(need))
                    .frame(width: 120)
                Text("\(have) of \(need) examples so far")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            Text(explanation)
                .font(.callout)
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
        VStack(alignment: .leading, spacing: 14) {
            CardTitle("How Long Insulin Seems to Work",
                      trailing: "\(overall.examples) usable of \(insights.bolusCount) boluses")
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
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Site")
                        Text("Examples")
                        Text("Starts working")
                        Text("Stops falling after")
                        Text("Drop per unit")
                    }
                    .font(.caption.weight(.medium))
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
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
            if insights.correctionsSetAside > 0 {
                setAsideNote(insights.correctionsSetAside, noun: "bolus", plural: "boluses",
                             hasRows: !insights.byTag.isEmpty && overall.examples >= need)
            }
            Text("“Starts working” is when glucose was 0.5 mmol/L below where it started. “Stops falling after” is when it reached its lowest point: a rough guide to how long the insulin kept acting. “Drop per unit” is how far glucose fell per unit in those doses. It is an observation, not your correction factor (ISF), which your care team sets.")
                .font(.caption)
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
        .font(.caption)
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
        VStack(alignment: .leading, spacing: 14) {
            CardTitle("After Meals", trailing: "\(usable) usable of \(insights.mealCount) logged")
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
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Examples")
                        Text("Typical rise")
                        Text("Peak after")
                        Text("Rise per 10 g carbs")
                    }
                    .font(.caption.weight(.medium))
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
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
            if insights.mealsSetAside > 0 {
                setAsideNote(insights.mealsSetAside, noun: "meal", plural: "meals", hasRows: false)
            }
            Text(showsInsulin
                 ? "Rise is from your glucose when you logged the meal to the highest point in the next 3 hours. “With insulin” means a bolus was logged within 30 minutes of eating, so the rise reflects both the food and the insulin."
                 : "Rise is from your glucose when you logged the meal to the highest point in the next 3 hours.")
                .font(.caption)
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
        VStack(alignment: .leading, spacing: 14) {
            CardTitle("Glucose by Day of Site Wear")
            if buckets.isEmpty {
                NeedsMore(have: 0, need: 2,
                          explanation: hasSiteChanges
                          ? "Each day of wear needs at least two sites' worth of readings. Keep logging site changes."
                          : "Log each infusion site change (+ button → Changed infusion site) to see whether your glucose changes as a site ages.")
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Day", b.title), y: .value("Average", unit.value(fromMgdl: b.meanMgdl)))
                        .foregroundStyle(Color.purple.gradient)
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 0) {
                                Text(unit.format(mgdl: b.meanMgdl)).font(.caption.weight(.semibold))
                                Text("\(Format.percent(b.timeInRange)) in range").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
                .chartYAxisLabel { Text("Average (\(unit.label))") }
                .frame(height: 200)
                Text("Average glucose on each day a site was worn, across \(buckets.map(\.sites).max() ?? 0) sites.")
                    .font(.caption)
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
        VStack(alignment: .leading, spacing: 14) {
            CardTitle("Injection Sites", trailing: "last 14 days")
            if last.isEmpty {
                Text("Choose an injection site when you log a dose to see how you've been rotating.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Area")
                        Text("Left")
                        Text("Right")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    ForEach([BodyArea.abdomen, .arm, .thigh, .hip]) { area in
                        let sites = InjectionSite.allCases.filter { $0.area == area }
                        GridRow {
                            Text(area.title)
                            ForEach(sites) { s in
                                cell(last: last[s], count: recent[s]?.count ?? 0)
                            }
                        }
                        .font(.callout)
                    }
                }
                Text("Rotating injection sites helps avoid lumpy areas under the skin, which can make insulin absorb unpredictably.")
                    .font(.caption)
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
                    .font(.caption2)
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
