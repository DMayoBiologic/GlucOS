import SwiftUI

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
/// the therapy type in Settings. It records what the user enters and never suggests an amount.
struct LogSheet: View {
    private enum Part { case dose, meal, siteChange }

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Set when editing: only that part is shown.
    private let editing: Part?
    private let doseID: UUID
    private let mealID: UUID
    private let siteID: UUID

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
    @State private var note: String

    init(target: LogSheetTarget) {
        let s = AppSettings.shared
        var editing: Part?
        var doseID = UUID(), mealID = UUID(), siteID = UUID()
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
        var note = ""

        if case .edit(let entry) = target {
            time = entry.timestamp
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
            }
        }

        self.editing = editing
        self.doseID = doseID
        self.mealID = mealID
        self.siteID = siteID
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
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.therapy == .notSet && editing == nil {
                TherapySetupView()
                    .padding(24)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            } else {
                form
                Divider()
                HStack(spacing: 10) {
                    Text("GlucOS records what you enter. It never suggests a dose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(editing == nil ? "Log" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
                .padding(16)
            }
        }
        .frame(width: 480)
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
    }

    // MARK: Form

    private var showsInsulin: Bool { editing == .dose || (editing == nil && settings.therapy.logsInsulin) }
    private var showsFood: Bool { editing == .meal || editing == nil }
    private var showsSiteChange: Bool { editing == .siteChange || (editing == nil && settings.therapy == .pump) }

    private var form: some View {
        Form {
            Section {
                DatePicker("Time", selection: $time, in: ...Date().addingTimeInterval(15 * 60))
            }

            if showsInsulin { insulinSection }
            if showsFood { foodSection }
            if showsSiteChange { siteChangeSection }

            Section {
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...3)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 320, idealHeight: 460)
    }

    private var insulinSection: some View {
        Section {
            if editing == nil {
                Toggle(viaPump ? "Bolus" : "Insulin", isOn: $includeInsulin)
                    .font(.headline)
            }
            if includeInsulin {
                LabeledContent("Amount") {
                    HStack(spacing: 6) {
                        TextField("Units", text: $unitsText, prompt: Text("0"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 72)
                        Text("units").foregroundStyle(.secondary)
                    }
                }
                Picker("Insulin", selection: $kind) {
                    ForEach(viaPump ? InsulinKind.pumpKinds : InsulinKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                TextField("Name", text: $insulinName, prompt: Text(kind.examples))
                if viaPump {
                    LabeledContent("Infusion site") {
                        Text(pumpSiteText).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Injection site", selection: $injectionSite) {
                        Text("Not recorded").tag(InjectionSite?.none)
                        Divider()
                        ForEach(InjectionSite.allCases) { s in
                            Text(siteLabel(s)).tag(InjectionSite?.some(s))
                        }
                    }
                }
                if let problem = unitsProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            if editing == .dose { Text(viaPump ? "Bolus" : "Insulin") }
        }
    }

    private var foodSection: some View {
        Section {
            if editing == nil {
                Toggle("Food", isOn: $includeFood)
                    .font(.headline)
            }
            if includeFood {
                LabeledContent("Carbohydrate") {
                    HStack(spacing: 6) {
                        TextField("Carbs", text: $carbsText, prompt: Text("0"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 72)
                        Text("grams").foregroundStyle(.secondary)
                    }
                }
                TextField("What you ate", text: $food, prompt: Text("e.g. toast and a banana"))
                if let problem = foodProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            if editing == .meal { Text("Food") }
        }
    }

    private var siteChangeSection: some View {
        Section {
            if editing == nil {
                Toggle("Changed infusion site", isOn: $includeSiteChange)
                    .font(.headline)
            }
            if includeSiteChange {
                Picker("New site", selection: $newSite) {
                    ForEach(InjectionSite.allCases) { s in Text(s.title).tag(s) }
                }
            }
        } header: {
            if editing == .siteChange { Text("Infusion Site Change") }
        } footer: {
            if includeSiteChange || editing == .siteChange {
                Text("Boluses after this time are counted against this site.")
                    .foregroundStyle(.secondary)
            }
        }
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
        ].filter { $0.0 }
        return !parts.isEmpty && parts.allSatisfy { $0.1 }
    }

    private var pumpSiteText: String {
        if showsSiteChange && includeSiteChange { return "\(newSite.title) (new)" }
        guard let current = logbook.infusionSite(at: time) else { return "None logged yet" }
        return "\(current.site.title), since \(current.timestamp.formatted(.relative(presentation: .named)))"
    }

    private func siteLabel(_ s: InjectionSite) -> String {
        guard let last = logbook.lastInjectionBySite[s] else { return s.title }
        return "\(s.title) · last used \(last.formatted(.relative(presentation: .named)))"
    }

    private func save() {
        guard canSave else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if showsInsulin && includeInsulin, let units {
            logbook.save(.dose(InsulinDose(id: doseID, timestamp: time, units: units, kind: kind,
                                           name: insulinName.trimmingCharacters(in: .whitespacesAndNewlines),
                                           site: viaPump ? nil : injectionSite, viaPump: viaPump,
                                           note: trimmedNote)))
        }
        if showsFood && includeFood, let carbs {
            logbook.save(.meal(MealEntry(id: mealID, timestamp: time, carbs: carbs, food: foodText, note: trimmedNote)))
        }
        if showsSiteChange && includeSiteChange {
            logbook.save(.siteChange(SiteChange(id: siteID, timestamp: time, site: newSite, note: trimmedNote)))
        }
        dismiss()
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
