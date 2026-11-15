import SwiftUI
import AppKit

/// Half an hour after a bolus with no food logged near it (here, on the iPhone, or anywhere else
/// the logbook syncs): "4 u NovoRapid at 9:12 am. Was it for a meal?" with Meal, Correction and a
/// close button. Asks once per dose (`DoseMealCheck`); after answering it confirms, with Undo, and
/// after Meal offers to add what was eaten.
struct PopoverDosePrompt: View {
    @EnvironmentObject var logbook: LogbookStore
    @ObservedObject private var question = DoseQuestion.shared
    @Environment(\.openWindow) private var openWindow

    /// Worth a place in the popover right now: asking, or confirming an answer just given.
    @MainActor
    static func isRelevant(logbook: LogbookStore, now: Date = Date()) -> Bool {
        DoseQuestion.shared.confirmation(now: now) != nil
            || !DoseMealCheck.pending(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts, now: now).isEmpty
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let c = question.confirmation(now: now) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: c.purpose == .meal ? "fork.knife" : "checkmark.circle")
                    .foregroundStyle(c.purpose == .meal ? Palette.food : Palette.insulin)
                Text(DoseMealCheck.answered(c.purpose))
                    .dsFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if c.purpose == .meal {
                    Button("Add Food") {
                        question.clearConfirmation()
                        LogWindowRequest.shared.target = .meal(at: c.dose.timestamp)
                        openWindow(id: LogWindow.id)
                        NSApp.activate()
                    }
                    .buttonStyle(.link)
                    .help("Log what you ate at \(ClockLabel.time(c.dose.timestamp))")
                }
                Button("Undo") { question.undo() }
                    .buttonStyle(.link)
            }
            .dsCard(.standard, padding: DS.Space.md)
        } else if let dose = DoseMealCheck.pending(doses: logbook.doses, meals: logbook.meals,
                                                   contexts: logbook.contexts, now: now).first {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: dose.viaPump ? "cross.vial" : "syringe").foregroundStyle(Palette.insulin)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(DoseMealCheck.doseLine(dose)). \(DoseMealCheck.question)")
                            .dsFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(DoseMealCheck.detail)
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        question.answer(.unsure, doseID: dose.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Don't ask about this dose")
                    .accessibilityLabel("Don't ask about this dose")
                }
                HStack(spacing: DS.Space.sm) {
                    Button {
                        question.answer(.meal, doseID: dose.id)
                    } label: {
                        Label("Meal", systemImage: "fork.knife")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.food)
                    .help("It was for food that isn't logged. The forecast won't expect its full drop.")
                    Button {
                        question.answer(.correction, doseID: dose.id)
                    } label: {
                        Label("Correction", systemImage: "arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.insulin)
                    .help("It was to bring a high down, with no food.")
                }
                .controlSize(.small)
                .padding(.leading, 26)
            }
            .dsCard(.standard, padding: DS.Space.md)
            .accessibilityElement(children: .contain)
        }
    }
}
