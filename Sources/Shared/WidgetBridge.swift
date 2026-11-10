import Foundation

/// Lets the sandboxed widget ask the app for a fresh reading.
///
/// The widget can't fetch on its own (it has no credentials and no network access), so its
/// refresh button posts a Darwin notification, which is allowed from inside the sandbox. The app
/// listens for it and runs a normal refresh, which writes the snapshot and reloads every widget.
enum WidgetBridge {
    static let refreshRequestName = "au.com.declanmayo.glucos.widget.refresh-request" as CFString

    /// Called from the widget's refresh intent.
    static func requestRefresh() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(refreshRequestName), nil, nil, true)
    }

    private final class Token {}
    private static let token = Token()
    private static var onRefreshRequest: (() -> Void)?

    /// Called once by the app. The handler runs on the main queue.
    static func observeRefreshRequests(_ handler: @escaping () -> Void) {
        let first = onRefreshRequest == nil
        onRefreshRequest = handler
        guard first else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(token).toOpaque(),
            { _, _, _, _, _ in DispatchQueue.main.async { WidgetBridge.onRefreshRequest?() } },
            refreshRequestName, nil, .deliverImmediately)
    }
}
