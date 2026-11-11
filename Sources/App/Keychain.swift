import Foundation
import Security

/// Tiny generic-password Keychain wrapper. Credentials never leave the Mac except to Abbott.
///
/// On the Mac, items live in the data protection keychain (the iOS-style one), where access is
/// tied to the app's Team ID and keychain access group, not to the exact binary. That's what lets
/// a Sparkle update read them without macOS asking for the login password. The old file-based
/// login keychain trusts a specific code signature, and ad-hoc builds got a new one every release.
///
/// Release builds are Developer ID signed with a `keychain-access-groups` entitlement (see
/// scripts/sign_mac.sh). Local ad-hoc builds don't have that entitlement, so the data protection
/// keychain refuses them (`errSecMissingEntitlement`) and they keep using the login keychain.
///
/// Items saved by builds before this change sit in the login keychain. The first read of each one
/// copies it across, which is the last time macOS asks. The old copy is left alone (deleting it
/// could prompt again); a per-account marker in UserDefaults means it's never read again.
enum Keychain {
    private static let service = "au.com.declanmayo.glucos"
    private static let lock = NSLock()
    /// Reads are frequent (AppSettings.password is a computed property), so values are cached.
    /// `.some(nil)` caches "not there".
    private static var cache: [String: String?] = [:]
    #if os(macOS)
    /// nil until the first call finds out whether this build may use the data protection keychain.
    private static var modernAvailable: Bool?
    #endif

    static func set(_ value: String, for account: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data(value.utf8)
        #if os(macOS)
        if useModern() {
            if store(data, account: account, modern: true) { cache[account] = value; markMigrated(account) }
            return
        }
        #endif
        if store(data, account: account, modern: false) { cache[account] = value }
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[account] { return hit }
        let result: ReadResult
        #if os(macOS)
        if useModern() {
            result = readMigrating(account)
        } else {
            result = read(account, modern: false)
        }
        #else
        result = read(account, modern: false)
        #endif
        switch result {
        case .found(let v): cache[account] = .some(v); return v
        case .notFound: cache[account] = .some(nil); return nil
        // Locked, denied or otherwise unreadable right now: try again next time, don't cache.
        case .failed: return nil
        }
    }

    /// Returns false when the item couldn't be removed (it's then still there and still readable).
    @discardableResult
    static func delete(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var modern = false
        #if os(macOS)
        modern = useModern()
        #endif
        let status = SecItemDelete(query(account, modern: modern) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            cache[account] = nil   // forget what we knew; the next read asks the keychain again
            return false
        }
        cache[account] = .some(nil)
        #if os(macOS)
        // The login keychain copy stays (deleting it could prompt), but it's never migrated now.
        if modern { markMigrated(account) }
        #endif
        return true
    }

    // MARK: - Internals (call with `lock` held)

    private enum ReadResult {
        case found(String), notFound, failed
    }

    private static func query(_ account: String, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    private static func read(_ account: String, modern: Bool) -> ReadResult {
        var q = query(account, modern: modern)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return .notFound }
            return .found(s)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed
        }
    }

    @discardableResult
    private static func store(_ data: Data, account: String, modern: Bool) -> Bool {
        let q = query(account, modern: modern)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    #if os(macOS)
    /// Each account is copied from the login keychain at most once. The marker also stops a
    /// stale login-keychain copy from coming back after the item is changed or deleted.
    private static func migratedKey(_ account: String) -> String { "keychain.migrated.\(account)" }
    private static func markMigrated(_ account: String) {
        UserDefaults.standard.set(true, forKey: migratedKey(account))
    }

    private static func readMigrating(_ account: String) -> ReadResult {
        let modern = read(account, modern: true)
        guard case .notFound = modern, !UserDefaults.standard.bool(forKey: migratedKey(account)) else { return modern }
        switch read(account, modern: false) {
        case .found(let legacy):
            if store(Data(legacy.utf8), account: account, modern: true) { markMigrated(account) }
            return .found(legacy)
        case .notFound:
            markMigrated(account)
            return .notFound
        case .failed:
            return .failed
        }
    }

    /// Whether this build is entitled to the data protection keychain. A lookup for an item that
    /// can't exist answers it without touching anything: missing entitlement vs. not found.
    private static func useModern() -> Bool {
        if let known = modernAvailable { return known }
        var q = query("glucos.probe", modern: true)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        let ok = status != errSecMissingEntitlement
        modernAvailable = ok
        return ok
    }
    #endif
}
