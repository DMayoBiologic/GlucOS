import Foundation

// What glucose usually does in the hours after this person wakes up: the dawn phenomenon and the
// rise many people see once they're up and moving. Learnt from the wake-ups the user logs
// ("Woke up" events), and only used in the forecast once it has been shown, on the user's own
// past mornings, to make forecasts better.
//
// Method: each logged wake-up starts a 3-hour window cut into 15-minute steps. For every step the
// glucose change is measured, and the part that logged insulin and carbs explain (using the
// effects `EffectProfileLearner` fitted) is taken away:
//
//     residual(step) = Δglucose + S × (insulin acting) − K × (carbs absorbed)
//
// Steps the model can't describe are left out: insulin or carbs acting while their effect isn't
// learnt yet, food without carbs, hypo treatments, lows and what follows them, gaps in the data.
// A morning with illness, alcohol or a site problem logged is left out altogether. Exercise isn't:
// getting up and moving is part of what's being learnt.
//
// The pattern is the median residual at each step across mornings, shrunk towards zero while
// there are few examples, and ends at the first step without enough of them. It's checked by
// replaying the forecast after each past wake-up with a pattern learnt from the *other* mornings,
// with and without the adjustment. Only a pattern that made those forecasts clearly closer is
// used, and how much closer sets its confidence.
//
// It's a forecast input only. It's never shown as a setting and never used to work out a dose.

/// How the pattern did when past forecasts were replayed with and without it.
struct MorningValidation: Hashable, Codable {
    /// Forecasts compared (origins × horizons).
    let checks: Int
    /// Mean absolute error with and without the morning adjustment, mg/dL.
    let errorWith: Double
    let errorWithout: Double

    /// Share of the error the adjustment took away. Negative when it made forecasts worse.
    var improvement: Double { errorWithout > 0 ? 1 - errorWith / errorWithout : 0 }
}

struct MorningPattern: Hashable, Codable {
    static let step: TimeInterval = 15 * 60
    static let span: TimeInterval = 3 * 3600
    static var steps: Int { Int(span / step) }

    /// Change per 15-minute step after waking beyond what logged insulin and carbs explain,
    /// mg/dL. Step 0 runs from waking to 15 minutes after. Only steps with enough examples.
    var stepChange: [Double]
    /// Mornings that contributed to each step.
    var stepExamples: [Int]
    /// Logged wake-ups in the history looked at.
    var loggedWakes: Int
    /// Wake-ups that gave at least one usable step.
    var mornings: Int
    var validation: MorningValidation?
    var learnedAt: Date

    static let empty = MorningPattern(stepChange: [], stepExamples: [], loggedWakes: 0, mornings: 0,
                                      validation: nil, learnedAt: .distantPast)

    /// How long after waking the pattern reaches.
    var duration: TimeInterval { Double(stepChange.count) * Self.step }

    /// Used in the forecast: enough mornings, and it made past forecasts clearly better.
    var isUsable: Bool {
        guard mornings >= MorningPatternLearner.minimumMornings, !stepChange.isEmpty,
              let v = validation, v.checks >= MorningPatternLearner.minimumChecks else { return false }
        return v.improvement >= MorningPatternLearner.requiredImprovement
    }

    var confidence: MorningConfidence? {
        guard isUsable, let v = validation else { return nil }
        if mornings >= 14 && v.checks >= 30 && v.improvement >= 0.25 { return .high }
        if mornings >= 8 && v.improvement >= 0.15 { return .moderate }
        return .low
    }

    /// mg/dL per minute `t` seconds after waking. Zero outside the pattern.
    func ratePerMinute(after t: TimeInterval) -> Double {
        guard t >= 0 else { return 0 }
        let i = Int(t / Self.step)
        guard i < stepChange.count else { return 0 }
        return stepChange[i] / (Self.step / 60)
    }

    /// Total change from waking to `t` seconds after, mg/dL.
    func cumulative(after t: TimeInterval) -> Double {
        guard t > 0 else { return 0 }
        var total = 0.0
        for (i, c) in stepChange.enumerated() {
            let start = Double(i) * Self.step
            if t >= start + Self.step { total += c } else { total += c * (t - start) / Self.step; break }
        }
        return total
    }

    /// The biggest total change after waking and when it's reached.
    var peak: (minutes: Int, mgdl: Double)? {
        guard !stepChange.isEmpty else { return nil }
        var running = 0.0, best = (minutes: 0, mgdl: 0.0)
        for (i, c) in stepChange.enumerated() {
            running += c
            if abs(running) > abs(best.mgdl) { best = ((i + 1) * Int(Self.step / 60), running) }
        }
        return best.minutes > 0 ? best : nil
    }

    /// One sentence for the Outlook page: what usually happens after waking.
    func summary(unit: GlucoseUnit) -> String {
        guard let peak, abs(peak.mgdl) >= MorningPatternLearner.notableChange else {
            return "After you wake, glucose usually stays fairly level, apart from what insulin and food do."
        }
        let amount = unit.format(mgdl: abs(peak.mgdl), withUnit: true)
        let verb = peak.mgdl > 0 ? "rises" : "falls"
        return "After you wake, glucose usually \(verb) about \(amount) over the first \(LogFormat.duration(Double(peak.minutes) * 60)), on top of what logged insulin and food explain."
    }

    /// Mornings still needed before the pattern can be checked.
    var morningsNeeded: Int { max(0, MorningPatternLearner.minimumMornings - mornings) }
}

extension MorningPattern {
    /// Where learning stands, for the Outlook page.
    enum Status: Hashable {
        /// No wake-ups logged in the last 90 days.
        case notLogged
        /// Fewer than `minimumMornings` usable mornings.
        case learning(needed: Int)
        /// Enough mornings, but it didn't make past forecasts clearly better.
        case notHelping
        case used(MorningConfidence)
    }

    var status: Status {
        if loggedWakes == 0 { return .notLogged }
        if mornings < MorningPatternLearner.minimumMornings { return .learning(needed: morningsNeeded) }
        if let c = confidence { return .used(c) }
        return .notHelping
    }

    /// "Forecasts after waking were 23% closer, checked on 12 past mornings." Nil before a check.
    var checkSummary: String? {
        guard let v = validation, v.checks > 0 else { return nil }
        let pct = Int((abs(v.improvement) * 100).rounded())
        let mornings = "\(self.mornings) past morning\(self.mornings == 1 ? "" : "s")"
        if v.improvement >= 0.005 {
            return "With it, forecasts after waking were \(pct)% closer, checked on \(mornings)."
        }
        if v.improvement <= -0.005 {
            return "With it, forecasts after waking were \(pct)% further off, checked on \(mornings)."
        }
        return "It made no difference to forecasts after waking, checked on \(mornings)."
    }

    /// Plain-language state for the Outlook page.
    var statusMessage: String {
        switch status {
        case .notLogged:
            return "Log when you wake up (the Woke up button, the Lock Screen widget, or Woke up under Event) and GlucOS will learn how your glucose moves after waking."
        case .learning(let needed):
            return "Learning: \(needed) more morning\(needed == 1 ? "" : "s") with a wake-up logged and clean readings before GlucOS can check it."
        case .notHelping:
            return "Not used in the forecast yet: it didn't make past forecasts clearly better. GlucOS keeps checking as you log more mornings."
        case .used:
            return "Used in the forecast for the first \(LogFormat.duration(duration)) after you log a wake-up."
        }
    }
}

/// The adjustment a forecast included.
struct AppliedMorningAdjustment: Hashable {
    let wokeAt: Date
    /// How much it moved the forecast's last point, mg/dL.
    let addedMgdl: Double
    let confidence: MorningConfidence?
}

enum MorningPatternLearner {
    static let minimumMornings = 5
    /// Mornings needed at a step for it to be part of the pattern.
    static let minimumPerStep = 4
    static let minimumChecks = 8
    /// The adjustment must take away at least this share of the forecast's error.
    static let requiredImprovement = 0.10
    /// Changes smaller than this are described as "fairly level", mg/dL (about 0.5 mmol/L).
    static let notableChange = 9.0
    /// A second "Woke up" within this long of one counts as the same morning.
    static let sameMorning: TimeInterval = 4 * 3600
    /// A 15-minute change larger than this is treated as a sensor artefact, mg/dL.
    static let maxStepChange = 40.0
    static let historyDays = 90

    /// One past morning: the residual change at each usable step.
    struct Morning: Hashable {
        let wake: Date
        let steps: [Int: Double]
    }

    /// Wake-up times, oldest first, one per morning.
    static func wakeTimes(_ contexts: [ContextEvent]) -> [Date] {
        var out: [Date] = []
        for t in contexts.filter(\.isWake).map(\.timestamp).sorted() {
            if let last = out.last, t.timeIntervalSince(last) < sameMorning { continue }
            out.append(t)
        }
        return out
    }

    static func learn(readings: [GlucoseReading], doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                      profile: EffectProfile, low: Double, now: Date = Date()) -> MorningPattern {
        let series = GlucoseSeries(readings)
        let from = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let wakes = wakeTimes(contexts).filter { $0 >= from && $0 <= now }
        let examples = mornings(series: series, wakes: wakes, doses: doses, meals: meals, contexts: contexts,
                                profile: profile, low: low, now: now)
        var pattern = fit(examples)
        pattern.loggedWakes = wakes.count
        pattern.learnedAt = now
        if pattern.mornings >= minimumMornings {
            pattern.validation = validate(examples: examples, series: series, doses: doses, meals: meals,
                                          contexts: contexts, profile: profile, now: now)
        }
        return pattern
    }

    /// The pattern from a set of mornings (no validation).
    static func fit(_ mornings: [Morning]) -> MorningPattern {
        var stepChange: [Double] = [], stepExamples: [Int] = []
        for i in 0..<MorningPattern.steps {
            let values = mornings.compactMap { $0.steps[i] }
            guard values.count >= minimumPerStep else { break }
            // Shrink towards no change while there are few examples.
            let n = Double(values.count)
            stepChange.append(EngineMath.median(values) * n / (n + 2))
            stepExamples.append(values.count)
        }
        return MorningPattern(stepChange: stepChange, stepExamples: stepExamples, loggedWakes: mornings.count,
                              mornings: mornings.filter { !$0.steps.isEmpty }.count, validation: nil,
                              learnedAt: .distantPast)
    }

    /// The usable steps of each wake-up.
    static func mornings(series: GlucoseSeries, wakes: [Date], doses: [InsulinDose], meals: [MealEntry],
                         contexts: [ContextEvent], profile: EffectProfile, low: Double, now: Date) -> [Morning] {
        let fast = doses.compactMap(TimedDose.init(fastPartOf:))
        let carbs = meals.filter { $0.carbs > 0 }.map { TimedCarbs(date: $0.timestamp, grams: $0.carbs) }
        let untimedFood = meals.filter { $0.carbs <= 0 }.map(\.timestamp)
            + contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        let foodReach = CarbAbsorptionCurve.standard.totalDuration
        let S = profile.reliableInsulin?.value
        let K = profile.reliableCarbs?.value

        var out: [Morning] = []
        for (n, wake) in wakes.enumerated() {
            let end = min(wake.addingTimeInterval(MorningPattern.span), now,
                          n + 1 < wakes.count ? wakes[n + 1] : .distantFuture)
            // Illness, alcohol or a delivery problem make the whole morning unlike the others.
            let spoilt = contexts.contains { c in
                c.tags.contains { tag in
                    switch tag {
                    case .illness, .alcohol:
                        return c.timestamp <= end && c.timestamp >= wake.addingTimeInterval(-tag.reach)
                    case .siteProblem:
                        return abs(c.timestamp.timeIntervalSince(wake)) <= 6 * 3600
                    default:
                        return false
                    }
                }
            }
            if spoilt { continue }

            var steps: [Int: Double] = [:]
            for i in 0..<MorningPattern.steps {
                let t0 = wake.addingTimeInterval(Double(i) * MorningPattern.step)
                let t1 = t0.addingTimeInterval(MorningPattern.step)
                guard t1 <= end else { break }
                // A low (and the rebound after it) or untimed food ends what can be read.
                if series.slice(from: t0.addingTimeInterval(-3600), through: t1).contains(where: { $0.mgdl < low }) { break }
                if untimedFood.contains(where: { $0 <= t1 && $0 > t0.addingTimeInterval(-foodReach) }) { break }
                guard let g0 = series.value(at: t0), let g1 = series.value(at: t1),
                      (40...400).contains(g0), (40...400).contains(g1) else { continue }
                let insulin = fast.reduce(0) { $0 + $1.acting(from: t0, to: t1) }
                let grams = carbs.reduce(0) { $0 + $1.absorbed(from: t0, to: t1) }
                if insulin > 0.05 && S == nil { continue }
                if grams > 0.5 && K == nil { continue }
                let residual = (g1 - g0) + (S ?? 0) * insulin - (K ?? 0) * grams
                guard abs(residual) <= maxStepChange else { continue }
                steps[i] = residual
            }
            out.append(Morning(wake: wake, steps: steps))
        }
        return out
    }

    /// Replays forecasts after each past wake-up, with a pattern learnt from the other mornings
    /// and without one, and compares both with what happened.
    static func validate(examples: [Morning], series: GlucoseSeries, doses: [InsulinDose], meals: [MealEntry],
                         contexts: [ContextEvent], profile: EffectProfile, now: Date) -> MorningValidation {
        let eventTimes = (doses.map(\.timestamp) + meals.map(\.timestamp)
            + contexts.filter { !$0.isWake }.map(\.timestamp)).sorted()
        var errWith = 0.0, errWithout = 0.0, checks = 0
        for (k, m) in examples.enumerated() where !m.steps.isEmpty {
            var others = examples
            others.remove(at: k)
            let pattern = fit(others)
            guard !pattern.stepChange.isEmpty else { continue }
            let local = GlucoseSeries(Array(series.slice(from: m.wake.addingTimeInterval(-3600),
                                                         through: m.wake.addingTimeInterval(MorningPattern.span + 3600))),
                                      sorted: true)
            for offset in [10.0, 40, 70, 100] {
                let target = m.wake.addingTimeInterval(offset * 60)
                guard let origin = local.upTo(target).last, target.timeIntervalSince(origin.timestamp) < 5 * 60 else { continue }
                let t0 = origin.timestamp
                let next = eventTimes.first { $0 > t0 } ?? .distantFuture
                func forecast(_ p: MorningPattern?) -> GlucoseForecast? {
                    var input = ForecastInputs(readings: local.upTo(t0), doses: doses.filter { $0.timestamp <= t0 },
                                               meals: meals.filter { $0.timestamp <= t0 },
                                               contexts: contexts.filter { $0.timestamp <= t0 },
                                               profile: profile, now: t0)
                    input.morning = p
                    if case .success(let f) = GlucoseForecaster.forecast(input, maxHorizon: 60 * 60) { return f }
                    return nil
                }
                guard let with = forecast(pattern), let without = forecast(nil) else { continue }
                for h in [30.0, 60] {
                    let at = t0.addingTimeInterval(h * 60)
                    guard at <= now, at < next, let actual = local.value(at: at),
                          let a = with.samples.first(where: { abs($0.date.timeIntervalSince(at)) < 30 }),
                          let b = without.samples.first(where: { abs($0.date.timeIntervalSince(at)) < 30 }) else { continue }
                    errWith += abs(actual - a.mgdl)
                    errWithout += abs(actual - b.mgdl)
                    checks += 1
                }
            }
        }
        guard checks > 0 else { return MorningValidation(checks: 0, errorWith: 0, errorWithout: 0) }
        return MorningValidation(checks: checks, errorWith: errWith / Double(checks), errorWithout: errWithout / Double(checks))
    }
}

// MARK: - Logging wake-ups

/// When to offer "Woke up?" and with what time.
enum WakeLog {
    /// Hours of the day the prompt can show.
    static let promptHours = 4..<13
    /// A wake-up logged this recently already covers this morning.
    static let coversMorning: TimeInterval = 10 * 3600
    /// A quick "Woke up" within this long of the last one isn't logged twice.
    static let duplicateWindow: TimeInterval = 3 * 3600

    /// The latest logged wake-up at or before `now`.
    static func latest(_ contexts: [ContextEvent], before now: Date = Date()) -> ContextEvent? {
        contexts.filter { $0.isWake && $0.timestamp <= now }.max { $0.timestamp < $1.timestamp }
    }

    /// A wake-up logged within `duplicateWindow`, which a one-tap log would repeat.
    static func recent(_ contexts: [ContextEvent], now: Date = Date()) -> ContextEvent? {
        latest(contexts, before: now.addingTimeInterval(60)).flatMap {
            now.timeIntervalSince($0.timestamp) < duplicateWindow ? $0 : nil
        }
    }

    /// Whether to ask "Woke up?" now. `firstActive` is when this device was first used this
    /// morning (the iPhone app opened, the Mac's screen woke); `dismissedOn` is the day the user
    /// last said "Not today", as `dayKey`.
    static func shouldPrompt(contexts: [ContextEvent], now: Date = Date(), dismissedOn: String?,
                             calendar: Calendar = .current) -> Bool {
        guard promptHours.contains(calendar.component(.hour, from: now)) else { return false }
        if dismissedOn == dayKey(now, calendar: calendar) { return false }
        if let last = latest(contexts, before: now.addingTimeInterval(60)),
           now.timeIntervalSince(last.timestamp) < coversMorning { return false }
        return true
    }

    /// The time to suggest: when the device was first used this morning, if that was today from
    /// 4 am on and isn't in the future. Otherwise nil (the prompt offers "now").
    static func suggestedTime(firstActive: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let firstActive, firstActive <= now, calendar.isDate(firstActive, inSameDayAs: now),
              calendar.component(.hour, from: firstActive) >= promptHours.lowerBound else { return nil }
        // To the minute: seconds would look falsely precise.
        let minute = calendar.dateInterval(of: .minute, for: firstActive)?.start ?? firstActive
        return minute
    }

    /// Notes the first use of the device this morning. Returns the value to keep.
    static func noteActive(previous: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if let previous, calendar.isDate(previous, inSameDayAs: now),
           calendar.component(.hour, from: previous) >= promptHours.lowerBound { return previous }
        return calendar.component(.hour, from: now) >= promptHours.lowerBound ? now : previous
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// A new wake-up entry.
    static func entry(at date: Date) -> ContextEvent {
        ContextEvent(timestamp: date, tags: [.wokeUp])
    }
}
