import SwiftUI
import UIKit

/// Logs what's happening on iPhone, into the same `LogbookStore` the Mac uses, so it syncs both
/// ways. It starts from the moment ("What's happening?": eating, a bolus, a basal dose, waking up,
/// going to sleep, something else) rather than a type of record, and each moment opens the part of
/// the entry it needs. Parts are always shown in the order of `LogFlow`: food first, then the dose
/// for it, so the carbs run straight into the bolus calculator below.
///
/// Same rules as the Mac log sheet: what it asks for follows the therapy type, and it records what
/// the user enters. Presets and "same as last" only repeat numbers the user typed themselves. The
/// one suggested amount is the bolus calculator's, from the user's confirmed settings, and logging
/// a dose from it asks for confirmation first.
struct PhoneLogSheet: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.dismiss) private var dismiss

    private let editing: PhoneLogPart?
    /// The part a new entry was opened for (the Event button, `glucos://log/event`…).
    private let start: PhoneLogPart?
    private let editingID: UUID?
    private let doseID: UUID
    private let mealID: UUID
    private let siteID: UUID
    private let contextID: UUID

    @State private var time: Date
    @State private var parts: Set<PhoneLogPart>
    @State private var viaPump: Bool
    @State private var unitsText: String
    @State private var kind: InsulinKind
    @State private var insulinName: String
    /// Typing an insulin that isn't in Settings → Your insulins.
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
    @State private var showsTimePicker = false
    @State private var mealItems: [MealItem]
    @State private var showsFoodPicker = false
    /// What the food picker opens with: empty, or the meal as typed in the food card.
    @State private var foodQuery = ""
    @State private var showsNote: Bool
    @State private var showsBolusSettings = false
    /// The calculator suggestion the dose was filled from, if any.
    @State private var usedSuggestion: BolusSuggestion?
    /// What the calculator says now, to check a used suggestion against.
    @State private var liveSuggestion: BolusSuggestion?
    /// Works the calculator's answer out again on the spot, for the check at save and log.
    @State private var recomputeSuggestion: (@MainActor () -> BolusSuggestion?)?
    @State private var confirmingDose = false
    @FocusState private var focus: LogFieldFocus?

    init(target: PhoneLogTarget) {
        let s = AppSettings.shared
        var editing: PhoneLogPart?
        var startPart: PhoneLogPart?
        var editingID: UUID?
        var doseID = UUID(), mealID = UUID(), siteID = UUID(), contextID = UUID()
        var time = Date()
        var parts = Set<PhoneLogPart>()
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

        switch target {
        case .new(let start):
            startPart = start
            // Opened for one thing (the log bar, a widget) it starts there; otherwise it asks.
            if let start { parts = [start] }
        case .edit(let entry):
            time = entry.timestamp
            editingID = entry.id
            switch entry {
            case .dose(let d):
                editing = .insulin
                doseID = d.id
                viaPump = d.viaPump
                unitsText = LogFormat.number(d.units)
                kind = d.kind
                insulinName = d.name
                injectionSite = d.site
                note = d.note
            case .meal(let m):
                editing = .food
                mealID = m.id
                carbsText = m.carbs > 0 ? LogFormat.number(m.carbs) : ""
                food = m.food
                note = m.note
                items = m.items ?? []
                // A description made from the foods' names is remade from them on save.
                if !items.isEmpty && food == items.map(\.name).joined(separator: ", ") { food = "" }
            case .siteChange(let c):
                editing = .site
                siteID = c.id
                newSite = c.site
                note = c.note
            case .context(let c):
                editing = .event
                contextID = c.id
                tags = c.tags
                note = c.note
            }
            if let editing { parts = [editing] }
        }

        self.editing = editing
        self.start = startPart
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
        _showsNote = State(initialValue: !note.isEmpty)
    }

    private var isNew: Bool { editing == nil }
    private var needsTherapy: Bool { isNew && settings.therapy == .notSet }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        if needsTherapy {
                            PhoneTherapyPicker()
                        } else {
                            if isNew { momentPicker }
                            whenCard
                            if isNew { quickAdd }
                            ForEach(shownParts) { part in
                                bridge(before: part)
                                card(for: part)
                                    .id(part)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                bridge(after: part)
                            }
                            extras
                            Label("GlucOS records what you enter. Only the bolus calculator suggests a dose, from your own settings.", systemImage: "info.circle")
                                .dsFont(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.xs)
                            if !isNew {
                                Button(role: .destructive) { confirmingDelete = true } label: {
                                    Label("Delete Entry", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.top, DS.Space.sm)
                    .padding(.bottom, DS.Space.xxl)
                    .animation(DSMotion.standard.animation, value: parts)
                    .animation(DSMotion.quick.animation, value: tags)
                }
                .onChange(of: parts) { old, new in
                    // Bring the part that was just opened into view.
                    guard isNew, let part = LogFlow.focusPart(from: old, to: new, available: availableParts) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(DSMotion.standard.animation) { proxy.scrollTo(part, anchor: .top) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Log" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !needsTherapy { saveBar }
            }
        }
        .onAppear { startDose(); focusFirstField() }
        .onChange(of: settings.therapy) { _, therapy in
            // Picked in the setup step: keep the part the sheet was opened for if this therapy
            // has it, otherwise start from that therapy's default.
            guard isNew else { return }
            viaPump = therapy == .pump
            if let start, availableParts.contains(start) { parts = [start] } else { parts = [] }
            kind = settings.bolusInsulinKind
            insulinName = settings.bolusInsulinName
            startDose()
            focusFirstField()
        }
        .onChange(of: logbook.insulins) { _, _ in
            // The list can arrive by sync after the sheet opened.
            guard isNew, !typesInsulin, insulinName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let p = logbook.preferredInsulin(viaPump: viaPump) else { return }
            kind = p.kind
            insulinName = p.name
        }
        .onChange(of: time) { _, newTime in
            // Keep an automatic site in step with the dose time; a site the user picked stays.
            guard isNew, !viaPump, siteIsAutomatic else { return }
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
                // The meal typed in the food card is now its foods: don't also keep it as a name.
                if !mealItems.isEmpty, !foodQuery.isEmpty, foodText == foodQuery { food = "" }
                showsFoodPicker = false
            })
            .environmentObject(logbook)
        }
        .sheet(isPresented: $showsBolusSettings) {
            NavigationStack {
                BolusSettingsEditor(current: logbook.bolusSettings) { showsBolusSettings = false }
                    .navigationTitle("Bolus calculator")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .environmentObject(logbook)
            .environmentObject(store)
            .environmentObject(settings)
        }
        .confirmationDialog(units.map { "Log a \(LogFormat.units($0)) dose?" } ?? "Log this dose?",
                            isPresented: $confirmingDose, titleVisibility: .visible) {
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
            // Typing a different amount means it's no longer the calculator's, but the confirm step
            // still says what it suggested.
            if text.trimmingCharacters(in: .whitespaces).isEmpty { usedSuggestion = nil }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let editingID { logbook.delete(ids: [editingID]) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can undo this from the Logbook card.")
        }
    }

    private var title: String {
        switch editing {
        case .none: return "Log"
        case .insulin: return viaPump ? "Edit Bolus" : "Edit Insulin"
        case .food: return "Edit Food"
        case .site: return "Edit Site Change"
        case .event: return "Edit Event"
        }
    }

    // MARK: When

    private static let offsets = [0, 15, 30, 60, 120]

    /// One row: the time, then one-tap offsets. "Other" opens the full date and time.
    private var whenCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs + 2) {
                    Label(timeSummary, systemImage: "clock")
                        .dsFont(.headline)
                        .monospacedDigit()
                        .padding(.trailing, DS.Space.xs)
                        .accessibilityLabel("Time, \(timeSummary)")
                    ForEach(Self.offsets, id: \.self) { minutes in
                        Button(minutes == 0 ? "Now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago") {
                            time = Date().addingTimeInterval(-Double(minutes) * 60)
                            showsTimePicker = false
                        }
                        .buttonStyle(ChipButtonStyle(selected: isOffset(minutes)))
                    }
                    Button { withAnimation(DSMotion.quick.animation) { showsTimePicker.toggle() } } label: {
                        Label("Other", systemImage: "calendar")
                    }
                    .buttonStyle(ChipButtonStyle(selected: showsTimePicker || !Self.offsets.contains(where: isOffset)))
                    .accessibilityHint("Pick another time")
                }
                .padding(.vertical, 1)
            }
            if showsTimePicker {
                DatePicker("Time", selection: $time, in: ...Date().addingTimeInterval(15 * 60),
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .dsFont(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.md)
    }

    private var timeSummary: String {
        if Calendar.current.isDateInToday(time) { return time.formatted(date: .omitted, time: .shortened) }
        return time.formatted(date: .abbreviated, time: .shortened)
    }

    private func isOffset(_ minutes: Int) -> Bool {
        abs(time.timeIntervalSince(Date().addingTimeInterval(-Double(minutes) * 60))) < 45
    }

    // MARK: Quick add

    /// The user's presets: one tap fills the form with what they saved. (The last dose and recent
    /// foods are offered inside the dose and food cards, where they belong.)
    @ViewBuilder
    private var quickAdd: some View {
        let presets = logbook.presets
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Eyebrow(title: "Your presets", systemImage: "bolt.fill")
                    .padding(.horizontal, DS.Space.xs)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(presets) { p in
                            QuickAddTile(title: p.name, detail: p.summary, systemImage: p.systemImage,
                                         tint: p.hasInsulin ? Palette.insulin : p.hasFood ? Palette.food : Palette.context,
                                         selected: appliedPresetID == p.id) { apply(p) }
                        }
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.vertical, 2)
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
        // Waking up and going to sleep show on their own tiles; anything else opens its card.
        if p.tags.contains(where: { !$0.isMoment }) { next.insert(.event) }
        parts = next
        Haptics.tap()
    }

    private func applyLast(_ d: InsulinDose) {
        parts.insert(.insulin)
        unitsText = LogFormat.number(d.units)
        if !viaPump || InsulinKind.pumpKinds.contains(d.kind) { kind = d.kind }
        insulinName = d.name
        Haptics.tap()
    }

    private func apply(_ f: RecentFood) {
        parts.insert(.food)
        food = f.food
        if f.carbs > 0 { carbsText = LogFormat.number(f.carbs) }
        Haptics.tap()
    }

    // MARK: Insulin

    /// Saved insulins this dose can be logged with. A new dose shows the ones for the moment that
    /// was picked: mealtime insulins for a bolus, background ones for a basal dose.
    private var insulinChoices: [SavedInsulin] {
        let all = InsulinLibrary.choices(logbook.insulins, viaPump: viaPump)
        return isNew ? all.filter { $0.kind.isBolus == kind.isBolus } : all
    }

    /// Show the type chips and name field: nothing saved yet, "Other" tapped, or a name (from an
    /// older entry or preset) that isn't in the list.
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
        Haptics.tap()
    }

    /// A new entry starts on the user's usual insulin and, for an injection, the site used
    /// longest ago. Both are one tap to change.
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

    private var availableParts: [LogPart] {
        LogFlow.parts(logsInsulin: settings.therapy.logsInsulin, pump: settings.therapy == .pump)
    }

    private func includes(_ part: LogPart) -> Bool {
        if let editing { return editing == part }
        return parts.contains(part) && availableParts.contains(part)
    }

    /// The parts on screen, in flow order: food always sits above the dose for it.
    private var shownParts: [LogPart] {
        if let editing { return [editing] }
        return LogFlow.ordered(parts, available: availableParts)
    }

    @ViewBuilder
    private func card(for part: LogPart) -> some View {
        switch part {
        case .food: foodCard
        case .insulin: insulinCard
        case .site: siteCard
        case .event: eventCard
        }
    }

    // MARK: Moments

    private var moments: [LogMoment] {
        LogFlow.moments(logsInsulin: settings.therapy.logsInsulin, pump: settings.therapy == .pump)
    }

    private func isOn(_ moment: LogMoment) -> Bool {
        LogFlow.isOn(moment, parts: Set(shownParts), mealtimeDose: kind.isBolus, tags: tags)
    }

    private func tint(_ moment: LogMoment) -> Color {
        switch moment {
        case .eating: return Palette.food
        case .bolus, .basal: return Palette.insulin
        case .newSite: return Palette.site
        case .wokeUp, .bedtime, .other: return Palette.context
        }
    }

    /// "What's happening?": the moments to pick from. More than one can be on (eating and a bolus).
    private var momentPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("What's happening?")
                .dsFont(.title)
                .padding(.horizontal, DS.Space.xs)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: 3), spacing: DS.Space.sm) {
                ForEach(moments) { m in
                    PartTile(title: m.title, systemImage: m.systemImage, tint: tint(m), isOn: isOn(m)) { toggle(m) }
                        .accessibilityHint(m.detail)
                }
            }
        }
    }

    private func toggle(_ moment: LogMoment) {
        Haptics.tap()
        switch moment {
        case .eating:
            if parts.contains(.food) { parts.remove(.food) } else { parts.insert(.food) }
        case .bolus, .basal:
            if isOn(moment) {
                parts.remove(.insulin)
            } else {
                startDose(bolus: moment == .bolus)
                parts.insert(.insulin)
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

    /// Above the dose when there's no food: one tap adds the food part (where it belongs, above).
    @ViewBuilder
    private func bridge(before part: LogPart) -> some View {
        if part == .insulin, nextStep == .addFood {
            BridgeButton(title: "Eating with this? Add the food", systemImage: "fork.knife", tint: Palette.food) {
                parts.insert(.food)
                Haptics.tap()
            }
        }
    }

    /// Under the food once it has carbs: one tap carries on to the dose for it.
    @ViewBuilder
    private func bridge(after part: LogPart) -> some View {
        if part == .food, case .addInsulin(let grams)? = nextStep {
            BridgeButton(title: "Next: bolus for \(LogFormat.grams(grams))", systemImage: "syringe", tint: Palette.insulin) {
                startDose(bolus: true)
                parts.insert(.insulin)
                focus = nil
                Haptics.tap()
            }
        }
    }

    /// The last dose of the kind being logged, to repeat in one tap.
    private var lastDose: InsulinDose? {
        kind.isBolus ? logbook.lastBolus : logbook.doses.last { !$0.kind.isBolus }
    }

    /// The calculator leads the dose card once it's set up; until then it waits at the bottom.
    @ViewBuilder
    private var calculatorCard: some View {
        BolusSuggestionCard(carbs: calculatorCarbs,
                            onUse: { s in
                                unitsText = LogFormat.number(s.units)
                                usedSuggestion = s
                                Haptics.tap()
                            },
                            onSetUp: { showsBolusSettings = true },
                            onUpdate: { live, recompute in
                                liveSuggestion = live
                                recomputeSuggestion = recompute
                                dropSuggestionIfStale()
                            })
    }

    private var insulinCard: some View {
        PhoneLogPanel(part: .insulin, title: isNew ? (kind.isBolus ? "Bolus" : "Basal") : (viaPump ? "Bolus" : "Insulin")) {
            if showsCalculator && logbook.bolusSettings != nil { calculatorCard }
            PhoneAmountField(title: "Units", text: $unitsText, unitLabel: "units",
                             step: InsulinLibrary.step(for: logbook.savedInsulin(named: insulinName), viaPump: viaPump),
                             range: LogLimits.units, tint: Palette.insulin,
                             focus: $focus, focusValue: .units)
            if let problem = unitsProblem { FieldProblem(text: problem) }
            if isNew, unitsText.isEmpty, let d = lastDose {
                Button { applyLast(d) } label: {
                    Label("Same as last: \(LogFormat.units(d.units)) \(d.displayName)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ChipButtonStyle(tint: Palette.insulin))
                .accessibilityHint("Fills in the amount you logged \(d.timestamp.formatted(.relative(presentation: .named)))")
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Insulin").dsFont(.label).foregroundStyle(.secondary)
                let choices = insulinChoices
                let picked = showsInsulinEntry ? nil : logbook.savedInsulin(named: insulinName)
                if !choices.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.xs + 2) {
                            ForEach(choices) { i in
                                Button { pick(i) } label: {
                                    VStack(spacing: 0) {
                                        Text(i.name)
                                        Text(i.kind.title).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(ChipButtonStyle(selected: picked?.id == i.id, tint: Palette.insulin))
                                .accessibilityLabel("\(i.name), \(i.kind.title)")
                            }
                            Button {
                                typesInsulin = true
                                // An edited dose keeps its name until the user changes it.
                                if isNew { insulinName = "" }
                                Haptics.tap()
                            } label: {
                                Label("Other", systemImage: "pencil")
                            }
                            .buttonStyle(ChipButtonStyle(selected: showsInsulinEntry, tint: Palette.insulin))
                        }
                        .padding(.vertical, 1)
                    }
                }
                if showsInsulinEntry {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.xs + 2) {
                            ForEach(viaPump ? InsulinKind.pumpKinds : InsulinKind.allCases) { k in
                                Button(k.title) { kind = k }
                                    .buttonStyle(ChipButtonStyle(selected: kind == k, tint: Palette.insulin))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    TextField("Name", text: $insulinName, prompt: Text(kind.examples))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Text("Names you log are saved under Settings → Your insulins, ready to tap next time.")
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if viaPump {
                LabeledContent("Infusion site") {
                    Text(pumpSiteText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                .dsFont(.callout)
            } else {
                PhoneInjectionSitePicker(selection: $injectionSite, at: time)
            }
            if showsCalculator && logbook.bolusSettings == nil { calculatorCard }
        }
    }

    /// The calculator is for a mealtime or correction dose being logged now.
    private var showsCalculator: Bool {
        isNew && kind.isBolus && abs(time.timeIntervalSinceNow) < 15 * 60
    }

    private static let carbChips = [10, 15, 20, 30, 45, 60]

    private var foodCard: some View {
        PhoneLogPanel(part: .food, title: isNew ? "What are you eating?" : "Food") {
            // Looks like a search box; opens the full search, where a whole meal can be described.
            Button { foodQuery = ""; showsFoodPicker = true } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                    Text(mealItems.isEmpty ? "Search or describe your meal" : "Add another food")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .dsFont(.callout)
                .foregroundStyle(Palette.food)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.food.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityHint("Finds foods and works out their carbs")
            let recent = isNew && mealItems.isEmpty && foodText.isEmpty ? logbook.recentFoods(limit: 6) : []
            if !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs + 2) {
                        ForEach(recent) { f in
                            Button { apply(f) } label: {
                                Label(f.carbs > 0 ? "\(f.food) · \(LogFormat.grams(f.carbs))" : f.food, systemImage: "clock.arrow.circlepath")
                            }
                            .buttonStyle(ChipButtonStyle(tint: Palette.food))
                            .accessibilityHint("Fills in what you logged last time")
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            if !mealItems.isEmpty { mealItemList }
            PhoneAmountField(title: "Carbs", text: $carbsText, unitLabel: "g carbs",
                             step: 5, range: LogLimits.carbs, tint: Palette.food,
                             focus: $focus, focusValue: .carbs)
            if mealItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs + 2) {
                        ForEach(Self.carbChips, id: \.self) { g in
                            Button("\(g) g") { carbsText = "\(g)"; Haptics.tap() }
                                .buttonStyle(ChipButtonStyle(selected: carbs == Double(g), tint: Palette.food))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            if let problem = foodProblem { FieldProblem(text: problem) }
            TextField("What you ate", text: $food, prompt: Text(mealItems.isEmpty ? "Or just name it, e.g. toast and a banana" : "Name this meal (optional)"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .food)
                .submitLabel(.done)
            if mealItems.isEmpty && foodText.count >= 3 {
                Button {
                    foodQuery = foodText
                    focus = nil
                    showsFoodPicker = true
                } label: {
                    Label("Find the carbs in \u{201C}\(foodText)\u{201D}", systemImage: "sparkle.magnifyingglass")
                        .lineLimit(1)
                }
                .buttonStyle(ChipButtonStyle(tint: Palette.food))
            }
            let suggestions = logbook.recentFoods(matching: foodText, limit: 6)
                .filter { $0.food.caseInsensitiveCompare(foodText) != .orderedSame }
            if !foodText.isEmpty && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs + 2) {
                        ForEach(suggestions) { f in
                            Button(f.carbs > 0 ? "\(f.food) · \(LogFormat.grams(f.carbs))" : f.food) { apply(f) }
                                .buttonStyle(ChipButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var mealItemList: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(mealItems) { item in
                HStack(spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).dsFont(.callout).lineLimit(2)
                        Text(item.summary).dsFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { removeItem(item) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(item.name)")
                }
            }
            if let c = carbs, abs(c - itemsTotal) > 0.05 {
                Button("Carbs changed by hand. Use the foods' total, \(LogFormat.grams(itemsTotal))") {
                    carbsText = LogFormat.number(itemsTotal)
                }
                .buttonStyle(.plain)
                .dsFont(.caption)
                .foregroundStyle(Tone.brand.textColor)
            }
        }
        .padding(DS.Space.sm)
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

    private var siteCard: some View {
        PhoneLogPanel(part: .site, title: "Infusion site change") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.sm), GridItem(.flexible())], spacing: DS.Space.sm) {
                ForEach(InjectionSite.allCases) { s in
                    Button { newSite = s; Haptics.tap() } label: {
                        Text(s.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(selected: newSite == s, tint: Palette.site))
                }
            }
            Text("Boluses after this time are counted against this site.")
                .dsFont(.caption)
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

    private var eventCard: some View {
        PhoneLogPanel(part: .event, title: isNew ? "What else is going on?" : "Event") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.sm), GridItem(.flexible())],
                      alignment: .leading, spacing: DS.Space.sm) {
                ForEach(tagChoices) { t in
                    Button {
                        if tags.contains(t) { tags.remove(t) } else { tags.insert(t) }
                        Haptics.tap()
                    } label: {
                        Label(t.title, systemImage: t.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ChipButtonStyle(selected: tags.contains(t), tint: Palette.context))
                    .accessibilityHint(t.help)
                }
            }
            if let t = tags.filter({ !$0.isMoment || !isNew }).count == 1 ? tags.first(where: { !$0.isMoment || !isNew }) : nil {
                Text(t.help).dsFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Doses and meals around these are kept out of the typical figures in Insights, so they don't skew them.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A note and "save as preset": out of the way until asked for.
    private var extras: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if isNew {
                HStack(spacing: DS.Space.xs + 2) {
                    Button {
                        withAnimation(DSMotion.quick.animation) { showsNote.toggle() }
                    } label: {
                        Label("Note", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(ChipButtonStyle(selected: showsNote || !note.isEmpty))
                    Button {
                        withAnimation(DSMotion.quick.animation) { savesAsPreset.toggle() }
                    } label: {
                        Label("Save as preset", systemImage: "bolt")
                    }
                    .buttonStyle(ChipButtonStyle(selected: savesAsPreset))
                    .disabled(!canSave || !hasPresetContent)
                    .accessibilityHint("Keeps this combination as a one-tap quick add")
                    Spacer(minLength: 0)
                }
            }
            if showsNote || !note.isEmpty || !isNew {
                TextField("Note", text: $note, prompt: Text("Add a note (optional)"), axis: .vertical)
                    .lineLimit(1...4)
                    .dsFont(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(.standard, padding: DS.Space.lg)
            }
            if isNew && savesAsPreset {
                TextField("Preset name", text: $presetName, prompt: Text(defaultPresetName))
                    .dsFont(.body)
                    .focused($focus, equals: .presetName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(.standard, padding: DS.Space.lg)
            }
        }
    }

    // MARK: Save bar

    private var saveBar: some View {
        Button { save() } label: {
            HStack(spacing: DS.Space.sm) {
                if canSave { Image(systemName: "checkmark.circle.fill") }
                Text(canSave ? saveSummary : (missing ?? saveSummary)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .dsFont(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.md + 2)
            .foregroundStyle(.white)
            .background(canSave ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm)
        .padding(.bottom, DS.Space.xs)
        .background(.bar)
        .animation(DSMotion.quick.animation, value: canSave)
    }

    /// "Log 45 g + 4 u", "Log Woke up", "Save".
    private var saveSummary: String {
        guard isNew else { return "Save" }
        return LogFlow.summary(carbs: includes(.food) && foodValid ? carbs : nil,
                               foodName: foodText.isEmpty ? (mealItems.first?.name ?? "") : foodText,
                               units: includes(.insulin) ? units : nil,
                               newSite: includes(.site),
                               events: ContextTag.allCases.filter(tags.contains).map(\.title))
    }

    /// What the entry still needs, shown on the Log button while it can't be logged.
    private var missing: String? {
        guard isNew else { return nil }
        return LogFlow.missing(picked: parts, available: availableParts, foodValid: foodValid,
                               unitsValid: units != nil, hasEvents: !tags.isEmpty)
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

    private var foodValid: Bool {
        guard let c = carbs else { return false }
        return c > 0 || !foodText.isEmpty || !mealItems.isEmpty
    }

    private var canSave: Bool {
        let checks = [
            (includes(.insulin), units != nil),
            (includes(.food), foodValid),
            (includes(.site), true),
            // Waking up or going to sleep is an entry without the card being open.
            (includes(.event) || (isNew && !tags.isEmpty), !tags.isEmpty),
        ].filter { $0.0 }
        return !checks.isEmpty && checks.allSatisfy { $0.1 }
    }

    /// A preset needs something to fill in: a site change on its own isn't one.
    private var hasPresetContent: Bool {
        includes(.insulin) || includes(.food) || !tags.isEmpty
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
        // Opened straight on a dose, the number pad comes up. Food leaves the keyboard down so the
        // search and recent foods are in view.
        guard isNew, start == .insulin else { return }
        // Sheets take focus a beat after appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if includes(.insulin) && unitsText.isEmpty && logbook.bolusSettings == nil { focus = .units }
        }
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
            let existing = editing == .insulin ? logbook.doses.first { $0.id == doseID } : nil
            let kept = existing.flatMap { d in
                d.units == units && d.kind == kind && d.timestamp == time ? d.calculation : nil
            }
            let calculation = (suggestionStillApplies ? usedSuggestion.map(BolusCalculation.init) : nil) ?? kept
            logbook.save(.dose(InsulinDose(id: doseID, timestamp: time, units: units, kind: kind, name: trimmedName,
                                           site: viaPump ? nil : injectionSite, viaPump: viaPump, note: trimmedNote,
                                           calculation: calculation)))
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
            let logsTags = !tags.isEmpty
            logbook.savePreset(LogPreset(name: name.isEmpty ? defaultPresetName : name,
                                         units: logsInsulin ? units : nil,
                                         kind: logsInsulin ? kind : nil,
                                         insulinName: logsInsulin ? trimmedName : "",
                                         carbs: logsFood ? carbs : nil,
                                         food: logsFood ? foodText : "",
                                         tags: logsTags ? tags : []))
        }
        Haptics.success()
        dismiss()
    }
}

// MARK: - Part styling

extension PhoneLogPart {
    var systemImage: String {
        switch self {
        case .insulin: return "syringe"
        case .food: return "fork.knife"
        case .site: return "arrow.triangle.2.circlepath"
        case .event: return "tag"
        }
    }

    var tint: Color {
        switch self {
        case .insulin: return Palette.insulin
        case .food: return Palette.food
        case .site: return Palette.site
        case .event: return Palette.context
        }
    }
}

enum Haptics {
    static func tap() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Building blocks

/// A dashed "next step" row between cards: adds the part that naturally comes next.
private struct BridgeButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title).dsFont(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .transition(.opacity)
    }
}

/// A large tile for one moment ("Eating", "Bolus", "Woke up"), on or off.
private struct PartTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs + 2) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.12)))
                        .frame(width: 40, height: 40)
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(tint))
                }
                Text(title)
                    .dsFont(.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.vertical, DS.Space.sm)
            .padding(.horizontal, DS.Space.xs)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: isOn ? 1.5 : 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A preset, "same as last" or recent food: name over its amounts, one tap to fill the form.
private struct QuickAddTile: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).dsFont(.headline).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).dsFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            .padding(.leading, DS.Space.sm)
            .padding(.trailing, DS.Space.md)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: selected ? 1.5 : 0.75)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("\(title), \(detail)")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// A card for one part of the entry, with a coloured title.
private struct PhoneLogPanel<Content: View>: View {
    let part: PhoneLogPart
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: part.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(part.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).dsFont(.sectionTitle)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}

/// A big number with − and + either side and the decimal keypad, e.g. units or grams.
private struct PhoneAmountField: View {
    let title: String
    @Binding var text: String
    let unitLabel: String
    let step: Double
    let range: ClosedRange<Double>
    let tint: Color
    var focus: FocusState<LogFieldFocus?>.Binding
    var focusValue: LogFieldFocus

    var body: some View {
        HStack(spacing: DS.Space.md) {
            stepButton("minus", delta: -step)
            VStack(spacing: 0) {
                TextField(title, text: $text, prompt: Text("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .focused(focus, equals: focusValue)
                    .accessibilityLabel(title)
                Text(unitLabel)
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.sm)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .onTapGesture { focus.wrappedValue = focusValue }
            stepButton("plus", delta: step)
        }
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let current = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
            let next = min(range.upperBound, max(range.lowerBound, ((current + delta) / step).rounded() * step))
            text = LogFormat.number(next)
            Haptics.tap()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(delta > 0 ? "Increase \(title)" : "Decrease \(title)")
    }
}

/// Body areas with left and right, each showing when it was last used. The site used longest ago
/// is suggested (and picked to start with for a new dose), and picking one used in the last few
/// days says so, to help with rotation.
private struct PhoneInjectionSitePicker: View {
    @Binding var selection: InjectionSite?
    /// When the dose is: only injections before it count.
    var at: Date = .distantFuture
    @EnvironmentObject var logbook: LogbookStore
    /// Folded to one line (the site, already picked) until tapped.
    @State private var expanded = false

    var body: some View {
        let last = logbook.lastInjectionBySite(before: at)
        let suggested = SiteRotation.suggestion(lastUse: last)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                withAnimation(DSMotion.quick.animation) { expanded.toggle() }
                Haptics.tap()
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Text("Injection site").dsFont(.label).foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.sm)
                    if let selection, selection == suggested {
                        Image(systemName: "sparkle").imageScale(.small).foregroundStyle(Palette.insulin)
                    }
                    Text(selection?.title ?? "Not recorded")
                        .dsFont(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Injection site, \(selection?.title ?? "not recorded")")
            .accessibilityHint(expanded ? "Hides the other sites" : "Shows the other sites")
            if !expanded, let selection, selection == suggested {
                Text("Suggested: the site you've gone longest without using. Tap to change.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if expanded {
                if let suggested, selection != suggested {
                    Button { selection = suggested; Haptics.tap() } label: {
                        Label("Use \(suggested.title)", systemImage: "sparkle")
                            .lineLimit(1)
                    }
                    .dsFont(.caption)
                    .foregroundStyle(Palette.insulin)
                    .accessibilityHint("The site you've gone longest without using")
                }
                Grid(alignment: .leading, horizontalSpacing: DS.Space.sm, verticalSpacing: DS.Space.sm) {
                    ForEach([BodyArea.abdomen, .arm, .thigh, .hip]) { area in
                        GridRow {
                            Text(area.title)
                                .dsFont(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            ForEach(InjectionSite.allCases.filter { $0.area == area }) { s in
                                siteButton(s, last: last[s], suggested: s == suggested)
                            }
                        }
                    }
                }
                HStack(spacing: DS.Space.xs + 2) {
                    Button("Other") { selection = selection == .other ? nil : .other }
                        .buttonStyle(ChipButtonStyle(selected: selection == .other, tint: Palette.insulin))
                    Button("Not recorded") { selection = nil }
                        .buttonStyle(ChipButtonStyle(selected: selection == nil, tint: Palette.insulin))
                }
            }
            if let recent = SiteRotation.recentUse(of: selection, lastUse: last) {
                Label("Used \(recent.formatted(.relative(presentation: .named))). Moving to a site you haven't used lately helps avoid lumps under the skin, where insulin absorbs unevenly.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func siteButton(_ s: InjectionSite, last: Date?, suggested: Bool) -> some View {
        Button {
            selection = selection == s ? nil : s
            Haptics.tap()
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
        .buttonStyle(ChipButtonStyle(selected: selection == s, tint: Palette.insulin))
        .overlay {
            // Dashed ring on the suggested site while another is picked.
            if suggested && selection != s {
                Capsule().strokeBorder(Palette.insulin.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(suggested ? "\(s.title), suggested" : s.title)
        .accessibilityValue(last.map { "last used \($0.formatted(.relative(presentation: .named)))" } ?? "not used")
    }
}

/// How the user takes insulin. Asked the first time they log on this iPhone, and in Settings.
struct PhoneTherapyPicker: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("How do you take insulin?").dsFont(.title)
                Text("GlucOS uses this to decide what to ask when you log. You can change it any time in Settings.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([TherapyType.injections, .pump, .noInsulin]) { t in
                Button { settings.therapy = t; Haptics.tap() } label: {
                    HStack(spacing: DS.Space.md) {
                        Image(systemName: t.systemImage)
                            .font(.title2)
                            .foregroundStyle(Palette.brand)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).dsFont(.headline)
                            Text(t.detail).dsFont(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if settings.therapy == t {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(.standard, padding: DS.Space.lg)
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}
