import SwiftUI

/// "Send a Test Alert" in Settings › Alerts on iPhone and Mac (docs/TestAlert.md). Sends a sample
/// low alert (`AlertManager.sendTest`), then reads "Test Alert Sent" for a few seconds: a short
/// cross-fade, instant under Reduce Motion, and one VoiceOver announcement saying nothing was
/// logged or snoozed.
struct TestAlertButton: View {
    @EnvironmentObject private var store: GlucoseStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Asks for notification permission first (iPhone Settings, where it may not have been asked).
    var requestsAuthorization = false
    /// The shorter title some setup screens use.
    var title: String = TestAlert.buttonTitle

    @State private var sentAt: Date?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: send) {
            Text(sentAt == nil ? title : TestAlert.sentTitle)
                .contentTransition(.opacity)
        }
        .accessibilityLabel(TestAlert.accessibilityLabel)
        .accessibilityValue(sentAt == nil ? "" : "Sent")
        .accessibilityHint(TestAlert.accessibilityHint)
        .onDisappear { resetTask?.cancel() }
    }

    private func send() {
        if requestsAuthorization { store.alerts.requestAuthorization() }
        store.alerts.sendTest(settings: settings)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sentAt = Date() }
        AccessibilityNotification.Announcement(TestAlert.sentAnnouncement).post()
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TestAlert.sentShowsFor))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sentAt = nil }
        }
    }
}
