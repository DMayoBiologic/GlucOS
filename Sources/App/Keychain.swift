import Foundation
import Security

/// Tiny generic-password Keychain wrapper. Credentials never leave the Mac except to Abbott.
///
/// Why there are two services on the Mac: the login keychain remembers *which app* may read an
/// item by its code signature. Ad-hoc builds (every release before Developer ID signing) had a
/// signature that changed with each build, so after every Sparkle update macOS asked for the
/// Keychain password again. Developer ID builds keep the same Team ID across updates, but items
/// the old builds made still name the old signature. So a Developer ID build keeps its items
/// under `signedService`, created by itself (and so trusted by every later build of the same
/// team), and copies each old item across the first time it reads it. That first read may ask
/// one last time; nothing asks after that.
///
/// Ad-hoc builds (local development) and the iPhone keep using `service`, as before.
enum Keychain {
    private static let service = "au.com.declanmayo.glucos"
    private static let signedService = "au.com.declanmayo.glucos.signed"

    /// The service this build reads and writes.
    private static var current: String { signingTeam == nil ? service : signedService }

    static func set(_ value: String, for account: String) {
        if write(value, account: account, service: current), current != service { markMoved(account) }
    }

    static func get(_ account: String) -> String? {
        if let value = read(account, service: current) { return value }
        guard current != service, !moved(account) else { return nil }
        // Not moved yet: read the old item (this is the read that may ask, once) and copy it
        // under this build's own service. The old item is left alone (removing another build's
        // item can ask too); once moved it is never read again.
        guard let old = read(account, service: service) else { return nil }
        if write(old, account: account, service: current) { markMoved(account) }
        return old
    }

    static func delete(_ account: String) {
        remove(account, service: current)
        guard current != service else { return }
        // Signing out: the old copy must not come back on the next read either.
        markMoved(account)
        remove(account, service: service)
    }

    private static func movedKey(_ account: String) -> String { "keychainMoved.\(account)" }
    private static func moved(_ account: String) -> Bool { UserDefaults.standard.bool(forKey: movedKey(account)) }
    private static func markMoved(_ account: String) { UserDefaults.standard.set(true, forKey: movedKey(account)) }

    // MARK: - Items

    @discardableResult
    private static func write(_ value: String, account: String, service: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func remove(_ account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Signature

    /// The Team ID this copy of the app is signed with, or nil for ad-hoc builds and the iPhone.
    static let signingTeam: String? = {
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
        #else
        return nil
        #endif
    }()
}
