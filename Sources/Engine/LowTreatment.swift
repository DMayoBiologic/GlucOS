import Foundation

// Carbs taken for a low, and the fast curve the forecast models them on.
//
// The standard carb curve is a meal's: absorbed over three hours, starting ten minutes in. Fast
// carbs taken for a low act much sooner. On this user's four treated lows (12–16 Nov 2026, sports
// drinks, cola and one small meal, 21–38 g) glucose was back up 90–145 mg/dL within about 40 minutes, more
// than the learnt carb effect gives the same grams over three hours. Held out one low at a time,
// a curve absorbed over 30 minutes after a 10-minute delay, at 1.5× the learnt carb effect, cut the
// 15- and 30-minute miss after those lows from 24.4 and 40.5 mg/dL to 18.9 and 25.6, better on
// every low (docs/ForecastAccuracy.md §37).
//
// Forecast only. Carbs on board, the effect learner and the bolus calculator keep the standard
// curve, and predicted alerts read the forecast without this curve (`Outlook.alertForecast`).

enum LowTreatment {
    /// Absorbed over 30 minutes after a 10-minute delay: done 40 minutes after it's taken.
    static let curve = CarbAbsorptionCurve(delay: 10 * 60, absorptionTime: 30 * 60)
    /// How much more each gram raises glucose than the learnt carb effect says (rebound from the
    /// low on top of the carbs themselves).
    static let effectScale = 1.5
    /// Below this reading, carbs logged count as treating a low.
    static let lowMgdl = 70.0
    /// More than this is a meal, whatever the reading: it keeps the meal curve.
    static let maximumGrams = 45.0
    /// How old the reading at the time of the log may be.
    static let readingAge: TimeInterval = 10 * 60

    /// Carbs logged with a hypo treatment tag, or logged while the reading was under `lowMgdl`,
    /// and no more than `maximumGrams`.
    static func isTreatment(_ meal: MealEntry, readings: GlucoseSeries, contexts: [ContextEvent]) -> Bool {
        guard meal.carbs > 0, meal.carbs <= maximumGrams else { return false }
        if UsualEntries.isHypoTreatment(meal, contexts: contexts) { return true }
        guard let reading = readings.slice(from: meal.timestamp.addingTimeInterval(-readingAge), through: meal.timestamp).last
        else { return false }
        return reading.mgdl < lowMgdl
    }
}
