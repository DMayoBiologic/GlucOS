import Foundation

// Tidies the logbook before the engine learns from it or forecasts with it.
//
// The same meal sometimes gets logged twice: once on the iPhone at the table and again on the Mac
// later with the time set back, or twice from the same food list. Counted twice, the carbs push
// every forecast for the next three hours too high and halve the carb effect the learner fits
// (on 14 Nov 2026 one repeated 35.8 g breakfast was enough to stop the learnt carb effect passing
// its reliability check). Only the engine's view is tidied: the logbook itself is never changed.

enum LogCleanup {
    /// Two entries this close together can be one meal logged twice.
    static let duplicateWindow: TimeInterval = 45 * 60
    /// Their carbs must agree to within this share (or 1 g, whichever is more).
    static let carbTolerance = 0.1

    /// `meals` without repeats of the same meal. A repeat is a later entry within 45 minutes of a
    /// kept one, with the same food (same description, or the same foods picked from the list)
    /// and the same carbs to within 10%. The earliest entry is kept. Entries with no carbs are
    /// never merged, so a described-only meal still marks the food as uncounted.
    static func mealsWithoutRepeats(_ meals: [MealEntry]) -> [MealEntry] {
        guard meals.count > 1 else { return meals }
        var kept: [MealEntry] = []
        for meal in meals.sorted(by: { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }) {
            let repeated = kept.reversed().prefix { meal.timestamp.timeIntervalSince($0.timestamp) <= duplicateWindow }
                .contains { isRepeat(meal, of: $0) }
            if !repeated { kept.append(meal) }
        }
        return kept
    }

    static func isRepeat(_ a: MealEntry, of b: MealEntry) -> Bool {
        guard a.carbs > 0, b.carbs > 0, a.id != b.id,
              abs(a.timestamp.timeIntervalSince(b.timestamp)) <= duplicateWindow,
              abs(a.carbs - b.carbs) <= max(1, carbTolerance * max(a.carbs, b.carbs)) else { return false }
        return sameFood(a, b)
    }

    private static func sameFood(_ a: MealEntry, _ b: MealEntry) -> Bool {
        if let x = a.items, let y = b.items, !x.isEmpty, !y.isEmpty {
            return x.map(\.foodID).sorted() == y.map(\.foodID).sorted()
        }
        return normalised(a.food) == normalised(b.food)
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
