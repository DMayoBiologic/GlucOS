import SwiftUI

/// "Low alerts snoozed until 2:30 pm · 12 min", under the reading on iPhone Today and in the Mac
/// popover while any alert is snoozed (docs/AlertActions.md, "Snoozed chip"). Tapping it turns
/// every alert back on now.
///
/// Motion: it fades in once when a snooze starts and out once when it ends or is resumed, and is
/// instant under Reduce Motion. Nothing loops: it redraws once a minute for the minutes left, and
/// at each snooze's end (`AlertSnoozes.redrawDates`), and not at all while nothing is snoozed.
struct AlertSnoozeChipView: View {
    let snoozes: AlertSnoozes
    /// A Resume that didn't take (iPhone: the relay couldn't be reached), shown under the chip.
    var error: String?
    let onResume: () -> Void

    var body: some View {
        TimelineView(.explicit(snoozes.redrawDates(from: Date()))) { context in
            AlertSnoozeChipContent(chip: AlertSnoozeChip(snoozes, now: context.date), error: error,
                                   onResume: onResume)
        }
        .onChange(of: error) { _, e in
            if let e { AccessibilityNotification.Announcement(e).post() }
        }
    }
}

private struct AlertSnoozeChipContent: View {
    let chip: AlertSnoozeChip?
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
                .transition(.opacity)
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
            Image(systemName: "bell.slash.fill")
                .imageScale(.small)
                .accessibilityHidden(true)
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
