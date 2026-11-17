import SwiftUI

/// "Low alerts snoozed until 2:30 pm · 12 min", under the reading on iPhone Today and in the Mac
/// popover while any alert is snoozed (docs/AlertActions.md, "Snoozed chip"). Tapping it turns
/// every alert back on now.
///
/// Motion: it fades in once when a snooze starts and shrinks out once when it ends or is resumed,
/// and is instant under Reduce Motion. A ring around the bell drains as the snooze runs out
/// (docs/AlertActions.md, "Countdown ring"); under Reduce Motion it holds still with the minutes
/// left inside. Nothing loops: it redraws once a minute for the minutes left (the ring glides
/// once to its new length), and at each snooze's end (`AlertSnoozes.redrawDates`), and not at all
/// while nothing is snoozed.
struct AlertSnoozeChipView: View {
    let snoozes: AlertSnoozes
    /// When the snooze the ring counts down to began (`AlertSnoozeStore.countdown`). Nil: worked out
    /// from what's left.
    var countdown: AlertSnoozeCountdown?
    /// A Resume that didn't take (iPhone: the relay couldn't be reached), shown under the chip.
    var error: String?
    let onResume: () -> Void

    var body: some View {
        TimelineView(.explicit(snoozes.redrawDates(from: Date()))) { context in
            AlertSnoozeChipContent(chip: AlertSnoozeChip(snoozes, now: context.date),
                                   ring: ring(at: context.date), error: error, onResume: onResume)
        }
        .onChange(of: error) { _, e in
            if let e { AccessibilityNotification.Announcement(e).post() }
        }
    }

    private func ring(at now: Date) -> SnoozeRingState? {
        guard let end = snoozes.chipEnd(at: now),
              let c = AlertSnoozeCountdown.tracking(end, previous: countdown, now: now) else { return nil }
        return SnoozeRingState(fraction: c.fraction(at: now),
                               minutes: AlertSnoozeChip.minutesLeft(until: end, now: now))
    }

    /// How the chip leaves the screen: it shrinks out toward its leading edge as it fades, or just
    /// fades under Reduce Motion (where the parent's animation is nil, so it's instant anyway).
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .opacity,
                          removal: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
    }
}

struct SnoozeRingState: Equatable {
    /// 1 just after snoozing, 0 at the end.
    var fraction: Double
    /// Whole minutes left, rounded up, the same number the chip's text shows.
    var minutes: Int
}

private struct AlertSnoozeChipContent: View {
    let chip: AlertSnoozeChip?
    let ring: SnoozeRingState?
    let error: String?
    let onResume: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let chip {
                Button {
                    onResume()
                    AccessibilityNotification.Announcement("Alerts are back on.").post()
                } label: {
                    label(chip)
                }
                .buttonStyle(SnoozeChipStyle())
                .accessibilityLabel(chip.accessibilityLabel)
                .accessibilityHint(AlertSnoozeChip.accessibilityHint)
                .transition(AlertSnoozeChipView.transition(reduceMotion: reduceMotion))
            }
            if chip != nil, let error {
                Text(error)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Once in, once out. Under Reduce Motion `.standard` is no animation, so it's instant.
        .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: chip != nil)
        .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: error)
    }

    private func label(_ chip: AlertSnoozeChip) -> some View {
        HStack(spacing: DS.Space.xs) {
            SnoozeRing(state: ring)
            // Wraps rather than truncates at large text sizes.
            Text(chip.title)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("· \(chip.remaining)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(AlertSnoozeChip.resumeTitle)
                .fontWeight(.semibold)
                .padding(.leading, DS.Space.xs)
        }
    }
}

/// The countdown ring around the bell. It moves once a minute at most: each redraw glides the arc
/// to its new length (one short animation, never a loop). Under Reduce Motion the arc just steps,
/// and the minutes left sit inside it in place of the bell. VoiceOver skips it: the chip's label
/// already says the minutes left, and only when it's read.
private struct SnoozeRing: View {
    let state: SnoozeRingState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 20

    var body: some View {
        let line = max(1.5, size / 10)
        ZStack {
            Circle()
                .stroke(Tone.warning.color.opacity(contrast == .increased ? 0.5 : 0.25), lineWidth: line)
            Circle()
                .trim(from: 0, to: state?.fraction ?? 1)
                .stroke(Tone.warning.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if reduceMotion, let minutes = state?.minutes {
                Text("\(minutes)")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(line)
            } else {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: size * 0.45))
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : DSMotion.ambient.animation, value: state?.fraction)
        .accessibilityHidden(true)
    }
}

/// A warning-tinted capsule (rounded box once the text wraps). Its own style rather than
/// `DSChipButtonStyle`, which would read the chip to VoiceOver as a selected filter.
private struct SnoozeChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        var body: some View {
            let increased = contrast == .increased
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .dsFont(.callout)
                .foregroundStyle(Tone.warning.textColor)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs + 2)
                .frame(minHeight: 28)
                .background { shape.fill(Tone.warning.color.opacity(hovering ? 0.24 : 0.16)) }
                .overlay {
                    shape.strokeBorder(Tone.warning.color.opacity(increased ? 1 : 0.4),
                                       lineWidth: increased ? DS.Stroke.increased : DS.Stroke.hairline)
                }
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .dsAnimation(.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
