import AppIntents
import Foundation

// The Your usual widget's buttons (docs/UsualEntries.md). Compiled into both the widget extension
// (which draws the buttons) and the app. A button never logs anything: it opens GlucOS on the log
// sheet, filled in from that entry, where the user checks it and taps Log, after `RepeatCheck`
// (logged twice?), the calculator and its confirm step, exactly as tapping the tile in the sheet.

/// What a button does, plugged in by the app at launch (`GlucOSPhoneApp.init`). Nil in the widget
/// extension's own process.
enum UsualActions {
    @MainActor static var open: ((_ usualID: String) -> Void)?

    /// Where a tap waits for the app when the intent ran in the widget extension's process instead.
    static let pendingKey = "usual.widget.pending"
    static let pendingAtKey = "usual.widget.pendingAt"
    /// An older tap is dropped: the app may have opened for something else since.
    static let pendingFor: TimeInterval = 60

    static var defaults: UserDefaults { UserDefaults(suiteName: SharedStore.appGroup) ?? .standard }

    /// Called by the app as it becomes active: the entry a widget tap asked for, if one is waiting.
    /// Taking it clears it, so it opens once.
    static func takePending(now: Date = Date()) -> String? {
        let d = defaults
        guard let id = d.string(forKey: pendingKey) else { return nil }
        let at = d.double(forKey: pendingAtKey)
        d.removeObject(forKey: pendingKey)
        d.removeObject(forKey: pendingAtKey)
        return now.timeIntervalSince1970 - at <= pendingFor ? id : nil
    }
}

/// A Your usual button: opens the log sheet on that entry, for the user to check and log.
struct OpenUsualIntent: AppIntent {
    static let title: LocalizedStringResource = "Open your usual"
    static let description = IntentDescription("Opens the GlucOS log sheet filled in with one of your usual entries, to check and log.")
    static let isDiscoverable = false
    static let openAppWhenRun = true

    /// `UsualEntry.id`: "meal-breakfast", "correction", "low".
    @Parameter(title: "Usual")
    var usualID: String

    init() {}

    init(usualID: String) {
        self.usualID = usualID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let open = UsualActions.open {
            open(usualID)
        } else {
            // Run in the widget's process: leave it for the app, which is opening.
            let d = UsualActions.defaults
            d.set(usualID, forKey: UsualActions.pendingKey)
            d.set(Date().timeIntervalSince1970, forKey: UsualActions.pendingAtKey)
        }
        return .result()
    }
}
