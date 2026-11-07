import Foundation

// What the user logs by hand: insulin, food and (on a pump) infusion site changes.
// GlucOS only records these and shows them back. It never suggests or calculates a dose.

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

    var displayName: String { name.isEmpty ? kind.title : name }
}

struct MealEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    /// Grams of carbohydrate. 0 when the user only described the food.
    var carbs: Double
    var food: String = ""
    var note: String = ""
}

/// A pump infusion set (or patch pump) moved to a new site.
struct SiteChange: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp: Date
    var site: InjectionSite
    var note: String = ""
}

/// One row in the logbook, whatever its type.
enum LogEntry: Identifiable, Hashable {
    case dose(InsulinDose)
    case meal(MealEntry)
    case siteChange(SiteChange)

    var id: UUID {
        switch self {
        case .dose(let d): return d.id
        case .meal(let m): return m.id
        case .siteChange(let s): return s.id
        }
    }

    var timestamp: Date {
        switch self {
        case .dose(let d): return d.timestamp
        case .meal(let m): return m.timestamp
        case .siteChange(let s): return s.timestamp
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
