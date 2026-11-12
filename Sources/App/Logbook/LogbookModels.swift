import Foundation

// What the user logs by hand: insulin, food and (on a pump) infusion site changes.
// GlucOS records these and shows them back. The only dose it ever works out is the optional bolus
// calculator's (Sources/Engine/BolusCalculator.swift), from settings the user entered and
// confirmed, and the user always decides what to log.

/// How the user takes insulin. Decides what the log sheet asks for and which insights appear.
enum TherapyType: String, CaseIterable, Identifiable, Codable {
    case notSet
    case injections
    case pump
    case noInsulin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notSet: return "Not set"
        case .injections: return "Injections"
        case .pump: return "Insulin pump"
        case .noInsulin: return "I don't take insulin"
        }
    }

    var detail: String {
        switch self {
        case .notSet: return ""
        case .injections: return "Pens or syringes. Log each dose, the insulin and where you injected it."
        case .pump: return "Log boluses and food, and each time you change your infusion site."
        case .noInsulin: return "Log food only."
        }
    }

    var systemImage: String {
        switch self {
        case .notSet: return "questionmark.circle"
        case .injections: return "syringe"
        case .pump: return "cross.vial"
        case .noInsulin: return "fork.knife"
        }
    }

    var logsInsulin: Bool { self == .injections || self == .pump }
}

enum InsulinKind: String, CaseIterable, Identifiable, Codable {
    case rapid, ultraRapid, short, intermediate, long, premixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rapid: return "Rapid-acting"
        case .ultraRapid: return "Ultra-rapid"
        case .short: return "Short-acting"
        case .intermediate: return "Intermediate"
        case .long: return "Long-acting"
        case .premixed: return "Premixed"
        }
    }

    var examples: String {
        switch self {
        case .rapid: return "NovoRapid, Humalog, Apidra"
        case .ultraRapid: return "Fiasp, Lyumjev"
        case .short: return "Actrapid, Humulin R"
        case .intermediate: return "Protaphane, Humulin NPH"
        case .long: return "Optisulin, Lantus, Levemir, Toujeo, Tresiba"
        case .premixed: return "NovoMix, Humalog Mix"
        }
    }

    /// Mealtime / correction insulin: the doses whose effect shows up within hours and can be
    /// read off the glucose trace.
    var isBolus: Bool { self == .rapid || self == .ultraRapid || self == .short }

    /// Has a fast-acting part, so it moves glucose within hours (premixed included). Used to
    /// rule out examples where other insulin was still acting.
    var actsWithinHours: Bool { isBolus || self == .premixed }

    /// How long after a bolus GlucOS looks for the glucose response.
    var responseWindow: TimeInterval {
        switch self {
        case .ultraRapid: return 5 * 3600
        case .rapid: return 6 * 3600
        default: return 8 * 3600
        }
    }

    /// Kinds a pump delivers.
    static let pumpKinds: [InsulinKind] = [.rapid, .ultraRapid]
}

/// Broad body area. Insights group by area, since left/right rarely differ and per-side groups
/// would take twice as long to fill.
enum BodyArea: String, CaseIterable, Identifiable, Codable {
    case abdomen, arm, thigh, hip, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .abdomen: return "Abdomen"
        case .arm: return "Upper arm"
        case .thigh: return "Thigh"
        case .hip: return "Buttock / hip"
        case .other: return "Other"
        }
    }
}

enum InjectionSite: String, CaseIterable, Identifiable, Codable {
    case abdomenLeft, abdomenRight, armLeft, armRight, thighLeft, thighRight, hipLeft, hipRight, other

    var id: String { rawValue }

    var area: BodyArea {
        switch self {
        case .abdomenLeft, .abdomenRight: return .abdomen
        case .armLeft, .armRight: return .arm
        case .thighLeft, .thighRight: return .thigh
        case .hipLeft, .hipRight: return .hip
        case .other: return .other
        }
    }

    var side: String? {
        switch self {
        case .abdomenLeft, .armLeft, .thighLeft, .hipLeft: return "left"
        case .abdomenRight, .armRight, .thighRight, .hipRight: return "right"
        case .other: return nil
        }
    }

    var title: String {
        guard let side else { return area.title }
        return "\(area.title), \(side)"
    }
}

struct InsulinDose: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    var units: Double
    var kind: InsulinKind
    /// Brand name, e.g. "NovoRapid". Empty when not given.
    var name: String = ""
    /// Where it was injected. Nil for a pump bolus, whose site is the infusion site in use.
    var site: InjectionSite?
    var viaPump: Bool = false
    var note: String = ""
    /// The bolus calculator's working, when the user logged this dose from a suggestion.
    var calculation: BolusCalculation? = nil

    var displayName: String { name.isEmpty ? kind.title : name }
}

struct MealEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    /// Grams of carbohydrate. 0 when the user only described the food.
    var carbs: Double
    var food: String = ""
    var note: String = ""
    /// The foods picked from the food list, when the meal was built from it. `carbs` is what the
    /// user confirmed, which may differ from the items' total if they changed it.
    var items: [MealItem]? = nil
}

/// A pump infusion set (or patch pump) moved to a new site.
struct SiteChange: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    var site: InjectionSite
    var note: String = ""
}

/// Something going on that changes how glucose responds. Examples affected by a tag are set
/// aside from the main insights (or shown on their own), so they don't skew the typical figures.
enum ContextTag: String, CaseIterable, Identifiable, Codable {
    case exercise, illness, alcohol, stress, period, hypoTreatment, siteProblem
    /// When the user woke up. A marker, not something that skews examples: GlucOS learns the
    /// user's usual post-wake rise from it (`MorningPatternLearner`).
    case wokeUp
    /// When the user went to bed. Like a wake-up, it only marks a time.
    case bedtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exercise: return "Exercise"
        case .illness: return "Unwell"
        case .alcohol: return "Alcohol"
        case .stress: return "Stress"
        case .period: return "Period"
        case .hypoTreatment: return "Hypo treatment"
        case .siteProblem: return "Site or delivery problem"
        case .wokeUp: return "Woke up"
        case .bedtime: return "Went to sleep"
        }
    }

    var systemImage: String {
        switch self {
        case .exercise: return "figure.run"
        case .illness: return "thermometer.medium"
        case .alcohol: return "wineglass"
        case .stress: return "bolt.heart"
        case .period: return "calendar.circle"
        case .hypoTreatment: return "cube"
        case .siteProblem: return "bandage"
        case .wokeUp: return "sunrise"
        case .bedtime: return "bed.double"
        }
    }

    var help: String {
        switch self {
        case .exercise: return "Exercise can make insulin work harder and for longer, for hours afterwards."
        case .illness: return "Being unwell usually pushes glucose up and makes insulin less effective."
        case .alcohol: return "Alcohol can lower glucose for many hours, often overnight."
        case .stress: return "Stress hormones can push glucose up."
        case .period: return "Insulin needs often shift across the menstrual cycle."
        case .hypoTreatment: return "Fast sugar taken for a low. Counted like food."
        case .siteProblem: return "A bent cannula, leak or bad site means insulin may not have gone in properly."
        case .wokeUp: return "When you got up. Glucose often rises after waking; GlucOS learns how yours moves."
        case .bedtime: return "When you went to bed, so the night that follows can be told apart from the evening."
        }
    }

    /// How long before an example a tag can still affect it.
    var reach: TimeInterval {
        switch self {
        case .exercise: return 6 * 3600
        case .alcohol: return 12 * 3600
        case .illness, .stress, .period: return 24 * 3600
        case .hypoTreatment, .siteProblem, .wokeUp, .bedtime: return 0
        }
    }

    /// Tags whose examples are shown as their own rows rather than only set aside.
    var isComparable: Bool {
        switch self {
        case .exercise, .illness, .alcohol, .stress, .period: return true
        case .hypoTreatment, .siteProblem, .wokeUp, .bedtime: return false
        }
    }

    /// Tags that change how glucose responds, so examples near them are set aside or segmented.
    /// Waking up and going to sleep only mark a time.
    var affectsResponses: Bool { !isMoment }

    /// Logged as a moment of its own from the log sheet ("Woke up", "Going to sleep"), rather than
    /// picked from the list of things going on.
    var isMoment: Bool { self == .wokeUp || self == .bedtime }
}

/// Context logged at a time, on its own or alongside a dose or meal.
struct ContextEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    var tags: Set<ContextTag>
    var note: String = ""

    /// Tags in a stable order for display.
    var sortedTags: [ContextTag] { ContextTag.allCases.filter(tags.contains) }

    /// Marks when the user woke up.
    var isWake: Bool { tags.contains(.wokeUp) }

    init(id: UUID = UUID(), timestamp: Date, tags: Set<ContextTag>, note: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.tags = tags
        self.note = note
    }

    /// A tag from a newer version of GlucOS is skipped rather than failing the whole entry (and,
    /// in the logbook file, everything stored with it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        tags = Set(try c.decode([String].self, forKey: .tags).compactMap(ContextTag.init(rawValue:)))
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// One row in the logbook, whatever its type.
enum LogEntry: Identifiable, Hashable {
    case dose(InsulinDose)
    case meal(MealEntry)
    case siteChange(SiteChange)
    case context(ContextEvent)

    var id: UUID {
        switch self {
        case .dose(let d): return d.id
        case .meal(let m): return m.id
        case .siteChange(let s): return s.id
        case .context(let c): return c.id
        }
    }

    var timestamp: Date {
        switch self {
        case .dose(let d): return d.timestamp
        case .meal(let m): return m.timestamp
        case .siteChange(let s): return s.timestamp
        case .context(let c): return c.timestamp
        }
    }
}

/// Valid input ranges. Generous, just enough to catch a slipped decimal point.
enum LogLimits {
    static let units: ClosedRange<Double> = 0.05...100
    static let carbs: ClosedRange<Double> = 0...500
}

enum LogFormat {
    /// "4", "4.5", "0.35": no trailing zeros.
    static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func units(_ v: Double) -> String { "\(number(v)) u" }
    static func grams(_ v: Double) -> String { "\(number(v)) g" }

    /// "45 min", "3 h", "3 h 20 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60 / 5).rounded()) * 5
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Presets

/// A saved combination the user logs often ("Usual breakfast", "Hypo: 3 jelly beans"). Tapping one
/// fills the log sheet with exactly what the user saved. GlucOS never creates or changes the
/// amounts in a preset on its own.
struct LogPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var units: Double?
    var kind: InsulinKind?
    var insulinName: String = ""
    var carbs: Double?
    var food: String = ""
    var tags: Set<ContextTag> = []

    var hasInsulin: Bool { units != nil }
    var hasFood: Bool { (carbs ?? 0) > 0 || !food.isEmpty }

    var systemImage: String {
        if tags.contains(.hypoTreatment) { return ContextTag.hypoTreatment.systemImage }
        if hasInsulin && hasFood { return "takeoutbag.and.cup.and.straw" }
        if hasInsulin { return "syringe" }
        if hasFood { return "fork.knife" }
        return "tag"
    }

    /// "4 u · 45 g · Exercise".
    var summary: String {
        var parts: [String] = []
        if let units { parts.append(LogFormat.units(units)) }
        if let carbs, carbs > 0 { parts.append(LogFormat.grams(carbs)) }
        if !food.isEmpty, food != name { parts.append(food) }
        parts += ContextTag.allCases.filter(tags.contains).map(\.title)
        return parts.joined(separator: " · ")
    }
}

/// A food the user has logged before, offered again as a one-tap suggestion.
struct RecentFood: Identifiable, Hashable {
    let food: String
    let carbs: Double
    let count: Int
    var id: String { food.lowercased() }
}
