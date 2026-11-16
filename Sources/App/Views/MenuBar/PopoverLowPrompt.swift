import SwiftUI
import AppKit

/// Once a low has come back up with nothing logged for it (here, on the iPhone, or anywhere else
/// the logbook syncs): "You went low at 9:12 pm and were back up by 9:40 pm. Did you treat it?"
/// One click logs the usual low treatment at the time it was most likely eaten; Other opens the log
/// window there; No and the close button stop it asking about that low on every device. Never
/// shown during a low (`LowTreatmentCheck`, docs/LowTreatmentQuestion.md).
struct PopoverLowPrompt: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var question = LowQuestion.shared
    @Environment(\.openWindow) private var openWindow

    /// Worth a place in the popover right now: asking, or confirming an answer just given.
    @MainActor
    static func isRelevant(logbook: LogbookStore, store: GlucoseStore, settings: AppSettings,
                           now: Date = Date()) -> Bool {
        LowQuestion.shared.confirmation(logbook: logbook, now: now) != nil
            || LowQuestion.shared.pending(logbook: logbook, snapshot: store.snapshot, settings: settings, now: now) != nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
    }

    private func openLog(at time: Date) {
        LogWindowRequest.shared.target = .lowTreatment(at: time)
        openWindow(id: LogWindow.id)
        NSApp.activate()
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let c = question.confirmation(logbook: logbook, now: now) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark.circle").foregroundStyle(GlucoseRange.low.tint)
                Text(c.text)
                    .dsFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Undo") { question.undo(logbook: logbook) }
                    .buttonStyle(.link)
            }
            .dsCard(.standard, padding: DS.Space.md)
        } else if let low = question.pending(logbook: logbook, snapshot: store.snapshot, settings: settings, now: now) {
            let usual = question.usual(logbook: logbook, now: now)
            let at = LowTreatmentCheck.treatmentTime(for: low)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: ContextTag.hypoTreatment.systemImage).foregroundStyle(GlucoseRange.low.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(LowTreatmentCheck.lowLine(low)) \(LowTreatmentCheck.question)")
                            .dsFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LowTreatmentCheck.detail)
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        question.answer(.dismissed, for: low, logbook: logbook)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Don't ask about this low")
                    .accessibilityLabel("Don't ask about this low")
                }
                HStack(spacing: DS.Space.sm) {
                    if let usual {
                        Button {
                            question.logUsual(usual, for: low, logbook: logbook, now: now)
                        } label: {
                            Text(usual.detail.isEmpty ? "Yes" : usual.detail).lineLimit(1)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.food)
                        .help("Logs it as a hypo treatment at \(ClockLabel.time(at)).")
                        Button("Other…") { openLog(at: at) }
                            .buttonStyle(.bordered)
                            .help("Log something else as a hypo treatment at \(ClockLabel.time(at)).")
                    } else {
                        Button("Log what I had…") { openLog(at: at) }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.food)
                            .help("Log it as a hypo treatment at \(ClockLabel.time(at)).")
                    }
                    Button("No") { question.answer(.notTreated, for: low, logbook: logbook, now: now) }
                        .buttonStyle(.bordered)
                        .help("It came up by itself.")
                        .accessibilityLabel("No, it came up by itself")
                }
                .controlSize(.small)
                .padding(.leading, 26)
            }
            .dsCard(.standard, padding: DS.Space.md)
            .accessibilityElement(children: .contain)
        }
    }
}
