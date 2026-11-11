import Foundation

// Bolus calculator, in the style of an insulin pump's (Tandem t:slim, Omnipod, Medtronic).
//
// The maths only ever uses the numbers the user has entered and confirmed: carb ratio, correction
// factor and target for the time of day, their pen or pump increment and their maximum bolus.
// Nothing learnt from the logbook goes in (`BolusSettingsReview` can only *propose* a change,
// which the user has to accept), and the glucose forecast is never used.
//
//     food        = carbs ÷ carb ratio
//     correction  = (glucose − target) ÷ correction factor          (negative below target)
//
//     at or above target:  total = food + max(0, correction − insulin on board)
//     below target:        total = max(0, food + correction − insulin on board)
//     no reading / falling fast (correction left out):  total = max(0, food − insulin on board)
//
// That's the rule Tandem's pumps use: insulin still on board only cancels out a correction when
// glucose is high, but when glucose is under target it comes off the food bolus too. Without a
// current reading there's no correction, and insulin on board still comes off the food bolus.
// The total is capped at the user's maximum, then rounded *down* to their increment.
//
// Safety gates: no suggestion while glucose is low, or falling fast towards a low; corrections are
// left out when glucose is falling fast or the reading is old. Everything the user sees carries
// "check it yourself, not medical advice".

// MARK: - Settings

/// One time-of-day block of bolus settings, like a pump's personal profile segment.
struct BolusScheduleBlock: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Minutes after local midnight when this block starts. The first block starts at 0.
    var startMinute: Int
    /// Grams of carbohydrate that one unit covers ("1 unit per 10 g" is 10).
    var carbRatio: Double
    /// How far one unit lowers glucose, mg/dL.
    var correctionFactor: Double
    /// Glucose the correction aims for, mg/dL.
    var targetMgdl: Double

    /// "6:00 am", in the given calendar's zone.
    func startLabel(calendar: Calendar = .current) -> String {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let date = midnight.addingTimeInterval(Double(startMinute) * 60)
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// The user's bolus calculator settings. Synced between their devices with the logbook.
struct BolusSettings: Codable, Hashable {
    /// The one logbook record that holds these settings.
    static let recordID = UUID(uuidString: "B0105E77-1465-4C0B-8A1E-000000000001")!

    /// Sorted by start; the first starts at midnight. At least one.
    var blocks: [BolusScheduleBlock]
    /// Smallest step the user's pen or pump can give, units.
    var increment: Double
    /// Never suggest more than this, units.
    var maxBolus: Double
    /// When the user last reviewed and confirmed these numbers. Nil until they have; the
    /// calculator gives nothing until then.
    var confirmedAt: Date?
    /// The user turned the calculator off.
    var disabled: Bool = false

    /// Steps pens and pumps actually give.
    static let increments: [Double] = [0.05, 0.1, 0.5, 1]

    // Limits on what can be entered. Wide enough for anyone's real settings, narrow enough to
    // catch a slipped digit or a mmol/L value typed as mg/dL.
    static let carbRatioRange: ClosedRange<Double> = 1...150            // g per unit
    static let correctionFactorRange: ClosedRange<Double> = 5...400     // mg/dL per unit (0.3–22 mmol/L)
    static let targetRange: ClosedRange<Double> = 72...200              // mg/dL (4.0–11.1 mmol/L)
    static let maxBolusRange: ClosedRange<Double> = 0.5...30            // units

    /// A starting point for the setup screen. Not usable until the user changes and confirms it:
    /// `confirmedAt` is nil.
    static let blank = BolusSettings(
        blocks: [BolusScheduleBlock(startMinute: 0, carbRatio: 10, correctionFactor: 2.5 * GlucoseUnit.mgdlPerMmol,
                                    targetMgdl: 6 * GlucoseUnit.mgdlPerMmol)],
        increment: 0.5, maxBolus: 10, confirmedAt: nil)

    var isConfirmed: Bool { confirmedAt != nil }
    var isUsable: Bool { isConfirmed && !disabled && problems.isEmpty }

    /// What's wrong with these settings, in plain words. Empty when they're valid.
    var problems: [String] {
        var out: [String] = []
        if blocks.isEmpty { out.append("Add at least one time block.") }
        let starts = blocks.map(\.startMinute)
        if let first = starts.min(), first != 0 { out.append("The first time block has to start at midnight.") }
        if Set(starts).count != starts.count { out.append("Two time blocks start at the same time.") }
        if starts.contains(where: { $0 < 0 || $0 >= 1440 }) { out.append("A time block starts outside the day.") }
        for b in blocks {
            let at = b.startLabel()
            if !Self.carbRatioRange.contains(b.carbRatio) {
                out.append("Carb ratio from \(at) must be 1–150 g per unit.")
            }
            if !Self.correctionFactorRange.contains(b.correctionFactor) {
                out.append("Correction factor from \(at) is outside 0.3–22 mmol/L (5–400 mg/dL) per unit.")
            }
            if !Self.targetRange.contains(b.targetMgdl) {
                out.append("Target from \(at) must be 4.0–11.1 mmol/L (72–200 mg/dL).")
            }
        }
        if !Self.increments.contains(where: { abs($0 - increment) < 1e-9 }) { out.append("Choose a dose step.") }
        if !Self.maxBolusRange.contains(maxBolus) { out.append("Maximum bolus must be 0.5–30 units.") }
        return out
    }

    /// The block in effect at `date`.
    func block(at date: Date, calendar: Calendar = .current) -> BolusScheduleBlock? {
        let sorted = blocks.sorted { $0.startMinute < $1.startMinute }
        guard !sorted.isEmpty else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // Before the first block's start (only if it doesn't start at midnight): yesterday's last.
        return sorted.last { $0.startMinute <= minute } ?? sorted.last
    }

    /// A copy with blocks sorted by start time.
    var normalised: BolusSettings {
        var s = self
        s.blocks.sort { $0.startMinute < $1.startMinute }
        return s
    }
}

// MARK: - Request and result

struct BolusRequest {
    /// Grams of carbohydrate about to be eaten. 0 for a correction only.
    var carbs: Double
    var now: Date
    /// Recent CGM readings, any order.
    var readings: [GlucoseReading]
    /// A finger-prick value the user typed, mg/dL. Used instead of the sensor when given.
    var manualGlucose: Double? = nil
    /// The logbook's doses: insulin on board is worked out from these.
    var doses: [InsulinDose]
    var contexts: [ContextEvent] = []
    /// The user's low threshold, mg/dL.
    var lowMgdl: Double
    var therapy: TherapyType
}

enum BolusNoticeLevel: Int, Comparable, Codable {
    case info, caution, stop
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Something the user needs to know about a suggestion.
enum BolusNotice: Hashable {
    case notSetUp
    case turnedOff
    case invalidSettings([String])
    case carbsOutOfRange
    case low(mgdl: Double)
    case fallingFastTowardsLow
    case fallingFast
    case noReading
    case staleReading(minutes: Int)
    case recentLow
    case veryHigh
    case capped(calculated: Double, max: Double)
    case recentBolus(minutes: Int)
    case exercise
    case pumpInsulinOnBoard
    case manualGlucose

    var level: BolusNoticeLevel {
        switch self {
        case .notSetUp, .turnedOff, .invalidSettings, .carbsOutOfRange, .low, .fallingFastTowardsLow: return .stop
        case .fallingFast, .noReading, .staleReading, .recentLow, .veryHigh, .capped: return .caution
        case .recentBolus, .exercise, .pumpInsulinOnBoard, .manualGlucose: return .info
        }
    }

    func text(unit: GlucoseUnit) -> String {
        switch self {
        case .notSetUp:
            return "Set up your carb ratio, correction factor and target first, as your diabetes team gave them to you."
        case .turnedOff:
            return "The bolus calculator is turned off in Settings."
        case .invalidSettings(let p):
            return "Your bolus settings need fixing: " + p.joined(separator: " ")
        case .carbsOutOfRange:
            return "Carbs must be between 0 and 500 g."
        case .low(let g):
            return "Glucose is low (\(unit.format(mgdl: g, withUnit: true))). Treat the low first. No bolus is suggested."
        case .fallingFastTowardsLow:
            return "Glucose is falling fast and could be low within 20 minutes. Check with a finger-prick and treat if needed. No bolus is suggested."
        case .fallingFast:
            return "Glucose is falling fast, so no correction was added. Consider waiting and checking again."
        case .noReading:
            return "No current glucose reading, so there's no correction. Insulin on board still comes off the food dose. Check with a finger-prick if you can."
        case .staleReading(let m):
            return "The last reading is \(m) minutes old, so there's no correction. Insulin on board still comes off the food dose."
        case .recentLow:
            return "You were low in the last hour. Glucose can drop again; consider a smaller dose."
        case .veryHigh:
            return "Glucose is very high. Check for ketones, and check your pump site or pen. Confirm with a finger-prick."
        case .capped(let c, let max):
            return "Worked out as \(LogFormat.units(c)), capped at your maximum of \(LogFormat.units(max))."
        case .recentBolus(let m):
            return "You logged a bolus \(m) minutes ago. It's counted as insulin on board."
        case .exercise:
            return "Exercise logged recently: insulin can work harder for hours afterwards."
        case .pumpInsulinOnBoard:
            return "Insulin on board only counts doses logged in GlucOS. If your pump shows more, use your pump's calculator."
        case .manualGlucose:
            return "Using the glucose you entered instead of the sensor."
        }
    }
}

/// What the calculator worked out, with every step so it can be shown.
struct BolusSuggestion: Hashable {
    let at: Date
    /// The time block whose settings were used. Nil when blocked before getting that far.
    let block: BolusScheduleBlock?
    let carbs: Double
    /// Glucose used for the correction, mg/dL. Nil when there was no current reading.
    let glucose: Double?
    /// mg/dL per minute over the last 15 minutes, when known.
    let ratePerMinute: Double?

    /// carbs ÷ carb ratio.
    let foodUnits: Double
    /// (glucose − target) ÷ correction factor, before insulin on board. Negative below target.
    /// 0 when there was no reading.
    let correctionUnits: Double
    /// A positive correction was left out because glucose is falling fast.
    let correctionWithheld: Bool
    /// Fast-acting insulin from logged doses that hasn't acted yet.
    let insulinOnBoard: Double
    /// How much of `insulinOnBoard` was taken off.
    let insulinOnBoardApplied: Double
    /// Before the cap and rounding.
    let calculated: Double
    /// What to show as the suggestion: capped, then rounded down to the increment. 0 when blocked.
    let units: Double
    let increment: Double
    let notices: [BolusNotice]

    var level: BolusNoticeLevel { notices.map(\.level).max() ?? .info }
    var isBlocked: Bool { level == .stop }
}

// MARK: - Calculator

enum BolusCalculator {
    /// Readings older than this aren't used for a correction.
    static let freshFor: TimeInterval = 15 * 60
    /// Faster than this (mg/dL per minute) counts as falling fast: Libre's ↓ arrow.
    static let fallingFastRate = -2.0
    /// How far ahead the "falling towards a low" check looks.
    static let lowLookahead: TimeInterval = 20 * 60
    /// The low gate is never set lower than this (3.9 mmol/L), even if the low alert is.
    static let minimumLowMgdl = 70.0
    /// At or above this, suggest checking for ketones.
    static let veryHighMgdl = 300.0

    static func suggest(_ r: BolusRequest, settings: BolusSettings?, calendar: Calendar = .current) -> BolusSuggestion {
        var notices: [BolusNotice] = []
        func blocked(_ n: BolusNotice, block: BolusScheduleBlock? = nil, glucose: Double? = nil,
                     rate: Double? = nil, iob: Double = 0) -> BolusSuggestion {
            BolusSuggestion(at: r.now, block: block, carbs: r.carbs, glucose: glucose, ratePerMinute: rate,
                            foodUnits: 0, correctionUnits: 0, correctionWithheld: false, insulinOnBoard: iob,
                            insulinOnBoardApplied: 0, calculated: 0, units: 0,
                            increment: settings?.increment ?? 0.5, notices: notices + [n])
        }

        guard let settings, settings.isConfirmed else { return blocked(.notSetUp) }
        if settings.disabled { return blocked(.turnedOff) }
        let problems = settings.problems
        if !problems.isEmpty { return blocked(.invalidSettings(problems)) }
        guard r.carbs.isFinite, LogLimits.carbs.contains(r.carbs) else { return blocked(.carbsOutOfRange) }
        guard let block = settings.block(at: r.now, calendar: calendar) else { return blocked(.notSetUp) }

        let iob = InsulinActivity.compute(doses: r.doses.filter { $0.timestamp <= r.now }, at: r.now).onBoard

        // Glucose: a typed finger-prick wins; otherwise the latest sensor reading if it's fresh.
        let sorted = r.readings.filter { $0.timestamp <= r.now.addingTimeInterval(60) }
            .sorted { $0.timestamp < $1.timestamp }
        let latest = sorted.last
        var glucose: Double?
        var rate: Double?
        if let manual = r.manualGlucose, manual.isFinite, manual > 0 {
            glucose = manual
            notices.append(.manualGlucose)
        } else if let latest {
            let age = r.now.timeIntervalSince(latest.timestamp)
            if age <= freshFor {
                glucose = latest.mgdl
            } else {
                notices.append(.staleReading(minutes: Int((age / 60).rounded())))
            }
        } else {
            notices.append(.noReading)
        }
        if let latest, r.now.timeIntervalSince(latest.timestamp) <= freshFor {
            rate = ratePerMinute(sorted, at: latest.timestamp) ?? arrowRate(latest.trend)
        }

        // Low, or heading there fast: stop. Never below 3.9 mmol/L, whatever the low alert is set to.
        let low = max(r.lowMgdl, minimumLowMgdl)
        if let g = glucose, g < low {
            return blocked(.low(mgdl: g), block: block, glucose: g, rate: rate, iob: iob)
        }
        if let g = glucose, let rate, rate <= fallingFastRate, g + rate * lowLookahead / 60 < low {
            return blocked(.fallingFastTowardsLow, block: block, glucose: g, rate: rate, iob: iob)
        }

        let food = r.carbs / block.carbRatio
        var correction = 0.0
        var withheld = false
        if let g = glucose {
            correction = (g - block.targetMgdl) / block.correctionFactor
            if let rate, rate <= fallingFastRate, correction > 0 {
                withheld = true
                notices.append(.fallingFast)
            }
            if g >= veryHighMgdl { notices.append(.veryHigh) }
        }
        let usedCorrection = withheld ? 0 : correction

        var total: Double
        var iobApplied: Double
        if glucose != nil && !withheld && usedCorrection >= 0 {
            // At or above target: on-board insulin offsets the correction, never the food.
            iobApplied = min(iob, usedCorrection)
            total = food + usedCorrection - iobApplied
        } else {
            // Below target, no reading, or falling fast: on-board insulin comes off the food dose too.
            let before = food + usedCorrection
            iobApplied = min(iob, max(0, before))
            total = max(0, before - iob)
        }
        if !total.isFinite { total = 0 }

        var final = total
        if total > settings.maxBolus {
            final = settings.maxBolus
            notices.append(.capped(calculated: roundDown(total, to: 0.01), max: settings.maxBolus))
        }
        final = roundDown(final, to: settings.increment)

        // Context worth knowing.
        let hourAgo = r.now.addingTimeInterval(-3600)
        let recentLowReading = sorted.contains { $0.timestamp >= hourAgo && $0.mgdl < r.lowMgdl }
        let recentHypoTreatment = r.contexts.contains {
            $0.tags.contains(.hypoTreatment) && $0.timestamp >= hourAgo && $0.timestamp <= r.now
        }
        if recentLowReading || recentHypoTreatment { notices.append(.recentLow) }
        if let last = r.doses.filter({ $0.kind.isBolus && $0.timestamp <= r.now }).max(by: { $0.timestamp < $1.timestamp }),
           r.now.timeIntervalSince(last.timestamp) < 3600 {
            notices.append(.recentBolus(minutes: max(0, Int((r.now.timeIntervalSince(last.timestamp) / 60).rounded()))))
        }
        if r.contexts.contains(where: {
            $0.tags.contains(.exercise) && $0.timestamp <= r.now && r.now.timeIntervalSince($0.timestamp) < ContextTag.exercise.reach
        }) {
            notices.append(.exercise)
        }
        if r.therapy == .pump { notices.append(.pumpInsulinOnBoard) }

        return BolusSuggestion(at: r.now, block: block, carbs: r.carbs, glucose: glucose, ratePerMinute: rate,
                               foodUnits: food, correctionUnits: correction, correctionWithheld: withheld,
                               insulinOnBoard: iob, insulinOnBoardApplied: iobApplied, calculated: total,
                               units: final, increment: settings.increment, notices: notices)
    }

    /// Rounds down to a multiple of `step`, clearing floating-point dust ("2.9999999" → 3).
    static func roundDown(_ value: Double, to step: Double) -> Double {
        guard step > 0, value.isFinite, value > 0 else { return 0 }
        let steps = (value / step + 1e-9).rounded(.down)
        return (steps * step * 1000).rounded() / 1000
    }

    /// Least-squares slope over the 15 minutes up to `end`, mg/dL per minute. Needs at least three
    /// readings spanning eight minutes.
    static func ratePerMinute(_ sorted: [GlucoseReading], at end: Date) -> Double? {
        let window = sorted.filter { $0.timestamp <= end && $0.timestamp >= end.addingTimeInterval(-15 * 60) }
        guard window.count >= 3, let first = window.first, let last = window.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 8 * 60 else { return nil }
        let x = window.map { $0.timestamp.timeIntervalSince(end) / 60 }
        let y = window.map(\.mgdl)
        return EngineMath.slope(x: x, y: y)
    }

    /// A rate for when there aren't enough readings to measure one: the middle of the arrow's band.
    static func arrowRate(_ trend: Trend) -> Double? {
        switch trend {
        case .fallingQuickly: return -2.5
        case .falling: return -1.5
        case .flat: return 0
        case .rising: return 1.5
        case .risingQuickly: return 2.5
        case .unknown: return nil
        }
    }
}

// MARK: - What was suggested, kept with the dose

/// The calculator's working, saved on the dose the user logged from it, so the logbook shows what
/// it was based on and the settings review can tell food insulin from correction insulin.
struct BolusCalculation: Codable, Hashable {
    var carbs: Double
    var glucose: Double?
    var carbRatio: Double
    var correctionFactor: Double
    var targetMgdl: Double
    var foodUnits: Double
    var correctionUnits: Double
    var insulinOnBoard: Double
    /// What the calculator suggested; the dose's own units are what the user actually took.
    var suggestedUnits: Double

    init(_ s: BolusSuggestion) {
        carbs = s.carbs
        glucose = s.glucose
        carbRatio = s.block?.carbRatio ?? 0
        correctionFactor = s.block?.correctionFactor ?? 0
        targetMgdl = s.block?.targetMgdl ?? 0
        foodUnits = s.foodUnits
        correctionUnits = s.correctionWithheld ? 0 : s.correctionUnits
        insulinOnBoard = s.insulinOnBoardApplied
        suggestedUnits = s.units
    }
}
