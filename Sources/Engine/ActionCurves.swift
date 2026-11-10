import Foundation

// How insulin and carbohydrate act over time. These are population curves from the published
// literature (the same shapes Loop and OpenAPS use), not anything measured from this user. They
// only describe *timing*. How far glucose moves per unit or per gram is learnt separately
// (`EffectProfileLearner`) and is never shown as a setting or used to work out a dose.

/// Exponential insulin action curve (Loop's `ExponentialInsulinModel`): activity rises from zero
/// after `delay`, peaks at `peak` after the delay and reaches zero at `duration` after the delay.
/// Activity integrates to exactly 1 over the curve, so `units × fractionRemaining` is insulin on board.
struct InsulinActionCurve: Hashable {
    /// Time before absorption starts.
    let delay: TimeInterval
    /// Time from the end of the delay to peak activity.
    let peak: TimeInterval
    /// Time from the end of the delay until the insulin has finished acting.
    let duration: TimeInterval

    private let tau: Double
    private let a: Double
    private let s: Double

    init(delay: TimeInterval = 10 * 60, peak: TimeInterval, duration: TimeInterval) {
        // The exponential model needs the peak before the halfway point.
        precondition(peak > 0 && peak < duration / 2, "peak must be inside the first half of the curve")
        self.delay = delay
        self.peak = peak
        self.duration = duration
        tau = peak * (1 - peak / duration) / (1 - 2 * peak / duration)
        a = 2 * tau / duration
        s = 1 / (1 - a + (1 + a) * exp(-duration / tau))
    }

    /// Delay plus duration: after this, nothing is left.
    var totalDuration: TimeInterval { delay + duration }

    /// Share of the dose still to act, `elapsed` seconds after it was given (1 before, 0 after).
    func fractionRemaining(after elapsed: TimeInterval) -> Double {
        let t = elapsed - delay
        if t <= 0 { return 1 }
        if t >= duration { return 0 }
        let value = 1 - s * (1 - a) * ((t * t / (tau * duration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
        return min(1, max(0, value))
    }

    /// Share of the dose acting per second, `elapsed` seconds after it was given.
    func activity(after elapsed: TimeInterval) -> Double {
        let t = elapsed - delay
        if t <= 0 || t >= duration { return 0 }
        return max(0, (s / (tau * tau)) * t * (1 - t / duration) * exp(-t / tau))
    }

    /// Share of the dose that acts between two times after it was given.
    func fractionActing(from start: TimeInterval, to end: TimeInterval) -> Double {
        max(0, fractionRemaining(after: start) - fractionRemaining(after: end))
    }

    /// When activity is highest, measured from the dose.
    var peakTime: TimeInterval { delay + peak }
}

/// One part of a dose: premixed insulin is a fast part and an intermediate part.
struct InsulinComponent: Hashable {
    let share: Double
    let curve: InsulinActionCurve
}

extension InsulinKind {
    /// Timing for each part of this insulin. Long-acting insulin has none: it covers background
    /// needs over a day or more and isn't modelled hour to hour.
    var components: [InsulinComponent] {
        switch self {
        case .ultraRapid:   // Fiasp, Lyumjev
            return [InsulinComponent(share: 1, curve: .ultraRapid)]
        case .rapid:        // NovoRapid, Humalog, Apidra
            return [InsulinComponent(share: 1, curve: .rapid)]
        case .short:        // Regular human insulin
            return [InsulinComponent(share: 1, curve: .regular)]
        case .intermediate: // NPH
            return [InsulinComponent(share: 1, curve: .nph)]
        case .premixed:     // Typically 30% fast, 70% NPH (NovoMix 30, Humalog Mix 25 is close)
            return [InsulinComponent(share: 0.3, curve: .rapid), InsulinComponent(share: 0.7, curve: .nph)]
        case .long:
            return []
        }
    }

    /// The parts whose effect plays out over the next few hours and so belong in a short-term
    /// forecast and in "insulin on board". The slow part of premixed insulin and NPH behave like
    /// background insulin, which (like a pump's basal) is assumed to hold glucose steady.
    var fastComponents: [InsulinComponent] {
        switch self {
        case .rapid, .ultraRapid, .short: return components
        case .premixed: return components.filter { $0.curve == .rapid }
        case .intermediate, .long: return []
        }
    }
}

extension InsulinActionCurve {
    /// Rapid-acting analogues: peak about 75 minutes after the delay, finished by about 6 hours.
    static let rapid = InsulinActionCurve(delay: 10 * 60, peak: 75 * 60, duration: 6 * 3600)
    /// Faster formulations: peak about 55 minutes after the delay.
    static let ultraRapid = InsulinActionCurve(delay: 10 * 60, peak: 55 * 60, duration: 6 * 3600)
    /// Regular human insulin: slower to peak and longer lasting.
    static let regular = InsulinActionCurve(delay: 30 * 60, peak: 2.5 * 3600, duration: 8 * 3600)
    /// NPH: broad peak around 6 hours, lasting well into the next half day.
    static let nph = InsulinActionCurve(delay: 60 * 60, peak: 6 * 3600, duration: 16 * 3600)
}

/// Carbohydrate absorption (Loop's piecewise-linear model): the rate ramps up over the first 15%
/// of the absorption time, holds, then tapers off over the second half.
struct CarbAbsorptionCurve: Hashable {
    let delay: TimeInterval
    let absorptionTime: TimeInterval

    private static let endOfRise = 0.15
    private static let startOfFall = 0.5
    private static let scale = 2 / (1 + startOfFall - endOfRise)

    init(delay: TimeInterval = 10 * 60, absorptionTime: TimeInterval = 3 * 3600) {
        precondition(absorptionTime > 0)
        self.delay = delay
        self.absorptionTime = absorptionTime
    }

    var totalDuration: TimeInterval { delay + absorptionTime }

    /// Share of the carbs absorbed `elapsed` seconds after eating.
    func fractionAbsorbed(after elapsed: TimeInterval) -> Double {
        let x = (elapsed - delay) / absorptionTime
        let rise = Self.endOfRise, fall = Self.startOfFall, scale = Self.scale
        switch x {
        case ...0: return 0
        case ..<rise: return 0.5 * scale * x * x / rise
        case ..<fall: return scale * (x - 0.5 * rise)
        case ..<1: return scale * (fall - 0.5 * rise + (x - fall) * (1 - 0.5 * (x - fall) / (1 - fall)))
        default: return 1
        }
    }

    func fractionRemaining(after elapsed: TimeInterval) -> Double { 1 - fractionAbsorbed(after: elapsed) }

    /// Share absorbed per second.
    func rate(after elapsed: TimeInterval) -> Double {
        let x = (elapsed - delay) / absorptionTime
        let rise = Self.endOfRise, fall = Self.startOfFall, scale = Self.scale
        let perUnit: Double
        switch x {
        case ...0: perUnit = 0
        case ..<rise: perUnit = scale * x / rise
        case ..<fall: perUnit = scale
        case ..<1: perUnit = scale * (1 - x) / (1 - fall)
        default: perUnit = 0
        }
        return perUnit / absorptionTime
    }

    func fractionAbsorbed(from start: TimeInterval, to end: TimeInterval) -> Double {
        max(0, fractionAbsorbed(after: end) - fractionAbsorbed(after: start))
    }

    static let standard = CarbAbsorptionCurve()
}
