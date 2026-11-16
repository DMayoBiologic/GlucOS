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
// The trend: glucose moving shifts the correction by where it will be in 30 minutes at the
// measured rate (beyond ±0.5 mg/dL per minute, counted up to 3). A fall always takes insulin off,
// and can come off the food dose. A rise only adds insulin if the user turned that on. This is the
// published "trend arrow" adjustment (Pettus & Edelman 2017, Aleppo et al. 2017) done with the
// measured rate; it is not the glucose forecast. An exercise reduction the user picks comes off
// last, before the cap and rounding.
//
// That's the rule Tandem's pumps use: insulin still on board only cancels out a correction when
// glucose is high, but when glucose is under target it comes off the food bolus too. Without a
// current reading there's no correction, and insulin on board still comes off the food bolus.
// The total is capped at the user's maximum, then rounded *down* to their increment.
//
// Safety gates: no suggestion while glucose is low, or falling towards a low within 20 minutes;
// corrections are left out when glucose is falling fast or the reading is old. A high that hasn't
// come down since a dose 1½–4 hours ago raises a site / pen check. Everything the user sees carries
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
    /// Add insulin for a rising trend. Off unless the user turns it on (nil on settings saved before
    /// this existed). A falling trend always takes insulin off.
    var addsForRisingTrend: Bool? = nil

    var risingTrendAdds: Bool { addsForRisingTrend == true }

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
    /// A reduction the user picked for exercise (0, 0.25 or 0.5). Comes off the total.
    var reduction: Double = 0
}

/// Reductions offered for exercise, the usual 25% and 50% starting points.
enum BolusReduction {
    static let choices: [Double] = [0, 0.25, 0.5]
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
    case fallingTowardsLow
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
    case trendLowered
    case trendRaised
    case notComingDown(units: Double, minutesAgo: Int)
    case possibleRepeat(units: Double, minutesAgo: Int)
    case reduced(percent: Int)

    var level: BolusNoticeLevel {
        switch self {
        case .notSetUp, .turnedOff, .invalidSettings, .carbsOutOfRange, .low, .fallingTowardsLow: return .stop
        case .fallingFast, .noReading, .staleReading, .recentLow, .veryHigh, .capped, .notComingDown, .possibleRepeat:
            return .caution
        case .recentBolus, .exercise, .pumpInsulinOnBoard, .manualGlucose, .trendLowered, .trendRaised, .reduced:
            return .info
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
        case .fallingTowardsLow:
            return "Glucose is falling and could be low within 20 minutes. Check with a finger-prick and treat if needed, then check again. No bolus is suggested."
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
            return "Exercise logged recently: insulin can work harder for hours afterwards. Consider a reduction."
        case .pumpInsulinOnBoard:
            return "Insulin on board only counts doses logged in GlucOS. If your pump shows more, use your pump's calculator."
        case .manualGlucose:
            return "Using the glucose you entered instead of the sensor."
        case .trendLowered:
            return "Glucose is falling, so the dose allows for where it's heading in the next 30 minutes."
        case .trendRaised:
            return "Glucose is rising, so the dose allows for where it's heading in the next 30 minutes (turned on in your settings)."
        case .notComingDown(let u, let m):
            return "Glucose is higher now than when you took \(LogFormat.units(u)) \(m) minutes ago. Check your pump site or pen and needle, and check for ketones. If you use a pump, consider an injection by pen."
        case .possibleRepeat(let u, let m):
            return "You took \(LogFormat.units(u)) for about the same carbs \(m) minutes ago. If this is the same meal, don't dose again. That dose only counts as insulin on board against a correction."
        case .reduced(let p):
            return "Reduced by \(p)% for exercise, as you chose."
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
    /// Units for where the trend takes glucose in 30 minutes: negative when falling, positive when
    /// rising (only if the user turned that on), 0 otherwise.
    let trendUnits: Double
    /// mg/dL the trend shifted the glucose used, matching `trendUnits`.
    let trendMgdl: Double
    /// Fast-acting insulin from logged doses that hasn't acted yet.
    let insulinOnBoard: Double
    /// How much of `insulinOnBoard` was taken off.
    let insulinOnBoardApplied: Double
    /// Share taken off for exercise (0, 0.25, 0.5), and the units that came to.
    let reduction: Double
    let reductionUnits: Double
    /// Before the cap and rounding.
    let calculated: Double
    /// What to show as the suggestion: capped, then rounded down to the increment. 0 when blocked.
    let units: Double
    let increment: Double
    let notices: [BolusNotice]

    var level: BolusNoticeLevel { notices.map(\.level).max() ?? .info }
    var isBlocked: Bool { level == .stop }
}

extension BolusSuggestion {
    /// Whether a suggestion the user took still stands, given what the calculator says now (nil when
    /// it can't say, e.g. a finger-prick box ticked with no number). It falls the moment the calculator
    /// would block, the carbs differ, or it would now suggest less, e.g. after a new low reading or a
    /// settings change. A small rise as insulin on board wears off doesn't undo it.
    func stillStands(given live: BolusSuggestion?) -> Bool {
        guard let live, !isBlocked, !live.isBlocked, abs(live.carbs - carbs) < 0.001 else { return false }
        return live.units + 1e-6 >= units
    }
}

// MARK: - Calculator

enum BolusCalculator {
    /// Readings older than this aren't used for a correction.
    static let freshFor: TimeInterval = 15 * 60
    /// Faster than this (mg/dL per minute) counts as falling fast: Libre's ↓ arrow.
    static let fallingFastRate = -2.0
    /// How far ahead the "falling towards a low" check looks.
    static let lowLookahead: TimeInterval = 20 * 60
    /// Falling at least this fast (mg/dL per minute, Libre's ↘ arrow) is checked for a low ahead.
    static let fallingRate = -1.0
    /// Trend adjustment: rates within this of flat don't count (mg/dL per minute)...
    static let trendDeadband = 0.5
    /// ...nor does anything beyond this...
    static let trendMaxRate = 3.0
    /// ...and the shift is where that rate gets to in this long.
    static let trendHorizonMinutes = 30.0
    /// A dose this long ago (and no longer) that glucose hasn't come down from raises a site check.
    static let notComingDownWindow: ClosedRange<TimeInterval> = (90 * 60)...(4 * 3600)
    /// Only for highs at or above this (13.9 mmol/L), when the dose was taken at 200 mg/dL or more.
    static let notComingDownMgdl = 250.0
    /// The low gate is never set lower than this (3.9 mmol/L), even if the low alert is.
    static let minimumLowMgdl = 70.0
    /// At or above this, suggest checking for ketones.
    static let veryHighMgdl = 300.0

    static func suggest(_ r: BolusRequest, settings: BolusSettings?, calendar: Calendar = .current) -> BolusSuggestion {
        var notices: [BolusNotice] = []
        func blocked(_ n: BolusNotice, block: BolusScheduleBlock? = nil, glucose: Double? = nil,
                     rate: Double? = nil, iob: Double = 0) -> BolusSuggestion {
            BolusSuggestion(at: r.now, block: block, carbs: r.carbs, glucose: glucose, ratePerMinute: rate,
                            foodUnits: 0, correctionUnits: 0, correctionWithheld: false, trendUnits: 0, trendMgdl: 0,
                            insulinOnBoard: iob, insulinOnBoardApplied: 0, reduction: 0, reductionUnits: 0,
                            calculated: 0, units: 0,
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
        /// The 15-minute least-squares rate, without the arrow fallback. Only this can add insulin.
        var measuredRate: Double?
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
            measuredRate = ratePerMinute(sorted, at: latest.timestamp)
            rate = measuredRate ?? arrowRate(latest.trend)
        }

        // Low, or heading there fast: stop. Never below 3.9 mmol/L, whatever the low alert is set to.
        let low = max(r.lowMgdl, minimumLowMgdl)
        if let g = glucose, g < low {
            return blocked(.low(mgdl: g), block: block, glucose: g, rate: rate, iob: iob)
        }
        if let g = glucose, let rate, rate <= fallingRate, g + rate * lowLookahead / 60 < low {
            return blocked(.fallingTowardsLow, block: block, glucose: g, rate: rate, iob: iob)
        }
        let reduction = BolusReduction.choices.contains(r.reduction) ? r.reduction : 0

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
        // The trend, only with a current sensor rate behind the glucose used.
        var trendMgdl = 0.0
        if glucose != nil, let rate {
            let counted = min(max(abs(rate) - trendDeadband, 0), trendMaxRate - trendDeadband)
            let shift = (rate < 0 ? -counted : counted) * trendHorizonMinutes
            // A fall may come from the arrow alone (it only lowers the dose); a rise needs a measured rate.
            if shift < 0 || (shift > 0 && settings.risingTrendAdds && measuredRate != nil) { trendMgdl = shift }
        }
        let trend = trendMgdl / block.correctionFactor
        if trend < -0.005 { notices.append(.trendLowered) }
        if trend > 0.005 { notices.append(.trendRaised) }

        let usedCorrection = (withheld ? 0 : correction) + trend

        var total: Double
        var iobApplied: Double
        // Which rule applies is decided by glucose against target, before the trend: below target,
        // on-board insulin always comes off the food dose too, even if a rise lifts the correction.
        if glucose != nil && !withheld && correction >= 0 && usedCorrection >= 0 {
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
        let reductionUnits = total * reduction
        total -= reductionUnits
        if reduction > 0 { notices.append(.reduced(percent: Int((reduction * 100).rounded()))) }

        var final = total
        if total > settings.maxBolus {
            final = settings.maxBolus
            notices.append(.capped(calculated: roundDown(total, to: 0.01), max: settings.maxBolus))
        }
        final = roundDown(final, to: settings.increment)

        // Context worth knowing.
        let hourAgo = r.now.addingTimeInterval(-3600)
        let recentLowReading = sorted.contains { $0.timestamp >= hourAgo && $0.mgdl < low }
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
        if let g = glucose, let stuck = notComingDown(from: r.doses, readings: sorted, glucose: g, now: r.now) {
            notices.append(stuck)
        }
        if let again = possibleRepeat(carbs: r.carbs, doses: r.doses, now: r.now) { notices.append(again) }
        if r.therapy == .pump { notices.append(.pumpInsulinOnBoard) }

        return BolusSuggestion(at: r.now, block: block, carbs: r.carbs, glucose: glucose, ratePerMinute: rate,
                               foodUnits: food, correctionUnits: correction, correctionWithheld: withheld,
                               trendUnits: trend, trendMgdl: trendMgdl,
                               insulinOnBoard: iob, insulinOnBoardApplied: iobApplied,
                               reduction: reduction, reductionUnits: reductionUnits, calculated: total,
                               units: final, increment: settings.increment, notices: notices)
    }

    /// How far back, and how close in carbs, a dose from the calculator counts as maybe the same meal.
    static let repeatWindow: TimeInterval = 45 * 60
    static let repeatCarbShare = 0.10

    /// A calculator dose for about the same carbs in the last 45 minutes: the meal may have been logged
    /// twice (e.g. on the Mac and the iPhone), and a second full food dose would double it.
    static func possibleRepeat(carbs: Double, doses: [InsulinDose], now: Date) -> BolusNotice? {
        guard carbs >= 5 else { return nil }
        let match = doses.filter { d in
            guard let c = d.calculation, c.carbs > 0, d.kind.isBolus else { return false }
            let age = now.timeIntervalSince(d.timestamp)
            return age >= 0 && age <= repeatWindow && abs(c.carbs - carbs) <= repeatCarbShare * max(c.carbs, carbs)
        }.max { $0.timestamp < $1.timestamp }
        guard let match else { return nil }
        return .possibleRepeat(units: match.units, minutesAgo: Int((now.timeIntervalSince(match.timestamp) / 60).rounded()))
    }

    /// A high that hasn't come down since a fast-acting dose 1½–4 hours ago, taken when glucose was
    /// already 200 mg/dL or more: the usual sign of a blocked pump site, a bad pen or spoiled insulin.
    /// The latest such dose is named.
    static func notComingDown(from doses: [InsulinDose], readings sorted: [GlucoseReading], glucose: Double,
                              now: Date) -> BolusNotice? {
        guard glucose >= notComingDownMgdl else { return nil }
        let candidates = doses.filter {
            !$0.kind.fastComponents.isEmpty && $0.units >= 0.5
                && notComingDownWindow.contains(now.timeIntervalSince($0.timestamp))
        }.sorted { $0.timestamp > $1.timestamp }
        for d in candidates {
            // The reading nearest the dose, within 10 minutes.
            guard let at = sorted.min(by: { abs($0.timestamp.timeIntervalSince(d.timestamp)) < abs($1.timestamp.timeIntervalSince(d.timestamp)) }),
                  abs(at.timestamp.timeIntervalSince(d.timestamp)) <= 10 * 60 else { continue }
            if at.mgdl >= 200 && glucose >= at.mgdl {
                return .notComingDown(units: d.units, minutesAgo: Int((now.timeIntervalSince(d.timestamp) / 60).rounded()))
            }
        }
        return nil
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
    /// Units for the trend (nil on doses logged before the trend was counted).
    var trendUnits: Double? = nil
    var insulinOnBoard: Double
    /// Share taken off for exercise, when one was chosen.
    var reduction: Double? = nil
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
        trendUnits = s.trendUnits
        insulinOnBoard = s.insulinOnBoardApplied
        reduction = s.reduction > 0 ? s.reduction : nil
        suggestedUnits = s.units
    }
}
