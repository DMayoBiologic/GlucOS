import SwiftUI
import AppKit

/// The menu bar popover. Laid out by importance: the current reading, then anything that needs
/// attention, the recent trace, the longer view, and finally actions.
///
/// Keyboard: ⌘L log, ⌘R refresh, ⌘D dashboard, ⌘, settings, ⌘C copy reading, ⌘1–3 chart range,
/// ⌘Q quit, ← → step through chart readings, Escape closes. Hold ⌘ to see the shortcuts.
struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var commandKey = CommandKeyMonitor()
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.current != nil {
                PopoverHero(onCopy: copyReading, onRefresh: refresh, onOpenDashboard: showDashboard)
            } else {
                emptyState
            }
            PopoverBanners(onRefresh: refresh)
            if s.current != nil {
                PopoverChartCard(showsShortcuts: commandKey.isHeld, onOpenDashboard: showDashboard)
                PopoverRecentActivity(onOpen: showDashboard)
                PopoverGlanceCard()
            }
            PopoverToolbar(showsShortcuts: commandKey.isHeld,
                           onLog: showLogSheet, onRefresh: refresh, onDashboard: showDashboard,
                           onSettings: showSettings, onCopy: copyReading)
            PopoverFooter()
        }
        .padding(12)
        .frame(width: 368)
        .background(alignment: .top) {
            // A wash of the current range colour at the top of the popover.
            AmbientGlow(tint: s.displayTint(), intensity: 0.45)
                .frame(height: 260)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .accessibilityHidden(true)
            }
        }
        .background { shortcuts }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: s.current)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: s.lastError)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: s.isStale())
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: toast)
        .task { await store.checkNotificationPermission() }
        .onAppear { commandKey.start() }
        .onDisappear { commandKey.stop() }
    }

    /// Shortcuts without a visible button of their own.
    private var shortcuts: some View {
        ZStack {
            HiddenShortcut(key: "1") { settings.chartHours = 3 }
            HiddenShortcut(key: "2") { settings.chartHours = 6 }
            HiddenShortcut(key: "3") { settings.chartHours = 12 }
            HiddenShortcut(key: "c", action: copyReading)
            HiddenShortcut(key: "q") { NSApplication.shared.terminate(nil) }
        }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func refresh() {
        Task { await store.refresh() }
    }

    private func copyReading() {
        guard store.copyReadingToClipboard() else { return }
        showToast("Reading copied")
        VoiceOver.announce("Reading copied")
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Group {
            if settings.hasCredentials {
                ContentUnavailableView {
                    Label("Waiting for Data", systemImage: "drop")
                } description: {
                    Text("Fetching from LibreLinkUp. If this persists, check the message below.")
                } actions: {
                    Button("Refresh") { Task { await store.refresh() } }
                        .disabled(store.isRefreshing)
                }
            } else {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Sign in with your LibreLinkUp follower account to start.")
                } actions: {
                    Button("Open Settings…") { showSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassCard()
    }

    /// `LSUIElement` apps don't come forward on their own, so the Settings window would open
    /// behind whatever app was frontmost.
    private func showSettings() {
        openSettings()
        NSApp.activate()
    }

    private func showDashboard() {
        openWindow(id: DashboardView.windowID)
        NSApp.activate()
    }

    /// The log sheet lives in the dashboard window, since a sheet can't hang off the popover.
    private func showLogSheet() {
        logbook.logSheetRequested = true
        showDashboard()
    }
}
