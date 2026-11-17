import SwiftUI

/// The small card that opens from the current reading (improvement round 56): tapping the reading
/// on iPhone Today, or clicking it in the Mac popover. When it was taken, where it came from, the
/// trend as a rate per minute and when the next one is due (`ReadingDetails`). It ticks on its own
/// 5-second clock only while it's open, and VoiceOver reads it as one element.
struct ReadingDetailsCard: View {
    let details: ReadingDetails
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("This reading")
                .dsFont(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            row("clock", title: "Taken", value: details.takenText(), caption: details.ageText)
            row(details.source.systemImage, title: "Source", value: details.source.label,
                caption: details.source.detail)
            row("speedometer", title: "Trend", value: details.rateText(unit: unit),
                caption: details.rateCaption)
            row(details.stale ? "clock.badge.exclamationmark" : "arrow.clockwise", title: "Next reading",
                value: details.nextDueText(), caption: nil,
                warning: details.stale)
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(details.spoken(unit: unit))
    }

    private func row(_ systemImage: String, title: String, value: String, caption: String?,
                     warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(warning ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .dsFont(.headline)
                    .monospacedDigit()
                    .foregroundStyle(warning ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Puts `ReadingDetailsCard` behind a tap or click on the view it's attached to: the reading's
/// figure, trend and dial. The card is a popover (kept a popover on iPhone too, rather than a
/// sheet) that re-reads the snapshot every 5 seconds while open. The reading's card is one
/// VoiceOver element, so the caller adds the "Show reading details" action there; this only
/// handles the tap. A tap doesn't compete with the long-press menu, and the Today stage's
/// collapse is driven by scrolling, not a gesture on the reading.
struct ReadingDetailsPopover: ViewModifier {
    @Binding var isPresented: Bool
    let snapshot: GlucoseSnapshot
    let unit: GlucoseUnit
    let lastCheck: Date?
    let checkEvery: TimeInterval

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { if snapshot.current != nil { isPresented = true } }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let details = ReadingDetails(snapshot: snapshot, lastCheck: lastCheck,
                                                    checkEvery: checkEvery, now: context.date) {
                        ReadingDetailsCard(details: details, unit: unit)
                    }
                }
                .presentationCompactAdaptation(.popover)
            }
            // The reading went away (signed out, a new sensor warming up): close the card.
            .onChange(of: snapshot.current == nil) { _, gone in if gone { isPresented = false } }
    }
}

extension View {
    func readingDetailsPopover(isPresented: Binding<Bool>, snapshot: GlucoseSnapshot, unit: GlucoseUnit,
                               lastCheck: Date?, checkEvery: TimeInterval) -> some View {
        modifier(ReadingDetailsPopover(isPresented: isPresented, snapshot: snapshot, unit: unit,
                                       lastCheck: lastCheck, checkEvery: checkEvery))
    }
}
