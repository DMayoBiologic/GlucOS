import AppIntents
import Foundation

// The Live Activity's check-in buttons. Compiled into both the widget extension (which draws the
// buttons) and the app: as `LiveActivityIntent`s they run in the app's process, launched in the
// background if it isn't running, so they can use the app's Keychain and network. The app plugs
// the work in at launch (`CheckInActions`, set by `CheckInCoordinator` in Sources/iOS/CheckIns.swift).

/// What the buttons do, filled in by the app. nil in the widget extension's own process.
enum CheckInActions {
    @MainActor static var ask: ((_ followID: String) async throws -> Void)?
    /// true: "I'm okay"; false: "I need help".
    @MainActor static var answer: ((_ okay: Bool) async throws -> Void)?

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Open GlucOS and try again." }
    }
}

/// On a follower's card while the person they follow is low: ask them if they're okay.
struct CheckInIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Check in"
    static let description = IntentDescription("Ask the person you follow if they're okay.")
    static let isDiscoverable = false

    @Parameter(title: "Follow")
    var followID: String

    init() {}

    init(followID: String) {
        self.followID = followID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let ask = CheckInActions.ask else { throw CheckInActions.Unavailable() }
        try await ask(followID)
        return .result()
    }
}

/// On the owner's card while someone's checking in: answer everyone waiting.
struct AnswerCheckInIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer check-in"
    static let description = IntentDescription("Tell the people checking in on you how you are.")
    static let isDiscoverable = false

    @Parameter(title: "Okay")
    var okay: Bool

    init() {}

    init(okay: Bool) {
        self.okay = okay
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let answer = CheckInActions.answer else { throw CheckInActions.Unavailable() }
        try await answer(okay)
        return .result()
    }
}
