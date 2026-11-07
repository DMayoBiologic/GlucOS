import Foundation

// Observed patterns from the user's own logs and readings. Descriptive only: nothing here
// suggests, calculates or adjusts a dose, ratio or pump setting. Every figure needs a minimum
// number of clean examples before it's shown.

enum InsightRules {
    /// Clean examples needed before any figure is shown.
    static let minimumEvents = 3
    /// A dose or meal needs a reading this close to it to know the starting glucose.
    static let startTolerance: TimeInterval = 10 * 60
    /// Longest gap in readings allowed inside a response window.
    static let maxGap: TimeInterval = 40 * 60
    /// Share of 15-minute periods in a window that must have a reading.
    static let minCoverage = 0.7
    /// A correction needs no other bolus this long before it (that insulin would still be working).
    static let priorBolusGap: TimeInterval = 3 * 3600
    /// …and no food this long before it.
    static let priorMealGap: TimeInterval = 90 * 60
    /// A correction window cut short (by food or another bolus) must still be at least this long.
    static let minimumCorrectionWindow: TimeInterval = 3 * 3600
    /// Below this drop the low point is noise, so no timing is read from it.
    static let measurableDrop = 18.0          // 1 mmol/L
    /// "Starts working": glucose 0.5 mmol/L below where it started.
    static let onsetDrop = 9.0
    /// The low point must come at least this long before the window ends, or the fall hadn't finished.
    static let settledBeforeEnd: TimeInterval = 20 * 60

    static let mealWindow: TimeInterval = 3 * 3600
    static let minimumMealWindow: TimeInterval = 2 * 3600
    static let minimumCarbs = 5.0
    /// Food logged this close together counts as one meal.
    static let mealGrouping: TimeInterval = 20 * 60
    /// A meal needs no other food this long before it.
    static let priorFoodGap: TimeInterval = 2 * 3600
    /// Insulin this close to a meal counts as taken with it.
    static let withMealGap: TimeInterval = 30 * 60

    static let curveStep = 15   // minutes
}

/// Glucose change from the starting value, `minutes` after a dose or meal.
struct CurvePoint: Hashable {
    let minutes: Int
    let change: Double   // mg/dL
}

/// Median and interquartile range of a set of observations.
struct Spread: Hashable {
    let median: Double
    let lower: Double   // 25th percentile
    let upper: Double   // 75th percentile
    let count: Int

    static func of(_ values: [Double], minimum: Int = InsightRules.minimumEvents) -> Spread? {
        guard values.count >= minimum else { return nil }
        let s = values.sorted()
        return Spread(median: GlucoseAnalytics.quantile(s, 0.5),
                      lower: GlucoseAnalytics.quantile(s, 0.25),
                      upper: GlucoseAnalytics.quantile(s, 0.75),
                      count: s.count)
    }
}

/// What glucose did after a bolus taken without food.
struct DoseResponse: Identifiable, Hashable {
    let dose: InsulinDose
    let area: BodyArea?
    let startMgdl: Double
    let lowestMgdl: Double
    let timeToLowest: TimeInterval
    /// Time until glucose was 0.5 mmol/L below the start. Nil when it never got there.
    let onset: TimeInterval?
    let curve: [CurvePoint]
    /// Context logged around it (exercise, illness…). Tagged examples are kept out of the main figures.
    var tags: Set<ContextTag> = []

    var id: UUID { dose.id }
    var drop: Double { startMgdl - lowestMgdl }
    var dropPerUnit: Double { drop / dose.units }
    /// Clear enough fall to read timings from.
    var isMeasurable: Bool { drop >= InsightRules.measurableDrop }
}

/// What glucose did after a meal.
struct MealResponse: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let carbs: Double
    let startMgdl: Double
    let peakMgdl: Double
    let timeToPeak: TimeInterval
    /// Bolus insulin logged within 30 minutes of the meal, if any.
    let insulinUnits: Double?
    let curve: [CurvePoint]
    var tags: Set<ContextTag> = []

    var rise: Double { peakMgdl - startMgdl }
    var risePer10g: Double { rise / carbs * 10 }
}

struct DoseSummary: Identifiable, Hashable {
    /// Nil for all areas together.
    let area: BodyArea?
    /// Set for a row of examples with this context.
    var tag: ContextTag? = nil
    let examples: Int
    /// Examples with a clear enough fall to read timings from.
    let measurable: Int
    let timeToLowest: Spread?
    let onset: Spread?
    let dropPerUnit: Spread?
    let curve: [CurvePoint]

    var id: String { tag.map { "tag-\($0.rawValue)" } ?? area?.rawValue ?? "all" }
    var title: String {
        if let tag { return "With \(tag.title.lowercased())" }
        return area?.title ?? "All sites"
    }
}

struct MealSummary: Hashable {
    let examples: Int
    let rise: Spread?
    let timeToPeak: Spread?
    let risePer10g: Spread?
    let curve: [CurvePoint]
}

/// Glucose by day of infusion-site wear (pump only).
struct SiteAgeBucket: Identifiable, Hashable {
    /// 1, 2, 3, or 4 for "day 4 or later".
    let day: Int
    let meanMgdl: Double
    let timeInRange: Double
    let readings: Int
    let sites: Int

    var id: Int { day }
    var title: String { day >= 4 ? "Day 4+" : "Day \(day)" }
}

struct LogInsights {
    /// Bolus doses logged in the analysed period.
    let bolusCount: Int
    /// Boluses without food that had clean enough data to use and no context tags.
    let corrections: [DoseResponse]
    let overall: DoseSummary
    /// Areas with at least one clean example, most examples first.
    let byArea: [DoseSummary]
    /// Clean examples with a context tag, kept out of the figures above.
    let correctionsSetAside: Int
    /// One row per comparable tag (exercise, illness…) that has examples.
    let byTag: [DoseSummary]

    let mealCount: Int
    /// Untagged meals with clean enough data to use.
    let mealResponses: [MealResponse]
    let mealsSetAside: Int
    let mealsWithInsulin: MealSummary
    let mealsWithoutInsulin: MealSummary

    let siteAge: [SiteAgeBucket]

    static func compute(readings: [GlucoseReading], doses: [InsulinDose], meals rawMeals: [MealEntry],
                        siteChanges: [SiteChange], contexts: [ContextEvent], low: Double, high: Double,
                        siteOf: (InsulinDose) -> InjectionSite?, now: Date = Date()) -> LogInsights {
        let start = readings.first?.timestamp ?? now
        let boluses = doses.filter { $0.kind.isBolus && $0.timestamp >= start }
        let mealsInPeriod = rawMeals.filter { $0.timestamp >= start }
        // A hypo treatment is food as far as the glucose trace is concerned.
        let meals = (rawMeals + contexts.filter { $0.tags.contains(.hypoTreatment) }
            .map { MealEntry(id: $0.id, timestamp: $0.timestamp, carbs: 0) })
            .sorted { $0.timestamp < $1.timestamp }

        var allCorrections: [DoseResponse] = []
        for dose in boluses {
            guard var r = correctionResponse(dose, readings: readings, doses: doses, meals: meals,
                                             area: siteOf(dose)?.area) else { continue }
            r.tags = tags(around: dose.timestamp, through: dose.timestamp.addingTimeInterval(dose.kind.responseWindow),
                          in: contexts)
            allCorrections.append(r)
        }
        let corrections = allCorrections.filter { $0.tags.isEmpty }
        let byTag = ContextTag.allCases.filter(\.isComparable).compactMap { tag -> DoseSummary? in
            let tagged = allCorrections.filter { $0.tags.contains(tag) }
            guard !tagged.isEmpty else { return nil }
            var s = summarize(tagged, area: nil)
            s.tag = tag
            return s
        }

        // Doses with no recorded site count towards "All sites" only.
        let areas = Dictionary(grouping: corrections.filter { $0.area != nil }) { $0.area ?? .other }
        let byArea = areas.map { summarize($0.value, area: $0.key) }
            .sorted { $0.examples != $1.examples ? $0.examples > $1.examples : $0.title < $1.title }

        let allMeals = groupMeals(mealsInPeriod).compactMap { meal -> MealResponse? in
            guard var r = mealResponse(meal, readings: readings, doses: doses, meals: meals) else { return nil }
            r.tags = tags(around: meal.timestamp, through: meal.timestamp.addingTimeInterval(InsightRules.mealWindow),
                          in: contexts)
            return r
        }
        let mealResponses = allMeals.filter { $0.tags.isEmpty }

        return LogInsights(
            bolusCount: boluses.count,
            corrections: corrections,
            overall: summarize(corrections, area: nil),
            byArea: byArea,
            correctionsSetAside: allCorrections.count - corrections.count,
            byTag: byTag,
            mealCount: mealsInPeriod.count,
            mealResponses: mealResponses,
            mealsSetAside: allMeals.count - mealResponses.count,
            mealsWithInsulin: summarize(mealResponses.filter { $0.insulinUnits != nil }),
            mealsWithoutInsulin: summarize(mealResponses.filter { $0.insulinUnits == nil }),
            siteAge: siteAge(readings: readings, siteChanges: siteChanges, low: low, high: high, now: now)
        )
    }

    /// Tags that could affect an example running from `start` to `end`. Hypo treatments are
    /// left out: they're handled as food (the window ends at them, or the example is skipped).
    static func tags(around start: Date, through end: Date, in contexts: [ContextEvent]) -> Set<ContextTag> {
        var out = Set<ContextTag>()
        for c in contexts where c.timestamp <= end {
            for tag in c.tags where tag != .hypoTreatment && c.timestamp >= start.addingTimeInterval(-tag.reach) {
                out.insert(tag)
            }
        }
        return out
    }

    // MARK: Corrections

    static func correctionResponse(_ dose: InsulinDose, readings: [GlucoseReading],
                                   doses: [InsulinDose], meals: [MealEntry], area: BodyArea?) -> DoseResponse? {
        guard dose.units > 0 else { return nil }
        let t0 = dose.timestamp

        // Nothing else acting at the start: no recent bolus, no recent or simultaneous food.
        let otherBoluses = doses.filter { $0.id != dose.id && $0.kind.actsWithinHours }
        if otherBoluses.contains(where: { $0.timestamp <= t0 && t0.timeIntervalSince($0.timestamp) < InsightRules.priorBolusGap }) {
            return nil
        }
        // Any food counts here, even without carbs entered.
        let food = meals
        if food.contains(where: { $0.timestamp <= t0.addingTimeInterval(InsightRules.withMealGap)
                                  && t0.timeIntervalSince($0.timestamp) < InsightRules.priorMealGap }) {
            return nil
        }

        // The window ends at the next food or bolus, whichever comes first.
        var end = t0.addingTimeInterval(dose.kind.responseWindow)
        if let next = otherBoluses.first(where: { $0.timestamp > t0 })?.timestamp { end = min(end, next) }
        if let next = food.first(where: { $0.timestamp > t0 })?.timestamp { end = min(end, next) }
        guard end.timeIntervalSince(t0) >= InsightRules.minimumCorrectionWindow else { return nil }

        guard let w = ResponseWindow(readings: readings, start: t0, end: end) else { return nil }
        guard let lowest = w.points.min(by: { $0.mgdl < $1.mgdl }) else { return nil }
        // Still falling when the window closed: the full effect wasn't seen.
        guard lowest.date <= end.addingTimeInterval(-InsightRules.settledBeforeEnd) else { return nil }

        let onset = w.points.first { $0.mgdl <= w.startMgdl - InsightRules.onsetDrop }
            .map { $0.date.timeIntervalSince(t0) }

        return DoseResponse(dose: dose, area: area, startMgdl: w.startMgdl, lowestMgdl: lowest.mgdl,
                            timeToLowest: lowest.date.timeIntervalSince(t0), onset: onset, curve: w.curve)
    }

    static func summarize(_ responses: [DoseResponse], area: BodyArea?) -> DoseSummary {
        let measurable = responses.filter(\.isMeasurable)
        return DoseSummary(area: area,
                           examples: responses.count,
                           measurable: measurable.count,
                           timeToLowest: Spread.of(measurable.map(\.timeToLowest)),
                           onset: Spread.of(measurable.compactMap(\.onset)),
                           dropPerUnit: Spread.of(responses.map(\.dropPerUnit)),
                           curve: medianCurve(responses.map(\.curve)))
    }

    // MARK: Meals

    /// Food logged within a few minutes is one meal: earliest time, carbs added up.
    static func groupMeals(_ meals: [MealEntry]) -> [MealEntry] {
        var out: [MealEntry] = []
        for m in meals.sorted(by: { $0.timestamp < $1.timestamp }) where m.carbs > 0 {
            if let last = out.last, m.timestamp.timeIntervalSince(last.timestamp) <= InsightRules.mealGrouping {
                out[out.count - 1].carbs += m.carbs
            } else {
                out.append(m)
            }
        }
        return out
    }

    static func mealResponse(_ meal: MealEntry, readings: [GlucoseReading],
                             doses: [InsulinDose], meals: [MealEntry]) -> MealResponse? {
        guard meal.carbs >= InsightRules.minimumCarbs else { return nil }
        let t0 = meal.timestamp
        let food = meals
        // Earlier food still being absorbed.
        if food.contains(where: { $0.timestamp < t0 && t0.timeIntervalSince($0.timestamp) < InsightRules.priorFoodGap }) {
            return nil
        }
        let boluses = doses.filter { $0.kind.actsWithinHours }
        // A bolus shortly before the meal would already be pulling glucose down, which is fine
        // (it's the meal's insulin), but one from earlier still acting isn't.
        if boluses.contains(where: {
            let before = t0.timeIntervalSince($0.timestamp)
            return before > InsightRules.withMealGap && before < InsightRules.priorBolusGap
        }) { return nil }

        let withMeal = boluses.filter { abs($0.timestamp.timeIntervalSince(t0)) <= InsightRules.withMealGap }
        let units: Double? = withMeal.isEmpty ? nil : withMeal.reduce(0.0) { $0 + $1.units }

        // Ends at the next food or at a later (correction) bolus.
        let grouped = t0.addingTimeInterval(InsightRules.mealGrouping)
        var end = t0.addingTimeInterval(InsightRules.mealWindow)
        if let next = food.first(where: { $0.timestamp > grouped })?.timestamp { end = min(end, next) }
        if let next = boluses.first(where: { $0.timestamp > t0.addingTimeInterval(InsightRules.withMealGap) })?.timestamp {
            end = min(end, next)
        }
        guard end.timeIntervalSince(t0) >= InsightRules.minimumMealWindow else { return nil }

        guard let w = ResponseWindow(readings: readings, start: t0, end: end),
              let peak = w.points.max(by: { $0.mgdl < $1.mgdl }) else { return nil }

        return MealResponse(id: meal.id, timestamp: t0, carbs: meal.carbs, startMgdl: w.startMgdl,
                            peakMgdl: peak.mgdl, timeToPeak: peak.date.timeIntervalSince(t0),
                            insulinUnits: units, curve: w.curve)
    }

    static func summarize(_ responses: [MealResponse]) -> MealSummary {
        MealSummary(examples: responses.count,
                    rise: Spread.of(responses.map(\.rise)),
                    timeToPeak: Spread.of(responses.map(\.timeToPeak)),
                    risePer10g: Spread.of(responses.map(\.risePer10g)),
                    curve: medianCurve(responses.map(\.curve)))
    }

    // MARK: Pump site age

    static func siteAge(readings: [GlucoseReading], siteChanges: [SiteChange],
                        low: Double, high: Double, now: Date) -> [SiteAgeBucket] {
        let changes = siteChanges.sorted { $0.timestamp < $1.timestamp }
        var values: [Int: [Double]] = [:]
        var sites: [Int: Set<UUID>] = [:]
        for (i, change) in changes.enumerated() {
            // A site worn over a week was probably a missed log, not a real wear time.
            let next = i + 1 < changes.count ? changes[i + 1].timestamp : now
            let end = min(next, change.timestamp.addingTimeInterval(7 * 86_400))
            guard end > change.timestamp else { continue }
            for r in GlucoseAnalytics.slice(readings, from: change.timestamp, to: end) {
                let day = min(4, Int(r.timestamp.timeIntervalSince(change.timestamp) / 86_400) + 1)
                values[day, default: []].append(r.mgdl)
                sites[day, default: []].insert(change.id)
            }
        }
        return (1...4).compactMap { day -> SiteAgeBucket? in
            guard let v = values[day], v.count >= 144, (sites[day]?.count ?? 0) >= 2 else { return nil }
            let inRange = v.filter { $0 >= low && $0 <= high }.count
            return SiteAgeBucket(day: day, meanMgdl: v.reduce(0, +) / Double(v.count),
                                 timeInRange: Double(inRange) / Double(v.count),
                                 readings: v.count, sites: sites[day]?.count ?? 0)
        }
    }

    // MARK: Curves

    /// Median change at each step, where enough examples have a value.
    static func medianCurve(_ curves: [[CurvePoint]]) -> [CurvePoint] {
        var byMinute: [Int: [Double]] = [:]
        for c in curves { for p in c { byMinute[p.minutes, default: []].append(p.change) } }
        return byMinute.compactMap { minute, values -> CurvePoint? in
            guard values.count >= InsightRules.minimumEvents else { return nil }
            return CurvePoint(minutes: minute, change: GlucoseAnalytics.quantile(values.sorted(), 0.5))
        }
        .sorted { $0.minutes < $1.minutes }
    }
}

/// Lightly smoothed readings from `start` to `end`, if there's enough data to trust.
struct ResponseWindow {
    struct Point { let date: Date; let mgdl: Double }

    /// After `start`, oldest → newest.
    let points: [Point]
    let startMgdl: Double
    let curve: [CurvePoint]

    init?(readings: [GlucoseReading], start: Date, end: Date) {
        let raw = GlucoseAnalytics.slice(readings, from: start.addingTimeInterval(-InsightRules.startTolerance), to: end)
        guard raw.count >= 4 else { return nil }

        // Mean over ±7.5 minutes takes the edge off sensor noise without hiding the shape.
        let half: TimeInterval = 7.5 * 60
        var smoothed: [Point] = []
        smoothed.reserveCapacity(raw.count)
        var lo = 0, hi = 0, sum = 0.0
        for r in raw {
            while hi < raw.count, raw[hi].timestamp.timeIntervalSince(r.timestamp) <= half { sum += raw[hi].mgdl; hi += 1 }
            while r.timestamp.timeIntervalSince(raw[lo].timestamp) > half { sum -= raw[lo].mgdl; lo += 1 }
            smoothed.append(Point(date: r.timestamp, mgdl: sum / Double(hi - lo)))
        }

        guard let first = smoothed.min(by: { abs($0.date.timeIntervalSince(start)) < abs($1.date.timeIntervalSince(start)) }),
              abs(first.date.timeIntervalSince(start)) <= InsightRules.startTolerance else { return nil }

        let after = smoothed.filter { $0.date >= start }
        guard let last = after.last else { return nil }

        // Enough data across the whole window.
        var previous = start
        for p in after {
            if p.date.timeIntervalSince(previous) > InsightRules.maxGap { return nil }
            previous = p.date
        }
        if end.timeIntervalSince(last.date) > InsightRules.maxGap { return nil }
        let slot: TimeInterval = 15 * 60
        let slots = max(1, Int((end.timeIntervalSince(start) / slot).rounded(.up)))
        let filled = Set(after.map { Int($0.date.timeIntervalSince(start) / slot) }).count
        guard Double(filled) / Double(slots) >= InsightRules.minCoverage else { return nil }

        points = after
        startMgdl = first.mgdl

        let minutes = Int(end.timeIntervalSince(start) / 60)
        var curve: [CurvePoint] = []
        for m in stride(from: 0, through: minutes, by: InsightRules.curveStep) {
            let t = start.addingTimeInterval(Double(m) * 60)
            if let p = after.min(by: { abs($0.date.timeIntervalSince(t)) < abs($1.date.timeIntervalSince(t)) }),
               abs(p.date.timeIntervalSince(t)) <= 8 * 60 {
                curve.append(CurvePoint(minutes: m, change: m == 0 ? 0 : p.mgdl - first.mgdl))
            }
        }
        self.curve = curve
    }
}
