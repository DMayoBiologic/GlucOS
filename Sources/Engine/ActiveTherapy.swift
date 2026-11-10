import Foundation

// Insulin and carbs still acting at a given moment, from what the user logged. Descriptive only:
// these say how much of what was logged hasn't acted yet, on population timing curves.

/// A logged dose reduced to what the models need.
struct TimedDose: Hashable {
    let date: Date
    let units: Double
    let components: [InsulinComponent]

    init(date: Date, units: Double, components: [InsulinComponent]) {
        self.date = date
        self.units = units
        self.components = components
    }

    /// The parts of `dose` that act within hours. Nil for long-acting and NPH doses.
    init?(fastPartOf dose: InsulinDose) {
        let parts = dose.kind.fastComponents
        guard !parts.isEmpty, dose.units > 0 else { return nil }
        self.init(date: dose.timestamp, units: dose.units, components: parts)
    }

    /// Units of this dose still to act at `date`.
    func remaining(at date: Date) -> Double {
        let t = date.timeIntervalSince(self.date)
        if t < 0 { return 0 }   // not given yet
        return components.reduce(0) { $0 + units * $1.share * $1.curve.fractionRemaining(after: t) }
    }

    /// Units acting per hour at `date`.
    func activityPerHour(at date: Date) -> Double {
        let t = date.timeIntervalSince(self.date)
        if t < 0 { return 0 }
        return components.reduce(0) { $0 + units * $1.share * $1.curve.activity(after: t) } * 3600
    }

    /// Units that act between two moments.
    func acting(from start: Date, to end: Date) -> Double {
        let t0 = max(0, start.timeIntervalSince(date)), t1 = end.timeIntervalSince(date)
        guard t1 > t0 else { return 0 }
        return components.reduce(0) { $0 + units * $1.share * $1.curve.fractionActing(from: t0, to: t1) }
    }

    /// Share of the dose made up of the parts modelled here (1, or 0.3 for premixed).
    var share: Double { components.reduce(0) { $0 + $1.share } }

    var end: Date { date.addingTimeInterval(components.map(\.curve.totalDuration).max() ?? 0) }
}

/// A logged meal reduced to what the models need.
struct TimedCarbs: Hashable {
    let date: Date
    let grams: Double
    let curve: CarbAbsorptionCurve

    init(date: Date, grams: Double, curve: CarbAbsorptionCurve = .standard) {
        self.date = date
        self.grams = grams
        self.curve = curve
    }

    func remaining(at date: Date) -> Double {
        let t = date.timeIntervalSince(self.date)
        if t < 0 { return 0 }
        return grams * curve.fractionRemaining(after: t)
    }

    /// Grams absorbed per hour at `date`.
    func ratePerHour(at date: Date) -> Double {
        let t = date.timeIntervalSince(self.date)
        if t < 0 { return 0 }
        return grams * curve.rate(after: t) * 3600
    }

    func absorbed(from start: Date, to end: Date) -> Double {
        let t0 = max(0, start.timeIntervalSince(date)), t1 = end.timeIntervalSince(date)
        guard t1 > t0 else { return 0 }
        return grams * curve.fractionAbsorbed(from: t0, to: t1)
    }

    var end: Date { date.addingTimeInterval(curve.totalDuration) }
}

/// One step of an activity curve.
struct ActivitySample: Hashable {
    let date: Date
    /// Units (or grams) still to act.
    let remaining: Double
    /// Units (or grams) acting per hour.
    let ratePerHour: Double
}

/// Fast-acting insulin still working, and when it winds down.
struct InsulinActivity: Hashable {
    let at: Date
    /// Units of fast-acting insulin not yet acted.
    let onBoard: Double
    /// Units acting per hour right now.
    let ratePerHour: Double
    /// When combined activity peaks, if that's still ahead.
    let peakAt: Date?
    /// When what's left drops to a negligible amount (`InsulinActivity.tailUnits` or 10% of what
    /// was given, whichever is more). Nil when it's already there.
    let mostlyDoneAt: Date?
    /// When the last of it has finished acting on the model's timing.
    let finishedAt: Date?
    /// Doses still acting.
    let doseCount: Int
    /// Units given in those doses (fast parts only).
    let unitsGiven: Double
    /// From 3 hours before `at` to `finishedAt` (or 6 hours ahead), every 5 minutes.
    let curve: [ActivitySample]
    /// A long-acting or NPH dose was logged within its usual action time. Not included above.
    let backgroundInsulinLogged: Bool

    /// Below this many units, what's left is too small to matter.
    static let tailUnits = 0.1

    var isActive: Bool { mostlyDoneAt != nil }

    static func compute(doses: [InsulinDose], at now: Date, step: TimeInterval = 5 * 60) -> InsulinActivity {
        let timed = doses.compactMap(TimedDose.init(fastPartOf:)).filter { $0.date <= now && $0.end > now }
        let background = doses.contains { d in
            d.timestamp <= now && (d.kind == .long ? now.timeIntervalSince(d.timestamp) < 36 * 3600
                                   : d.kind == .intermediate && now.timeIntervalSince(d.timestamp) < 18 * 3600)
        }
        func remaining(_ t: Date) -> Double { timed.reduce(0) { $0 + $1.remaining(at: t) } }
        func rate(_ t: Date) -> Double { timed.reduce(0) { $0 + $1.activityPerHour(at: t) } }

        let given = timed.reduce(0) { $0 + $1.units * $1.share }
        let threshold = max(tailUnits, 0.1 * given)
        let finished = timed.map(\.end).max()
        let horizonEnd = max(finished ?? now, now.addingTimeInterval(6 * 3600))

        // The curve includes doses that have since finished, so the chart shows their tail.
        let past = doses.compactMap(TimedDose.init(fastPartOf:))
            .filter { $0.date <= now && $0.end > now.addingTimeInterval(-3 * 3600) }
        var curve: [ActivitySample] = []
        var t = now.addingTimeInterval(-3 * 3600)
        while t <= horizonEnd {
            let r = past.reduce(0) { $0 + $1.remaining(at: t) }
            let a = past.reduce(0) { $0 + $1.activityPerHour(at: t) }
            curve.append(ActivitySample(date: t, remaining: r, ratePerHour: a))
            t = t.addingTimeInterval(step)
        }

        let nowRemaining = remaining(now)
        var mostlyDone: Date?
        if nowRemaining > threshold {
            var probe = now
            while probe < horizonEnd && remaining(probe) > threshold { probe = probe.addingTimeInterval(60) }
            mostlyDone = probe
        }

        var peak: Date?
        if !timed.isEmpty {
            // Search minute by minute over the next 8 hours.
            var best = rate(now), bestTime = now
            var probe = now.addingTimeInterval(60)
            let limit = now.addingTimeInterval(8 * 3600)
            while probe <= limit {
                let r = rate(probe)
                if r > best { best = r; bestTime = probe }
                probe = probe.addingTimeInterval(60)
            }
            if bestTime.timeIntervalSince(now) >= 60 { peak = bestTime }
        }

        return InsulinActivity(at: now, onBoard: nowRemaining, ratePerHour: rate(now), peakAt: peak,
                               mostlyDoneAt: mostlyDone, finishedAt: timed.isEmpty ? nil : finished,
                               doseCount: timed.count, unitsGiven: given, curve: curve,
                               backgroundInsulinLogged: background)
    }
}

/// Logged carbs still being absorbed.
struct CarbActivity: Hashable {
    let at: Date
    let onBoard: Double
    let ratePerHour: Double
    /// When what's left drops under 5 g.
    let mostlyAbsorbedAt: Date?
    let mealCount: Int
    /// Food logged in the last 3 hours without a carb amount: its effect can't be modelled.
    let uncountedFood: Bool

    static let tailGrams = 5.0

    static func compute(meals: [MealEntry], hypoTreatments: [Date] = [], at now: Date) -> CarbActivity {
        let timed = meals.filter { $0.carbs > 0 && $0.timestamp <= now }
            .map { TimedCarbs(date: $0.timestamp, grams: $0.carbs) }
            .filter { $0.end > now }
        let window = now.addingTimeInterval(-CarbAbsorptionCurve.standard.totalDuration)
        let uncounted = meals.contains { $0.carbs <= 0 && $0.timestamp <= now && $0.timestamp > window }
            || hypoTreatments.contains { $0 <= now && $0 > window }
        func remaining(_ t: Date) -> Double { timed.reduce(0) { $0 + $1.remaining(at: t) } }
        let onBoard = remaining(now)
        var mostly: Date?
        if onBoard > tailGrams {
            var probe = now
            let limit = timed.map(\.end).max() ?? now
            while probe < limit && remaining(probe) > tailGrams { probe = probe.addingTimeInterval(60) }
            mostly = probe
        }
        return CarbActivity(at: now, onBoard: onBoard,
                            ratePerHour: timed.reduce(0) { $0 + $1.ratePerHour(at: now) },
                            mostlyAbsorbedAt: mostly, mealCount: timed.count, uncountedFood: uncounted)
    }
}
