import SwiftUI
import AppKit

/// "Your usual" in the menu bar popover (docs/UsualEntries.md): the same one-tap repeats the log
/// sheet offers (the usual meal for this time of day, the usual correction while high, what the
/// user takes for a low), up to three. A click, or ⌥⌘1–⌥⌘3, opens the log window filled in from
/// it. Nothing is logged from here: the entry is logged with Log in that window, so it still goes
/// through `RepeatCheck` ("Already logged?"), the bolus calculator and its confirm step. A meal
/// never brings a dose with it; a correction fills only the units the user took themselves.
struct PopoverUsualRow: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    /// ⌘ is held: show each chip's key.
    let showsShortcuts: Bool

    /// What the row offers now. Empty before the therapy type is set, since logging starts with
    /// that question.
    @MainActor
    static func entries(logbook: LogbookStore, store: GlucoseStore, settings: AppSettings,
                        now: Date = Date()) -> [UsualEntry] {
        guard settings.therapy != .notSet else { return [] }
        return Array(logbook.usualEntries(store: store, settings: settings, now: now).prefix(UsualKeys.limit))
    }

    var body: some View {
        let entries = Self.entries(logbook: logbook, store: store, settings: settings)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
                Eyebrow(title: "Your usual", systemImage: "arrow.triangle.2.circlepath")
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: DS.Space.sm - 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, u in
                        chip(u, index: index)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 2)
            .dsAnimation(.standard, value: entries.map(\.id))
            .accessibilityElement(children: .contain)
        }
    }

    private func chip(_ u: UsualEntry, index: Int) -> some View {
        Button { open(u) } label: {
            Label {
                Text(u.shortTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: u.systemImage)
            }
        }
        // The low treatment stands out by fill, not colour alone, as in the sheet.
        .buttonStyle(ChipButtonStyle(selected: u.kind == .lowTreatment, tint: u.tint))
        .usualShortcut(index)
        .help(help(u, index: index))
        .accessibilityLabel(u.spokenLabel)
        .accessibilityHint("Opens the log window filled in. Check it, then log.")
        .overlay(alignment: .bottom) {
            if showsShortcuts, let key = UsualKeys.display(for: index) {
                ShortcutBadge(text: key).offset(y: 15)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func help(_ u: UsualEntry, index: Int) -> String {
        let what = u.detail.isEmpty ? u.title : "\(u.title): \(u.detail)"
        let key = UsualKeys.display(for: index).map { " (\($0))" } ?? ""
        return "\(what). Opens the log window filled in, to check and log\(key)."
    }

    /// Logging opens its own small window, since a sheet can't hang off the popover.
    private func open(_ u: UsualEntry) {
        LogWindowRequest.shared.target = .usual(u)
        openWindow(id: LogWindow.id)
        NSApp.activate()
    }
}

extension View {
    /// ⌥⌘1–⌥⌘3 on the first three "Your usual" chips (`UsualKeys`). No key past the third.
    func usualShortcut(_ index: Int) -> some View {
        modifier(UsualShortcut(index: index))
    }
}

private struct UsualShortcut: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if let digit = UsualKeys.digit(for: index) {
            content.keyboardShortcut(KeyEquivalent(digit), modifiers: [.command, .option])
        } else {
            content
        }
    }
}
