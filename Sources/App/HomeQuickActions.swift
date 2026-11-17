import Foundation

// The iPhone's Home Screen quick actions: long-press the GlucOS icon (docs/iOS.md "Home Screen
// quick actions"). Each one opens the app on a screen the app already has, the same as Siri, the
// Control Center controls and the alert buttons: none of them logs anything by itself.
// Plain Foundation so the routing can be unit-tested (HomeQuickActionTests); the app turns these
// into UIApplicationShortcutItems and hands a tapped one to `PhoneLogRouter.openQuickAction`.

enum HomeQuickAction: String, CaseIterable {
    case logTreatment = "log-treatment"
    case logMeal = "log-meal"
    case latestReading = "latest-reading"

    /// Where a quick action takes the app.
    enum Destination: Equatable {
        /// The log sheet for treating a low: the same sheet as the alert's "Log treatment" button,
        /// the inline button, the Siri shortcut and the Control Center control (`.treating(.low)`).
        case treating(AlertTreatment)
        /// The log sheet, started on this part.
        case log(LogPart)
        /// Today, back at the top of the stack, with a fresh fetch of the reading.
        case today
    }

    /// `UIApplicationShortcutItem.type`. Kept stable: iOS remembers the items between launches.
    static let typePrefix = "glucos.quick."

    var type: String { Self.typePrefix + rawValue }

    /// The action an item's `type` names. Nil for anything else, including items from an older
    /// build that this one no longer offers.
    init?(type: String) {
        guard type.hasPrefix(Self.typePrefix) else { return nil }
        self.init(rawValue: String(type.dropFirst(Self.typePrefix.count)))
    }

    var title: String {
        switch self {
        case .logTreatment: return "Log treatment"
        case .logMeal: return "Log meal"
        case .latestReading: return "Latest reading"
        }
    }

    var subtitle: String {
        switch self {
        case .logTreatment: return "Treat a low"
        case .logMeal: return "Food and carbs"
        case .latestReading: return "Today and the forecast"
        }
    }

    /// SF Symbol for `UIApplicationShortcutIcon(systemImageName:)`.
    var symbol: String {
        switch self {
        case .logTreatment: return "cross.case"
        case .logMeal: return "fork.knife"
        case .latestReading: return "drop"
        }
    }

    var destination: Destination {
        switch self {
        case .logTreatment: return .treating(.low)
        case .logMeal: return .log(.food)
        case .latestReading: return .today
        }
    }

    /// What an entry saved from a quick action's sheet is highlighted with (`LoggedElsewhere`).
    static let origin: LogOrigin = .homeScreen

    /// The items to offer, in Home Screen order (the first sits nearest the icon). Only a phone
    /// that logs its own readings gets them: a follower-only phone, or one that hasn't picked yet,
    /// has no log sheet and no reading of its own, so it gets none.
    static func offered(logsOwnReadings: Bool) -> [HomeQuickAction] {
        logsOwnReadings ? allCases : []
    }

    /// A tapped item's action, if this phone should act on it now. An item left over from before
    /// the phone switched to following does nothing.
    static func resolve(type: String, logsOwnReadings: Bool) -> HomeQuickAction? {
        guard let action = HomeQuickAction(type: type), offered(logsOwnReadings: logsOwnReadings).contains(action) else {
            return nil
        }
        return action
    }
}
