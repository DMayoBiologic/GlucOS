import Foundation

/// One part of a log entry. The cases are in the order the log sheets show them: what you ate
/// comes first, then the dose for it, so the carbs feed straight into the insulin step below.
enum LogPart: String, CaseIterable, Identifiable, Sendable {
    case food, insulin, site, event

    var id: String { rawValue }
}

/// What the user is doing when they open the log sheet. The sheet asks this first ("What's
/// happening?") rather than which kind of record to make: each moment turns on the part of the
/// entry it needs, or (waking up, going to sleep) is the whole entry by itself.
enum LogMoment: String, CaseIterable, Identifiable, Sendable {
    case eating, bolus, basal, newSite, wokeUp, bedtime, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eating: return "Eating"
        case .bolus: return "Bolus"
        case .basal: return "Basal"
        case .newSite: return "New site"
        case .wokeUp: return "Woke up"
        case .bedtime: return "Going to sleep"
        case .other: return "Something else"
        }
    }

    /// One line under the question, for the moment that was picked last.
    var detail: String {
        switch self {
        case .eating: return "Food and carbs, then the dose for them"
        case .bolus: return "Mealtime or correction insulin"
        case .basal: return "Background (long-acting) insulin"
        case .newSite: return "A new pump infusion site"
        case .wokeUp: return "Marks when you got up"
        case .bedtime: return "Marks when you went to bed"
        case .other: return "Exercise, unwell, alcohol, a hypo treatment…"
        }
    }

    var systemImage: String {
        switch self {
        case .eating: return "fork.knife"
        case .bolus: return "syringe"
        case .basal: return "moon.stars"
        case .newSite: return "arrow.triangle.2.circlepath"
        case .wokeUp: return ContextTag.wokeUp.systemImage
        case .bedtime: return ContextTag.bedtime.systemImage
        case .other: return "ellipsis.circle"
        }
    }

    /// The part of the entry this moment opens. Waking up and going to sleep have none: the
    /// moment and its time are the entry.
    var part: LogPart? {
        switch self {
        case .eating: return .food
        case .bolus, .basal: return .insulin
        case .newSite: return .site
        case .other: return .event
        case .wokeUp, .bedtime: return nil
        }
    }

    /// The tag a moment without a part is stored as.
    var tag: ContextTag? {
        switch self {
        case .wokeUp: return .wokeUp
        case .bedtime: return .bedtime
        default: return nil
        }
    }
}

/// A step the log sheet offers once one part is filled in, so a meal and its dose read as one flow.
enum LogNextStep: Equatable, Sendable {
    /// Food with carbs is being logged and no dose yet.
    case addInsulin(carbs: Double)
    /// A mealtime dose is being logged with no food.
    case addFood
}

/// The rules both log sheets (Mac and iPhone) share for what to show and in what order. Plain
/// Foundation, so it's unit-tested. It never works out an amount: that's only the bolus calculator.
enum LogFlow {
    /// The parts someone can log, in the order they're shown.
    static func parts(logsInsulin: Bool, pump: Bool) -> [LogPart] {
        LogPart.allCases.filter { part in
            switch part {
            case .food, .event: return true
            case .insulin: return logsInsulin
            case .site: return pump
            }
        }
    }

    /// The moments someone can pick, in the order they're shown. Basal doses are for injections:
    /// a pump delivers its own.
    static func moments(logsInsulin: Bool, pump: Bool) -> [LogMoment] {
        LogMoment.allCases.filter { m in
            switch m {
            case .eating, .wokeUp, .bedtime, .other: return true
            case .bolus: return logsInsulin
            case .basal: return logsInsulin && !pump
            case .newSite: return pump
            }
        }
    }

    /// Whether a moment is part of the entry being built. `mealtimeDose` is whether the dose is a
    /// mealtime or correction one, which tells Bolus from Basal.
    static func isOn(_ moment: LogMoment, parts: Set<LogPart>, mealtimeDose: Bool, tags: Set<ContextTag>) -> Bool {
        switch moment {
        case .eating: return parts.contains(.food)
        case .bolus: return parts.contains(.insulin) && mealtimeDose
        case .basal: return parts.contains(.insulin) && !mealtimeDose
        case .newSite: return parts.contains(.site)
        case .other: return parts.contains(.event)
        case .wokeUp: return tags.contains(.wokeUp)
        case .bedtime: return tags.contains(.bedtime)
        }
    }

    /// The tags after tapping Woke up or Going to sleep: on or off, and never both at once.
    static func toggling(_ tag: ContextTag, in tags: Set<ContextTag>) -> Set<ContextTag> {
        var out = tags
        if out.contains(tag) {
            out.remove(tag)
        } else {
            if tag.isMoment { out = out.filter { !$0.isMoment } }
            out.insert(tag)
        }
        return out
    }

    /// The picked parts in the order they're shown, whatever order they were picked in.
    static func ordered(_ picked: Set<LogPart>, available: [LogPart]) -> [LogPart] {
        available.filter(picked.contains)
    }

    /// The part to bring into view after the picked parts change: the first one just added.
    static func focusPart(from old: Set<LogPart>, to new: Set<LogPart>, available: [LogPart]) -> LogPart? {
        ordered(new.subtracting(old), available: available).first
    }

    /// What to offer next. `carbs` is what the food part holds; `mealtimeDose` is true while the
    /// dose is a mealtime or correction one (not a basal).
    static func nextStep(picked: Set<LogPart>, available: [LogPart], carbs: Double,
                         mealtimeDose: Bool) -> LogNextStep? {
        let shown = Set(ordered(picked, available: available))
        if shown.contains(.food), !shown.contains(.insulin), available.contains(.insulin), carbs > 0 {
            return .addInsulin(carbs: carbs)
        }
        if shown.contains(.insulin), !shown.contains(.food), available.contains(.food), mealtimeDose {
            return .addFood
        }
        return nil
    }

    /// The Log button's words: "Log 45 g + 4 u", "Log Exercise", or just "Log". Each argument is
    /// nil (or empty) when that part isn't being logged or isn't valid yet.
    static func summary(carbs: Double?, foodName: String = "", units: Double?, newSite: Bool = false,
                        events: [String] = []) -> String {
        var bits: [String] = []
        if let carbs {
            let name = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
            bits.append(carbs > 0 ? LogFormat.grams(carbs) : (name.isEmpty ? "food" : name))
        }
        if let units { bits.append(LogFormat.units(units)) }
        if newSite { bits.append("new site") }
        if events.count == 1 { bits.append(events[0]) } else if events.count > 1 { bits.append("\(events.count) events") }
        return bits.isEmpty ? "Log" : "Log " + bits.joined(separator: " + ")
    }

    /// What's still needed before the entry can be logged, in the order the parts are shown.
    static func missing(picked: Set<LogPart>, available: [LogPart], foodValid: Bool, unitsValid: Bool,
                        hasEvents: Bool) -> String? {
        let shown = ordered(picked, available: available)
        // Waking up or going to sleep is an entry by itself.
        if shown.isEmpty { return hasEvents ? nil : "Choose what's happening" }
        for part in shown {
            switch part {
            case .food where !foodValid: return "Add a food or its carbs"
            case .insulin where !unitsValid: return "Enter the units"
            case .event where !hasEvents: return "Pick what's going on"
            default: continue
            }
        }
        return nil
    }
}
