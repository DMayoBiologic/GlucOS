import SwiftUI

/// The toast that rises after a logbook delete or a saved edit: what went (or "Edited meal"), and
/// Undo. A thin bar along its bottom
/// drains over its lifetime (`UndoCountdownBar`), and it springs away by itself when the bar runs
/// out, `LogbookUndo.toastSeconds` after the last delete (`PhoneUndoCountdown`). A finger on it
/// pauses the bar; lifting carries on from where it stopped. Swipe it sideways or down to dismiss
/// it early (`UndoSwipe`), which never undoes. Undo puts the entries back on every device
/// (`LogbookStore.undoDelete`), or the edited entry back exactly as it was before the edit
/// (`LogbookStore.undoEdit`); the row cross-fades back to its old values. Under Reduce Motion it fades in and out in place, doesn't follow
/// the finger, and the bar steps down once a second. Nothing loops.
struct PhoneUndoToast: View {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(PhoneUndoClock.self) private var clock: PhoneUndoClock?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState(resetTransaction: Transaction(animation: DSMotion.emphasized.animation))
    private var drag: CGSize = .zero
    @GestureState private var touching = false
    /// Where a swiped-away toast flies off to.
    @State private var exit: CGSize = .zero
    @State private var width: CGFloat = 360

    var body: some View {
        let offer = logbook.undoOffer
        ZStack {
            if let offer {
                toast(offer)
                    .offset(shownOffset)
                    .transition(DS.Transition.toast(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
        .frame(maxWidth: 560)
        .animation(PhoneUndoToast.motion(reduceMotion: reduceMotion), value: offer == nil)
        .onChange(of: touching) { _, held in clock?.hold(held) }
        .onChange(of: offer == nil) { _, empty in
            if !empty { exit = .zero }
        }
    }

    /// With the finger (a little give upward), plus the fling once it's swiped away. Still under
    /// Reduce Motion.
    private var shownOffset: CGSize {
        guard !reduceMotion else { return .zero }
        let follow = UndoSwipe.offset(dx: drag.width, dy: drag.height)
        return CGSize(width: follow.x + exit.width, height: follow.y + exit.height)
    }

    /// A finger landing pauses the bar; a drag far or fast enough sideways or down dismisses.
    /// Simultaneous, so the Undo button still takes a tap.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, held, _ in held = true }
            .updating($drag) { value, offset, _ in offset = value.translation }
            .onEnded { value in
                guard let direction = UndoSwipe.dismissal(
                    dx: value.translation.width, dy: value.translation.height,
                    endX: value.predictedEndTranslation.width, endY: value.predictedEndTranslation.height)
                else { return }
                dismiss(direction, from: value.translation)
            }
    }

    private func dismiss(_ direction: UndoSwipe.Direction, from translation: CGSize) {
        let to = UndoSwipe.exit(direction, width: width)
        let follow = UndoSwipe.offset(dx: translation.width, dy: translation.height)
        withAnimation(PhoneUndoToast.motion(reduceMotion: reduceMotion)) {
            if !reduceMotion { exit = CGSize(width: follow.x + to.x, height: follow.y + to.y) }
            logbook.clearUndo()
        }
    }

    /// A spring in and out; a short fade under Reduce Motion, which moves nothing.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation
    }

    private func toast(_ offer: LogbookUndoOffer) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: offer.symbol)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .accessibilityHidden(true)
            Text(offer.title)
                .dsFont(.callout)
                .dsLineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText(value: Double(offer.count)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                // The restored row cross-fades back: a fade only, moving nothing, under Reduce Motion.
                withAnimation(PhoneUndoToast.motion(reduceMotion: reduceMotion)) { logbook.undo() }
                Haptics.play(.undone)
            } label: {
                Text("Undo")
                    .dsFont(.headline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.xs + 2)
                    .background(Palette.brand.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityHint(offer.hint)
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, DS.Space.sm)
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
        .overlay(alignment: .bottom) {
            if let countdown = clock?.countdown {
                UndoCountdownBar(countdown: countdown)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, 3)
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .contentShape(Capsule())
        .simultaneousGesture(swipe)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { dismiss(.down, from: .zero) }
        .accessibilityAction(named: "Dismiss") { dismiss(.down, from: .zero) }
    }

    /// "Deleted 4 u NovoRapid", or "3 entries deleted" (`LogbookUndo.title`, shared with the Mac).
    static func title(_ deleted: [LogEntry]) -> String { LogbookUndo.title(deleted) }
}

/// The one clock behind every undo toast on iPhone, so the toast on Today and the one on a pushed
/// Logbook drain and pause together.
@Observable @MainActor
final class PhoneUndoClock {
    private(set) var countdown: UndoCountdown?

    func start(seconds: Double) { countdown = UndoCountdown(total: seconds, start: Date()) }
    func clear() { countdown = nil }

    /// A finger on the toast pauses it; lifting carries on.
    func hold(_ held: Bool) {
        guard var c = countdown else { return }
        if held { c.pause(at: Date()) } else { c.resume(at: Date()) }
        if c != countdown { countdown = c }
    }
}

/// Clears the undo buffer when the toast's countdown runs out (`LogbookUndo.toastSeconds` after the
/// last delete or edit, longer while a finger holds it), so the toast springs away and later
/// changes start a fresh Undo. Applied once, on the home screen's stack, so pushed screens share
/// one clock. A new delete or edit starts it again and is announced to VoiceOver once; pauses, a partial Undo and sync
/// trimming the buffer neither restart nor re-announce it.
struct PhoneUndoCountdown: ViewModifier {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var clock = PhoneUndoClock()

    func body(content: Content) -> some View {
        content
            .environment(clock)
            .onChange(of: logbook.undoOffer?.ids ?? [], initial: true) { old, ids in
                guard !ids.isEmpty else { clock.clear(); return }
                guard UndoCountdown.restarts(from: old, to: ids) || clock.countdown == nil else { return }
                clock.start(seconds: voiceOver ? LogbookUndo.toastSecondsVoiceOver : LogbookUndo.toastSeconds)
                if voiceOver {
                    AccessibilityNotification.Announcement("\(logbook.undoOffer?.title ?? ""). Undo is at the bottom of the screen.").post()
                }
            }
            .task(id: clock.countdown) {
                guard let countdown = clock.countdown, !countdown.isPaused else { return }
                try? await Task.sleep(for: .seconds(countdown.left(at: Date())))
                guard !Task.isCancelled else { return }
                withAnimation(PhoneUndoToast.motion(reduceMotion: reduceMotion)) { logbook.clearUndo() }
            }
    }
}

extension View {
    func phoneUndoCountdown() -> some View { modifier(PhoneUndoCountdown()) }
}
