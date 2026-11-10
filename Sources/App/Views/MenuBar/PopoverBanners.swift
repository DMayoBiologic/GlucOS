import SwiftUI
import AppKit

/// Problems that need attention, most urgent first. Each says what's wrong, what it means, and
/// offers the one action that fixes it.
struct PopoverBanners: View {
    @EnvironmentObject var store: GlucoseStore
    var onRefresh: () -> Void

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        // A Group, not a stack, so nothing is added to the popover's spacing when all is well.
        Group {
            if let cur = s.current, s.isStale() {
                PopoverBanner(
                    tint: .orange,
                    systemImage: "clock.badge.exclamationmark.fill",
                    title: "No new reading for \(PopoverFormat.age(cur.age()))",
                    message: "Don't treat from this value. Check your sensor and phone, or scan with your reader.",
                    actionTitle: store.isRefreshing ? "Checking…" : "Check Now",
                    actionDisabled: store.isRefreshing,
                    action: onRefresh
                )
            }
            if let err = s.lastError {
                PopoverBanner(
                    tint: .orange,
                    systemImage: "exclamationmark.triangle.fill",
                    title: store.connectionProblem?.title ?? "Couldn't reach LibreLinkUp",
                    message: store.connectionProblem?.advice ?? err,
                    actionTitle: store.isRefreshing ? "Retrying…" : "Retry",
                    actionDisabled: store.isRefreshing,
                    action: onRefresh
                )
                .contextMenu {
                    Button("Copy Error", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(err, forType: .string)
                    }
                }
            }
            if store.notificationsBlocked {
                PopoverBanner(
                    tint: .red,
                    systemImage: "bell.slash.fill",
                    title: "Glucose alerts can't reach you",
                    message: "Notifications are off for GlucOS in System Settings.",
                    actionTitle: "Turn On…",
                    action: { NSWorkspace.shared.open(AlertManager.notificationSettingsURL) }
                )
            }
            if let sensor = s.sensor {
                let remaining = sensor.daysRemaining()
                if remaining <= 0 {
                    PopoverBanner(
                        tint: .red,
                        systemImage: "sensor.tag.radiowaves.forward.fill",
                        title: "Sensor has ended",
                        message: "Readings stop until you start a new sensor."
                    )
                } else if remaining < 0.25 {
                    PopoverBanner(
                        tint: .orange,
                        systemImage: "sensor.tag.radiowaves.forward.fill",
                        title: "Sensor ends in \(Format.days(remaining))",
                        message: "Have a replacement ready so you don't lose readings."
                    )
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// One popover notice, drawn with the design system's `StatusBanner`.
struct PopoverBanner: View {
    let tint: Color
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var actionDisabled = false
    var action: (() -> Void)?

    /// Red means alerts or readings have stopped; everything else here is a warning.
    private var severity: BannerSeverity { tint == .red ? .critical : .warning }

    var body: some View {
        StatusBanner(
            severity: severity,
            systemImage: systemImage,
            title: title,
            message: message,
            action: actionTitle.flatMap { t in action.map { BannerAction(title: t, isDisabled: actionDisabled, perform: $0) } },
            density: .compact
        )
    }
}
