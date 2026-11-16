import SwiftUI

/// The strip above the log bar's buttons half an hour after a bolus with no food logged near it:
/// "4 u NovoRapid at 9:12 am. Was it for a meal?" with Meal, Correction and a close button. Asks
/// once per dose (`DoseMealCheck`); after answering it confirms, with Undo, and after Meal offers
/// to add what was eaten.
struct PhoneDoseStrip: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var router: PhoneLogRouter
    @ObservedObject private var question = DoseQuestion.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .animation(DSMotion.quick.animation, value: question.lastAnswer)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let c = question.confirmation(now: now) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: c.purpose == .meal ? "fork.knife" : "checkmark.circle")
                    .foregroundStyle(c.purpose == .meal ? Palette.food : Palette.insulin)
                Text(DoseMealCheck.answered(c.purpose))
                    .dsFont(.callout)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: DS.Space.xs)
                if c.purpose == .meal {
                    Button("Add Food") {
                        question.clearConfirmation()
                        router.logMeal(at: c.dose.timestamp)
                    }
                    .dsFont(.headline)
                    .accessibilityHint("Logs what you ate at \(ClockLabel.time(c.dose.timestamp))")
                }
                Button("Undo") { question.undo(); Haptics.play(.undone) }
                    .dsFont(.headline)
            }
            .padding(.bottom, DS.Space.sm)
            .transition(.opacity)
        } else if let dose = DoseMealCheck.pending(doses: logbook.doses, meals: logbook.meals,
                                                   contexts: logbook.contexts, now: now).first {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: dose.viaPump ? "cross.vial" : "syringe").foregroundStyle(Palette.insulin)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(DoseMealCheck.doseLine(dose)). \(DoseMealCheck.question)")
                            .dsFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("No food is logged near it.")
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.xs)
                    Button {
                        question.answer(.unsure, doseID: dose.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Don't ask about this dose")
                }
                HStack(spacing: DS.Space.sm) {
                    Button {
                        question.answer(.meal, doseID: dose.id)
                        Haptics.play(.done)
                    } label: {
                        Label("Meal", systemImage: "fork.knife").dsFont(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.food)
                    .accessibilityHint("It was for food that isn't logged. The forecast won't expect its full drop.")
                    Button {
                        question.answer(.correction, doseID: dose.id)
                        Haptics.play(.done)
                    } label: {
                        Label("Correction", systemImage: "arrow.down.right").dsFont(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.insulin)
                    .accessibilityHint("It was to bring a high down, with no food.")
                }
                .controlSize(.small)
            }
            .padding(.bottom, DS.Space.sm)
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        }
    }
}
