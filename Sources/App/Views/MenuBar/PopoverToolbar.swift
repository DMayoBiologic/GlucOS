import SwiftUI
import AppKit

/// Floating pill toolbar. Primary actions stay one click away; rarely used ones live in the
/// overflow menu. Holding ⌘ shows each button's shortcut.
struct PopoverToolbar: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var updater: Updater

    var showsShortcuts: Bool
    var onLog: () -> Void
    var onRefresh: () -> Void
    var onDashboard: () -> Void
    var onSettings: () -> Void
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onLog) {
                Label("Log", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillIconButtonStyle(prominent: true))
            .keyboardShortcut("l")
            .help("Log insulin or food (⌘L)")
            .overlay(alignment: .bottom) { badge("⌘L") }

            Button(action: onRefresh) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(store.isRefreshing ? 0 : 1)
                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                }
            }
            .buttonStyle(PillIconButtonStyle())
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            .accessibilityLabel(store.isRefreshing ? "Refreshing" : "Refresh")
            .overlay(alignment: .bottom) { badge("⌘R") }

            pill("Open Dashboard", systemImage: "macwindow", shortcut: "⌘D", action: onDashboard)
                .keyboardShortcut("d")
            pill("Settings…", systemImage: "gearshape", shortcut: "⌘,", action: onSettings)
                .keyboardShortcut(",")

            Spacer(minLength: 4)

            overflowMenu
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.15), value: showsShortcuts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Copy Reading", systemImage: "doc.on.doc", action: onCopy)
                .keyboardShortcut("c")
                .disabled(store.snapshot.current == nil)
            Button("Check for Updates…", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
            Divider()
            Text("GlucOS \(updater.version)")
            Button("Quit GlucOS", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("More: copy reading, updates, quit")
        .accessibilityLabel("More")
    }

    private func pill(_ title: String, systemImage: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(PillIconButtonStyle())
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
        .overlay(alignment: .bottom) { badge(shortcut) }
    }

    @ViewBuilder
    private func badge(_ text: String) -> some View {
        if showsShortcuts {
            ShortcutBadge(text: text).offset(y: 15)
        }
    }
}

/// Footer: when GlucOS last checked, and the medical disclaimer.
struct PopoverFooter: View {
    @EnvironmentObject var store: GlucoseStore

    private static let disclaimer = "GlucOS is not a medical device. Confirm readings on your phone or reader before treating."

    var body: some View {
        HStack(spacing: 6) {
            if store.snapshot.lastError == nil, let attempt = store.lastAttempt {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text("Checked \(PopoverFormat.ageAgo(context.date.timeIntervalSince(attempt)))")
                        .monospacedDigit()
                }
                .help(store.statusLine)
            } else if store.snapshot.lastError == nil {
                Text(store.statusLine).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Label("Not a medical device", systemImage: "info.circle")
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .lineLimit(1)
                .help(Self.disclaimer)
                .accessibilityLabel(Self.disclaimer)
        }
        .dsFont(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
    }
}

/// A key-equivalent with no visible control, for shortcuts whose button lives in a menu or
/// doesn't exist (⌘1–3 for the chart range).
struct HiddenShortcut: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Publishes whether ⌘ is being held on its own, after a short delay so quick shortcuts like
/// ⌘R don't flash the hints.
@MainActor
final class CommandKeyMonitor: ObservableObject {
    @Published private(set) var isHeld = false
    private var monitor: Any?
    private var pending: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        // Local monitors are called on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending?.cancel()
        isHeld = false
    }

    private func handle(_ event: NSEvent) {
        pending?.cancel()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .flagsChanged, flags == .command else {
            if isHeld { isHeld = false }
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.isHeld = true
        }
    }
}
