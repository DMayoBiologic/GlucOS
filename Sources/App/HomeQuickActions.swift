import Foundation

// The iPhone's Home Screen quick actions: long-press the GlucOS icon (docs/iOS.md "Home Screen
// quick actions"). Each one opens the app on a screen the app already has, the same as Siri, the
// Control Center controls and the alert buttons: none of them logs anything by itself, and none
// fills in a dose.
// Plain Foundation so the list and the routing can be unit-tested (HomeQuickActionTests); the app
// turns `HomeQuickItem`s into UIApplicationShortcutItems and hands a tapped one's destination to
// `PhoneLogRouter.openQuickAction`.

enum HomeQuickAction: String, CaseIterable {
    case logTreatment = "log-treatment"
    case logMeal = "log-meal"
    case logInsulin = "log-insulin"
    /// "What's my glucose". The raw value is from when it was called Latest reading: iOS keeps the
    /// items between launches, so it stays.
    case latestReading = "latest-reading"

    /// Where a quick action takes the app.
    enum Destination: Equatable {
        /// The log sheet for treating a low: the same sheet as the alert's "Log treatment" button,
        /// the inline button, the Siri shortcut and the Control Center control (`.treating(.low)`).
        case treating(AlertTreatment)
        /// The log sheet, started on this part, empty.
        case log(LogPart)
        /// The log sheet filled in from this "Your usual" entry (`UsualEntry.id`), the same as the
        /// Your usual widget's button: worked out again on open, never logged until Log.
        case usual(id: String)
        /// The reading: Today, back at the top of the stack, with a fresh fetch. On a follower-only
        /// phone, the people it follows.
        case today
    }

    /// How this phone uses GlucOS (`PhoneMode` in the app).
    enum Mode: Equatable {
        /// Wears a sensor: logs its own readings, so every action.
        case sensor
        /// Only follows other people: no log sheet, so only the reading.
        case follower
        /// Hasn't picked yet: the welcome screen, so none.
        case unset
    }

    /// `UIApplicationShortcutItem.type`. Kept stable: iOS remembers the items between launches.
    static let typePrefix = "glucos.quick."
    /// A "Your usual" item's type is this plus the entry's id: `glucos.quick.usual.meal-breakfast`.
    static let usualTypePrefix = typePrefix + "usual."

    /// The most items iOS shows on the Home Screen. Anything past this is never seen.
    static let limit = 4

    var type: String { Self.typePrefix + rawValue }

    /// The action an item's `type` names. Nil for anything else, including a usual's item and items
    /// from an older build that this one no longer offers.
    init?(type: String) {
        guard type.hasPrefix(Self.typePrefix) else { return nil }
        self.init(rawValue: String(type.dropFirst(Self.typePrefix.count)))
    }

    var title: String {
        switch self {
        case .logTreatment: return "Log treatment"
        case .logMeal: return "Log meal"
        case .logInsulin: return "Log insulin"
        case .latestReading: return "What's my glucose"
        }
    }

    var subtitle: String {
        switch self {
        case .logTreatment: return "Treat a low"
        case .logMeal: return "Food and carbs"
        case .logInsulin: return "A dose you took"
        case .latestReading: return "Today and the forecast"
        }
    }

    /// SF Symbol for `UIApplicationShortcutIcon(systemImageName:)`.
    var symbol: String {
        switch self {
        case .logTreatment: return "cross.case"
        case .logMeal: return "fork.knife"
        case .logInsulin: return "syringe"
        case .latestReading: return "drop"
        }
    }

    var destination: Destination {
        switch self {
        case .logTreatment: return .treating(.low)
        case .logMeal: return .log(.food)
        // Empty: the dose step's calculator or the user's own typing fills the units, never this.
        case .logInsulin: return .log(.insulin)
        case .latestReading: return .today
        }
    }

    /// Opens a log sheet. A follower-only phone has none, so it never gets these.
    var logs: Bool { self != .latestReading }

    var item: HomeQuickItem {
        HomeQuickItem(type: type, title: title, subtitle: subtitle, symbol: symbol, destination: destination)
    }

    /// What an entry saved from a quick action's sheet is highlighted with (`LoggedElsewhere`).
    static let origin: LogOrigin = .homeScreen

    // MARK: The list

    /// The "Your usual" entry offered on the Home Screen: the usual meal for this part of the day,
    /// if there is one and its part of the day isn't over. Not the usual correction (a dose amount,
    /// and only while a fresh high lasts, which the Home Screen can't follow) and not Treat a low
    /// (Log treatment already fills in from it).
    static func topUsual(_ usuals: [UsualGlance], at now: Date) -> UsualGlance? {
        usuals.first { u in
            guard u.kind == .meal else { return false }
            if let until = u.until, until <= now { return false }
            return true
        }
    }

    /// The items to offer, in Home Screen order (the first sits nearest the icon). iOS shows four at
    /// most, so the usual meal takes Log meal's place: it opens the same sheet on food, filled in.
    static func items(mode: Mode, usuals: [UsualGlance] = [], at now: Date = Date()) -> [HomeQuickItem] {
        switch mode {
        case .unset:
            return []
        case .follower:
            return [HomeQuickItem(type: latestReading.type, title: "Latest readings",
                                  subtitle: "People you follow", symbol: latestReading.symbol, destination: .today)]
        case .sensor:
            var items = allCases.map(\.item)
            if let usual = topUsual(usuals, at: now), let i = items.firstIndex(where: { $0.type == logMeal.type }) {
                items[i] = HomeQuickItem(usual)
            }
            return Array(items.prefix(limit))
        }
    }

    /// Where a tapped item takes this phone now, or nil to do nothing: anything that isn't ours, and
    /// a logging item left over from before the phone switched to following. A usual's item opens
    /// its entry even if the list has moved on since: the sheet works the entry out again on open
    /// and, if it's no longer offered, starts on food with nothing filled in.
    static func resolve(type: String, mode: Mode) -> Destination? {
        switch mode {
        case .unset:
            return nil
        case .follower:
            return HomeQuickAction(type: type) == .latestReading ? .today : nil
        case .sensor:
            if let action = HomeQuickAction(type: type) { return action.destination }
            guard type.hasPrefix(usualTypePrefix) else { return nil }
            let id = String(type.dropFirst(usualTypePrefix.count))
            return id.isEmpty ? nil : .usual(id: id)
        }
    }
}

/// One Home Screen item, as the app hands it to iOS.
struct HomeQuickItem: Equatable {
    var type: String
    var title: String
    var subtitle: String
    var symbol: String
    var destination: HomeQuickAction.Destination
}

extension HomeQuickItem {
    /// A "Your usual" entry's item: "Usual breakfast", "Toast and banana · 45 g".
    init(_ usual: UsualGlance) {
        self.init(type: HomeQuickAction.usualTypePrefix + usual.id, title: usual.title, subtitle: usual.detail,
                  symbol: usual.systemImage, destination: .usual(id: usual.id))
    }
}
