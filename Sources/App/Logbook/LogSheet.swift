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

/// Logs what's happening. It starts from the moment ("What's happening?": eating, a bolus, a
/// basal dose, waking up, going to sleep, something else) rather than a type of record, and each
/// moment opens the part of the entry it needs, always in the order of `LogFlow`: food first, then
/// the dose for it, so the carbs run straight into the bolus calculator below. What it offers
/// follows the therapy type in Settings. It records what the user enters: presets and "same as last" only
/// ever repeat numbers the user typed themselves. The one suggested amount is the bolus
/// calculator's, from the user's confirmed settings, and logging it asks for confirmation.
///
/// Hosted both as a sheet on the dashboard and on its own in the quick-log window.
struct LogSheet: View {
    private enum Part { case dose, meal, siteChange, context }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: GlucoseStore
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
    /// The parts of the entry that are open. Shown in `LogFlow` order whatever order they were picked in.
    @State private var parts: Set<LogPart>
    @State private var viaPump: Bool
    @State private var unitsText: String
    @State private var kind: InsulinKind
    @State private var insulinName: String
    /// Typing an insulin that isn't in Settings → Your Insulins.
    @State private var typesInsulin = false
    /// The injection site filled in automatically, until the user picks another.
    @State private var autoSite: InjectionSite?
    /// The site is still the automatic one: no site has been picked by hand since.
    @State private var siteIsAutomatic = false
    @State private var injectionSite: InjectionSite?
    @State private var carbsText: String
    @State private var food: String
    @State private var newSite: InjectionSite
    @State private var tags: Set<ContextTag>
    @State private var note: String
    @State private var appliedPresetID: UUID?
    @State private var savesAsPreset = false
    @State private var presetName = ""
    @State private var confirmingDelete = false
    @State private var mealItems: [MealItem]
    @State private var showsFoodPicker = false
    /// What the food picker opens with: empty, or the meal as typed in the food panel.
    @State private var foodQuery = ""
    @State private var showsBolusSettings = false
    /// The calculator suggestion the dose was filled from, if any.
    @State private var usedSuggestion: BolusSuggestion?
    /// What the calculator says now, to check a used suggestion against.
    @State private var liveSuggestion: BolusSuggestion?
    /// Works the calculator's answer out again on the spot, for the check at save and log.
    @State private var recomputeSuggestion: (@MainActor () -> BolusSuggestion?)?
    @State private var confirmingDose = false
    @FocusState private var focus: LogFieldFocus?

    init(target: LogSheetTarget, onClose: (() -> Void)? = nil) {
        let s = AppSettings.shared
        var editing: Part?
        var editingID: UUID?
        var doseID = UUID(), mealID = UUID(), siteID = UUID(), contextID = UUID()
        var time = Date()
        // A new entry starts by asking what's happening; an edit shows its one part.
        var parts = Set<LogPart>()
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
        var items: [MealItem] = []

        if case .edit(let entry) = target {
            time = entry.timestamp
            editingID = entry.id
            switch entry {
            case .dose(let d):
                editing = .dose
                doseID = d.id
                parts = [.insulin]
                viaPump = d.viaPump
                unitsText = LogFormat.number(d.units)
                kind = d.kind
                insulinName = d.name
                injectionSite = d.site
                note = d.note
            case .meal(let m):
                editing = .meal
                mealID = m.id
                parts = [.food]
                carbsText = m.carbs > 0 ? LogFormat.number(m.carbs) : ""
                food = m.food
                note = m.note
                items = m.items ?? []
                // A description made from the foods' names is remade from them on save.
                if !items.isEmpty && food == items.map(\.name).joined(separator: ", ") { food = "" }
            case .siteChange(let c):
                editing = .siteChange
                siteID = c.id
                parts = [.site]
                newSite = c.site
                note = c.note
            case .context(let c):
                editing = .context
                contextID = c.id
                parts = [.event]
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
        _parts = State(initialValue: parts)
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
        _mealItems = State(initialValue: items)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if isNew { momentPicker }
                            if isNew { quickAdd }
                            ForEach(shownParts) { part in
                                bridge(before: part)
                                panel(for: part)
                                    .id(part)
                                    .transition(.opacity)
                                bridge(after: part)
                            }
                            TextField("Note", text: $note, prompt: Text("Add a note (optional)"), axis: .vertical)
                                .lineLimit(1...3)
                                .textFieldStyle(.roundedBorder)
                            Label("GlucOS records what you enter. Only the bolus calculator suggests a dose, from your own settings.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                        .padding(16)
                        .animation(.smooth(duration: 0.2), value: parts)
                        .animation(.smooth(duration: 0.2), value: tags)
                    }
                    .onChange(of: parts) { old, new in
                        // Bring the part that was just opened into view and put the cursor in it.
                        guard isNew, let part = LogFlow.focusPart(from: old, to: new, available: availableParts) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(part, anchor: .top) }
                            if part == .insulin { focus = .units } else if part == .food { focus = .carbs }
                        }
                    }
                }
                // Grows and shrinks with the window (or sheet), scrolling when there's more form than
                // room, instead of a fixed height that clips on small displays.
                .frame(minHeight: 220, idealHeight: editing == nil ? 520 : 360, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 780)
        .onAppear { startDose(); focusFirstField() }
        .onChange(of: settings.therapy) { _, therapy in
            // Picked in the setup step above: start from that therapy's defaults.
            guard editing == nil else { return }
            viaPump = therapy == .pump
            parts = []
            kind = settings.bolusInsulinKind
            insulinName = settings.bolusInsulinName
            startDose()
        }
        .onChange(of: logbook.insulins) { _, _ in
            // The list can arrive by sync after the sheet opened.
            guard editing == nil, !typesInsulin, insulinName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let p = logbook.preferredInsulin(viaPump: viaPump) else { return }
            kind = p.kind
            insulinName = p.name
        }
        .onChange(of: time) { _, newTime in
            // Keep an automatic site in step with the dose time; a site the user picked stays.
            guard editing == nil, !viaPump, siteIsAutomatic else { return }
            autoSite = logbook.suggestedInjectionSite(at: newTime)
            injectionSite = autoSite
            // With no suggestion the sheet shows "Not recorded", and a tap on it changes nothing
            // the sheet can see, so stop following the time rather than override that choice.
            if autoSite == nil { siteIsAutomatic = false }
        }
        .onChange(of: injectionSite) { _, site in
            // Any pick by hand (including "Not recorded") stops the site following the time.
            if site != autoSite { siteIsAutomatic = false }
        }
        .onChange(of: kind) { old, new in
            // An edited dose keeps its name whatever its type (the name field shows if they differ).
            guard editingID == nil else { return }
            // Picking another type while a saved insulin of the old type is selected.
            if let saved = logbook.savedInsulin(named: insulinName), saved.kind == old, saved.kind != new {
                insulinName = ""
            } else if insulinName == settings.defaultInsulinName(for: old) {
                insulinName = settings.defaultInsulinName(for: new)
            }
            dropSuggestionIfStale()
        }
        .onChange(of: time) { _, _ in dropSuggestionIfStale() }
        .onChange(of: parts) { _, _ in dropSuggestionIfStale() }
        .sheet(isPresented: $showsFoodPicker) {
            FoodPickerView(initialQuery: foodQuery, onAdd: { item in addItem(item) }, onClose: {
                // The meal typed in the food panel is now its foods: don't also keep it as a name.
                if !mealItems.isEmpty, !foodQuery.isEmpty, foodText == foodQuery { food = "" }
                showsFoodPicker = false
            })
            .environmentObject(logbook)
        }
        .sheet(isPresented: $showsBolusSettings) {
            BolusSettingsEditor(current: logbook.bolusSettings) { showsBolusSettings = false }
                .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
                .environmentObject(logbook)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .confirmationDialog(units.map { "Log a \(LogFormat.units($0)) dose?" } ?? "Log this dose?",
                            isPresented: $confirmingDose) {
            Button("Log \(units.map { LogFormat.units($0) } ?? "dose")") { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(usedSuggestion?.confirmation(loggedUnits: units ?? 0, unit: settings.unit) ?? "")
        }
        .onChange(of: carbsText) { _, _ in
            // A suggestion was for the carbs at the time: if they change, take it again.
            if let s = usedSuggestion, abs((carbs ?? -1) - s.carbs) > 0.001 {
                usedSuggestion = nil
                unitsText = ""
            }
        }
        .onChange(of: unitsText) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty { usedSuggestion = nil }
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
        case .context: return "Edit Event"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .dsFont(.title)
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

    /// The user's presets: one click fills the form with what they saved. (The last dose and
    /// recent foods are offered inside the dose and food panels, where they belong.)
    @ViewBuilder
    private var quickAdd: some View {
        let presets = logbook.presets
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: "Your presets", systemImage: "bolt.fill")
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
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func apply(_ p: LogPreset) {
        appliedPresetID = p.id
        var next = parts.subtracting([.insulin, .food, .event])
        if settings.therapy.logsInsulin, let u = p.units {
            next.insert(.insulin)
            unitsText = LogFormat.number(u)
            if let k = p.kind, !viaPump || InsulinKind.pumpKinds.contains(k) { kind = k }
            if !p.insulinName.isEmpty { insulinName = p.insulinName }
        }
        if p.hasFood { next.insert(.food) }
        carbsText = (p.carbs ?? 0) > 0 ? LogFormat.number(p.carbs ?? 0) : ""
        food = p.food
        tags = p.tags
        // Waking up and going to sleep show on their own tiles; anything else opens its panel.
        if p.tags.contains(where: { !$0.isMoment }) { next.insert(.event) }
        parts = next
    }

    private func applyLast(_ d: InsulinDose) {
        parts.insert(.insulin)
        unitsText = LogFormat.number(d.units)
        if !viaPump || InsulinKind.pumpKinds.contains(d.kind) { kind = d.kind }
        insulinName = d.name
        focus = .units
    }

    private func apply(_ f: RecentFood) {
        parts.insert(.food)
        food = f.food
        if f.carbs > 0 { carbsText = LogFormat.number(f.carbs) }
    }

    // MARK: Insulin

    /// Saved insulins this dose can be logged with. A new dose shows the ones for the moment that
    /// was picked: mealtime insulins for a bolus, background ones for a basal dose.
    private var insulinChoices: [SavedInsulin] {
        let all = InsulinLibrary.choices(logbook.insulins, viaPump: viaPump)
        return isNew ? all.filter { $0.kind.isBolus == kind.isBolus } : all
    }

    /// Show the type picker and name field: nothing saved yet, "Other…" chosen, or a name (from
    /// an older entry or preset) that isn't in the list.
    private var showsInsulinEntry: Bool {
        if insulinChoices.isEmpty || typesInsulin { return true }
        let name = insulinName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard let saved = logbook.savedInsulin(named: name) else { return true }
        // An older dose whose type differs from the saved insulin's shows its own type.
        return saved.kind != kind || !insulinChoices.contains(saved)
    }

    private func pick(_ insulin: SavedInsulin) {
        typesInsulin = false
        kind = insulin.kind
        insulinName = insulin.name
    }

    /// A new entry starts on the user's usual insulin and, for an injection, the site used
    /// longest ago. Both are one click to change.
    private func startDose(bolus: Bool = true) {
        guard isNew else { return }
        // Going from a bolus to a basal dose (or back): the amount typed was for the other one.
        if kind.isBolus != bolus { unitsText = "" }
        let preferred = bolus ? logbook.preferredInsulin(viaPump: viaPump)
            : InsulinLibrary.preferredBasal(in: logbook.insulins, doses: logbook.doses)
        if let p = preferred, p.kind.isBolus == bolus {
            kind = p.kind
            insulinName = p.name
            typesInsulin = false
        } else if kind.isBolus != bolus {
            kind = bolus ? .rapid : .long
            insulinName = settings.defaultInsulinName(for: kind)
        }
        if !viaPump, injectionSite == nil {
            autoSite = logbook.suggestedInjectionSite(at: time)
            injectionSite = autoSite
            siteIsAutomatic = autoSite != nil
        }
    }

    // MARK: Parts

    private var isNew: Bool { editing == nil }

    private var editingPart: LogPart? {
        switch editing {
        case .none: return nil
        case .dose: return .insulin
        case .meal: return .food
        case .siteChange: return .site
        case .context: return .event
        }
    }

    private var availableParts: [LogPart] {
        LogFlow.parts(logsInsulin: settings.therapy.logsInsulin, pump: settings.therapy == .pump)
    }

    private func includes(_ part: LogPart) -> Bool {
        if let editingPart { return editingPart == part }
        return parts.contains(part) && availableParts.contains(part)
    }

    /// The parts on screen, in flow order: food always sits above the dose for it.
    private var shownParts: [LogPart] {
        if let editingPart { return [editingPart] }
        return LogFlow.ordered(parts, available: availableParts)
    }

    @ViewBuilder
    private func panel(for part: LogPart) -> some View {
        switch part {
        case .food: foodPanel
        case .insulin: insulinPanel
        case .site: siteChangePanel
        case .event: tagsPanel
        }
    }

    private static let insulinTint = Palette.insulin
    private static let foodTint = Palette.food
    private static let siteTint = Palette.site
    private static let contextTint = Palette.context

    // MARK: Moments

    private var moments: [LogMoment] {
        LogFlow.moments(logsInsulin: settings.therapy.logsInsulin, pump: settings.therapy == .pump)
    }

    private func isOn(_ moment: LogMoment) -> Bool {
        LogFlow.isOn(moment, parts: Set(shownParts), mealtimeDose: kind.isBolus, tags: tags)
    }

    private func tint(_ moment: LogMoment) -> Color {
        switch moment {
        case .eating: return Self.foodTint
        case .bolus, .basal: return Self.insulinTint
        case .newSite: return Self.siteTint
        case .wokeUp, .bedtime, .other: return Self.contextTint
        }
    }

    /// "What's happening?": the moments to pick from, ⌘1 onwards. More than one can be on.
    private var momentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's happening?")
                .dsFont(.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(moments.enumerated()), id: \.element) { index, m in
                    Toggle(isOn: Binding(get: { isOn(m) }, set: { _ in toggle(m) })) {
                        Label(m.title, systemImage: m.systemImage)
                    }
                    .toggleStyle(TileToggleStyle(tint: tint(m)))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("\(m.detail) (⌘\(index + 1))")
                }
            }
        }
    }

    private func toggle(_ moment: LogMoment) {
        switch moment {
        case .eating:
            if parts.contains(.food) { parts.remove(.food) } else { parts.insert(.food) }
        case .bolus, .basal:
            if isOn(moment) {
                parts.remove(.insulin)
            } else {
                let wasOpen = parts.contains(.insulin)
                startDose(bolus: moment == .bolus)
                parts.insert(.insulin)
                if wasOpen { focus = .units }
            }
        case .newSite:
            if parts.contains(.site) { parts.remove(.site) } else { parts.insert(.site) }
        case .other:
            if parts.contains(.event) {
                parts.remove(.event)
                tags = tags.filter(\.isMoment)
            } else {
                parts.insert(.event)
            }
        case .wokeUp, .bedtime:
            if let tag = moment.tag { tags = LogFlow.toggling(tag, in: tags) }
        }
    }

    // MARK: Next step

    private var nextStep: LogNextStep? {
        guard isNew else { return nil }
        return LogFlow.nextStep(picked: parts, available: availableParts, carbs: foodValid ? (carbs ?? 0) : 0,
                                mealtimeDose: kind.isBolus)
    }

    /// Above the dose when there's no food: one click adds the food part (where it belongs, above).
    @ViewBuilder
    private func bridge(before part: LogPart) -> some View {
        if part == .insulin, nextStep == .addFood {
            bridgeButton("Eating with this? Add the food", systemImage: "fork.knife", tint: Self.foodTint) {
                parts.insert(.food)
            }
        }
    }

    /// Under the food once it has carbs: one click carries on to the dose for it.
    @ViewBuilder
    private func bridge(after part: LogPart) -> some View {
        if part == .food, case .addInsulin(let grams)? = nextStep {
            bridgeButton("Next: bolus for \(LogFormat.grams(grams))", systemImage: "syringe", tint: Self.insulinTint) {
                startDose(bolus: true)
                parts.insert(.insulin)
            }
        }
    }

    private func bridgeButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    /// The last dose of the kind being logged, to repeat in one click.
    private var lastDose: InsulinDose? {
        kind.isBolus ? logbook.lastBolus : logbook.doses.last { !$0.kind.isBolus }
    }

    /// The calculator leads the dose panel once it's set up; until then it waits at the bottom.
    @ViewBuilder
    private var calculatorCard: some View {
        BolusSuggestionCard(carbs: calculatorCarbs,
                            onUse: { s in
                                unitsText = LogFormat.number(s.units)
                                usedSuggestion = s
                            },
                            onSetUp: { showsBolusSettings = true },
                            onUpdate: { live, recompute in
                                liveSuggestion = live
                                recomputeSuggestion = recompute
                                dropSuggestionIfStale()
                            })
    }

    private var insulinPanel: some View {
        FlowPanel(title: isNew ? (kind.isBolus ? "Bolus" : "Basal") : (viaPump ? "Bolus" : "Insulin"),
                  systemImage: "syringe", tint: Self.insulinTint) {
            if showsCalculator && logbook.bolusSettings != nil { calculatorCard }
            HStack(spacing: 10) {
                NumberStepperField(title: "Units", text: $unitsText, unitLabel: "units",
                               step: InsulinLibrary.step(for: logbook.savedInsulin(named: insulinName), viaPump: viaPump),
                               range: LogLimits.units, focus: $focus, focusValue: .units)
                if isNew, unitsText.isEmpty, let d = lastDose {
                    Button { applyLast(d) } label: {
                        Label("Same as last: \(LogFormat.units(d.units))", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(ChipButtonStyle(tint: Self.insulinTint))
                    .help("\(LogFormat.units(d.units)) \(d.displayName), \(d.timestamp.formatted(.relative(presentation: .named)))")
                }
                Spacer(minLength: 0)
            }
            if let problem = unitsProblem { FieldProblem(text: problem) }
            VStack(alignment: .leading, spacing: 6) {
                let choices = insulinChoices
                let picked = showsInsulinEntry ? nil : logbook.savedInsulin(named: insulinName)
                if !choices.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(choices) { i in
                                Button { pick(i) } label: {
                                    Text(i.name) + Text("  \(i.kind.title)").foregroundColor(.secondary)
                                }
                                .buttonStyle(ChipButtonStyle(selected: picked?.id == i.id, tint: Self.insulinTint))
                                .help(i.summary)
                            }
                            Button {
                                typesInsulin = true
                                // An edited dose keeps its name until the user changes it.
                                if isNew { insulinName = "" }
                            } label: {
                                Label("Other…", systemImage: "pencil")
                            }
                            .buttonStyle(ChipButtonStyle(selected: showsInsulinEntry, tint: Self.insulinTint))
                        }
                        .padding(.vertical, 1)
                    }
                }
                if showsInsulinEntry {
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
                    Text("Names you log are saved under Settings → Logging → Your Insulins, ready to pick next time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if viaPump {
                LabeledContent("Infusion site") {
                    Text(pumpSiteText).foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                InjectionSitePicker(selection: $injectionSite, at: time)
            }
            if showsCalculator && logbook.bolusSettings == nil { calculatorCard }
        }
    }

    /// The calculator is for a mealtime or correction dose being logged now.
    private var showsCalculator: Bool {
        isNew && kind.isBolus && abs(time.timeIntervalSinceNow) < 15 * 60
    }

    private var foodPanel: some View {
        FlowPanel(title: isNew ? "What are you eating?" : "Food", systemImage: "fork.knife", tint: Self.foodTint) {
            // Looks like a search box; opens the full search, where a whole meal can be described.
            Button { foodQuery = ""; showsFoodPicker = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(mealItems.isEmpty ? "Search or describe your meal…" : "Add another food…")
                    Spacer(minLength: 0)
                    Text("⌘F").font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .foregroundStyle(Self.foodTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.foodTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find foods and work out their carbs")
            let recent = isNew && mealItems.isEmpty && foodText.isEmpty ? logbook.recentFoods(limit: 6) : []
            if !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recent) { f in
                            Button { apply(f) } label: {
                                Label(f.carbs > 0 ? "\(f.food) · \(LogFormat.grams(f.carbs))" : f.food, systemImage: "clock.arrow.circlepath")
                            }
                            .buttonStyle(ChipButtonStyle(tint: Self.foodTint))
                            .controlSize(.small)
                            .help("Fill in what you logged last time")
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            if !mealItems.isEmpty { mealItemList }
            HStack(alignment: .center, spacing: 12) {
                NumberStepperField(title: "Carbs", text: $carbsText, unitLabel: "g carbs",
                                   step: 5, range: LogLimits.carbs, focus: $focus, focusValue: .carbs)
                Spacer(minLength: 0)
            }
            if mealItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach([10, 15, 20, 30, 45, 60], id: \.self) { g in
                        Button("\(g) g") { carbsText = "\(g)" }
                            .buttonStyle(ChipButtonStyle(selected: carbs == Double(g)))
                            .controlSize(.small)
                    }
                }
            }
            if let problem = foodProblem { FieldProblem(text: problem) }
            HStack(spacing: 8) {
                TextField("What you ate", text: $food, prompt: Text(mealItems.isEmpty ? "Or just name it, e.g. toast and a banana" : "Name this meal (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .food)
                if mealItems.isEmpty && foodText.count >= 3 {
                    Button {
                        foodQuery = foodText
                        showsFoodPicker = true
                    } label: {
                        Label("Find its carbs", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(ChipButtonStyle(tint: Self.foodTint))
                    .help("Reads what you typed into foods with amounts and adds up the carbs")
                }
            }
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

    private var mealItemList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(mealItems) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.callout).lineLimit(2)
                        Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { removeItem(item) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                        .accessibilityLabel("Remove \(item.name)")
                }
            }
            if let c = carbs, abs(c - itemsTotal) > 0.05 {
                Button("Carbs changed by hand. Use the foods' total, \(LogFormat.grams(itemsTotal))") {
                    carbsText = LogFormat.number(itemsTotal)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(8)
        .dsCard(.inset, padding: 0)
    }

    private var itemsTotal: Double { (mealItems.reduce(0) { $0 + $1.carbs } * 10).rounded() / 10 }

    private func addItem(_ item: MealItem) {
        let followsItems = mealItems.isEmpty ? (carbs ?? 0) == 0 : abs((carbs ?? 0) - itemsTotal) < 0.05
        mealItems.append(item)
        if followsItems { carbsText = LogFormat.number(itemsTotal) }
        parts.insert(.food)
    }

    private func removeItem(_ item: MealItem) {
        let followsItems = abs((carbs ?? 0) - itemsTotal) < 0.05
        mealItems.removeAll { $0.id == item.id }
        if followsItems { carbsText = mealItems.isEmpty ? "" : LogFormat.number(itemsTotal) }
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

    /// A new entry leaves out waking up and going to sleep: those are tiles of their own.
    private var tagChoices: [ContextTag] {
        let all = settings.therapy.logsInsulin || tags.contains(.siteProblem)
            ? ContextTag.allCases
            : ContextTag.allCases.filter { $0 != .siteProblem }
        return isNew ? all.filter { !$0.isMoment } : all
    }

    private var tagsPanel: some View {
        FlowPanel(title: isNew ? "What else is going on?" : "Event", systemImage: "tag", tint: Self.contextTint) {
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
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if editing != nil {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } else {
                Toggle("Save as preset", isOn: $savesAsPreset.animation(.smooth(duration: 0.15)))
                    .toggleStyle(.checkbox)
                    .disabled(!canSave || !hasPresetContent)
                    .help("Keep this combination as a one-click preset")
                if savesAsPreset {
                    TextField("Preset name", text: $presetName, prompt: Text(defaultPresetName))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .focused($focus, equals: .presetName)
                }
            }
            Spacer()
            if !canSave, let missing {
                Text(missing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Cancel", role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button(canSave ? saveSummary : (isNew ? "Log" : "Save")) { save() }
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

    /// "Log 45 g + 4 u", "Log Woke up", "Save".
    private var saveSummary: String {
        guard isNew else { return "Save" }
        return LogFlow.summary(carbs: includes(.food) && foodValid ? carbs : nil,
                               foodName: foodText.isEmpty ? (mealItems.first?.name ?? "") : foodText,
                               units: includes(.insulin) ? units : nil,
                               newSite: includes(.site),
                               events: ContextTag.allCases.filter(tags.contains).map(\.title))
    }

    /// What the entry still needs, shown beside the Log button while it can't be logged.
    private var missing: String? {
        guard isNew else { return nil }
        return LogFlow.missing(picked: parts, available: availableParts, foodValid: foodValid,
                               unitsValid: units != nil, hasEvents: !tags.isEmpty)
    }

    /// A preset needs something to fill in: a site change on its own isn't one.
    private var hasPresetContent: Bool {
        includes(.insulin) || includes(.food) || !tags.isEmpty
    }

    private var insulinValid: Bool { units != nil }
    private var foodValid: Bool {
        guard let c = carbs else { return false }
        return c > 0 || !foodText.isEmpty || !mealItems.isEmpty
    }

    private var canSave: Bool {
        let checks = [
            (includes(.insulin), insulinValid),
            (includes(.food), foodValid),
            (includes(.site), true),
            // Waking up or going to sleep is an entry without the panel being open.
            (includes(.event) || (isNew && !tags.isEmpty), !tags.isEmpty),
        ].filter { $0.0 }
        return !checks.isEmpty && checks.allSatisfy { $0.1 }
    }

    private var pumpSiteText: String {
        if includes(.site) { return "\(newSite.title) (new)" }
        guard let current = logbook.infusionSite(at: time) else { return "None logged yet" }
        return "\(current.site.title), since \(current.timestamp.formatted(.relative(presentation: .named)))"
    }

    private var defaultPresetName: String {
        if includes(.food) && !foodText.isEmpty { return foodText }
        if includes(.insulin), let units { return "\(LogFormat.units(units)) \(kind.isBolus ? "bolus" : kind.title.lowercased())" }
        if includes(.food), let carbs, carbs > 0 { return "\(LogFormat.grams(carbs)) carbs" }
        return ContextTag.allCases.first(where: tags.contains)?.title ?? "Preset"
    }

    private func focusFirstField() {
        guard editing == .dose || editing == .meal else { return }
        // Sheets and new windows take focus a beat after appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focus = editing == .dose ? .units : .carbs
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The carbs the calculator works from: none when the food isn't being logged.
    private var calculatorCarbs: Double { includes(.food) ? (carbs ?? 0) : 0 }

    /// A suggestion is only kept while it still describes this dose: a bolus logged now, for the
    /// same carbs, that the calculator would still give (no new low, not now less). Otherwise it's dropped, units and all, so it can't be stored against the wrong dose.
    private var suggestionStillApplies: Bool {
        guard let s = usedSuggestion else { return false }
        return includes(.insulin) && showsCalculator && abs(calculatorCarbs - s.carbs) < 0.001
            && s.stillStands(given: liveSuggestion)
    }

    /// Brings the calculator's answer up to this moment: the card only refreshes every 30 seconds.
    private func refreshLiveSuggestion() {
        guard usedSuggestion != nil, let recomputeSuggestion else { return }
        liveSuggestion = recomputeSuggestion()
    }

    private func dropSuggestionIfStale() {
        guard usedSuggestion != nil, !suggestionStillApplies else { return }
        usedSuggestion = nil
        unitsText = ""
    }

    private func save() {
        guard canSave else { return }
        refreshLiveSuggestion()
        if includes(.insulin) && usedSuggestion != nil && !suggestionStillApplies {
            dropSuggestionIfStale()
            return
        }
        if includes(.insulin) && usedSuggestion != nil {
            confirmingDose = true
        } else {
            commit()
        }
    }

    private func commit() {
        guard canSave else { return }
        // Checked again here: the confirm step can sit open past the calculator's window.
        refreshLiveSuggestion()
        if includes(.insulin) && usedSuggestion != nil && !suggestionStillApplies {
            dropSuggestionIfStale()
            return
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let logsInsulin = includes(.insulin)
        let logsFood = includes(.food)
        let trimmedName = insulinName.trimmingCharacters(in: .whitespacesAndNewlines)
        if logsInsulin, let units {
            // An edited dose keeps its calculator record only while it's still the dose that was worked out.
            let existing = editing == .dose ? logbook.doses.first { $0.id == doseID } : nil
            let kept = existing.flatMap { d in
                d.units == units && d.kind == kind && d.timestamp == time ? d.calculation : nil
            }
            let calculation = (suggestionStillApplies ? usedSuggestion.map(BolusCalculation.init) : nil) ?? kept
            logbook.save(.dose(InsulinDose(id: doseID, timestamp: time, units: units, kind: kind,
                                           name: trimmedName,
                                           site: viaPump ? nil : injectionSite, viaPump: viaPump,
                                           note: trimmedNote, calculation: calculation)))
        }
        if logsFood, let carbs {
            let described = foodText.isEmpty ? mealItems.map(\.name).joined(separator: ", ") : foodText
            logbook.save(.meal(MealEntry(id: mealID, timestamp: time, carbs: carbs, food: described, note: trimmedNote,
                                         items: mealItems.isEmpty ? nil : mealItems)))
        }
        if includes(.site) {
            logbook.save(.siteChange(SiteChange(id: siteID, timestamp: time, site: newSite, note: trimmedNote)))
        }
        if isNew || includes(.event), !tags.isEmpty {
            logbook.save(.context(ContextEvent(id: contextID, timestamp: time, tags: tags, note: trimmedNote)))
        }
        if isNew && savesAsPreset && hasPresetContent {
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
    /// When the dose is: only injections before it count.
    var at: Date = .distantFuture
    @EnvironmentObject var logbook: LogbookStore
    /// Folded to one line (the site, already picked) until clicked.
    @State private var expanded = false

    var body: some View {
        let last = logbook.lastInjectionBySite(before: at)
        let suggested = SiteRotation.suggestion(lastUse: last)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Injection site").font(.callout)
                    Spacer(minLength: 8)
                    if let selection, selection == suggested {
                        Label("Suggested", systemImage: "sparkle")
                            .font(.caption)
                            .foregroundStyle(Palette.insulin)
                    }
                    Text(selection?.title ?? "Not recorded")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the other sites" : "Pick another site. The suggested one is the site you've gone longest without using.")
            .accessibilityLabel("Injection site, \(selection?.title ?? "not recorded")")
            if expanded {
                if let suggested, selection != suggested {
                    Button { selection = suggested } label: {
                        Label("Use \(suggested.title)", systemImage: "sparkle")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("The site you've gone longest without using")
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
            if let recent = SiteRotation.recentUse(of: selection, lastUse: last) {
                Label("Used \(recent.formatted(.relative(presentation: .named))). Moving to a site you haven't used lately helps avoid lumps under the skin, where insulin absorbs unevenly.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text(suggested ? "suggested" : last.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? "not used")
                    .font(.caption2)
                    .foregroundStyle(suggested ? AnyShapeStyle(Palette.insulin) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ChipButtonStyle(selected: selection == s))
        .overlay {
            // Dashed ring on the suggested site while another is picked.
            if suggested && selection != s {
                Capsule().strokeBorder(Palette.insulin.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .allowsHitTesting(false)
            }
        }
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
                Text("GlucOS uses this to decide what to ask when you log, and which patterns to show you. You can change it any time in Settings → Logging.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([TherapyType.injections, .pump, .noInsulin]) { t in
                Button { settings.therapy = t } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.systemImage)
                            .font(.title2)
                            .foregroundStyle(Palette.brand)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.headline)
                            Text(t.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if settings.therapy == t {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
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
