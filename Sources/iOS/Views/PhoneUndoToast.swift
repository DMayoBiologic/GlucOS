import SwiftUI

/// The toast that rises after a logbook delete: what went, and Undo. It springs away by itself
/// `LogbookUndo.toastSeconds` after the last delete (`PhoneUndoCountdown`), and Undo puts the
/// entries back on every device (`LogbookStore.undoDelete`). Under Reduce Motion it fades in
/// and out in place. Nothing loops.
struct PhoneUndoToast: View {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let deleted = logbook.lastDeleted
        ZStack {
            if !deleted.isEmpty {
                toast(deleted)
                    .transition(DS.Transition.toast(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
        .frame(maxWidth: 560)
        .animation(PhoneUndoToast.motion(reduceMotion: reduceMotion), value: deleted.isEmpty)
    }

    /// A spring in and out; a short fade under Reduce Motion, which moves nothing.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation
    }

    private func toast(_ deleted: [LogEntry]) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.title(deleted))
                .dsFont(.callout)
                .dsLineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText(value: Double(deleted.count)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                logbook.undoDelete()
                Haptics.success()
            } label: {
                Text("Undo")
                    .dsFont(.headline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.xs + 2)
                    .background(Palette.brand.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityHint("Puts back what you deleted, on all your devices")
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, DS.Space.sm)
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }

    /// "Deleted 4 u NovoRapid", or "3 entries deleted" (`LogbookUndo.title`, shared with the Mac).
    static func title(_ deleted: [LogEntry]) -> String { LogbookUndo.title(deleted) }
}

/// Clears the undo buffer `LogbookUndo.toastSeconds` after the last delete, so the toast springs
/// away and later deletes start a fresh Undo. Applied once, on the home screen's stack, so pushed
/// screens share one countdown. Every new delete starts it again.
struct PhoneUndoCountdown: ViewModifier {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content.task(id: logbook.lastDeleted.map(\.id)) {
            let deleted = logbook.lastDeleted
            guard !deleted.isEmpty else { return }
            if voiceOver {
                AccessibilityNotification.Announcement("\(PhoneUndoToast.title(deleted)). Undo is at the bottom of the screen.").post()
            }
            let seconds = voiceOver ? LogbookUndo.toastSecondsVoiceOver : LogbookUndo.toastSeconds
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(PhoneUndoToast.motion(reduceMotion: reduceMotion)) { logbook.clearUndo() }
        }
    }
}

extension View {
    func phoneUndoCountdown() -> some View { modifier(PhoneUndoCountdown()) }
}
