import Foundation

// One-tap repeats in the log sheets (docs/UsualEntries.md).
//
// Most of what someone logs is something they've logged before: the same breakfast most mornings,
// the same correction when they run high, the same jelly beans for a low. The log sheets offer
// those as one tap that fills the entry in, read from the user's own logbook. Every amount comes
// from an entry the user logged themselves (the latest one of that kind); GlucOS never makes one
// up. A meal never carries a dose: when the calculator is set up it works the dose out as usual,
// and otherwise the dose step offers the units the user took with that meal last time, for them to
// tap. Whatever was filled in, the entry still goes through the same checks before it's logged:
// `RepeatCheck` here, the calculator's own cautions, and its confirm step.

/// The part of the day a meal falls in, which names it ("Usual breakfast").
enum MealSlot: String, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack

    var title: String {
        switch self {
        case .breakfast: return "breakfast"
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case .snack: return "snack"
        }
    }

    /// Breakfast 5:00–10:59, lunch 11:00–14:59, dinner 17:00–21:59; anything else is a snack.
    static func at(_ date: Date, calendar: Calendar = .current) -> MealSlot {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<22: return .dinner
        default: return .snack
        }
    }
}

/// One thing the user logs often, ready to repeat.
struct UsualEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// The meal most often logged at this time of day.
        case meal(MealSlot)
        /// A fast-acting dose with no food near it.
        case correction
        /// What the user takes for a low.
        case lowTreatment
    }

    let kind: Kind
    /// What the food was called, as the user logged it. Empty for a correction, or for a meal
    /// logged as carbs only.
    let food: String
    /// Carbs from the latest time it was logged. 0 for a correction.
    let carbs: Double
    /// The foods picked from the food list the latest time, so the meal fills in the same way.
    let items: [MealItem]?
    /// A correction's units: the amount the user took most often (the latest, on a tie). For a meal,
    /// the units of the bolus logged with it the latest time, offered in the dose step and never
    /// filled in on its own. Nil when there's none.
    let units: Double?
    /// The insulin the units were taken with.
    let insulinKind: InsulinKind?
    let insulinName: String
    /// How many times it was logged in the look-back window.
    let count: Int
    /// The latest time.
    let lastLogged: Date

    var id: String {
        switch kind {
        case .meal(let slot): return "meal-\(slot.rawValue)"
        case .correction: return "correction"
        case .lowTreatment: return "low"
        }
    }

    /// "Usual breakfast", "Usual correction", "Treat a low".
    var title: String {
        switch kind {
        case .meal(let slot): return "Usual \(slot.title)"
        case .correction: return "Usual correction"
        case .lowTreatment: return "Treat a low"
        }
    }

    /// What it fills in: "Toast and banana · 45 g", "2 u NovoRapid", "Jelly beans · 15 g".
    var detail: String {
        switch kind {
        case .correction:
            guard let units else { return "" }
            let name = insulinName.isEmpty ? "" : " \(insulinName)"
            return LogFormat.units(units) + name
        case .meal, .lowTreatment:
            var bits: [String] = []
            if !food.isEmpty { bits.append(food) }
            if carbs > 0 { bits.append(LogFormat.grams(carbs)) }
            return bits.joined(separator: " · ")
        }
    }

    /// A short chip label for narrow places (the menu bar popover): what it is, not "Usual …".
    /// "Toast and banana", "45 g carbs", "Correction 2 u", "Treat a low".
    var shortTitle: String {
        switch kind {
        case .meal:
            if !food.isEmpty { return food }
            return carbs > 0 ? "\(LogFormat.grams(carbs)) carbs" : title
        case .correction:
            guard let units else { return "Correction" }
            return "Correction \(LogFormat.units(units))"
        case .lowTreatment:
            return title
        }
    }

    /// For VoiceOver: words, not symbols. "Usual breakfast: toast and banana, 45 grams of carbs".
    var spokenLabel: String {
        var bits: [String] = []
        switch kind {
        case .correction:
            if let units {
                bits.append("\(LogFormat.number(units)) \(units == 1 ? "unit" : "units")")
                if !insulinName.isEmpty { bits.append(insulinName) }
            }
        case .meal, .lowTreatment:
            if !food.isEmpty { bits.append(food) }
            if carbs > 0 { bits.append("\(LogFormat.number(carbs)) grams of carbs") }
        }
        return bits.isEmpty ? title : "\(title): " + bits.joined(separator: ", ")
    }

    var systemImage: String {
        switch kind {
        case .meal(let slot):
            switch slot {
            case .breakfast: return "sunrise"
            case .lunch: return "sun.max"
            case .dinner: return "moon"
            case .snack: return "carrot"
            }
        case .correction: return "syringe"
        case .lowTreatment: return ContextTag.hypoTreatment.systemImage
        }
    }
}

/// Where glucose is now, as far as the log sheet knows. All mg/dL.
struct UsualGlucose: Sendable {
    var mgdl: Double?
    /// mg/dL per minute, when measured.
    var ratePerMinute: Double?
    var lowMgdl: Double
    var highMgdl: Double

    /// Low now, or close to it and falling.
    var isLowOrHeadingLow: Bool {
        guard let mgdl else { return false }
        if mgdl < lowMgdl { return true }
        return mgdl < lowMgdl + 20 && (ratePerMinute ?? 0) <= -1
    }

    /// High, and not already on its way down fast.
    var isHigh: Bool {
        guard let mgdl else { return false }
        return mgdl >= highMgdl && (ratePerMinute ?? 0) > -2
    }
}

enum UsualEntries {
    /// How far back meals and corrections are read.
    static let lookBack: TimeInterval = 28 * 86400
    /// Lows are rarer, so their treatment is read from further back.
    static let lowLookBack: TimeInterval = 90 * 86400
    /// A meal has to be logged on this many different days in its slot to count as usual.
    static let mealMinimumDays = 3
    /// The same correction this many times.
    static let correctionMinimum = 3
    /// The same low treatment this many times.
    static let lowMinimum = 2
    /// Food this close to a hypo treatment tag is what was taken for the low.
    static let hypoFoodGap: TimeInterval = 10 * 60
    /// A bolus this close to a meal was for it.
    static let mealDoseGap: TimeInterval = 20 * 60
    /// No usual correction is offered within this long of the last bolus.
    static let correctionQuietTime: TimeInterval = 60 * 60

    /// What to offer now, most useful first. During (or heading into) a low only the low treatment
    /// and the usual meal are offered, the low treatment first; a correction is offered only while
    /// glucose is high and no bolus was logged in the last hour.
    static func suggest(meals: [MealEntry], doses: [InsulinDose], contexts: [ContextEvent], now: Date,
                        glucose: UsualGlucose, logsInsulin: Bool, calendar: Calendar = .current) -> [UsualEntry] {
        let hypoMeals = meals.filter { isHypoTreatment($0, contexts: contexts) }
        let hypoIDs = Set(hypoMeals.map(\.id))
        let ordinary = meals.filter { !hypoIDs.contains($0.id) }

        var out: [UsualEntry] = []
        let low = glucose.isLowOrHeadingLow
        if low, let t = lowTreatment(hypoMeals, now: now) { out.append(t) }
        if let meal = usualMeal(ordinary, doses: doses, now: now, calendar: calendar) { out.append(meal) }
        if !low, logsInsulin, glucose.isHigh,
           !doses.contains(where: { $0.kind.isBolus && $0.timestamp <= now && now.timeIntervalSince($0.timestamp) < correctionQuietTime }),
           let c = usualCorrection(doses: doses, meals: meals, contexts: contexts, now: now) {
            out.append(c)
        }
        return out
    }

    // MARK: Meals

    /// A name to group meals by: case, spaces and punctuation at the ends don't matter.
    static func key(_ food: String) -> String {
        food.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// The key for a meal: its name, or its carbs when it has no name.
    private static func key(_ m: MealEntry) -> String? {
        let name = key(m.food)
        if !name.isEmpty { return name }
        return m.carbs > 0 ? "carbs:\(LogFormat.number(m.carbs))" : nil
    }

    /// Meals by their key; meals with neither a name nor carbs are left out.
    private static func grouped(_ meals: [MealEntry]) -> [String: [MealEntry]] {
        var out: [String: [MealEntry]] = [:]
        for m in meals {
            if let k = key(m) { out[k, default: []].append(m) }
        }
        return out
    }

    /// The meal logged on the most days in the slot `now` is in. Ties go to the latest.
    static func usualMeal(_ meals: [MealEntry], doses: [InsulinDose], now: Date,
                          calendar: Calendar = .current) -> UsualEntry? {
        let slot = MealSlot.at(now, calendar: calendar)
        let since = now.addingTimeInterval(-lookBack)
        let inSlot = meals.filter {
            $0.timestamp >= since && $0.timestamp <= now && MealSlot.at($0.timestamp, calendar: calendar) == slot
        }
        let ranked = grouped(inSlot).values.compactMap { rows -> (days: Int, latest: MealEntry, count: Int)? in
            let days = Set(rows.map { calendar.startOfDay(for: $0.timestamp) }).count
            guard days >= mealMinimumDays, let latest = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return (days: days, latest: latest, count: rows.count)
        }
        guard let best = ranked.max(by: { a, b in
            a.days != b.days ? a.days < b.days : a.latest.timestamp < b.latest.timestamp
        }) else { return nil }
        let m = best.latest
        let dose = doses.filter { $0.kind.isBolus && abs($0.timestamp.timeIntervalSince(m.timestamp)) <= mealDoseGap }
            .min { abs($0.timestamp.timeIntervalSince(m.timestamp)) < abs($1.timestamp.timeIntervalSince(m.timestamp)) }
        return UsualEntry(kind: .meal(slot), food: displayName(m), carbs: m.carbs, items: m.items,
                          units: dose?.units, insulinKind: dose?.kind, insulinName: dose?.name ?? "",
                          count: best.count, lastLogged: m.timestamp)
    }

    /// The meal's name as logged, or its foods' names when it was built from the list.
    private static func displayName(_ m: MealEntry) -> String {
        let name = m.food.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return (m.items ?? []).map(\.name).joined(separator: ", ")
    }

    // MARK: Lows

    /// Food logged with (or within ten minutes of) a hypo treatment tag.
    static func isHypoTreatment(_ m: MealEntry, contexts: [ContextEvent]) -> Bool {
        contexts.contains {
            $0.tags.contains(.hypoTreatment) && abs($0.timestamp.timeIntervalSince(m.timestamp)) <= hypoFoodGap
        }
    }

    /// The treatment taken most often for a low. Ties go to the latest.
    static func lowTreatment(_ hypoMeals: [MealEntry], now: Date) -> UsualEntry? {
        let since = now.addingTimeInterval(-lowLookBack)
        let recent = hypoMeals.filter { $0.timestamp >= since && $0.timestamp <= now }
        guard let best = grouped(recent).values.compactMap({ rows -> (count: Int, latest: MealEntry)? in
            guard rows.count >= lowMinimum, let latest = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return (count: rows.count, latest: latest)
        }).max(by: { a, b in a.count != b.count ? a.count < b.count : a.latest.timestamp < b.latest.timestamp }) else {
            return nil
        }
        let m = best.latest
        return UsualEntry(kind: .lowTreatment, food: displayName(m), carbs: m.carbs, items: m.items,
                          units: nil, insulinKind: nil, insulinName: "", count: best.count, lastLogged: m.timestamp)
    }

    // MARK: Corrections

    /// A fast-acting dose with no food or hypo treatment near it, that wasn't marked as for a meal and
    /// wasn't worked out by the calculator for carbs.
    static func isCorrection(_ d: InsulinDose, meals: [MealEntry], contexts: [ContextEvent]) -> Bool {
        guard d.kind.isBolus, d.units >= DoseMealCheck.minimumUnits, d.purpose != .meal else { return false }
        if let c = d.calculation, c.carbs > 0 { return false }
        if d.purpose == .correction { return true }
        let t = d.timestamp
        if meals.contains(where: { abs($0.timestamp.timeIntervalSince(t)) <= DoseMealCheck.foodGap }) { return false }
        return !contexts.contains {
            $0.tags.contains(.hypoTreatment) && abs($0.timestamp.timeIntervalSince(t)) <= DoseMealCheck.foodGap
        }
    }

    /// The correction amount taken most often. Ties go to the latest.
    static func usualCorrection(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                                now: Date) -> UsualEntry? {
        let since = now.addingTimeInterval(-lookBack)
        let corrections = doses.filter {
            $0.timestamp >= since && $0.timestamp <= now && isCorrection($0, meals: meals, contexts: contexts)
        }
        guard corrections.count >= correctionMinimum else { return nil }
        let groups = Dictionary(grouping: corrections) { ($0.units * 100).rounded() }
        guard let best = groups.values.compactMap({ rows -> (count: Int, latest: InsulinDose)? in
            guard let latest = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return (count: rows.count, latest: latest)
        }).max(by: { a, b in a.count != b.count ? a.count < b.count : a.latest.timestamp < b.latest.timestamp }) else {
            return nil
        }
        let d = best.latest
        return UsualEntry(kind: .correction, food: "", carbs: 0, items: nil, units: d.units, insulinKind: d.kind,
                          insulinName: d.name, count: best.count, lastLogged: d.timestamp)
    }
}

extension UsualEntries {
    /// What a log sheet opened from a picked usual fills in. `shown` is the entry the menu, popover
    /// row or chip displayed, `pickedID` the id a widget link carried, `offered` what the sheet
    /// offers now.
    ///
    /// A meal or low treatment fills in exactly as it was shown, even if the time-of-day slot rolled
    /// over between showing it and the pick (a breakfast shown at 10:59 and picked at 11:00 still
    /// fills breakfast). A correction carries units, so it only fills while one is still offered now:
    /// if glucose came down in the meantime, the sheet opens unfilled. An id alone matches only what
    /// is offered now. Nothing here logs anything: the sheet still waits for Log and `RepeatCheck`.
    static func startingFill(shown: UsualEntry?, pickedID: String?, offered: [UsualEntry]) -> UsualEntry? {
        if let shown {
            switch shown.kind {
            case .meal, .lowTreatment: return shown
            case .correction: return offered.contains { $0.kind == .correction } ? shown : nil
            }
        }
        guard let pickedID else { return nil }
        return offered.first { $0.id == pickedID }
    }
}

// MARK: - Logged twice?

/// The check every one-tap fill (a usual entry, a preset, "same as last") goes through before it's
/// logged: is it already in the logbook? A meal logged on the Mac and again on the iPhone, or a dose
/// tapped in twice, is the double dose PR #54 guards the calculator against; this covers entries
/// that didn't come from the calculator, and a second low treatment before the first has had time.
enum RepeatCheck {
    /// Doses and meals this close to the entry's time may be the same one.
    static let window: TimeInterval = 45 * 60
    /// Carbs within this share of each other count as about the same.
    static let carbShare = 0.10
    /// A low treatment within this long of another one.
    static let lowWait: TimeInterval = 15 * 60

    /// What to tell the user before logging, or nil when nothing looks repeated. `units` is a
    /// fast-acting dose being logged; `carbs` and `food` the food; `hypoTreatment` whether the entry
    /// is tagged as treating a low. `now` decides whether "ago" or "earlier" reads right.
    static func warning(at time: Date, units: Double?, carbs: Double?, food: String, hypoTreatment: Bool,
                        doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                        now: Date = Date()) -> String? {
        var found: [String] = []
        if hypoTreatment, let last = contexts.filter({
            $0.tags.contains(.hypoTreatment) && $0.timestamp <= time && time.timeIntervalSince($0.timestamp) < lowWait
        }).max(by: { $0.timestamp < $1.timestamp }) {
            return "You logged a hypo treatment \(when(last.timestamp, from: time, now: now)). Fast sugar takes about 15 minutes to work: check again before taking more."
        }
        if let units, units > 0, let d = nearest(doses.filter(\.kind.isBolus), to: time) {
            found.append("\(LogFormat.units(d.units)) \(when(d.timestamp, from: time, now: now))")
        }
        let name = UsualEntries.key(food)
        if (carbs ?? 0) > 0 || !name.isEmpty, let m = nearest(meals.filter { m in
            if !name.isEmpty && UsualEntries.key(m.food) == name { return true }
            guard let c = carbs, c >= 5, m.carbs >= 5 else { return false }
            return abs(m.carbs - c) <= carbShare * max(m.carbs, c)
        }, to: time) {
            let what = m.food.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = what.isEmpty ? LogFormat.grams(m.carbs) : (m.carbs > 0 ? "\(what) (\(LogFormat.grams(m.carbs)))" : what)
            found.append("\(label) \(when(m.timestamp, from: time, now: now))")
        }
        guard !found.isEmpty else { return nil }
        let what = units != nil && (carbs ?? 0) > 0 ? "meal or dose" : units != nil ? "dose" : "meal"
        return "You logged " + found.joined(separator: " and ") + ". If it's the same \(what), don't log it again."
    }

    private static func nearest<T: TimedEntry>(_ entries: [T], to time: Date) -> T? {
        entries.filter { abs($0.timestamp.timeIntervalSince(time)) <= window }
            .min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }
    }

    /// "12 minutes ago" when the entry is for now; "12 minutes earlier" or "later" otherwise.
    static func when(_ t: Date, from time: Date, now: Date) -> String {
        let minutes = Int((abs(time.timeIntervalSince(t)) / 60).rounded())
        if minutes == 0 { return abs(time.timeIntervalSince(now)) < 120 ? "just now" : "at the same time" }
        let span = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if abs(time.timeIntervalSince(now)) < 120 { return t <= time ? "\(span) ago" : "\(span) from now" }
        return t <= time ? "\(span) earlier" : "\(span) later"
    }
}

/// Anything in the logbook with a time.
protocol TimedEntry { var timestamp: Date { get } }
extension InsulinDose: TimedEntry {}
extension MealEntry: TimedEntry {}

extension UsualGlance {
    /// The entry as the Your usual widget draws it (Sources/Shared/WidgetGlance.swift).
    init(_ u: UsualEntry, now: Date = Date(), calendar: Calendar = .current) {
        let kind: Kind
        var until: Date?
        switch u.kind {
        case .meal(let slot):
            kind = .meal
            until = slot.end(after: now, calendar: calendar)
        case .correction: kind = .correction
        case .lowTreatment: kind = .low
        }
        self.init(id: u.id, kind: kind, title: u.title, detail: u.detail, systemImage: u.systemImage,
                  spoken: u.spokenLabel, until: until)
    }
}

extension MealSlot {
    /// The first hour after `now` that falls in another part of the day: 11:00 for breakfast. Nil
    /// if `now` isn't in this part at all.
    func end(after now: Date, calendar: Calendar = .current) -> Date? {
        guard MealSlot.at(now, calendar: calendar) == self,
              var hour = calendar.dateInterval(of: .hour, for: now)?.start else { return nil }
        for _ in 0..<24 {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { return nil }
            hour = next
            if MealSlot.at(hour, calendar: calendar) != self { return hour }
        }
        return nil
    }
}
