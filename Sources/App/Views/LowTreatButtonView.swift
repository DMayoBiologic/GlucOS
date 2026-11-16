import SwiftUI

// "Log treatment" inline, under the reading on iPhone Today and in the Mac popover, while glucose
// is low or a low is predicted (`LowTreatButton`, docs/AlertActions.md "Log treatment in the app").
// It opens the same log sheet as the alert's Log treatment button, filled in from the "Treat a low"
// usual, and never logs by itself.

extension LowTreatButton {
    /// Whether to show the button now, from the latest reading, the forecast the predicted alerts
    /// read and the logbook. The predicted part follows the predicted low alert's own rule and
    /// switch, so the button and the alert agree about when a low is coming.
    @MainActor
    static func current(store: GlucoseStore, logbook: LogbookStore, settings: AppSettings,
                        now: Date = Date()) -> Reason? {
        let s = store.snapshot
        let fresh = s.current.flatMap { $0.age(at: now) <= GlucoseSnapshot.staleAfter ? $0 : nil }
        var predictedAt: Date?
        if fresh != nil, settings.alertOnPredictedLow, let forecast = store.outlook.outlook?.alertForecast {
            let rules = PredictiveAlertSettings(lows: true, highs: false,
                                                leadTime: TimeInterval(settings.predictiveAlertMinutes * 60),
                                                lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, highAlertsOn: false)
            if let d = PredictiveAlertRules.evaluate(forecast, settings: rules, now: now), d.kind.isLow {
                predictedAt = d.expectedAt
            }
        }
        return reason(mgdl: fresh?.mgdl, lowMgdl: s.lowMgdl, predictedLowAt: predictedAt,
                      meals: logbook.meals, contexts: logbook.contexts, now: now)
    }
}

/// The button. The parent shows it only while `LowTreatButton.current` has a reason, and fades it
/// in and out once (instant under Reduce Motion, where `DSMotion.standard` is no animation). The
/// caption redraws once a minute for "in about N min"; nothing loops.
struct LowTreatButtonView: View {
    let reason: LowTreatButton.Reason
    /// A "Treat a low" usual exists, so the sheet opens filled in (only changes the hint).
    let hasUsual: Bool
    /// The Mac popover gives it ⌘L while it shows (`ShortcutCatalog.lowTreatment`).
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Button(action: action) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: ContextTag.hypoTreatment.systemImage)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(LowTreatButton.title)
                        .fontWeight(.semibold)
                    Text("· \(LowTreatButton.caption(reason, now: context.date))")
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(LowTreatButtonStyle())
            .keyboardShortcut(shortcut)
            .help(shortcut == nil ? "" : "\(LowTreatButton.title) (⌘L)")
            .accessibilityLabel(LowTreatButton.accessibilityLabel(reason, now: context.date))
            .accessibilityHint(LowTreatButton.accessibilityHint(hasUsual: hasUsual))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A critical-tinted capsule, the low colour of the alert it stands in for.
private struct LowTreatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        #if os(iOS)
        private let minHeight: CGFloat = 44
        #else
        private let minHeight: CGFloat = 28
        #endif

        var body: some View {
            let increased = contrast == .increased
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .dsFont(.callout)
                .foregroundStyle(Tone.critical.textColor)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs + 2)
                .frame(minHeight: minHeight)
                .background { shape.fill(Tone.critical.color.opacity(hovering ? 0.24 : 0.16)) }
                .overlay {
                    shape.strokeBorder(Tone.critical.color.opacity(increased ? 1 : 0.4),
                                       lineWidth: increased ? DS.Stroke.increased : DS.Stroke.hairline)
                }
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .dsAnimation(.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
