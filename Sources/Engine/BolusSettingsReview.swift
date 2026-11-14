import Foundation

// Looks back over the logbook for meals and corrections whose outcome is easy to read, and asks
// whether the user's own settings would have done better with a different number. It never
// changes a setting: it can only offer one, with the evidence, for the user to accept or ignore.
// The bolus calculator itself only ever uses the confirmed settings.
//
// Meals. A meal is used when it had a bolus within 20 minutes, nothing else was eaten or injected
// from 3 hours before to 4 hours after, no other insulin was still acting, no context tags were in
// play, there was no low in the 4 hours, and there are readings at the start and 4 hours later.
// If glucose ends `Δ` away from where it started, with `left` units of the dose still on board at
// 4 hours (they'll lower it further), then with the correction factor `CF` the food insulin that
// would have ended level is `units + Δ ÷ CF − left`, and the ratio that would have given it is
// `carbs ÷ that`. Any correction in the dose cancels out of the sum.
//
// Corrections. A bolus with no food from 3 hours before to 4 hours after, started at least
// 2 mmol/L (36 mg/dL) above target, with the same other conditions. The fall per unit that had
// acted by then, `(start − 4 h later) ÷ (units − left)`, is the correction factor it showed.
//
// The median of at least five such examples per time block is compared with the setting. A change
// is offered only when it's 10% or more, and never more than 20% in one step, which is how
// diabetes teams usually adjust settings.

struct BolusReviewExample: Hashable {
    let date: Date
    let carbs: Double
    let units: Double
    let startMgdl: Double
    let endMgdl: Double
    /// The ratio (g/unit) or correction factor (mg/dL per unit) this example implies.
    let implied: Double
}

struct BolusSettingSuggestion: Hashable, Identifiable {
    enum Setting: String { case carbRatio, correctionFactor }
    enum Confidence: String { case moderate, high }

    let setting: Setting
    let blockID: UUID
    let blockStartMinute: Int
    let current: Double
    /// Median of what the examples implied.
    let observed: Double
    /// What's offered: `current` moved towards `observed`, by at most `maxStep`.
    let suggested: Double
    let examples: [BolusReviewExample]
    /// Interquartile range ÷ median of the implied values.
    let spread: Double
    let confidence: Confidence
    /// Mean of (4 h later − start), mg/dL. Positive: glucose tended to end higher.
    let averageChange: Double

    var id: String { "\(setting.rawValue)-\(blockID)" }

    /// "Moderate confidence: 7 meals, fairly consistent."
    var confidenceText: String {
        let what = setting == .carbRatio ? "meals" : "corrections"
        let consistency = spread <= 0.3 ? "consistent" : "fairly consistent"
        return "\(confidence == .high ? "High" : "Moderate") confidence: \(examples.count) \(what), \(consistency)."
    }

    func explanation(unit: GlucoseUnit, calendar: Calendar = .current) -> String {
        let from = BolusScheduleBlock(startMinute: blockStartMinute, carbRatio: 1, correctionFactor: 1, targetMgdl: 100)
            .startLabel(calendar: calendar)
        let change = unit.format(mgdl: abs(averageChange), withUnit: true)
        let direction = averageChange >= 0 ? "higher" : "lower"
        switch setting {
        case .carbRatio:
            return "Across \(examples.count) meals in the block from \(from), glucose 4 hours after eating ended on "
                + "average \(change) \(direction) than before the meal. With your correction factor, the doses that "
                + "would have ended level work out at about 1 unit per \(LogFormat.number(observed.rounded(toStep: 0.5))) g. "
                + "Your setting is 1 unit per \(LogFormat.number(current)) g. "
                + "This assumes your correction factor is right."
        case .correctionFactor:
            return "Across \(examples.count) corrections in the block from \(from), each unit lowered glucose by "
                + "about \(unit.format(mgdl: observed, withUnit: true)) over 4 hours. Your setting is "
                + "\(unit.format(mgdl: current, withUnit: true)) per unit. "
                + "Background insulin that's too high or too low affects this too."
        }
    }
}

struct BolusSettingsReview: Hashable {
    let suggestions: [BolusSettingSuggestion]
    /// Usable examples found per block, for "not enough yet" messages.
    let mealExamples: [UUID: Int]
    let correctionExamples: [UUID: Int]
    let days: Int

    static let lookbackDays = 45
    static let minimumExamples = 5
    static let minimumChange = 0.10
    static let maxStep = 0.20
    static let outcomeAfter: TimeInterval = 4 * 3600
    static let pairing: TimeInterval = 20 * 60
    static let quietBefore: TimeInterval = 3 * 3600

    static func review(settings: BolusSettings, readings: [GlucoseReading], doses: [InsulinDose],
                       meals: [MealEntry], contexts: [ContextEvent], lowMgdl: Double,
                       now: Date = Date(), calendar: Calendar = .current) -> BolusSettingsReview {
        let series = GlucoseSeries(readings)
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let boluses = doses.filter { $0.kind.isBolus && $0.units > 0 }.sorted { $0.timestamp < $1.timestamp }
        // The same meal logged twice (e.g. on two devices) counts once, so it can't look like extra food.
        let carbMeals = LogCleanup.mealsWithoutRepeats(meals).sorted { $0.timestamp < $1.timestamp }
        let fastDoses = doses.filter { !$0.kind.fastComponents.isEmpty && $0.units > 0 }

        func blockFor(_ date: Date) -> BolusScheduleBlock? { settings.block(at: date, calendar: calendar) }

        /// Nothing in the window that the simple sums can't account for.
        func clean(from start: Date, to end: Date, ignoringDoses: Set<UUID>, ignoringMeals: Set<UUID>) -> Bool {
            // Other food (with or without carbs).
            if carbMeals.contains(where: { !ignoringMeals.contains($0.id) && $0.timestamp >= start.addingTimeInterval(-quietBefore) && $0.timestamp <= end }) {
                return false
            }
            // Other fast insulin given in the window, or still acting from before it.
            let others = fastDoses.filter { !ignoringDoses.contains($0.id) }
            if others.contains(where: { $0.timestamp > start.addingTimeInterval(-quietBefore) && $0.timestamp <= end }) { return false }
            if InsulinActivity.compute(doses: others.filter { $0.timestamp <= start }, at: start).onBoard > 0.3 { return false }
            // Exercise, illness, hypo treatment, a bad site…
            if contexts.contains(where: { c in
                c.tags.contains { tag in
                    c.timestamp <= end && c.timestamp >= start.addingTimeInterval(-max(tag.reach, quietBefore))
                }
            }) { return false }
            // A low in the window (and its treatment, usually unlogged), or a gap in readings.
            let slice = series.slice(from: start, through: end)
            if slice.contains(where: { $0.mgdl < lowMgdl }) { return false }
            if slice.count < 8 { return false }
            return true
        }

        var mealExamples: [UUID: [BolusReviewExample]] = [:]
        var correctionExamples: [UUID: [BolusReviewExample]] = [:]
        var usedDoses = Set<UUID>()

        // Meals.
        for m in carbMeals where m.carbs >= 10 && m.timestamp >= since && m.timestamp.addingTimeInterval(outcomeAfter) <= now {
            let paired = boluses.filter { abs($0.timestamp.timeIntervalSince(m.timestamp)) <= pairing }
            guard !paired.isEmpty, let block = blockFor(m.timestamp) else { continue }
            let start = min(m.timestamp, paired.map(\.timestamp).min() ?? m.timestamp)
            let end = m.timestamp.addingTimeInterval(outcomeAfter)
            guard clean(from: start, to: end, ignoringDoses: Set(paired.map(\.id)), ignoringMeals: [m.id]),
                  let g0 = series.value(at: start), let g1 = series.value(at: end) else { continue }
            let units = paired.reduce(0) { $0 + $1.units }
            // What's still on board at 4 hours will lower glucose further, so it counts as not acted yet.
            let left = InsulinActivity.compute(doses: paired, at: end).onBoard
            let foodUnits = units + (g1 - g0) / block.correctionFactor - left
            guard foodUnits >= 0.5 else { continue }
            let implied = m.carbs / foodUnits
            guard BolusSettings.carbRatioRange.contains(implied) else { continue }
            mealExamples[block.id, default: []].append(
                BolusReviewExample(date: m.timestamp, carbs: m.carbs, units: units, startMgdl: g0, endMgdl: g1, implied: implied))
            usedDoses.formUnion(paired.map(\.id))
        }

        // Corrections.
        for d in boluses where !usedDoses.contains(d.id) && d.timestamp >= since && d.timestamp.addingTimeInterval(outcomeAfter) <= now {
            guard let block = blockFor(d.timestamp) else { continue }
            let end = d.timestamp.addingTimeInterval(outcomeAfter)
            guard clean(from: d.timestamp, to: end, ignoringDoses: [d.id], ignoringMeals: []),
                  let g0 = series.value(at: d.timestamp), let g1 = series.value(at: end),
                  g0 >= block.targetMgdl + 2 * GlucoseUnit.mgdlPerMmol else { continue }
            let acted = d.units - InsulinActivity.compute(doses: [d], at: end).onBoard
            guard acted > 0.2 else { continue }
            let implied = (g0 - g1) / acted
            guard BolusSettings.correctionFactorRange.contains(implied) else { continue }
            correctionExamples[block.id, default: []].append(
                BolusReviewExample(date: d.timestamp, carbs: 0, units: d.units, startMgdl: g0, endMgdl: g1, implied: implied))
        }

        var suggestions: [BolusSettingSuggestion] = []
        for block in settings.blocks.sorted(by: { $0.startMinute < $1.startMinute }) {
            if let s = suggestion(.carbRatio, block: block, current: block.carbRatio, examples: mealExamples[block.id] ?? []) {
                suggestions.append(s)
            }
            if let s = suggestion(.correctionFactor, block: block, current: block.correctionFactor,
                                  examples: correctionExamples[block.id] ?? []) {
                suggestions.append(s)
            }
        }
        return BolusSettingsReview(suggestions: suggestions,
                                   mealExamples: mealExamples.mapValues(\.count),
                                   correctionExamples: correctionExamples.mapValues(\.count),
                                   days: lookbackDays)
    }

    static func suggestion(_ setting: BolusSettingSuggestion.Setting, block: BolusScheduleBlock, current: Double,
                           examples: [BolusReviewExample]) -> BolusSettingSuggestion? {
        guard examples.count >= minimumExamples, current > 0 else { return nil }
        let values = examples.map(\.implied).sorted()
        let median = EngineMath.quantile(values, 0.5)
        guard median > 0 else { return nil }
        let spread = (EngineMath.quantile(values, 0.75) - EngineMath.quantile(values, 0.25)) / median
        let confidence: BolusSettingSuggestion.Confidence
        if examples.count >= 10 && spread <= 0.3 { confidence = .high }
        else if spread <= 0.5 { confidence = .moderate }
        else { return nil }   // too mixed to say anything
        guard abs(median - current) / current >= minimumChange else { return nil }

        let lower = current * (1 - maxStep), upper = current * (1 + maxStep)
        var target = min(upper, max(lower, median))
        switch setting {
        case .carbRatio: target = target.rounded(toStep: 0.5)
        case .correctionFactor: target = (target / GlucoseUnit.mgdlPerMmol).rounded(toStep: 0.1) * GlucoseUnit.mgdlPerMmol
        }
        // Rounding must not push it past the 20% step, or back onto the current value.
        target = min(upper, max(lower, target))
        guard abs(target - current) > 1e-6 else { return nil }
        let change = examples.reduce(0) { $0 + ($1.endMgdl - $1.startMgdl) } / Double(examples.count)
        return BolusSettingSuggestion(setting: setting, blockID: block.id, blockStartMinute: block.startMinute,
                                      current: current, observed: median, suggested: target,
                                      examples: examples.sorted { $0.date < $1.date }, spread: spread,
                                      confidence: confidence, averageChange: change)
    }
}

extension BolusSettings {
    /// A copy with `suggestion` applied, for when the user accepts it (and confirms the result).
    func applying(_ suggestion: BolusSettingSuggestion) -> BolusSettings {
        var s = self
        guard let i = s.blocks.firstIndex(where: { $0.id == suggestion.blockID }) else { return s }
        switch suggestion.setting {
        case .carbRatio: s.blocks[i].carbRatio = suggestion.suggested
        case .correctionFactor: s.blocks[i].correctionFactor = suggestion.suggested
        }
        return s
    }
}

extension Double {
    func rounded(toStep step: Double) -> Double {
        guard step > 0 else { return self }
        return ((self / step).rounded() * step * 1000).rounded() / 1000
    }
}
