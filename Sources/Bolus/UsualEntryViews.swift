import SwiftUI

// The app side of one-tap repeats (Sources/Engine/UsualEntries.swift, docs/UsualEntries.md):
// what to offer from the logbook and the current reading, and the check before a repeat is logged.
// Shared by the Mac and iPhone log sheets.

extension LogbookStore {
    /// The usual entries to offer now, from this logbook and the latest reading.
    @MainActor
    func usualEntries(store: GlucoseStore, settings: AppSettings, now: Date = Date()) -> [UsualEntry] {
        UsualEntries.suggest(meals: meals, doses: doses, contexts: contexts, now: now,
                             glucose: UsualGlucose.current(store.snapshot, settings: settings, now: now),
                             logsInsulin: settings.therapy.logsInsulin)
    }

    /// Whether a one-tap fill is already in the logbook, as `RepeatCheck` words it. Nil when it isn't.
    func repeatWarning(at time: Date, bolusUnits: Double?, carbs: Double?, food: String,
                       hypoTreatment: Bool) -> String? {
        RepeatCheck.warning(at: time, units: bolusUnits, carbs: carbs, food: food, hypoTreatment: hypoTreatment,
                            doses: doses, meals: meals, contexts: contexts)
    }
}

extension UsualGlucose {
    /// The latest reading while it's fresh, with its measured rate. No reading (or a stale one)
    /// offers neither the low treatment first nor a correction.
    @MainActor
    static func current(_ snapshot: GlucoseSnapshot, settings: AppSettings, now: Date) -> UsualGlucose {
        let fresh = snapshot.current.flatMap { $0.age(at: now) <= GlucoseSnapshot.staleAfter ? $0 : nil }
        let readings = (snapshot.history + (snapshot.current.map { [$0] } ?? [])).sorted { $0.timestamp < $1.timestamp }
        return UsualGlucose(mgdl: fresh?.mgdl,
                            ratePerMinute: fresh == nil ? nil : BolusCalculator.ratePerMinute(readings, at: now),
                            lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl)
    }
}

extension UsualEntry {
    var tint: Color {
        switch kind {
        case .meal: return Palette.food
        case .correction: return Palette.insulin
        case .lowTreatment: return Tone.critical.textColor
        }
    }

    /// What VoiceOver says a tap does.
    var spokenHint: String {
        switch kind {
        case .meal: return "Fills in the food, then the dose step. Check it, then log."
        case .correction: return "Fills in the dose. Check it, then log."
        case .lowTreatment: return "Fills in the food as a hypo treatment. Check it, then log."
        }
    }

    /// Said once the sheet is filled, for VoiceOver.
    var filledAnnouncement: String { "Filled in \(spokenLabel). Check it, then log." }

    /// The foods from last time as new items, so the new meal doesn't share their ids.
    var freshItems: [MealItem] {
        (items ?? []).map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
    }

    /// The meal's name to put in the food field: none when it's only the foods' names, which the
    /// sheet makes from the items itself.
    var foodFieldText: String {
        let names = (items ?? []).map(\.name).joined(separator: ", ")
        return !names.isEmpty && food == names ? "" : food
    }
}

/// Posts a VoiceOver announcement.
enum UsualAnnouncer {
    static func say(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
