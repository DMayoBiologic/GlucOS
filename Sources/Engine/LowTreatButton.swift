import Foundation

// The "Log treatment" button on iPhone Today and in the Mac popover (docs/AlertActions.md,
// "Log treatment in the app").
//
// The alert's Log treatment button (#113, #187) only helps when the notification is in front of
// you. Open the app during a low and the quickest way to log the jelly beans was the log bar and
// three taps. So while glucose is low, or the forecast says a low is coming, Today and the popover
// show the same button inline. It opens the log sheet the alert button opens, filled in from the
// "Treat a low" usual when there is one, and never logs anything by itself.
//
// It goes once a treatment is logged (any food, or a hypo treatment tag, in the last 15 minutes:
// the "rule of 15" recheck, so a low still going a quarter of an hour after treating offers it
// again), or once the reading is back at or above the low line with no low predicted.

enum LowTreatButton {
    /// Why the button is showing.
    enum Reason: Equatable, Sendable {
        /// The latest fresh reading is below the low line.
        case low
        /// The forecast crosses the low line at this time (the predicted low alert's rule).
        case predicted(Date)
    }

    /// A treatment logged this recently (by its time) hides the button: time to let it work.
    static let treatedWithin: TimeInterval = 15 * 60
    /// Entries a few minutes in the future (another device's clock) still count as logged now.
    static let futureSlack: TimeInterval = 5 * 60

    /// The button's title, the same words as the alert button.
    static let title = AlertSnoozes.treatTitle

    /// Whether to show the button, and why. `mgdl` is the latest reading while it's fresh (nil when
    /// stale or missing: then nothing shows, as nothing is known). `predictedLowAt` is when the
    /// predicted low alert's rule (`PredictiveAlertRules`, low or urgent low) says the forecast
    /// crosses the line, if it does.
    static func reason(mgdl: Double?, lowMgdl: Double, predictedLowAt: Date?, meals: [MealEntry],
                       contexts: [ContextEvent], now: Date) -> Reason? {
        guard let mgdl else { return nil }
        let reason: Reason
        if mgdl < lowMgdl {
            reason = .low
        } else if let at = predictedLowAt {
            reason = .predicted(at)
        } else {
            return nil
        }
        return isTreated(meals: meals, contexts: contexts, now: now) ? nil : reason
    }

    /// Food or a hypo treatment tag logged in the last `treatedWithin`.
    static func isTreated(meals: [MealEntry], contexts: [ContextEvent], now: Date) -> Bool {
        func recent(_ t: Date) -> Bool {
            t >= now.addingTimeInterval(-treatedWithin) && t <= now.addingTimeInterval(futureSlack)
        }
        if meals.contains(where: { recent($0.timestamp) }) { return true }
        return contexts.contains { $0.tags.contains(.hypoTreatment) && recent($0.timestamp) }
    }

    /// The line beside the button: "Low now" or "Low predicted in about 12 min".
    static func caption(_ reason: Reason, now: Date) -> String {
        switch reason {
        case .low: return "Low now"
        case .predicted(let at):
            let m = minutes(until: at, from: now)
            return m <= 1 ? "Low predicted any minute" : "Low predicted in about \(m) min"
        }
    }

    /// What VoiceOver reads for the button: what it is for, in words.
    static func accessibilityLabel(_ reason: Reason, now: Date) -> String {
        switch reason {
        case .low: return "\(title) for this low"
        case .predicted(let at):
            let m = minutes(until: at, from: now)
            let when = m <= 1 ? "any minute" : "in about \(m) minutes"
            return "\(title). Low predicted \(when)"
        }
    }

    /// What VoiceOver says a tap does.
    static func accessibilityHint(hasUsual: Bool) -> String {
        hasUsual
            ? "Opens the log sheet filled in with your usual low treatment. Nothing is logged until you log it."
            : "Opens the log sheet on food, tagged as a hypo treatment. Nothing is logged until you log it."
    }

    private static func minutes(until at: Date, from now: Date) -> Int {
        max(0, Int((at.timeIntervalSince(now) / 60).rounded()))
    }
}
