import Foundation

/// The parts of a log entry the iPhone log sheet can start on.
enum PhoneLogPart: String, CaseIterable, Identifiable {
    case insulin, food, site, event

    var id: String { rawValue }
}

/// What the iPhone log sheet opens for.
enum PhoneLogTarget {
    case new(start: PhoneLogPart?)
    case edit(LogEntry)
}

struct PhoneLogRequest: Identifiable {
    let id = UUID()
    let target: PhoneLogTarget
}

/// Opens the log sheet from anywhere: the + button, the Logbook card, `glucos://log` links (Lock
/// Screen widget, Dynamic Island) and the "Log in GlucOS" App Shortcut.
@MainActor
final class PhoneLogRouter: ObservableObject {
    static let shared = PhoneLogRouter()

    @Published var request: PhoneLogRequest?

    func open(_ start: PhoneLogPart? = nil) {
        request = PhoneLogRequest(target: .new(start: start))
    }

    func edit(_ entry: LogEntry) {
        request = PhoneLogRequest(target: .edit(entry))
    }

    /// `glucos://log`, `glucos://log/food`, `glucos://log?part=insulin`. True when the URL was a log link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "glucos", url.host == "log" else { return false }
        let fromPath = url.pathComponents.dropFirst().first
        let fromQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "part" }?.value
        open((fromPath ?? fromQuery).flatMap(PhoneLogPart.init(rawValue:)))
        return true
    }
}
