import Foundation
@testable import GlucOSEngine

/// Deterministic random numbers for repeatable simulations.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// Standard normal (Box–Muller).
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A fixed reference time on a half-hour boundary, so tests don't depend on the clock.
let referenceNow = Date(timeIntervalSince1970: 1_789_999_200)

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func reading(_ date: Date, _ mgdl: Double, _ trend: Trend = .flat) -> GlucoseReading {
    GlucoseReading(timestamp: date, mgdl: mgdl, trend: trend)
}

/// Readings every `step` seconds ending at `end`, following `value(minutesBeforeEnd)`.
func readings(endingAt end: Date, minutes: Int, step: Int = 5, value: (Double) -> Double) -> [GlucoseReading] {
    stride(from: minutes, through: 0, by: -step).map { m in
        reading(end.addingTimeInterval(-Double(m) * 60), value(Double(m)))
    }
}

/// A person whose glucose moves exactly as the engine's model says, plus noise and the usual
/// mismatch between the carbs logged and the carbs eaten. Lets the learner be checked against
/// known true values.
struct SimulatedPerson {
    var insulinEffect = 50.0    // mg/dL per unit
    var carbEffect = 4.0        // mg/dL per gram
    var days = 30
    var noise = 2.0             // mg/dL per 5 minutes, random walk
    var carbMisestimate = 0.2   // logged carbs are off by up to ±20%
    var seed: UInt64 = 42

    struct Output {
        var readings: [GlucoseReading]
        var doses: [InsulinDose]
        var meals: [MealEntry]
    }

    func run(endingAt end: Date = referenceNow) -> Output {
        var rng = SeededRandom(seed: seed)
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        var doses: [InsulinDose] = []
        var meals: [MealEntry] = []
        // True carbs eaten, which differ from what's logged.
        var eaten: [TimedCarbs] = []
        var given: [TimedDose] = []
        var g = 120.0
        var out: [GlucoseReading] = []
        var t = start
        let step: TimeInterval = 5 * 60
        let mealTimes: [(hour: Double, carbs: ClosedRange<Double>)] = [(7.5, 30...50), (12.5, 40...70), (18.75, 50...80)]
        while t <= end {
            let secondsIntoDay = t.timeIntervalSince(utc.startOfDay(for: t))
            for meal in mealTimes where abs(secondsIntoDay - meal.hour * 3600) < step / 2 {
                let jitter = rng.uniform(-20 * 60 ... 20 * 60)
                let when = t.addingTimeInterval(jitter)
                let actual = rng.uniform(meal.carbs)
                let logged = (actual * (1 + rng.uniform(-carbMisestimate ... carbMisestimate))).rounded()
                eaten.append(TimedCarbs(date: when, grams: actual))
                meals.append(MealEntry(timestamp: when, carbs: logged))
                // A bolus roughly matching the logged carbs, sometimes a bit early or late.
                let units = (logged * carbEffect / insulinEffect * rng.uniform(0.8 ... 1.2) * 2).rounded() / 2
                let dose = InsulinDose(timestamp: when.addingTimeInterval(rng.uniform(-10 * 60 ... 15 * 60)), units: units, kind: .rapid)
                doses.append(dose)
                given.append(TimedDose(fastPartOf: dose)!)
            }
            // Corrections mid-afternoon and late evening when high.
            for hour in [15.5, 22.0] where abs(secondsIntoDay - hour * 3600) < step / 2 && g > 170 {
                let units = ((g - 120) / insulinEffect * 2).rounded() / 2
                if units >= 0.5 {
                    let dose = InsulinDose(timestamp: t, units: units, kind: .rapid)
                    doses.append(dose)
                    given.append(TimedDose(fastPartOf: dose)!)
                }
            }
            // A logged snack when heading low, so the trace stays mostly in range.
            if g < 85, meals.last.map({ t.timeIntervalSince($0.timestamp) > 90 * 60 }) ?? true {
                eaten.append(TimedCarbs(date: t, grams: 15))
                meals.append(MealEntry(timestamp: t, carbs: 15))
            }
            let next = t.addingTimeInterval(step)
            let insulin = given.reduce(0) { $0 + $1.acting(from: t, to: next) }
            let carbs = eaten.reduce(0) { $0 + $1.absorbed(from: t, to: next) }
            out.append(reading(t, min(400, max(40, g))))
            g += carbEffect * carbs - insulinEffect * insulin + noise * rng.normal()
            g = min(400, max(40, g))
            t = next
        }
        return Output(readings: out, doses: doses, meals: meals)
    }
}
