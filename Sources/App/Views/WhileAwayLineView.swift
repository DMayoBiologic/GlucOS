import SwiftUI

// "Away 5 h 20 m · 3.9–11.2 · 84% in range · 1 low alert" under the reading, on iPhone Today and in
// the Mac popover (`WhileAway`, docs/WhileAway.md). It shows once per opening after 2 hours or more
// unseen, slides in, and fades after 10 seconds. A tap opens the Logbook on the span.

/// The span the current opening was away, kept for the line while the screen stays open.
@MainActor
final class WhileAwayModel: ObservableObject {
    static let shared = WhileAwayModel()

    /// The span to sum up, from the last look to this opening. Nil when there's nothing to show.
    @Published private(set) var span: DateInterval?
    /// The span whose line has already faded (or was tapped), so it doesn't come back on a redraw.
    @Published private(set) var finished: DateInterval?

    private let clock: LastLookedClock

    init(clock: LastLookedClock = .defaults()) {
        self.clock = clock
    }

    /// The screen opened. A second call for the same opening (an appear and a scene change landing
    /// together) finds the look it just stored and keeps the span it has.
    func opened(isFollower: Bool, now: Date = Date()) {
        if let away = clock.open(now: now, isFollower: isFollower) { span = away }
    }

    /// The screen stopped being looked at. `ends` drops the line too: the screen has gone, and the
    /// next opening decides afresh.
    func closed(isFollower: Bool, ends: Bool = true, now: Date = Date()) {
        clock.close(now: now, isFollower: isFollower)
        if ends { span = nil; finished = nil }
    }

    /// The iPhone scene changed phase (`LastLookedClock.sceneChanged`). Only going to the
    /// background drops the line.
    func sceneChanged(from old: LastLookedClock.Phase, to new: LastLookedClock.Phase, isFollower: Bool,
                      now: Date = Date()) {
        if let away = clock.sceneChanged(from: old, to: new, now: now, isFollower: isFollower) { span = away }
        if new == .background { span = nil; finished = nil }
    }

    func finish(_ span: DateInterval) { finished = span }
}

/// The line, or nothing. Only fades move it under Reduce Motion: it cross-fades in and out.
struct WhileAwayLine: View {
    @ObservedObject var model: WhileAwayModel
    let readings: [GlucoseReading]
    let alerts: [AlertRecord]
    let lowMgdl: Double
    let highMgdl: Double
    let unit: GlucoseUnit
    let open: (LogbookLink) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var summary: WhileAway? {
        guard let span = model.span, model.finished != span else { return nil }
        return WhileAway.compute(span: span, readings: readings, alerts: alerts, low: lowMgdl, high: highMgdl)
    }

    var body: some View {
        let summary = summary
        Group {
            if let summary {
                line(summary)
                    .transition(Self.transition(reduceMotion: reduceMotion))
            }
        }
        // In once (the readings for the span may land a moment after opening), out once.
        .animation(Self.animation(reduceMotion: reduceMotion), value: summary != nil)
        // Ten seconds from when it first shows, then it fades. With VoiceOver on it stays until the
        // screen closes, so it can still be reached.
        // Keyed on VoiceOver too: turning it on stops the countdown, turning it off starts one.
        .task(id: FadeKey(span: summary?.span, voiceOver: voiceOver)) {
            guard let span = summary?.span, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(WhileAway.shownFor))
            guard !Task.isCancelled else { return }
            model.finish(span)
        }
    }

    private func line(_ w: WhileAway) -> some View {
        Button {
            model.finish(w.span)
            open(.whileAway(w.span))
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(WhileAwayText.line(w, unit: unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .dsFont(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this time in the Logbook")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhileAwayText.spoken(w, unit: unit))
        .accessibilityHint("Opens this time in the Logbook")
        .accessibilityAddTraits(.isButton)
    }

    private struct FadeKey: Equatable {
        let span: DateInterval?
        let voiceOver: Bool
    }

    /// Slides down from under the reading as it fades in, and only fades out. A cross-fade both
    /// ways under Reduce Motion.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation
    }
}
