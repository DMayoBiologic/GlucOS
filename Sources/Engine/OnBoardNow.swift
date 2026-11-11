import Foundation

// What's still acting right now, from the logbook. Shared by the Mac dashboard and the iPhone.
// Every number is an estimate on typical timing curves for what was logged, never dosing advice.

/// Insulin and carbs still acting at one moment, worked out from the logbook with the engine's
/// own models. Worked out on the view's clock rather than taken from the last outlook, so the
/// numbers keep counting down even when readings stop coming in.
struct OnBoardNow {
    let insulin: InsulinActivity
    let background: BackgroundInsulinActivity
    let carbs: CarbActivity

    init(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent], at now: Date) {
        let hypo = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        insulin = InsulinActivity.compute(doses: doses, at: now)
        background = BackgroundInsulinActivity.compute(doses: doses, at: now)
        carbs = CarbActivity.compute(meals: meals, hypoTreatments: hypo, at: now)
    }

    /// People who don't take insulin only see carbs and the forecast, unless they logged some anyway.
    func showsInsulin(therapy: TherapyType) -> Bool {
        therapy != .noInsulin || insulin.doseCount > 0 || background.isActive
    }

    var isEmpty: Bool { insulin.onBoard < 0.05 && !background.isActive && carbs.onBoard < 1 }
}
