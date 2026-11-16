import SwiftUI

extension View {
    /// Pull-to-refresh with GlucOS's own ring instead of the spinner. The ring's track fades in as
    /// the list is pulled; letting go past `PullRefresh.armDistance` starts `action`, and the ring
    /// fills each time the action reports a finished step, so a slow step holds it still rather
    /// than spinning. A light tap when new data lands.
    ///
    /// Under Reduce Motion, and with VoiceOver (whose three-finger scroll drives the system
    /// control), this is the system `.refreshable` and its indicator.
    ///
    /// - Parameters:
    ///   - steps: how many times `action` will call its `stepDone`.
    ///   - tint: the ring's colour for a refresh that worked.
    ///   - action: does the refresh, calling `stepDone` after each step.
    func phonePullToRefresh(steps: Int, tint: Color,
                            action: @escaping (_ stepDone: @escaping @MainActor () -> Void) async -> PullRefresh.Outcome) -> some View {
        modifier(PhonePullRefresh(steps: steps, tint: tint, action: action))
    }
}

private struct PhonePullRefresh: ViewModifier {
    let steps: Int
    let tint: Color
    let action: (_ stepDone: @escaping @MainActor () -> Void) async -> PullRefresh.Outcome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// How far past the top the list is pulled, in points.
    @State private var overscroll: Double = 0
    /// Pulled far enough, and still held: letting go refreshes.
    @State private var armed = false
    /// A finger is on the list.
    @State private var holding = false
    /// Steps of the running refresh that have finished.
    @State private var stepsDone = 0
    @State private var running = false
    @State private var fill: Double = 0
    @State private var outcome: PullRefresh.Outcome?
    /// Counts refreshes that brought new data, for the tap.
    @State private var landed = 0

    func body(content: Content) -> some View {
        Group {
            if reduceMotion || voiceOver {
                content.refreshable {
                    if await action({}) == .newData { landed &+= 1 }
                }
            } else {
                content
                    .onScrollGeometryChange(for: Double.self) { geo in
                        max(0, -(geo.contentOffset.y + geo.contentInsets.top))
                    } action: { _, pulled in
                        overscroll = pulled
                    }
                    .onScrollPhaseChange { old, new in
                        holding = new == .interacting
                        if old == .interacting, new != .interacting {
                            if armed, !running { start() }
                            armed = false
                        }
                    }
                    .onChange(of: overscroll) { _, pulled in
                        // While held: armed past the line, disarmed if pushed back above it.
                        guard holding, !running else { return }
                        let past = pulled >= PullRefresh.armDistance
                        if past != armed { armed = past }
                    }
                    .overlay(alignment: .top) { puck }
            }
        }
        .haptic(.newData, trigger: landed)
    }

    private var pullProgress: Double { PullRefresh.pullProgress(overscroll: overscroll) }

    private var puck: some View {
        let visible = running || pullProgress > 0.05
        let size: CGFloat = 36
        // Sits in the gap the pull opens, then stays at the top while the refresh runs.
        let travel = running ? PullRefresh.armDistance : min(overscroll, PullRefresh.armDistance)
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(armed || running ? 0.3 : 0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(outcome == .failed ? Tone.warning.color : tint,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .frame(width: size, height: size)
        .background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .scaleEffect(running ? 1 : 0.6 + 0.4 * pullProgress)
        .opacity(visible ? (running ? 1 : pullProgress) : 0)
        .offset(y: max(4, CGFloat(travel) / 2 - size / 2))
        .animation(running ? DSMotion.standard.animation : nil, value: travel)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func start() {
        running = true
        outcome = nil
        let total = max(1, steps)
        stepsDone = 0
        withAnimation(DSMotion.quick.animation) { fill = PullRefresh.fill(completed: 0, of: total) }
        Task { @MainActor in
            let result = await action {
                stepsDone += 1
                withAnimation(DSMotion.emphasized.animation) {
                    fill = PullRefresh.fill(completed: stepsDone, of: total)
                }
            }
            outcome = result
            withAnimation(DSMotion.emphasized.animation) { fill = 1 }
            if result == .newData { landed &+= 1 }
            // Let the full ring be seen before it goes.
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(DSMotion.standard.animation) { running = false }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !running { fill = 0 }
        }
    }
}
