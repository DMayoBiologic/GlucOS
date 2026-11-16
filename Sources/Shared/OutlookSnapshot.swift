import Foundation

// The short-term outlook the app works out and the widget shows: a glucose forecast with its
// likely range, and how much logged insulin and carbohydrate is still acting. Everything here is
// an estimate. It's never shown as a reading, never in a reading's colour, and never offered as
// advice on what to dose or eat.

/// What a forecast was built from.
enum ForecastBasis: String, Codable, Hashable, CaseIterable {
    /// The recent trend only, fading out over half an hour.
    case trend
    /// The recent trend handing over to the logged insulin and carbs still acting.
    case trendInsulinCarbs

    var title: String {
        switch self {
        case .trend: return "Recent trend"
        case .trendInsulinCarbs: return "Trend, insulin and carbs"
        }
    }
}

struct ForecastSample: Codable, Hashable, Identifiable {
    let date: Date
    let mgdl: Double
    /// The likely range: about 8 in 10 past forecasts at this distance landed inside it.
    let lowerMgdl: Double
    let upperMgdl: Double

    var id: Date { date }
}

/// What the widget and the popover need. Written into `GlucoseSnapshot.outlook`.
struct OutlookSnapshot: Codable, Hashable {
    /// The reading the forecast starts from.
    var issuedAt: Date
    var basis: ForecastBasis
    /// From the starting reading forward, every 5 minutes. Empty when no forecast could be made.
    var forecast: [ForecastSample] = []
    /// Fast-acting insulin not yet acted, units. Nil when no insulin is logged.
    var insulinOnBoard: Double?
    /// When the logged fast-acting insulin will have mostly finished acting.
    var insulinMostlyDoneAt: Date?
    /// Logged carbs not yet absorbed, grams.
    var carbsOnBoard: Double?
    /// When the forecast's central line first goes below the low threshold.
    var lowExpectedAt: Date?
    /// When the forecast's likely range first reaches below the low threshold.
    var lowPossibleAt: Date?
    /// From above range: when the forecast's central line comes back down to the high threshold.
    /// Nil when it doesn't within the drawn forecast, or while this device's checks of the
    /// estimate miss by more than 15 minutes typically (`BackInRange`).
    var backInRangeAt: Date?
    /// Plain-language reason no forecast is shown, if none is.
    var unavailableReason: String?
    /// The user's usual post-wake rise, when the forecast includes it.
    var morning: MorningAdjustmentSnapshot?
    /// Why the forecast is hidden, trend-only, shorter or wider than usual, in one plain line.
    /// Nil when it's an ordinary forecast.
    var caveat: ForecastCaveat?

    /// Only usable while the reading it started from is still current.
    func isCurrent(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) <= GlucoseSnapshot.staleAfter
    }

    var horizon: TimeInterval { forecast.last.map { $0.date.timeIntervalSince(issuedAt) } ?? 0 }

    /// The forecast point nearest `minutes` after the starting reading.
    func sample(minutesAhead minutes: Double) -> ForecastSample? {
        let target = issuedAt.addingTimeInterval(minutes * 60)
        guard let last = forecast.last, last.date >= target.addingTimeInterval(-60) else { return nil }
        return forecast.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }

    /// The insulin numbers are worth showing.
    var showsInsulin: Bool { (insulinOnBoard ?? 0) >= 0.05 }
    var showsCarbs: Bool { (carbsOnBoard ?? 0) >= 1 }
}

// MARK: - Caveat

/// The one thing that most limits the forecast right now, said in one plain line ("Trend only for
/// now: a meal or dose was logged in the last hour"). Worked out by the engine
/// (`ForecastCaveat.pick`) from the forecast's limitations; the Outlook detail on iPhone and Mac
/// shows it next to the forecast it explains.
struct ForecastCaveat: Codable, Hashable {
    /// What happened to the forecast, most serious first.
    enum Kind: String, Codable, Hashable, CaseIterable {
        /// No forecast is shown.
        case hidden
        /// The forecast follows the trend alone, though insulin or carbs are acting.
        case trendOnly
        /// The forecast stops sooner than it usually would.
        case shortened
        /// The likely range is drawn wider than usual.
        case widened

        var systemImage: String {
            switch self {
            case .hidden: return "eye.slash"
            case .trendOnly: return "arrow.forward"
            case .shortened: return "arrow.right.to.line"
            case .widened: return "arrow.up.and.down"
            }
        }
    }

    var kind: Kind
    /// The line itself.
    var text: String
    /// The fuller explanation, for a tooltip or VoiceOver hint.
    var detail: String?
    /// The limitation (or unavailable reason) it came from, by its stable code.
    var source: String
}

// MARK: - Mornings

/// How far a learnt morning pattern can be trusted, from how many mornings it's seen and how
/// much it improved past forecasts in a check that left each morning out.
enum MorningConfidence: String, Codable, Hashable, CaseIterable {
    case low, moderate, high

    var title: String {
        switch self {
        case .low: return "Low confidence"
        case .moderate: return "Moderate confidence"
        case .high: return "High confidence"
        }
    }
}

/// The post-wake adjustment in the current forecast, for the popover, widget and iPhone.
struct MorningAdjustmentSnapshot: Codable, Hashable {
    /// The logged wake-up the adjustment counts from.
    var wokeAt: Date
    /// How much the adjustment moves the forecast's last point, mg/dL (negative: a fall).
    var addedMgdl: Double
    var confidence: MorningConfidence
}

// MARK: - Back in range

/// "Back in range ≈ 25 min" (`BackInRange`, docs/ForecastAccuracy.md §24), worded once for the
/// iPhone Today card, the Mac popover and the Mac menu bar tooltip, so every place shows the same
/// estimate under the same rules.
enum BackInRangeText {
    /// Minutes from the reading, rounded to 5 like every forecast time (never under 5).
    static func minutes(_ back: Date, from reading: Date) -> Int {
        max(5, Int((back.timeIntervalSince(reading) / 300).rounded()) * 5)
    }

    /// "Back in range ≈ 25 min".
    static func short(minutes: Int) -> String { "Back in range ≈ \(minutes) min" }

    static func spoken(minutes: Int) -> String {
        "Back in range in about \(minutes) minutes if nothing else changes"
    }

    /// "Back in range ≈ 25 min (around 10:40 am) if nothing else changes": the clock time keeps
    /// the tooltip true while it sits unchanged between readings.
    static func toolTip(minutes: Int, reading: Date, calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String {
        let at = ClockLabel.time(reading.addingTimeInterval(Double(minutes) * 60), calendar: calendar, locale: locale)
        return "Back in range ≈ \(minutes) min (around \(at)) if nothing else changes"
    }
}

extension GlucoseSnapshot {
    /// When the forecast says a high comes back into range, if that may be shown now: only while
    /// the reading is live and above range, the outlook belongs to it, no low is expected, and
    /// this device's own checks of the estimate keep it within 15 minutes (`backInRangeAt` is nil
    /// otherwise). Never for a low.
    func backInRange(at now: Date = Date()) -> (date: Date, minutes: Int)? {
        guard let current, !isStale(at: now), let outlook, outlook.isCurrent(at: now),
              outlook.lowExpectedAt == nil, let back = outlook.backInRangeAt,
              current.mgdl > highMgdl, back > current.timestamp else { return nil }
        return (back, BackInRangeText.minutes(back, from: current.timestamp))
    }
}
