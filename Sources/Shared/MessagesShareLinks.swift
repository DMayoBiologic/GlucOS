#if os(iOS)
import Foundation

/// Share links made in the Messages app, so the iPhone app can send them again. They're in the app
/// group's defaults because the Messages app can't write to the app's Keychain. A link's token
/// is what the link itself carries, and every link expires or can be stopped from the app.
enum MessagesShareLinks {
    private static let key = "messagesShareTokens"

    private static var all: [String: String] {
        SharedStore.defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func token(for id: String) -> String? { all[id] }

    static func save(_ token: String, for id: String) {
        var a = all
        a[id] = token
        SharedStore.defaults.set(a, forKey: key)
    }

    /// Forgets links that have ended.
    static func keep(only ids: Set<String>) {
        let a = all.filter { ids.contains($0.key) }
        SharedStore.defaults.set(a, forKey: key)
    }
}
#endif
