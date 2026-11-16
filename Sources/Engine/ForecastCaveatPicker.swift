import Foundation

// Picks the one line that says why the forecast isn't an ordinary one: hidden, following the trend
// alone while insulin or carbs are acting, drawn less far ahead than usual, or with a wider range.
// The most serious wins, so the line answers the first question someone has looking at it ("why
// is there no forecast?" before "why is the range wide?"). The other limitations stay in the Mac's
// fuller list.

extension ForecastCaveat {
    /// Widening from the forecasts shown on this device worth mentioning: a quarter wider or more.
    static let noticeableRangeScale = 1.25

    /// The caveat for this forecast, or nil when it's an ordinary one.
    static func pick(_ forecast: Result<GlucoseForecast, ForecastFailure>) -> ForecastCaveat? {
        switch forecast {
        case .failure(let failure):
            return hidden(failure)
        case .success(let f):
            return trendOnly(f) ?? shortened(f) ?? widened(f)
        }
    }

    private static func hidden(_ failure: ForecastFailure) -> ForecastCaveat {
        let reason = failure.reason
        let source = "unavailable:\(reason.code)"
        // This device's own recent forecasts lost to no change even 15 minutes ahead.
        if let live = failure.limitations.first(where: \.isLiveHorizon) {
            return ForecastCaveat(live, kind: .hidden)
        }
        // Even the trend alone hasn't beaten "no change" in this situation: say which situation.
        if case .notAccurateEnough = reason, let forcing = trendOnlyOrder.first(where: { failure.limitations.contains($0) }) {
            return ForecastCaveat(kind: .hidden, text: "No forecast: past forecasts weren't accurate enough here.",
                                  detail: "\(reason.message) \(forcing.message)", source: source)
        }
        return ForecastCaveat(kind: .hidden, text: reason.message, detail: nil, source: source)
    }

    /// Most specific first: a site problem or uncounted food explain more than "still learning".
    static let trendOnlyOrder: [ForecastLimitation] = [
        .deliveryProblem, .uncountedFood, .freshLog, .insulinNotLearned, .carbsNotLearned,
    ]

    private static func trendOnly(_ f: GlucoseForecast) -> ForecastCaveat? {
        guard f.basis == .trend, let l = trendOnlyOrder.first(where: { f.limitations.contains($0) }) else { return nil }
        return ForecastCaveat(l, kind: .trendOnly)
    }

    /// How far ahead a forecast of this kind is usually drawn.
    static func usualHorizon(_ f: GlucoseForecast) -> TimeInterval {
        f.basis == .trend ? GlucoseForecaster.trendHorizon : GlucoseForecaster.modelHorizon
    }

    private static func shortened(_ f: GlucoseForecast) -> ForecastCaveat? {
        if let live = f.limitations.first(where: \.isLiveHorizon) { return ForecastCaveat(live, kind: .shortened) }
        let usual = usualHorizon(f)
        guard f.horizon > 0, f.horizon < usual - 60 else { return nil }
        if f.insulinOnly { return ForecastCaveat(.insulinOnly, kind: .shortened) }
        let minutes = Int((f.horizon / 60).rounded())
        let ahead = minutes < 60 || minutes % 60 != 0 ? "\(minutes) min" : "\(minutes / 60) h"
        if !f.calibrated {
            return ForecastCaveat(kind: .shortened,
                                  text: "Drawn only \(ahead) ahead: not yet checked against enough of your history.",
                                  detail: ForecastLimitation.uncalibrated.message, source: "uncalibratedHorizon")
        }
        return ForecastCaveat(kind: .shortened,
                              text: "Drawn only \(ahead) ahead: further out, past forecasts weren't closer than no change.",
                              detail: "GlucOS replays its forecasts against your history and only draws them as far ahead as they beat assuming glucose stays where it is.",
                              source: "calibratedHorizon")
    }

    private static func widened(_ f: GlucoseForecast) -> ForecastCaveat? {
        if let context = f.limitations.first(where: { if case .context = $0 { return true } else { return false } }) {
            return ForecastCaveat(context, kind: .widened)
        }
        if f.rangeScale >= noticeableRangeScale {
            return ForecastCaveat(kind: .widened,
                                  text: "Wider range: recent forecasts here missed by more than their range allowed.",
                                  detail: "The likely range is drawn wider to match how the forecasts shown on this device actually did.",
                                  source: "rangeScale")
        }
        if f.limitations.contains(.uncalibrated) {
            return ForecastCaveat(.uncalibrated, kind: .widened)
        }
        return nil
    }
}

extension ForecastLimitation {
    var isLiveHorizon: Bool { if case .liveHorizon = self { return true } else { return false } }
}

extension ForecastCaveat {
    init(_ limitation: ForecastLimitation, kind: Kind) {
        self.init(kind: kind, text: limitation.shortReason, detail: limitation.message, source: limitation.code)
    }
}
