import Foundation
import Combine
import Sparkle

/// Sparkle wrapper. Checks the GitHub-hosted appcast every 6 h and installs updates silently
/// (they apply on next launch/relaunch). Also exposes a manual "Check for Updates…" action.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published private(set) var canCheck = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)
    }

    var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty
    }

    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
