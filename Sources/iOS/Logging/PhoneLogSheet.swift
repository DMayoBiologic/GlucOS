import SwiftUI
import UIKit

/// Logs insulin, food, a pump site change and events (exercise, illness, a hypo…) on iPhone, all
/// at one time, into the same `LogbookStore` the Mac uses, so it syncs both ways.
///
/// Same rules as the Mac log sheet: what it asks for follows the therapy type, it records what the
/// user enters and never suggests an amount. Presets and "same as last" only repeat numbers the
/// user typed themselves.
struct PhoneLogSheet: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
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

        switch target {
        case .new(let start):
            startPart = start
            if let start {
                parts = [start]
            } else {
                parts = s.therapy.logsInsulin ? [.insulin] : [.food]
            }
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
    }

    private var isNew: Bool { editing == nil }
    private var needsTherapy: Bool { isNew && settings.therapy == .notSet }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    if needsTherapy {
                        PhoneTherapyPicker()
                    } else {
                        whenCard
                        if isNew { quickAdd }
                        if isNew { partTiles }
                        if includes(.insulin) { insulinCard.transition(.opacity.combined(with: .move(edge: .top))) }
                        if includes(.food) { foodCard.transition(.opacity.combined(with: .move(edge: .top))) }
                        if includes(.site) { siteCard.transition(.opacity.combined(with: .move(edge: .top))) }
                        if includes(.event) { eventCard.transition(.opacity.combined(with: .move(edge: .top))) }
                        noteCard
                        if isNew { presetCard }
                        Label("GlucOS records what you enter. It never suggests a dose.", systemImage: "info.circle")
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
            if let start, availableParts.contains(start) {
                parts = [start]
            } else {
                parts = therapy.logsInsulin ? [.insulin] : [.food]
            }
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
            // Picking another type while a saved insulin of the old type is selected. An edited
            // dose keeps its name (the name field then shows, since the types differ).
            if editingID == nil, let saved = logbook.savedInsulin(named: insulinName), saved.kind == old, saved.kind != new {
                insulinName = ""
            } else if insulinName == settings.defaultInsulinName(for: old) {
                insulinName = settings.defaultInsulinName(for: new)
            }
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

    private var whenCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title: "When", systemImage: "clock")
                Button {
                    withAnimation(DSMotion.quick.animation) { showsTimePicker.toggle() }
                } label: {
                    Text(timeSummary)
                        .dsFont(.headline)
                        .monospacedDigit()
                }
                .accessibilityHint("Pick another time")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs + 2) {
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
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private var timeSummary: String {
        if Calendar.current.isDateInToday(time) { return time.formatted(date: .omitted, time: .shortened) }
        return time.formatted(date: .abbreviated, time: .shortened)
    }

    private func isOffset(_ minutes: Int) -> Bool {
        abs(time.timeIntervalSince(Date().addingTimeInterval(-Double(minutes) * 60))) < 45
    }

    // MARK: Quick add

    /// Presets, the last bolus and recent foods: one tap fills the form with numbers the user
    /// logged before.
    @ViewBuilder
    private var quickAdd: some View {
        let presets = logbook.presets
        let lastBolus = settings.therapy.logsInsulin ? logbook.lastBolus : nil
        let foods = logbook.recentFoods(limit: 4)
        if !presets.isEmpty || lastBolus != nil || !foods.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Eyebrow(title: "Quick add", systemImage: "bolt.fill",
                        trailing: presets.isEmpty ? "Save a preset below" : nil)
                    .padding(.horizontal, DS.Space.xs)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(presets) { p in
                            QuickAddTile(title: p.name, detail: p.summary, systemImage: p.systemImage,
                                         tint: p.hasInsulin ? Palette.insulin : p.hasFood ? Palette.food : Palette.context,
                                         selected: appliedPresetID == p.id) { apply(p) }
                        }
                        if let d = lastBolus {
                            QuickAddTile(title: "Same as last", detail: "\(LogFormat.units(d.units)) \(d.displayName)",
                                         systemImage: "arrow.uturn.backward", tint: Palette.insulin,
                                         selected: false) { applyLast(d) }
                        }
                        ForEach(foods) { f in
                            QuickAddTile(title: f.food, detail: f.carbs > 0 ? "\(LogFormat.grams(f.carbs)) carbs" : "Food",
                                         systemImage: "fork.knife", tint: Palette.food,
                                         selected: includes(.food) && foodText.caseInsensitiveCompare(f.food) == .orderedSame) { apply(f) }
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
        if !p.tags.isEmpty { next.insert(.event) }
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

    /// Saved insulins this dose can be logged with.
    private var insulinChoices: [SavedInsulin] { InsulinLibrary.choices(logbook.insulins, viaPump: viaPump) }

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
    private func startDose() {
        guard isNew else { return }
        if let p = logbook.preferredInsulin(viaPump: viaPump) {
            kind = p.kind
            insulinName = p.name
            typesInsulin = false
        }
        if !viaPump, injectionSite == nil {
            autoSite = logbook.suggestedInjectionSite(at: time)
            injectionSite = autoSite
            siteIsAutomatic = autoSite != nil
        }
    }

    // MARK: Parts

    private var availableParts: [PhoneLogPart] {
        var out: [PhoneLogPart] = []
        if settings.therapy.logsInsulin { out.append(.insulin) }
        out.append(.food)
        if settings.therapy == .pump { out.append(.site) }
        out.append(.event)
        return out
    }

    private func includes(_ part: PhoneLogPart) -> Bool {
        if let editing { return editing == part }
        return parts.contains(part) && availableParts.contains(part)
    }

    private var partTiles: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(availableParts) { part in
                PartTile(title: part.title(pump: viaPump), systemImage: part.systemImage, tint: part.tint,
                         isOn: parts.contains(part)) {
                    if parts.contains(part) { parts.remove(part) } else { parts.insert(part) }
                    Haptics.tap()
                    if parts.contains(part) {
                        if part == .insulin { focus = .units } else if part == .food { focus = .carbs }
                    }
                }
            }
        }
    }

    private var insulinCard: some View {
        PhoneLogPanel(part: .insulin, title: viaPump ? "Bolus" : "Insulin") {
            PhoneAmountField(title: "Units", text: $unitsText, unitLabel: "units",
                             step: InsulinLibrary.step(for: logbook.savedInsulin(named: insulinName), viaPump: viaPump),
                             range: LogLimits.units, tint: Palette.insulin,
                             focus: $focus, focusValue: .units)
            if let problem = unitsProblem { FieldProblem(text: problem) }
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
        }
    }

    private static let carbChips = [10, 15, 20, 30, 45, 60]

    private var foodCard: some View {
        PhoneLogPanel(part: .food, title: "Food") {
            PhoneAmountField(title: "Carbs", text: $carbsText, unitLabel: "g carbs",
                             step: 5, range: LogLimits.carbs, tint: Palette.food,
                             focus: $focus, focusValue: .carbs)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs + 2) {
                    ForEach(Self.carbChips, id: \.self) { g in
                        Button("\(g) g") { carbsText = "\(g)"; Haptics.tap() }
                            .buttonStyle(ChipButtonStyle(selected: carbs == Double(g), tint: Palette.food))
                    }
                }
                .padding(.vertical, 1)
            }
            if let problem = foodProblem { FieldProblem(text: problem) }
            TextField("What you ate", text: $food, prompt: Text("What you ate, e.g. toast and a banana"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .food)
                .submitLabel(.done)
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

    private var tagChoices: [ContextTag] {
        settings.therapy.logsInsulin || tags.contains(.siteProblem)
            ? ContextTag.allCases
            : ContextTag.allCases.filter { $0 != .siteProblem }
    }

    private var eventCard: some View {
        PhoneLogPanel(part: .event, title: isNew ? "What's going on?" : "Event") {
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
            if let t = tags.count == 1 ? tags.first : nil {
                Text(t.help).dsFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Doses and meals around these are kept out of the typical figures in Insights, so they don't skew them.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noteCard: some View {
        TextField("Note", text: $note, prompt: Text("Add a note (optional)"), axis: .vertical)
            .lineLimit(1...4)
            .dsFont(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(.standard, padding: DS.Space.lg)
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Toggle(isOn: $savesAsPreset.animation(DSMotion.quick.animation)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save as preset").dsFont(.headline)
                    Text("Keep this combination as a one-tap quick add.").dsFont(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(Palette.brand)
            .disabled(!canSave || !hasPresetContent)
            if savesAsPreset {
                TextField("Preset name", text: $presetName, prompt: Text(defaultPresetName))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .presetName)
            }
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }

    // MARK: Save bar

    private var saveBar: some View {
        Button { save() } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark.circle.fill")
                Text(saveSummary).lineLimit(1).minimumScaleFactor(0.8)
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

    /// "Log 4 u + 45 g", "Log Exercise", "Save".
    private var saveSummary: String {
        guard isNew else { return "Save" }
        var bits: [String] = []
        if includes(.insulin), let units { bits.append(LogFormat.units(units)) }
        if includes(.food), foodValid, let carbs { bits.append(carbs > 0 ? LogFormat.grams(carbs) : (foodText.isEmpty ? "food" : foodText)) }
        if includes(.site) { bits.append("new site") }
        if includes(.event), !tags.isEmpty {
            bits.append(tags.count == 1 ? (tags.first?.title ?? "") : "\(tags.count) events")
        }
        return bits.isEmpty ? "Log" : "Log " + bits.joined(separator: " + ")
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
        return c > 0 || !foodText.isEmpty
    }

    private var canSave: Bool {
        let checks = [
            (includes(.insulin), units != nil),
            (includes(.food), foodValid),
            (includes(.site), true),
            (includes(.event), !tags.isEmpty),
        ].filter { $0.0 }
        return !checks.isEmpty && checks.allSatisfy { $0.1 }
    }

    /// A preset needs something to fill in: a site change on its own isn't one.
    private var hasPresetContent: Bool {
        includes(.insulin) || includes(.food) || (includes(.event) && !tags.isEmpty)
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
        guard editing == nil || editing == .insulin || editing == .food else { return }
        // Sheets take focus a beat after appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if includes(.insulin) && unitsText.isEmpty { focus = .units } else if includes(.food) && carbsText.isEmpty && editing == nil { focus = .carbs }
        }
    }

    private func save() {
        guard canSave else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let logsInsulin = includes(.insulin)
        let logsFood = includes(.food)
        let trimmedName = insulinName.trimmingCharacters(in: .whitespacesAndNewlines)
        if logsInsulin, let units {
            logbook.save(.dose(InsulinDose(id: doseID, timestamp: time, units: units, kind: kind, name: trimmedName,
                                           site: viaPump ? nil : injectionSite, viaPump: viaPump, note: trimmedNote)))
        }
        if logsFood, let carbs {
            logbook.save(.meal(MealEntry(id: mealID, timestamp: time, carbs: carbs, food: foodText, note: trimmedNote)))
        }
        if includes(.site) {
            logbook.save(.siteChange(SiteChange(id: siteID, timestamp: time, site: newSite, note: trimmedNote)))
        }
        if includes(.event), !tags.isEmpty {
            logbook.save(.context(ContextEvent(id: contextID, timestamp: time, tags: tags, note: trimmedNote)))
        }
        if isNew && savesAsPreset && hasPresetContent {
            let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            let logsTags = includes(.event)
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
    func title(pump: Bool) -> String {
        switch self {
        case .insulin: return pump ? "Bolus" : "Insulin"
        case .food: return "Food"
        case .site: return "New site"
        case .event: return "Event"
        }
    }

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

/// A large tile that turns one part of the entry on or off.
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.md)
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

    var body: some View {
        let last = logbook.lastInjectionBySite(before: at)
        let suggested = SiteRotation.suggestion(lastUse: last)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Injection site").dsFont(.label).foregroundStyle(.secondary)
                Spacer()
                if let suggested {
                    if selection == suggested {
                        Label("Suggested: not used for longest", systemImage: "sparkle")
                            .dsFont(.caption)
                            .foregroundStyle(Palette.insulin)
                            .lineLimit(1)
                    } else {
                        Button { selection = suggested; Haptics.tap() } label: {
                            Label("Use \(suggested.title)", systemImage: "sparkle")
                                .lineLimit(1)
                        }
                        .dsFont(.caption)
                        .foregroundStyle(Palette.insulin)
                        .accessibilityHint("The site you've gone longest without using")
                    }
                }
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
            if let recent = SiteRotation.recentUse(of: selection, lastUse: last) {
                Label("Used \(recent.formatted(.relative(presentation: .named))). Moving to a site you haven't used lately helps avoid lumps under the skin, where insulin absorbs unevenly.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.xs + 2) {
                Button("Other") { selection = selection == .other ? nil : .other }
                    .buttonStyle(ChipButtonStyle(selected: selection == .other, tint: Palette.insulin))
                Button("Not recorded") { selection = nil }
                    .buttonStyle(ChipButtonStyle(selected: selection == nil, tint: Palette.insulin))
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
