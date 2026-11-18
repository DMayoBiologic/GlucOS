import SwiftUI

/// The Mac Logbook's toast after a delete or a saved edit: what went (or "Edited meal"), Undo (⌘Z)
/// and a close button. It rises
/// from the bottom of the Logbook, and a thin bar along its bottom drains over its lifetime
/// (`UndoCountdownBar`): it goes away by itself `LogbookUndo.toastSeconds` after the last delete
/// (20 s under VoiceOver), the same as the iPhone's `PhoneUndoToast`. Holding the pointer over it
/// pauses the bar, and moving away carries on from where it stopped (`UndoCountdown`). Dragging it
/// sideways or down dismisses it (`UndoSwipe`), like the close button; neither undoes. Undo puts
/// the entries back on every device through `LogbookStore.undoDelete`, or the edited entry exactly
/// as it was before the edit through `LogbookStore.undoEdit`, the same sync-safe paths as the
/// iPhone; the row cross-fades back. Under Reduce Motion it fades in and out in place, doesn't follow the pointer, and
/// the bar steps down once a second. Nothing loops.
struct LogbookUndoToast: View {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var hovering = false
    @State private var countdown: UndoCountdown?
    @GestureState(resetTransaction: Transaction(animation: DSMotion.emphasized.animation))
    private var drag: CGSize = .zero
    @GestureState private var dragging = false
    /// Where a dragged-away toast flies off to.
    @State private var exit: CGSize = .zero
    @State private var width: CGFloat = 480
    /// Which offers this toast shows: every one in the Logbook and Settings, only "Logged twice?"
    /// over the popover and the dashboard's other pages.
    private let shows: (LogbookUndoOffer) -> Bool

    init(shows: @escaping (LogbookUndoOffer) -> Bool = { _ in true }) {
        self.shows = shows
    }

    var body: some View {
        let offer = logbook.undoOffer.flatMap { shows($0) ? $0 : nil }
        ZStack {
            if let offer {
                toast(offer)
                    .offset(shownOffset)
                    .transition(DS.Transition.toast(reduceMotion: reduceMotion))
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: 560)
        .animation(Self.motion(reduceMotion: reduceMotion), value: offer == nil)
        .task(id: countdown) { await runOut() }
        // A new delete or edit starts the clock again and is announced once; a pause, a partial
        // Undo or sync trimming the buffer neither restarts nor re-announces it.
        .onChange(of: offer?.ids ?? [], initial: true) { old, ids in
            guard !ids.isEmpty else { countdown = nil; hovering = false; return }
            guard UndoCountdown.restarts(from: old, to: ids) || countdown == nil else { return }
            exit = .zero
            countdown = UndoCountdown(total: voiceOver ? LogbookUndo.toastSecondsVoiceOver : LogbookUndo.toastSeconds,
                                      start: Date())
            if voiceOver {
                AccessibilityNotification.Announcement("\(logbook.undoOffer?.title ?? ""). Press Command Z to undo.").post()
            }
        }
        .onChange(of: hovering || dragging) { _, held in hold(held) }
    }

    /// With the pointer (a little give upward), plus the fling once it's dragged away. Still under
    /// Reduce Motion.
    private var shownOffset: CGSize {
        guard !reduceMotion else { return .zero }
        let follow = UndoSwipe.offset(dx: drag.width, dy: drag.height)
        return CGSize(width: follow.x + exit.width, height: follow.y + exit.height)
    }

    /// Simultaneous with a minimum distance, so a click on Undo or the close button stays a click.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragging) { _, held, _ in held = true }
            .updating($drag) { value, offset, _ in offset = value.translation }
            .onEnded { value in
                guard let direction = UndoSwipe.dismissal(
                    dx: value.translation.width, dy: value.translation.height,
                    endX: value.predictedEndTranslation.width, endY: value.predictedEndTranslation.height)
                else { return }
                let to = UndoSwipe.exit(direction, width: width)
                let follow = UndoSwipe.offset(dx: value.translation.width, dy: value.translation.height)
                withAnimation(Self.motion(reduceMotion: reduceMotion)) {
                    if !reduceMotion { exit = CGSize(width: follow.x + to.x, height: follow.y + to.y) }
                    logbook.clearUndo()
                }
            }
    }

    private func hold(_ held: Bool) {
        guard var c = countdown else { return }
        if held { c.pause(at: Date()) } else { c.resume(at: Date()) }
        if c != countdown { countdown = c }
    }

    /// A spring in and out; a short fade under Reduce Motion, which moves nothing.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation
    }

    /// Clears the buffer once the bar has run out, unless the pointer is holding it.
    private func runOut() async {
        guard let c = countdown, !c.isPaused else { return }
        try? await Task.sleep(for: .seconds(c.left(at: Date())))
        guard !Task.isCancelled else { return }
        withAnimation(Self.motion(reduceMotion: reduceMotion)) { logbook.clearUndo() }
    }

    private func toast(_ offer: LogbookUndoOffer) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: offer.symbol)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .accessibilityHidden(true)
            Text(offer.title)
                .dsFont(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText(value: Double(offer.count)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(offer.title)
            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.ds(.primary))
            .controlSize(.small)
            .keyboardShortcut("z", modifiers: .command)
            .help("\(offer.hint) (⌘Z)")
            .accessibilityHint(offer.hint)
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
        .overlay(alignment: .bottom) {
            if let countdown {
                UndoCountdownBar(countdown: countdown)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, 2)
            }
        }
        .clipShape(Capsule())
        .dsShadow(.medium)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .simultaneousGesture(swipe)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    private func undo() {
        // The restored row cross-fades back: a fade only, moving nothing, under Reduce Motion.
        withAnimation(Self.motion(reduceMotion: reduceMotion)) { logbook.undo() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
