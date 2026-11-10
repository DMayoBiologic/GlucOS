import SwiftUI
import AppKit

/// The menu bar popover. One question per layer, most important first:
///
/// 1. **Now**: the current reading, its trend and how fresh it is (`PopoverHero`).
/// 2. **Needs attention**: the single most urgent notice, with any others one click away.
/// 3. **Lately**: the recent trace (`PopoverChartCard`).
/// 4. **Overall**: time in range and the last dose and meal, with the full stats behind
///    "Details" (`PopoverSummaryCard`).
/// 5. **Actions** (`PopoverToolbar`) and a one-line footer.
///
/// Keyboard: ⌘L log, ⌘R refresh, ⌘D dashboard, ⌘, settings, ⌘C copy reading, ⌘1–3 chart range,
/// ⌘I show or hide details, ⌘Q quit, ← → step through chart readings, Escape closes. Hold ⌘ to
/// see the shortcuts.
struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var commandKey = CommandKeyMonitor()
    @AppStorage("popoverDetailsExpanded") private var detailsExpanded = false
    @AppStorage("popoverGlanceWindow") private var glanceWindowRaw = GlanceWindow.day.rawValue
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var contentHeight: CGFloat = 0

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: PopoverHeightKey.self, value: geo.size.height)
                    }
                }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        // MenuBarExtra sizes its window to the content's ideal size, which a ScrollView doesn't
        // have. So measure the content and ask for exactly that, capped to the screen, so the
        // popover only scrolls on a display too short to show it all.
        .frame(width: PopoverLayout.width, height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        .onPreferenceChange(PopoverHeightKey.self) { contentHeight = $0 }
        .background(alignment: .top) {
            // A wash of the current range colour at the top of the popover.
            AmbientGlow(tint: s.displayTone().color, intensity: 0.4)
                .frame(height: 240)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { toastView }
        .background { shortcuts }
        .animation(PopoverMotion.standard(reduceMotion), value: s.current)
        .animation(PopoverMotion.standard(reduceMotion), value: s.lastError)
        .animation(PopoverMotion.standard(reduceMotion), value: s.isStale())
        .animation(PopoverMotion.quick(reduceMotion), value: toast)
        .task { await store.checkNotificationPermission() }
        .onAppear { commandKey.start() }
        .onDisappear { commandKey.stop() }
        .environment(\.dsDensity, .compact)
    }

    private var content: some View {
        let notices = PopoverNotice.current(store: store, onRefresh: refresh)
        return VStack(alignment: .leading, spacing: PopoverLayout.stackSpacing) {
            if s.current != nil {
                PopoverHero(onCopy: copyReading, onRefresh: refresh, onOpenDashboard: showDashboard)
                    .accessibilitySortPriority(4)
            } else {
                emptyState
            }
            PopoverNotices(notices: notices)
                .accessibilitySortPriority(3)
            if s.current != nil {
                PopoverChartCard(showsShortcuts: commandKey.isHeld)
                PopoverSummaryCard(expanded: detailsExpanded, showsShortcuts: commandKey.isHeld,
                                   onToggleDetails: toggleDetails, onOpenDashboard: showDashboard)
            }
            PopoverToolbar(showsShortcuts: commandKey.isHeld,
                           onLog: showLogSheet, onRefresh: refresh, onDashboard: showDashboard,
                           onSettings: showSettings, onCopy: copyReading)
                .padding(.top, 2)
            PopoverFooter()
        }
        .padding(PopoverLayout.outerPadding)
        // Observed here, on a view that's always present, so the first notice to appear while
        // the popover is open is spoken too. Contents already showing are read when it opens.
        .onChange(of: notices.map(\.kind)) { old, _ in
            for n in notices where !old.contains(n.kind) && n.severity <= .warning {
                VoiceOver.announce(n.severity.accessibilityPrefix + n.title)
            }
        }
    }

    /// Leaves room for the menu bar and a margin above the Dock, on the display the popover is
    /// on (it's the key window while open).
    private var maxHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        return max(320, visible - 24)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .fontWeight(.semibold).dsFont(.callout)
                .symbolRenderingMode(.hierarchical)
                .padding(.horizontal, DS.Space.md + 2)
                .padding(.vertical, DS.Space.sm)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .dsShadow(.high)
                .padding(.bottom, 60)
                .transition(DS.Transition.toast(reduceMotion: reduceMotion))
                .accessibilityHidden(true)   // announced separately
        }
    }

    /// Shortcuts without a visible button of their own.
    private var shortcuts: some View {
        ZStack {
            HiddenShortcut(key: "1") { settings.chartHours = 3 }
            HiddenShortcut(key: "2") { settings.chartHours = 6 }
            HiddenShortcut(key: "3") { settings.chartHours = 12 }
            HiddenShortcut(key: "c", action: copyReading)
            HiddenShortcut(key: "i", action: toggleDetails)
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

    /// Shared by the Details button and ⌘I, so both animate and announce the same way. Does
    /// nothing while there are no stats to show.
    private func toggleDetails() {
        let window = GlanceWindow(rawValue: glanceWindowRaw) ?? .day
        guard s.current != nil, store.glanceStats(window) != nil else { return }
        withAnimation(PopoverMotion.standard(reduceMotion)) { detailsExpanded.toggle() }
        VoiceOver.announce(detailsExpanded ? "Details shown" : "Details hidden")
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
                    Text("Fetching from LibreLinkUp. If this takes more than a minute, check the notice below.")
                } actions: {
                    Button {
                        refresh()
                    } label: {
                        if store.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .disabled(store.isRefreshing)
                }
            } else {
                ContentUnavailableView {
                    Label("Connect LibreLinkUp", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Sign in with the LibreLinkUp follower account that shares your sensor.")
                } actions: {
                    Button("Set Up GlucOS…") {
                        openWindow(id: OnboardingView.windowID)
                        NSApp.activate()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.sm)
        .dsCard(.standard)
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

    /// Logging opens its own small window, since a sheet can't hang off the popover.
    private func showLogSheet() {
        openWindow(id: LogWindow.id)
        NSApp.activate()
    }
}

private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Layout and motion

/// Popover measurements, from the design system's compact density, so every card lines up.
enum PopoverLayout {
    static let width: CGFloat = 360
    static let outerPadding: CGFloat = DS.Space.md
    /// Between cards.
    static let stackSpacing: CGFloat = DSDensity.compact.gutter
    static let cardPadding: CGFloat = DSDensity.compact.cardPadding
    static let cardRadius: CGFloat = DSDensity.compact.cardRadius
    static let heroRadius: CGFloat = DS.Radius.panel
    /// One step inside a card.
    static let tileRadius: CGFloat = DS.Radius.tile
}

/// Popover animations, on the design system's curves. Every one is nil under Reduce Motion, so
/// state still changes, instantly.
enum PopoverMotion {
    static func quick(_ reduce: Bool) -> Animation? { DSMotion.quick.animation(reduceMotion: reduce) }
    static func standard(_ reduce: Bool) -> Animation? { DSMotion.standard.animation(reduceMotion: reduce) }

    /// Content revealed below a header: fades and drops in, fades out.
    static func reveal(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                                        removal: .opacity)
    }

    /// Small floating things such as the toast.
    static func pop(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.92))
    }
}
