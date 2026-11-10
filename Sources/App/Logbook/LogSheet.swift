import SwiftUI
import AppKit

/// What the log sheet is for: a new entry, or editing one.
enum LogSheetTarget: Identifiable {
    case new
    case edit(LogEntry)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let e): return e.id.uuidString
        }
    }
}

/// Logs insulin, food and (on a pump) a site change, all at one time. What it asks for follows
/// the therapy type in Settings. It records what the user enters and never suggests an amount:
/// presets and "same as last" only ever repeat numbers the user typed themselves.
///
/// Hosted both as a sheet on the dashboard and on its own in the quick-log window.
struct LogSheet: View {
    private enum Part { case dose, meal, siteChange, context }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Closes the host. Nil for a sheet, which uses `dismiss`.
    private let onClose: (() -> Void)?

    /// Set when editing: only that part is shown.
    private let editing: Part?
    private let editingID: UUID?
    private let doseID: UUID
    private let mealID: UUID
    private let siteID: UUID
    private let contextID: UUID

    @State private var time: Date
    @State private var includeInsulin: Bool
    @State private var includeFood: Bool
    @State private var includeSiteChange: Bool
    @State private var viaPump: Bool
    @State private var unitsText: String
    @State private var kind: InsulinKind
    @State private var insulinName: String
    @State private var injectionSite: InjectionSite?
    @State private var carbsText: String
    @State private var food: String
    @State private var newSite: InjectionSite
    @State private var tags: Set<ContextTag>
    @State private var note: String
    @State private var showsTagPicker: Bool
    @State private var appliedPresetID: UUID?
    @State private var savesAsPreset = false
    @State private var presetName = ""
    @State private var confirmingDelete = false
    @FocusState private var focus: LogFieldFocus?

    init(target: LogSheetTarget, onClose: (() -> Void)? = nil) {
        let s = AppSettings.shared
        var editing: Part?
        var editingID: UUID?
        var doseID = UUID(), mealID = UUID(), siteID = UUID(), contextID = UUID()
        var time = Date()
        var includeInsulin = s.therapy.logsInsulin
        var includeFood = !s.therapy.logsInsulin
        var includeSiteChange = false
        var viaPump = s.therapy == .pump
        var unitsText = ""
        var kind = s.bolusInsulinKind
        var insulinName = s.bolusInsulinName
        var injectionSite: InjectionSite?
        var carbsText = ""
        var food = ""
        var newSite = InjectionSite.abdomenLeft
        var tags = Set<ContextTag>()
        var note = ""

        if case .edit(let entry) = target {
            time = entry.timestamp
            editingID = entry.id
            includeInsulin = false
            includeFood = false
            switch entry {
            case .dose(let d):
                editing = .dose
                doseID = d.id
                includeInsulin = true
                viaPump = d.viaPump
                unitsText = LogFormat.number(d.units)
                kind = d.kind
                insulinName = d.name
                injectionSite = d.site
                note = d.note
            case .meal(let m):
                editing = .meal
                mealID = m.id
                includeFood = true
                carbsText = m.carbs > 0 ? LogFormat.number(m.carbs) : ""
                food = m.food
                note = m.note
            case .siteChange(let c):
                editing = .siteChange
                siteID = c.id
                includeSiteChange = true
                newSite = c.site
                note = c.note
            case .context(let c):
                editing = .context
                contextID = c.id
                tags = c.tags
                note = c.note
            }
        }

        self.onClose = onClose
        self.editing = editing
        self.editingID = editingID
        self.doseID = doseID
        self.mealID = mealID
        self.siteID = siteID
        self.contextID = contextID
        _time = State(initialValue: time)
        _includeInsulin = State(initialValue: includeInsulin)
        _includeFood = State(initialValue: includeFood)
        _includeSiteChange = State(initialValue: includeSiteChange)
        _viaPump = State(initialValue: viaPump)
        _unitsText = State(initialValue: unitsText)
        _kind = State(initialValue: kind)
        _insulinName = State(initialValue: insulinName)
        _injectionSite = State(initialValue: injectionSite)
        _carbsText = State(initialValue: carbsText)
        _food = State(initialValue: food)
        _newSite = State(initialValue: newSite)
        _tags = State(initialValue: tags)
        _note = State(initialValue: note)
        _showsTagPicker = State(initialValue: editing == .context || !tags.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.therapy == .notSet && editing == nil {
                TherapySetupView()
                    .padding(24)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            } else {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if editing == nil { quickAdd }
                        if editing == nil { partPicker }
                        if showsInsulin && includeInsulin { insulinPanel }
                        if showsFood && includeFood { foodPanel }
                        if showsSiteChange && includeSiteChange { siteChangePanel }
                        if showsTags { tagsPanel }
                        TextField("Note", text: $note, prompt: Text("Add a note (optional)"), axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(16)
                    .animation(.smooth(duration: 0.2), value: includeInsulin)
                    .animation(.smooth(duration: 0.2), value: includeFood)
                    .animation(.smooth(duration: 0.2), value: includeSiteChange)
                    .animation(.smooth(duration: 0.2), value: showsTagPicker)
                }
                .frame(height: editing == nil ? 560 : 400)
                Divider()
                footer
            }
        }
        .frame(width: 520)
        .onAppear { focusFirstField() }
        .onChange(of: settings.therapy) { _, therapy in
            // Picked in the setup step above: start from that therapy's defaults.
            guard editing == nil else { return }
            viaPump = therapy == .pump
            includeInsulin = therapy.logsInsulin
            includeFood = !therapy.logsInsulin
            kind = settings.bolusInsulinKind
            insulinName = settings.bolusInsulinName
        }
        .onChange(of: kind) { old, new in
            if insulinName == settings.defaultInsulinName(for: old) {
                insulinName = settings.defaultInsulinName(for: new)
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let editingID { logbook.delete(ids: [editingID]) }
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can undo this from the Logbook.")
        }
    }

    // MARK: Header

    private var title: String {
        switch editing {
        case .none: return "Log"
        case .dose: return viaPump ? "Edit Bolus" : "Edit Insulin"
        case .meal: return "Edit Food"
        case .siteChange: return "Edit Site Change"
        case .context: return "Edit Context"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("GlucOS records what you enter. It never suggests a dose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("Time", selection: $time, in: ...Date().addingTimeInterval(15 * 60),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
            }
            HStack(spacing: 6) {
                ForEach([0, 15, 30, 60, 120], id: \.self) { minutes in
                    Button(minutes == 0 ? "Now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago") {
                        time = Date().addingTimeInterval(-Double(minutes) * 60)
                    }
                    .buttonStyle(ChipButtonStyle(selected: isOffset(minutes)))
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func isOffset(_ minutes: Int) -> Bool {
        abs(time.timeIntervalSince(Date().addingTimeInterval(-Double(minutes) * 60))) < 45
    }

    // MARK: Quick add

    private var recentFoods: [RecentFood] { logbook.recentFoods(limit: 4) }

    /// Presets, the last bolus and recent foods: one tap fills the form with numbers the user
    /// logged before.
    @ViewBuilder
    private var quickAdd: some View {
        let presets = logbook.presets
        let lastBolus = settings.therapy.logsInsulin ? logbook.lastBolus : nil
        let foods = recentFoods
        if !presets.isEmpty || lastBolus != nil || !foods.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: "Quick add", systemImage: "bolt.fill",
                        trailing: presets.isEmpty ? "save a preset below" : nil)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presets) { p in
                            Button { apply(p) } label: {
                                Label {
                                    Text(p.name) + Text(p.summary.isEmpty ? "" : "  \(p.summary)").foregroundColor(.secondary)
                                } icon: {
                                    Image(systemName: p.systemImage)
                                }
                            }
                            .buttonStyle(ChipButtonStyle(selected: appliedPresetID == p.id))
                            .help("Fill in \(p.name)")
                        }
                        if let d = lastBolus {
                            Button { applyLast(d) } label: {
                                Label("Same as last: \(LogFormat.units(d.units))", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(ChipButtonStyle())
                            .help("\(LogFormat.units(d.units)) \(d.displayName), \(d.timestamp.formatted(.relative(presentation: .named)))")
                        }
                        ForEach(foods) { f in
                            Button { apply(f) } label: {
                                Label(f.carbs > 0 ? "\(f.food) · \(LogFormat.grams(f.carbs))" : f.food, systemImage: "fork.knife")
                            }
                            .buttonStyle(ChipButtonStyle(selected: includeFood && foodText.caseInsensitiveCompare(f.food) == .orderedSame))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func apply(_ p: LogPreset) {
        appliedPresetID = p.id
        if showsInsulin {
            includeInsulin = p.hasInsulin
            if let u = p.units {
                unitsText = LogFormat.number(u)
                if let k = p.kind, !viaPump || InsulinKind.pumpKinds.contains(k) { kind = k }
                if !p.insulinName.isEmpty { insulinName = p.insulinName }
            }
        }
        includeFood = p.hasFood
        carbsText = (p.carbs ?? 0) > 0 ? LogFormat.number(p.carbs ?? 0) : ""
        food = p.food
        tags = p.tags
        if !p.tags.isEmpty { showsTagPicker = true }
    }

    private func applyLast(_ d: InsulinDose) {
        includeInsulin = true
        unitsText = LogFormat.number(d.units)
        if !viaPump || InsulinKind.pumpKinds.contains(d.kind) { kind = d.kind }
        insulinName = d.name
        focus = .units
    }

    private func apply(_ f: RecentFood) {
        includeFood = true
        food = f.food
        if f.carbs > 0 { carbsText = LogFormat.number(f.carbs) }
    }

    // MARK: Parts

    private var showsInsulin: Bool { editing == .dose || (editing == nil && settings.therapy.logsInsulin) }
    private var showsFood: Bool { editing == .meal || editing == nil }
    private var showsSiteChange: Bool { editing == .siteChange || (editing == nil && settings.therapy == .pump) }
    private var showsTags: Bool { editing == .context || editing == nil }

    private static let insulinTint = Color.blue
    private static let foodTint = Color.orange
    private static let siteTint = Color.purple
    private static let contextTint = Color.teal

    private var partPicker: some View {
        HStack(spacing: 8) {
            if showsInsulin {
                Toggle(isOn: $includeInsulin.animation(.smooth(duration: 0.2))) {
                    Label(viaPump ? "Bolus" : "Insulin", systemImage: "syringe")
                }
                .toggleStyle(TileToggleStyle(tint: Self.insulinTint))
                .keyboardShortcut("1", modifiers: .command)
            }
            Toggle(isOn: $includeFood.animation(.smooth(duration: 0.2))) {
                Label("Food", systemImage: "fork.knife")
            }
            .toggleStyle(TileToggleStyle(tint: Self.foodTint))
            .keyboardShortcut("2", modifiers: .command)
            if showsSiteChange {
                Toggle(isOn: $includeSiteChange.animation(.smooth(duration: 0.2))) {
                    Label("New site", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(TileToggleStyle(tint: Self.siteTint))
                .keyboardShortcut("3", modifiers: .command)
            }
        }
    }

    private var insulinPanel: some View {
        FlowPanel(title: viaPump ? "Bolus" : "Insulin", systemImage: "syringe", tint: Self.insulinTint) {
            NumberStepperField(title: "Units", text: $unitsText, unitLabel: "units",
                               step: viaPump ? 0.5 : 1, range: LogLimits.units,
                               focus: $focus, focusValue: .units)
            if let problem = unitsProblem { FieldProblem(text: problem) }
            HStack(spacing: 10) {
                Picker("Insulin", selection: $kind) {
                    ForEach(viaPump ? InsulinKind.pumpKinds : InsulinKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                .fixedSize()
                TextField("Name", text: $insulinName, prompt: Text(kind.examples))
                    .textFieldStyle(.roundedBorder)
            }
            if viaPump {
                LabeledContent("Infusion site") {
                    Text(pumpSiteText).foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                InjectionSitePicker(selection: $injectionSite)
            }
        }
    }

    private var foodPanel: some View {
        FlowPanel(title: "Food", systemImage: "fork.knife", tint: Self.foodTint) {
            HStack(alignment: .center, spacing: 12) {
                NumberStepperField(title: "Carbs", text: $carbsText, unitLabel: "g carbs",
                                   step: 5, range: LogLimits.carbs, focus: $focus, focusValue: .carbs)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach([10, 15, 20, 30, 45, 60], id: \.self) { g in
                    Button("\(g) g") { carbsText = "\(g)" }
                        .buttonStyle(ChipButtonStyle(selected: carbs == Double(g)))
                        .controlSize(.small)
                }
            }
            if let problem = foodProblem { FieldProblem(text: problem) }
            TextField("What you ate", text: $food, prompt: Text("What you ate, e.g. toast and a banana"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .food)
            let suggestions = logbook.recentFoods(matching: foodText, limit: 6)
                .filter { $0.food.caseInsensitiveCompare(foodText) != .orderedSame }
            if !foodText.isEmpty && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { f in
                            Button(f.carbs > 0 ? "\(f.food) · \(LogFormat.grams(f.carbs))" : f.food) { apply(f) }
                                .buttonStyle(ChipButtonStyle())
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var siteChangePanel: some View {
        FlowPanel(title: "Infusion site change", systemImage: "arrow.triangle.2.circlepath", tint: Self.siteTint) {
            Picker("New site", selection: $newSite) {
                ForEach(InjectionSite.allCases) { s in Text(s.title).tag(s) }
            }
            .fixedSize()
            Text("Boluses after this time are counted against this site.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tagChoices: [ContextTag] {
        settings.therapy.logsInsulin || tags.contains(.siteProblem)
            ? ContextTag.allCases
            : ContextTag.allCases.filter { $0 != .siteProblem }
    }

    @ViewBuilder
    private var tagsPanel: some View {
        if showsTagPicker {
            FlowPanel(title: editing == .context ? "Context" : "Anything else going on?", systemImage: "tag",
                      tint: Self.contextTint) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(tagChoices) { t in
                        Button {
                            if tags.contains(t) { tags.remove(t) } else { tags.insert(t) }
                        } label: {
                            Label(t.title, systemImage: t.systemImage)
                        }
                        .buttonStyle(ChipButtonStyle(selected: tags.contains(t), tint: Self.contextTint))
                        .help(t.help)
                    }
                }
                Text("Doses and meals around these are kept out of the typical figures in Insights, so they don't skew them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button {
                showsTagPicker = true
            } label: {
                Label("Add context: exercise, illness, alcohol…", systemImage: "tag")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if editing != nil {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } else {
                Toggle("Save as preset", isOn: $savesAsPreset.animation(.smooth(duration: 0.15)))
                    .toggleStyle(.checkbox)
                    .disabled(!canSave)
                    .help("Keep this combination as a one-tap quick add")
                if savesAsPreset {
                    TextField("Preset name", text: $presetName, prompt: Text(defaultPresetName))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .focused($focus, equals: .presetName)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Log" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(16)
    }

    // MARK: Values

    private static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : Double(t)
    }

    private var units: Double? {
        guard let u = Self.parse(unitsText), LogLimits.units.contains(u) else { return nil }
        return u
    }

    private var unitsProblem: String? {
        guard !unitsText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let u = Self.parse(unitsText) else { return "Enter the number of units." }
        if !LogLimits.units.contains(u) {
            return "Check the amount. GlucOS accepts \(LogFormat.number(LogLimits.units.lowerBound))–\(LogFormat.number(LogLimits.units.upperBound)) units."
        }
        return nil
    }

    private var carbs: Double? {
        let t = carbsText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        guard let c = Self.parse(t), LogLimits.carbs.contains(c) else { return nil }
        return c
    }

    private var foodProblem: String? {
        if !carbsText.trimmingCharacters(in: .whitespaces).isEmpty, carbs == nil {
            return "Enter grams of carbohydrate (0–\(LogFormat.number(LogLimits.carbs.upperBound)))."
        }
        return nil
    }

    private var foodText: String { food.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var insulinValid: Bool { units != nil }
    private var foodValid: Bool {
        guard let c = carbs else { return false }
        return c > 0 || !foodText.isEmpty
    }

    private var canSave: Bool {
        let parts = [
            (showsInsulin && includeInsulin, insulinValid),
            (showsFood && includeFood, foodValid),
            (showsSiteChange && includeSiteChange, true),
            (showsTags && !tags.isEmpty, true),
        ].filter { $0.0 }
        return !parts.isEmpty && parts.allSatisfy { $0.1 }
    }

    private var pumpSiteText: String {
        if showsSiteChange && includeSiteChange { return "\(newSite.title) (new)" }
        guard let current = logbook.infusionSite(at: time) else { return "None logged yet" }
        return "\(current.site.title), since \(current.timestamp.formatted(.relative(presentation: .named)))"
    }

    private var defaultPresetName: String {
        if showsFood && includeFood && !foodText.isEmpty { return foodText }
        if showsInsulin && includeInsulin, let units { return "\(LogFormat.units(units)) \(kind.isBolus ? "bolus" : kind.title.lowercased())" }
        if showsFood && includeFood, let carbs, carbs > 0 { return "\(LogFormat.grams(carbs)) carbs" }
        return ContextTag.allCases.first(where: tags.contains)?.title ?? "Preset"
    }

    private func focusFirstField() {
        guard editing == nil || editing == .dose || editing == .meal else { return }
        // Sheets and new windows take focus a beat after appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if showsInsulin && includeInsulin { focus = .units } else if showsFood && includeFood { focus = .carbs }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func save() {
        guard canSave else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let logsInsulin = showsInsulin && includeInsulin
        let logsFood = showsFood && includeFood
        let trimmedName = insulinName.trimmingCharacters(in: .whitespacesAndNewlines)
        if logsInsulin, let units {
            logbook.save(.dose(InsulinDose(id: doseID, timestamp: time, units: units, kind: kind,
                                           name: trimmedName,
                                           site: viaPump ? nil : injectionSite, viaPump: viaPump,
                                           note: trimmedNote)))
        }
        if logsFood, let carbs {
            logbook.save(.meal(MealEntry(id: mealID, timestamp: time, carbs: carbs, food: foodText, note: trimmedNote)))
        }
        if showsSiteChange && includeSiteChange {
            logbook.save(.siteChange(SiteChange(id: siteID, timestamp: time, site: newSite, note: trimmedNote)))
        }
        if showsTags && !tags.isEmpty {
            logbook.save(.context(ContextEvent(id: contextID, timestamp: time, tags: tags, note: trimmedNote)))
        }
        if editing == nil && savesAsPreset {
            let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            logbook.savePreset(LogPreset(name: name.isEmpty ? defaultPresetName : name,
                                         units: logsInsulin ? units : nil,
                                         kind: logsInsulin ? kind : nil,
                                         insulinName: logsInsulin ? trimmedName : "",
                                         carbs: logsFood ? carbs : nil,
                                         food: logsFood ? foodText : "",
                                         tags: tags))
        }
        close()
    }
}

// MARK: - Injection site picker

/// Body map as a grid of left/right buttons, each showing when it was last used. The site used
/// longest ago is marked, to help with rotation.
struct InjectionSitePicker: View {
    @Binding var selection: InjectionSite?
    @EnvironmentObject var logbook: LogbookStore

    var body: some View {
        let last = logbook.lastInjectionBySite
        let suggested = logbook.leastRecentInjectionSite
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Injection site").font(.callout)
                Spacer()
                if let suggested {
                    Text("Longest since used: \(suggested.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach([BodyArea.abdomen, .arm, .thigh, .hip]) { area in
                    GridRow {
                        Text(area.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .leading)
                        ForEach(InjectionSite.allCases.filter { $0.area == area }) { s in
                            siteButton(s, last: last[s], suggested: s == suggested)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Other") { selection = selection == .other ? nil : .other }
                    .buttonStyle(ChipButtonStyle(selected: selection == .other))
                Button("Not recorded") { selection = nil }
                    .buttonStyle(ChipButtonStyle(selected: selection == nil))
            }
            .controlSize(.small)
        }
    }

    private func siteButton(_ s: InjectionSite, last: Date?, suggested: Bool) -> some View {
        Button {
            selection = selection == s ? nil : s
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text((s.side ?? s.title).capitalized)
                    if suggested { Image(systemName: "sparkle").imageScale(.small) }
                }
                Text(last.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? "not used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ChipButtonStyle(selected: selection == s))
        .help(last.map { "\(s.title), last used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? s.title)
        .accessibilityLabel(s.title)
    }
}

// MARK: - Quick-log window

/// The log sheet in its own small window, so logging from the menu bar doesn't open the dashboard.
struct LogWindow: View {
    static let id = "log"
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        LogSheet(target: .new) { dismissWindow(id: Self.id) }
            .onAppear { NSApp.activate() }
    }
}

// MARK: - Therapy setup

/// Asks how the user takes insulin. Shown the first time they log or open Insights, and in Settings.
struct TherapySetupView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How do you take insulin?")
                    .font(.title2.weight(.semibold))
                Text("GlucOS uses this to decide what to ask when you log, and which patterns to show you. You can change it any time in Settings → Insulin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([TherapyType.injections, .pump, .noInsulin]) { t in
                Button { settings.therapy = t } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.systemImage)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.headline)
                            Text(t.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if settings.therapy == t {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
