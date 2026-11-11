import Foundation

/// The owner's share links, made and stopped through the push relay. The relay keeps only a
/// hash of each link's token, so this phone keeps the links it made (in the Keychain) to send
/// them again.
@MainActor
final class OwnerSharing: ObservableObject {
    @Published private(set) var shares: [ShareInfo] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    private let relay: RelaySettings

    init(relay: RelaySettings = .shared) {
        self.relay = relay
    }

    var isAvailable: Bool { relay.isConfigured }

    /// The link for a share this phone made, if it still has it.
    func link(for share: ShareInfo) -> URL? {
        (Keychain.get("ownShare.\(share.id)") ?? MessagesShareLinks.token(for: share.id)).flatMap(FollowLink.url(token:))
    }

    func refresh() async {
        guard let client = relay.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            shares = try await client.shares()
            error = nil
            forgetLinksNotIn(shares)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Makes a new link. Returns its URL to send.
    func create(label: String, duration: ShareDuration) async -> URL? {
        guard let client = relay.client else {
            error = "Sharing needs the push relay. Set it up in Settings."
            return nil
        }
        do {
            let made = try await client.createShare(CreateShare(label: label, expiresIn: duration.seconds))
            Keychain.set(made.token, for: "ownShare.\(made.share.id)")
            shares.removeAll { $0.id == made.share.id }
            shares.insert(made.share, at: 0)
            error = nil
            return FollowLink.url(token: made.token)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Stops a share now: its link stops working and followers' Lock Screen cards go.
    func stop(_ share: ShareInfo) async {
        guard let client = relay.client else { return }
        do {
            shares = try await client.revokeShare(id: share.id)
            Keychain.delete("ownShare.\(share.id)")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forgetLinksNotIn(_ live: [ShareInfo]) {
        let ids = Set(live.map(\.id))
        var known = UserDefaults.standard.stringArray(forKey: "ownShareIDs") ?? []
        for id in known where !ids.contains(id) { Keychain.delete("ownShare.\(id)") }
        MessagesShareLinks.keep(only: ids)
        known = Array(ids)
        UserDefaults.standard.set(known, forKey: "ownShareIDs")
    }
}
