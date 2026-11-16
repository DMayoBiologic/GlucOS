import SwiftUI

// The bolus calculator on screen: the suggestion with every step of its working, its settings,
// and the review of past meals that may offer a setting change. Shared by the Mac and the iPhone.
// The maths is in Sources/Engine/BolusCalculator.swift.

enum BolusText {
    static let disclaimer = "Not medical advice. The suggestion uses only the settings you entered, and the doses and readings GlucOS has. Check it, and take what you and your diabetes team decide."

    static func units(_ v: Double) -> String { "\(v.formatted(.number.precision(.fractionLength(2)))) u" }

    /// "2.0 mmol/L" or "36 mg/dL" per unit.
    static func factor(_ mgdl: Double, unit: GlucoseUnit) -> String {
        "\(unit.format(mgdl: mgdl, withUnit: true))"
    }

    static func ratio(_ g: Double) -> String { "1 u : \(LogFormat.number(g)) g" }
}

// MARK: - Suggestion

/// The calculator's suggestion for a dose now, for `carbs` grams, with its working. Tapping Use
/// only fills in the dose; the log sheet then asks the user to confirm.
struct BolusSuggestionCard: View {
    let carbs: Double
    let onUse: (BolusSuggestion) -> Void
    let onSetUp: () -> Void
    /// What the calculator says now, each time that changes: nil when it can't give a dose. The
    /// closure works it out again on the spot, for a check at the moment of logging.
    var onUpdate: ((BolusSuggestion?, @escaping @MainActor () -> BolusSuggestion?) -> Void)? = nil

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    @State private var usesFingerPrick = false
    @State private var fingerPrickText = ""
    @State private var showsWorking = true
    /// Exercise reduction the user picked: 0, 0.25 or 0.5.
    @State private var reduction = 0.0

    private var fingerPrick: Double? {
        guard usesFingerPrick,
              let v = Double(fingerPrickText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v > 0 else { return nil }
        let mgdl = settings.unit.mgdl(fromDisplay: v)
        return (20...600).contains(mgdl) ? mgdl : nil
    }

    /// Ticked but not a usable number: don't fall back to the sensor behind the person's back.
    private var fingerPrickMissing: Bool { usesFingerPrick && fingerPrick == nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let s = suggestion(at: context.date)
            let live = fingerPrickMissing ? nil : s
            content(s)
                .task(id: (live.map { "\($0.units)|\($0.isBlocked)|\($0.carbs)" } ?? "none") + "|\(fingerPrick ?? -1)|\(reduction)") {
                    onUpdate?(live, recompute())
                }
        }
    }

    /// Works the suggestion out again at the time it's called, from the current readings, doses and
    /// settings and the finger-prick value as it is now.
    private func recompute() -> @MainActor () -> BolusSuggestion? {
        let manual = fingerPrick, missing = fingerPrickMissing, carbs = carbs, reduction = reduction
        let logbook = logbook, store = store, settings = settings
        return { @MainActor in
            guard !missing else { return nil }
            return Self.suggestion(carbs: carbs, at: Date(), manual: manual, reduction: reduction,
                                   logbook: logbook, store: store, settings: settings)
        }
    }

    private func suggestion(at now: Date) -> BolusSuggestion {
        Self.suggestion(carbs: carbs, at: now, manual: fingerPrick, reduction: reduction,
                        logbook: logbook, store: store, settings: settings)
    }

    private static func suggestion(carbs: Double, at now: Date, manual: Double?, reduction: Double,
                                   logbook: LogbookStore, store: GlucoseStore, settings: AppSettings) -> BolusSuggestion {
        let snapshot = store.snapshot
        let readings = snapshot.history + (snapshot.current.map { [$0] } ?? [])
        let request = BolusRequest(carbs: carbs, now: now, readings: readings, manualGlucose: manual,
                                   doses: logbook.doses, contexts: logbook.contexts,
                                   lowMgdl: settings.lowMgdl, therapy: settings.therapy, reduction: reduction)
        return BolusCalculator.suggest(request, settings: logbook.bolusSettings)
    }

    @ViewBuilder
    private func content(_ s: BolusSuggestion) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Label("Bolus calculator", systemImage: "function").dsFont(.headline)
                Spacer()
                if s.block != nil {
                    Button(showsWorking ? "Hide working" : "Show working") { showsWorking.toggle() }
                        .buttonStyle(.plain)
                        .dsFont(.caption)
                        .foregroundStyle(Tone.brand.textColor)
                }
            }
            if s.notices.contains(.notSetUp) || s.notices.contains(.turnedOff) || s.notices.contains(where: {
                if case .invalidSettings = $0 { return true } else { return false }
            }) {
                Text(s.notices.first?.text(unit: settings.unit) ?? "")
                    .dsFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(logbook.bolusSettings == nil ? "Set up bolus calculator" : "Bolus calculator settings", action: onSetUp)
                    .buttonStyle(.ds(.secondary, size: .small))
            } else {
                if fingerPrickMissing {
                    Label("Enter your finger-prick reading, or untick it to use the sensor", systemImage: "drop")
                        .dsFont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if s.isBlocked {
                    Label("No suggestion", systemImage: "hand.raised.fill")
                        .dsFont(.headline).foregroundStyle(Tone.critical.textColor)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Text(LogFormat.number(s.units))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.insulin)
                        Text("units suggested").dsFont(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if showsWorking && !s.isBlocked && !fingerPrickMissing { BolusWorking(suggestion: s, unit: settings.unit) }
                if !fingerPrickMissing { BolusNoticeList(notices: s.notices, unit: settings.unit) }
                fingerPrickRow
                if !s.isBlocked { reductionRow }
                if !s.isBlocked && !fingerPrickMissing {
                    Button { onUse(s) } label: {
                        Label("Use \(LogFormat.units(s.units))", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ds(.tinted(.brand)))
                    .disabled(s.units <= 0)
                }
            }
            Text(BolusText.disclaimer)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.md)
        .dsCard(s.isBlocked && s.block != nil ? .tinted(.critical) : .inset, padding: 0)
    }

    /// Exercise before or after the meal: take a quarter or half off, the usual starting points.
    private var reductionRow: some View {
        HStack(spacing: DS.Space.sm) {
            Text("Exercise").dsFont(.callout)
            Spacer(minLength: DS.Space.sm)
            Picker("Exercise reduction", selection: $reduction.animation(DSMotion.quick.animation)) {
                Text("None").tag(0.0)
                Text("−25%").tag(0.25)
                Text("−50%").tag(0.5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
        .accessibilityHint("Takes a quarter or half off the suggestion if you're exercising around this meal.")
    }

    @ViewBuilder
    private var fingerPrickRow: some View {
        Toggle(isOn: $usesFingerPrick.animation(DSMotion.quick.animation)) {
            Text("Use a finger-prick reading").dsFont(.callout)
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        if usesFingerPrick {
            HStack {
                TextField("Glucose", text: $fingerPrickText, prompt: Text(settings.unit == .mmol ? "e.g. 7.4" : "e.g. 133"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(settings.unit.label).dsFont(.callout).foregroundStyle(.secondary)
                if !fingerPrickText.isEmpty && fingerPrick == nil {
                    Text("Check the number").dsFont(.caption).foregroundStyle(Tone.warning.textColor)
                }
            }
        }
    }
}

/// Every step of the sum, as a pump shows it.
struct BolusWorking: View {
    let suggestion: BolusSuggestion
    let unit: GlucoseUnit

    var body: some View {
        let s = suggestion
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let b = s.block {
                row("Food", "\(LogFormat.grams(s.carbs)) ÷ \(LogFormat.number(b.carbRatio)) g per unit", BolusText.units(s.foodUnits))
                if let g = s.glucose {
                    let sign = s.correctionUnits >= 0 ? "+" : "−"
                    row(s.correctionWithheld ? "Correction (left out)" : "Correction",
                        "(\(unit.format(mgdl: g)) − \(unit.format(mgdl: b.targetMgdl))) ÷ \(unit.format(mgdl: b.correctionFactor)) per unit",
                        s.correctionWithheld ? "0.00 u" : "\(sign)\(BolusText.units(abs(s.correctionUnits)))")
                } else {
                    row("Correction", "No current reading", "0.00 u")
                }
                if abs(s.trendUnits) > 0.005, let rate = s.ratePerMinute {
                    let sign = s.trendUnits >= 0 ? "+" : "−"
                    row("Trend",
                        "\(rate < 0 ? "Falling" : "Rising") \(unit.format(mgdl: abs(rate) * 5, withUnit: true)) per 5 min: \(s.trendMgdl < 0 ? "−" : "+")\(unit.format(mgdl: abs(s.trendMgdl))) in 30 min",
                        "\(sign)\(BolusText.units(abs(s.trendUnits)))")
                }
                row("Insulin on board",
                    s.insulinOnBoard > 0.005 ? "\(BolusText.units(s.insulinOnBoard)) still acting" : "None logged",
                    "−\(BolusText.units(s.insulinOnBoardApplied))")
                if s.reductionUnits > 0.005 {
                    row("Exercise", "\(Int((s.reduction * 100).rounded()))% less", "−\(BolusText.units(s.reductionUnits))")
                }
                Divider()
                row("Total", nil, BolusText.units(s.calculated))
                if case .capped(_, let cap)? = s.notices.first(where: { if case .capped = $0 { return true } else { return false } }) {
                    row("Capped", "Your maximum", BolusText.units(cap))
                }
                row("Suggested", "Rounded down to \(LogFormat.number(s.increment)) u steps", LogFormat.units(s.units), bold: true)
            }
        }
        .dsFont(.callout)
    }

    private func row(_ title: String, _ detail: String?, _ value: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).fontWeight(bold ? .semibold : .regular)
                if let detail { Text(detail).dsFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: DS.Space.sm)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BolusNoticeList: View {
    let notices: [BolusNotice]
    let unit: GlucoseUnit

    var body: some View {
        let sorted = notices.sorted { $0.level > $1.level }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(sorted, id: \.self) { n in
                    let tone: Tone = n.level == .stop ? .critical : n.level == .caution ? .warning : .info
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
                        Image(systemName: n.level == .info ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(tone.color)
                            .imageScale(.small)
                        Text(n.text(unit: unit))
                            .dsFont(.callout)
                            .foregroundStyle(n.level == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Settings

/// Carb ratio, correction factor and target by time of day, dose step and maximum. Nothing is
/// used until the user confirms the numbers are the ones their diabetes team gave them.
struct BolusSettingsEditor: View {
    let onDone: () -> Void

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    @State private var draft: BolusSettings
    @State private var confirmed: Bool
    @State private var review: BolusSettingsReview?
    @State private var reviewing = false
    @State private var applied: Set<String> = []

    init(current: BolusSettings?, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _draft = State(initialValue: current ?? .blank)
        _confirmed = State(initialValue: current?.isConfirmed ?? false)
    }

    private var unit: GlucoseUnit { settings.unit }
    private var changed: Bool { draft != logbook.bolusSettings }

    var body: some View {
        Form {
            Section {
                Text("Enter the settings your diabetes team gave you, as your pump or bolus plan has them. GlucOS uses only these numbers to suggest a dose: carbs ÷ carb ratio, plus (glucose − target) ÷ correction factor, minus insulin on board. It never changes them on its own.")
                    .dsFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($draft.blocks) { $block in
                Section {
                    if block.startMinute == 0 && draft.blocks.first?.id == block.id {
                        LabeledContent("Starts", value: "Midnight")
                    } else {
                        DatePicker("Starts", selection: startBinding($block), displayedComponents: .hourAndMinute)
                    }
                    numberField("Carb ratio", value: $block.carbRatio, suffix: "g per unit", fraction: 1)
                    numberField("Correction factor", value: displayBinding($block.correctionFactor),
                                suffix: "\(unit.label) per unit", fraction: unit == .mmol ? 1 : 0)
                    numberField("Target", value: displayBinding($block.targetMgdl), suffix: unit.label,
                                fraction: unit == .mmol ? 1 : 0)
                    if draft.blocks.count > 1 && block.startMinute != 0 {
                        Button("Remove this time block", role: .destructive) {
                            draft.blocks.removeAll { $0.id == block.id }
                        }
                    }
                } header: {
                    Text(draft.blocks.count == 1 ? "All day" : "From \(block.startLabel())")
                }
            }
            Section {
                Button { addBlock() } label: { Label("Add a time block", systemImage: "plus") }
                    .disabled(draft.blocks.count >= 12)
            } footer: {
                Text("Pumps often use different ratios for breakfast, lunch and dinner. Each block runs until the next one starts.")
            }

            Section("Dose") {
                Picker("Dose step", selection: $draft.increment) {
                    Text("0.05 u (pump)").tag(0.05)
                    Text("0.1 u (pump)").tag(0.1)
                    Text("0.5 u (half-unit pen)").tag(0.5)
                    Text("1 u (pen)").tag(1.0)
                }
                numberField("Maximum bolus", value: $draft.maxBolus, suffix: "units", fraction: 1)
                Toggle("Turn the calculator off", isOn: $draft.disabled)
            }

            Section {
                Toggle("Add insulin when glucose is rising", isOn: Binding(
                    get: { draft.risingTrendAdds },
                    set: { draft.addsForRisingTrend = $0 ? true : nil }))
            } header: {
                Text("Trend")
            } footer: {
                Text("When glucose is falling, the suggestion always allows for where it's heading in the next 30 minutes, so it's smaller. Allowing for a rise adds insulin, so it's off unless you and your diabetes team want it.")
            }

            let problems = draft.problems
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { FieldProblem(text: $0) }
                }
            }

            Section {
                Toggle(isOn: $confirmed) {
                    Text("These are the settings my diabetes team gave me, and I've checked them.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Save") { save() }
                    .disabled(!confirmed || !problems.isEmpty)
                Button("Cancel", role: .cancel) { onDone() }
            } footer: {
                Text(BolusText.disclaimer)
            }

            if logbook.bolusSettings?.isConfirmed == true { reviewSection }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, new in
            // Any change has to be confirmed again.
            if new != logbook.bolusSettings { confirmed = false }
        }
        .task { await runReview() }
    }

    // MARK: Review

    @ViewBuilder
    private var reviewSection: some View {
        Section {
            if reviewing {
                HStack(spacing: DS.Space.sm) { ProgressView().controlSize(.small); Text("Looking at your last \(BolusSettingsReview.lookbackDays) days…") }
            } else if let review {
                if review.suggestions.isEmpty {
                    let meals = review.mealExamples.values.reduce(0, +)
                    let corrections = review.correctionExamples.values.reduce(0, +)
                    Text(meals + corrections == 0
                         ? "No meals or corrections clean enough to learn from yet. GlucOS needs meals with a bolus logged within 20 minutes, carbs counted, and nothing else eaten or injected for the next 4 hours."
                         : "Your settings look in line with \(meals) meal\(meals == 1 ? "" : "s") and \(corrections) correction\(corrections == 1 ? "" : "s") from the last \(review.days) days, or there aren't yet \(BolusSettingsReview.minimumExamples) consistent examples in a time block.")
                        .dsFont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(review.suggestions) { s in suggestionRow(s) }
            }
        } header: {
            Text("Suggested changes")
        } footer: {
            Text("Worked out from your logged meals, doses and readings. A suggestion is never used unless you tap Try it, check the numbers and save. Talk to your diabetes team before changing your settings.")
        }
    }

    private func suggestionRow(_ s: BolusSettingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            let block = BolusScheduleBlock(startMinute: s.blockStartMinute, carbRatio: 1, correctionFactor: 1, targetMgdl: 100)
            Text(s.setting == .carbRatio
                 ? "Carb ratio from \(block.startLabel()): \(BolusText.ratio(s.current)) → \(BolusText.ratio(s.suggested))"
                 : "Correction factor from \(block.startLabel()): \(unit.format(mgdl: s.current, withUnit: true)) → \(unit.format(mgdl: s.suggested, withUnit: true)) per unit")
                .dsFont(.headline)
            Text(s.explanation(unit: unit)).dsFont(.callout).fixedSize(horizontal: false, vertical: true)
            TonePill(text: s.confidenceText, tone: s.confidence == .high ? .info : .neutral)
            if applied.contains(s.id) {
                Label("Filled in above. Check it, tick the box and save to use it.", systemImage: "checkmark")
                    .dsFont(.caption).foregroundStyle(.secondary)
            } else {
                Button("Try it") {
                    let next = draft.applying(s)
                    guard next != draft else { return }
                    draft = next
                    applied.insert(s.id)
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func runReview() async {
        guard let saved = logbook.bolusSettings, saved.isConfirmed else { return }
        reviewing = true
        let readings = store.archive
        let doses = logbook.doses, meals = logbook.meals, contexts = logbook.contexts
        let low = settings.lowMgdl
        let result = await Task.detached(priority: .utility) {
            BolusSettingsReview.review(settings: saved, readings: readings, doses: doses, meals: meals,
                                       contexts: contexts, lowMgdl: low)
        }.value
        review = result
        reviewing = false
    }

    // MARK: Editing

    private func save() {
        guard confirmed, draft.problems.isEmpty else { return }
        var s = draft.normalised
        s.confirmedAt = Date()
        logbook.saveBolusSettings(s)
        onDone()
    }

    private func addBlock() {
        let sorted = draft.blocks.sorted { $0.startMinute < $1.startMinute }
        guard let last = sorted.last else { return }
        // Halfway between the last block's start and midnight, on the hour.
        let start = min(23 * 60, ((last.startMinute + 1440) / 2 / 60) * 60)
        guard !sorted.contains(where: { $0.startMinute == start }) else { return }
        draft.blocks.append(BolusScheduleBlock(startMinute: start, carbRatio: last.carbRatio,
                                               correctionFactor: last.correctionFactor, targetMgdl: last.targetMgdl))
        draft.blocks.sort { $0.startMinute < $1.startMinute }
    }

    private func startBinding(_ block: Binding<BolusScheduleBlock>) -> Binding<Date> {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Binding(
            get: { midnight.addingTimeInterval(Double(block.wrappedValue.startMinute) * 60) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                block.wrappedValue.startMinute = max(1, min(1439, (c.hour ?? 0) * 60 + (c.minute ?? 0)))
            })
    }

    /// A mg/dL value shown and edited in the user's unit.
    private func displayBinding(_ mgdl: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { (unit.value(fromMgdl: mgdl.wrappedValue) * 10).rounded() / 10 },
            set: { mgdl.wrappedValue = unit.mgdl(fromDisplay: $0) })
    }

    private func numberField(_ title: String, value: Binding<Double>, suffix: String, fraction: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...max(fraction, 2))))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(suffix).foregroundStyle(.secondary).dsFont(.callout)
        }
    }
}

// MARK: - Confirming a dose

extension BolusSuggestion {
    /// The message on the confirm step before a dose from the calculator is logged.
    func confirmation(loggedUnits: Double, unit: GlucoseUnit) -> String {
        var bits = ["For \(LogFormat.grams(carbs)) carbs"]
        if let glucose { bits.append("glucose \(unit.format(mgdl: glucose, withUnit: true))") }
        if insulinOnBoardApplied > 0.005 { bits.append("\(BolusText.units(insulinOnBoardApplied)) on board taken off") }
        var text = bits.joined(separator: ", ") + "."
        if abs(loggedUnits - units) > 0.001 {
            text += " The calculator suggested \(LogFormat.units(units)); you're logging \(LogFormat.units(loggedUnits))."
        }
        return text + " Only take it if it's right for you. Not medical advice."
    }
}

// MARK: - Settings summary

/// One line about the calculator for Settings: off, or the numbers in use now.
struct BolusSettingsSummary: View {
    let settings: BolusSettings?
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).dsFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        guard let settings, settings.isConfirmed else { return "Bolus calculator: not set up" }
        return settings.disabled ? "Bolus calculator: off" : "Bolus calculator: on"
    }

    private var detail: String {
        guard let settings, settings.isConfirmed, let now = settings.block(at: Date()) else {
            return "Suggests a dose from your carb ratio, correction factor and target, like a pump's bolus calculator."
        }
        var bits = ["Now \(BolusText.ratio(now.carbRatio))",
                    "\(unit.format(mgdl: now.correctionFactor, withUnit: true)) per unit",
                    "target \(unit.format(mgdl: now.targetMgdl, withUnit: true))"]
        if settings.blocks.count > 1 { bits.append("\(settings.blocks.count) time blocks") }
        bits.append("\(LogFormat.number(settings.increment)) u steps, max \(LogFormat.units(settings.maxBolus))")
        return bits.joined(separator: " · ")
    }
}
