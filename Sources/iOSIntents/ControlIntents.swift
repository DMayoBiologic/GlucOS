import AppIntents
import Foundation

// The iPhone's Control Center and Lock Screen controls (iOS 18, Sources/iOSWidget/GlucoseControls.swift).
// Compiled into both the widget extension, which draws the controls, and the app, which runs them.
// Neither control logs anything: Glucose opens Today, Log treatment opens the log sheet for
// treating a low (the same sheet as the alert's "Log treatment" button, #187/#200), where the user
// checks it and taps Log.

/// What a control does, plugged in by the app at launch (`GlucOSPhoneApp.init`). Nil in the widget
/// extension's own process, where a tap is left in the app group for the app to pick up.
enum ControlActions {
    enum Target: String {
        case today
        case lowTreatment = "low-treatment"
    }

    @MainActor static var open: ((Target) -> Void)?

    static let pendingKey = "control.pending"
    static let pendingAtKey = "control.pendingAt"
    /// An older tap is dropped: the app may have opened for something else since.
    static let pendingFor: TimeInterval = 60

    static var defaults: UserDefaults { UserDefaults(suiteName: SharedStore.appGroup) ?? .standard }

    @MainActor
    static func run(_ target: Target) {
        if let open {
            open(target)
        } else {
            let d = defaults
            d.set(target.rawValue, forKey: pendingKey)
            d.set(Date().timeIntervalSince1970, forKey: pendingAtKey)
        }
    }

    /// Called by the app as it becomes active: the screen a control tap asked for, if one is
    /// waiting. Taking it clears it, so it opens once.
    static func takePending(now: Date = Date()) -> Target? {
        let d = defaults
        guard let raw = d.string(forKey: pendingKey) else { return nil }
        let at = d.double(forKey: pendingAtKey)
        d.removeObject(forKey: pendingKey)
        d.removeObject(forKey: pendingAtKey)
        guard now.timeIntervalSince1970 - at <= pendingFor else { return nil }
        return Target(rawValue: raw)
    }
}

/// The Glucose control: opens GlucOS on Today.
struct OpenTodayControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens GlucOS on Today, with your latest reading and forecast.")
    static let isDiscoverable = false
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        ControlActions.run(.today)
        return .result()
    }
}

/// The Log treatment control: opens the log sheet for treating a low, filled in from the "Treat a
/// low" usual when there is one. Never logs by itself.
struct OpenLowTreatmentControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Treatment"
    static let description = IntentDescription("Opens GlucOS on the log sheet for treating a low. Nothing is logged until you tap Log.")
    static let isDiscoverable = false
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        ControlActions.run(.lowTreatment)
        return .result()
    }
}
