import SwiftUI

/// The thin bar along the bottom of the undo toast (iPhone and Mac) that drains over the toast's
/// lifetime (`UndoCountdown`). One linear animation from what's left to empty each time the clock
/// starts or carries on; a pause freezes it where it is. Under Reduce Motion it steps down once a
/// second without gliding, and the loop ends with the toast. Hidden from VoiceOver: the toast's
/// announcement already says Undo is there.
struct UndoCountdownBar: View {
    let countdown: UndoCountdown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled: Double = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Palette.brand.opacity(0.6))
                .frame(width: max(0, geo.size.width * filled))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
        .task(id: Drive(countdown: countdown, reduceMotion: reduceMotion)) { await drive() }
    }

    private struct Drive: Equatable {
        let countdown: UndoCountdown
        let reduceMotion: Bool
    }

    private func set(_ value: Double) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { filled = value }
    }

    private func drive() async {
        let now = Date()
        if reduceMotion {
            set(countdown.steppedFraction(at: now))
            guard !countdown.isPaused else { return }
            while !Task.isCancelled, countdown.left(at: Date()) > 0 {
                let left = countdown.left(at: Date())
                let toNextSecond = left - (left - 0.001).rounded(.down)
                try? await Task.sleep(for: .seconds(max(0.05, toNextSecond)))
                guard !Task.isCancelled else { return }
                set(countdown.steppedFraction(at: Date()))
            }
            return
        }
        // Snap the bar to exactly what's left (where it already is, mid-drain), then let one
        // linear animation take it to empty. A pause lands here too and simply stops it.
        set(countdown.fraction(at: now))
        guard !countdown.isPaused else { return }
        // A frame for the snap to land, so the drain starts from it rather than from mid-flight.
        try? await Task.sleep(for: .milliseconds(16))
        let left = countdown.left(at: Date())
        guard !Task.isCancelled, left > 0 else { return }
        withAnimation(.linear(duration: left)) { filled = 0 }
    }
}
