import AppIntents

// "Log in GlucOS" for Shortcuts, Siri, Spotlight and the Action button. It only opens the log
// sheet: amounts are always entered by the user, never by an automation.

enum LogPartAppEnum: String, AppEnum {
    case insulin, food, site, event

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Log entry")
    static var caseDisplayRepresentations: [LogPartAppEnum: DisplayRepresentation] = [
        .insulin: DisplayRepresentation(title: "Insulin", image: .init(systemName: "syringe")),
        .food: DisplayRepresentation(title: "Food", image: .init(systemName: "fork.knife")),
        .site: DisplayRepresentation(title: "Site change", image: .init(systemName: "arrow.triangle.2.circlepath")),
        .event: DisplayRepresentation(title: "Event", image: .init(systemName: "tag")),
    ]

    var part: PhoneLogPart {
        switch self {
        case .insulin: return .insulin
        case .food: return .food
        case .site: return .site
        case .event: return .event
        }
    }
}

struct OpenLogIntent: AppIntent {
    static var title: LocalizedStringResource = "Log in GlucOS"
    static var description = IntentDescription("Opens GlucOS ready to log insulin, food, a site change or an event.")
    static var openAppWhenRun = true

    @Parameter(title: "Entry")
    var part: LogPartAppEnum?

    init() {}

    init(part: LogPartAppEnum?) {
        self.part = part
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneLogRouter.shared.open(part?.part)
        return .result()
    }
}

/// "I'm up": logs a wake-up now (not twice within a few hours). Handy on the Action button or as
/// a morning alarm automation.
struct LogWakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Wake-Up in GlucOS"
    static var description = IntentDescription("Logs that you've just woken up, so GlucOS can learn how your glucose moves in the morning.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneWakeLogger.shared.quickLog()
        return .result()
    }
}

struct GlucOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenLogIntent(),
                    phrases: ["Log in \(.applicationName)",
                              "Log \(\.$part) in \(.applicationName)",
                              "Add to my \(.applicationName) logbook"],
                    shortTitle: "Log",
                    systemImageName: "plus.circle.fill")
        AppShortcut(intent: LogWakeIntent(),
                    phrases: ["I'm up in \(.applicationName)",
                              "Log wake-up in \(.applicationName)",
                              "I just woke up in \(.applicationName)"],
                    shortTitle: "Woke Up",
                    systemImageName: "sunrise.fill")
    }
}
