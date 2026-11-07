import Foundation
import Combine
import Sparkle

/// Sparkle wrapper. Checks the GitHub-hosted appcast every hour, downloads updates in the
/// background, then installs them straight away and relaunches: no dialogs, no clicks, no
/// waiting for the user to quit. Also exposes a manual "Check for Updates…" action.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    // Sparkle holds its delegate weakly, so keep it alive here.
    private let delegate: SilentInstallDelegate

    @Published private(set) var canCheck = false

    init() {
        let delegate = SilentInstallDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
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

/// By default Sparkle stages a silently downloaded update and applies it only when the app quits.
/// A menu bar app that launches at login practically never quits, so install the staged update
/// immediately instead; Sparkle then relaunches the new version itself.
final class SilentInstallDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Let Sparkle finish its current callback before it terminates and relaunches us.
        DispatchQueue.main.async { immediateInstallHandler() }
        return true
    }
}
