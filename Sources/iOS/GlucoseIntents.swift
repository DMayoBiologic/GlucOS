import AppIntents
import Foundation

// Siri, Shortcuts and Spotlight for the reading and for a low (docs/iOS.md "Siri and Shortcuts").
// "What's my glucose" answers out loud without opening the app, in the widgets' words
// (`SpokenGlucose`): a stale reading is said to be stale, never spoken as the current glucose.
// "Log treatment" opens the app on the same filled-in low treatment sheet as the inline button and
// the alert's button; it never logs anything by itself.

struct ReadGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "What's My Glucose"
    static let description = IntentDescription("Says your latest glucose reading, its trend and how old it is, and any note about the forecast. A stale reading is said to be stale.")
    static let openAppWhenRun = false

    /// How long to wait for a new reading when the saved one isn't fresh.
    static let refreshWait: TimeInterval = 8

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = PhoneServices.shared?.store
        var snapshot = store?.snapshot ?? SharedStore.load()
        if SpokenGlucose.wantsRefresh(snapshot, at: Date()), let store {
            // iOS doesn't keep the app fetching in the background, so the saved reading is often
            // old: try once for a new one, briefly, and say whatever is true after that.
            let before = store.snapshot.fetchedAt
            Task { await store.refresh() }
            let deadline = Date().addingTimeInterval(Self.refreshWait)
            while store.snapshot.fetchedAt <= before, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            snapshot = store.snapshot
        }
        let text = SpokenGlucose.answer(snapshot, at: Date())
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct LogLowTreatmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Low Treatment"
    static let description = IntentDescription("Opens GlucOS on the log sheet for treating a low, filled in from your \u{201C}Treat a low\u{201D} usual when you have one. Nothing is logged until you tap Log.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneLogRouter.shared.treat(.low, from: .siri)
        return .result()
    }
}
