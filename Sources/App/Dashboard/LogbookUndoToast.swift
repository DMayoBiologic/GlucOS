import SwiftUI

/// The Mac Logbook's toast after a delete: what went, Undo (⌘Z) and a close button. It rises
/// from the bottom of the Logbook and goes away by itself `LogbookUndo.toastSeconds` after the
/// last delete (20 s under VoiceOver), the same as the iPhone's `PhoneUndoToast`. Holding the
/// pointer over it pauses that, and moving away starts it again. Undo puts the entries back on
/// every device through `LogbookStore.undoDelete`, the same sync-safe path as the iPhone.
/// Under Reduce Motion it fades in and out in place. Nothing loops.
struct LogbookUndoToast: View {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var hovering = false

    var body: some View {
        let deleted = logbook.lastDeleted
        ZStack {
            if !deleted.isEmpty {
                toast(deleted)
                    .transition(DS.Transition.toast(reduceMotion: reduceMotion))
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: 560)
        .animation(Self.motion(reduceMotion: reduceMotion), value: deleted.isEmpty)
        .task(id: Countdown(ids: deleted.map(\.id), paused: hovering)) { await countdown() }
        .onChange(of: deleted.map(\.id)) { _, ids in
            guard voiceOver, !ids.isEmpty else { return }
            AccessibilityNotification.Announcement("\(LogbookUndo.title(logbook.lastDeleted)). Press Command Z to undo.").post()
        }
    }

    /// A spring in and out; a short fade under Reduce Motion, which moves nothing.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation
    }

    /// Restarts whenever another delete joins the buffer, or the pointer leaves the toast.
    private struct Countdown: Equatable {
        let ids: [UUID]
        let paused: Bool
    }

    private func countdown() async {
        let deleted = logbook.lastDeleted
        guard !deleted.isEmpty, !hovering else { return }
        let seconds = voiceOver ? LogbookUndo.toastSecondsVoiceOver : LogbookUndo.toastSeconds
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        withAnimation(Self.motion(reduceMotion: reduceMotion)) { logbook.clearUndo() }
    }

    private func toast(_ deleted: [LogEntry]) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(LogbookUndo.title(deleted))
                .dsFont(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText(value: Double(deleted.count)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(LogbookUndo.title(deleted))
            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.ds(.primary))
            .controlSize(.small)
            .keyboardShortcut("z", modifiers: .command)
            .help("Put back what you deleted, on all your devices (⌘Z)")
            .accessibilityHint("Puts back what you deleted, on all your devices")
            Button {
                withAnimation(Self.motion(reduceMotion: reduceMotion)) { logbook.clearUndo() }
            } label: {
                Image(systemName: "xmark")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .dsShadow(.medium)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func undo() {
        withAnimation(Self.motion(reduceMotion: reduceMotion)) { logbook.undoDelete() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
