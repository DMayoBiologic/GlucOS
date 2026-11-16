import Foundation

// "Was that dose for a meal?" (docs/DoseQuestion.md)
//
// A fast-acting dose with no food logged near it reads as a correction: the forecast expects its
// whole drop, and the learners take the glucose that follows as insulin alone. When it was really
// for a meal nobody logged, the forecast runs low and the fitted insulin effect comes out weak.
// docs/ForecastAccuracy.md §7 found four such doses (1.5–10 U) on 14–15 Nov 2026.
//
// So half an hour after such a dose GlucOS asks, once, whether it was for a meal or a correction:
// on the iPhone and Mac, and as a notification if the app isn't open. Either answer, or
// dismissing it, is stored on the dose (`InsulinDose.purpose`) and syncs, so no device asks again.
//
// A dose marked as for a meal, with still no food logged near it, then counts everywhere as food
// logged without carbs: the forecast follows the trend instead of expecting the full drop, and the
// effect learner, the morning pattern, Insights and the bolus settings review leave it out. A dose
// marked as a correction is read as before, now with the user's word for it.

enum DoseMealCheck {
    /// Food logged this close to a dose, either side, is taken to be what it was for.
    static let foodGap: TimeInterval = 30 * 60
    /// How long after the dose to ask, so a meal logged just after it is seen first.
    static let askAfter: TimeInterval = 30 * 60
    /// Doses older than this aren't asked about: the answer matters most while the insulin acts.
    static let askUntil: TimeInterval = 12 * 3600
    /// Smaller doses aren't worth a question.
    static let minimumUnits = 0.5
    /// For a dose marked as for a meal, food logged from this long before it…
    static let mealBefore: TimeInterval = 30 * 60
    /// …to this long after it is that meal (a long pre-bolus counts).
    static let mealAfter: TimeInterval = 90 * 60

    /// A bolus with no food (or hypo treatment) logged near it, that the user hasn't said anything
    /// about. Doses from the bolus calculator are left alone: the calculator knows what they were for.
    static func isUnexplained(_ dose: InsulinDose, meals: [MealEntry], contexts: [ContextEvent]) -> Bool {
        guard dose.purpose == nil, dose.calculation == nil, dose.kind.isBolus, dose.units >= minimumUnits else {
            return false
        }
        let t = dose.timestamp
        if meals.contains(where: { abs($0.timestamp.timeIntervalSince(t)) <= foodGap }) { return false }
        if contexts.contains(where: { $0.tags.contains(.hypoTreatment) && abs($0.timestamp.timeIntervalSince(t)) <= foodGap }) {
            return false
        }
        return true
    }

    /// Worth asking about right now.
    static func shouldAsk(_ dose: InsulinDose, meals: [MealEntry], contexts: [ContextEvent], now: Date) -> Bool {
        let age = now.timeIntervalSince(dose.timestamp)
        return age >= askAfter && age <= askUntil && isUnexplained(dose, meals: meals, contexts: contexts)
    }

    /// The doses to ask about now, newest first.
    static func pending(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent], now: Date) -> [InsulinDose] {
        doses.filter { shouldAsk($0, meals: meals, contexts: contexts, now: now) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// When to ask about a dose: half an hour after it, or now if that has passed. Nil when it
    /// needs no question or is too old for one.
    static func askTime(for dose: InsulinDose, meals: [MealEntry], contexts: [ContextEvent], now: Date) -> Date? {
        guard isUnexplained(dose, meals: meals, contexts: contexts) else { return nil }
        let at = max(now, dose.timestamp.addingTimeInterval(askAfter))
        guard at.timeIntervalSince(dose.timestamp) <= askUntil else { return nil }
        return at
    }

    /// The times of doses the user said were for a meal, where no food has been logged with them.
    /// Everything that models glucose treats these like food logged without carbs.
    static func unloggedMealTimes(doses: [InsulinDose], meals: [MealEntry]) -> [Date] {
        doses.filter { d in
            d.purpose == .meal && d.kind.isBolus && !meals.contains { m in
                let dt = m.timestamp.timeIntervalSince(d.timestamp)
                return dt >= -mealBefore && dt <= mealAfter
            }
        }
        .map(\.timestamp)
    }

    /// "4 u NovoRapid at 9:12 am": the dose, as the question names it.
    static func doseLine(_ dose: InsulinDose) -> String {
        "\(LogFormat.units(dose.units)) \(dose.displayName) at \(ClockLabel.time(dose.timestamp))"
    }

    static let question = "Was it for a meal?"
    static let detail = "No food is logged near it. Your answer helps the forecast read this dose."

    /// What the confirmation says once answered.
    static func answered(_ purpose: DosePurpose) -> String {
        switch purpose {
        case .meal: return "Marked as for a meal. The forecast won't expect its full drop."
        case .correction: return "Marked as a correction."
        case .unsure: return "Won't ask about this dose again."
        }
    }
}
