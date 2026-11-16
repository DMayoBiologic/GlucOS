import SwiftUI

/// The strip above the log bar's buttons once a low has come back up with nothing logged for it:
/// "You went low at 9:12 pm and were back up by 9:40 pm. Did you treat it?" One tap logs the usual
/// low treatment at the time it was most likely eaten; Other opens the log sheet there; No and the
/// close button stop it asking about that low on every device. Never shown during a low
/// (`LowTreatmentCheck`, docs/LowTreatmentQuestion.md).
struct PhoneLowStrip: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: PhoneLogRouter
    @ObservedObject private var question = LowQuestion.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .animation(DSMotion.quick.animation, value: question.lastAnswer)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let c = question.confirmation(logbook: logbook, now: now) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark.circle").foregroundStyle(GlucoseRange.low.tint)
                Text(c.text)
                    .dsFont(.callout)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: DS.Space.xs)
                Button("Undo") { question.undo(logbook: logbook); Haptics.play(.undone) }
                    .dsFont(.headline)
            }
            .padding(.bottom, DS.Space.sm)
            .transition(.opacity)
        } else if let low = question.pending(logbook: logbook, snapshot: store.snapshot, settings: settings, now: now) {
            let usual = question.usual(logbook: logbook, now: now)
            let at = LowTreatmentCheck.treatmentTime(for: low)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: ContextTag.hypoTreatment.systemImage).foregroundStyle(GlucoseRange.low.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(LowTreatmentCheck.lowLine(low)) \(LowTreatmentCheck.question)")
                            .dsFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Nothing is logged for it.")
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.xs)
                    Button {
                        question.answer(.dismissed, for: low, logbook: logbook)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Don't ask about this low")
                }
                HStack(spacing: DS.Space.sm) {
                    if let usual {
                        Button {
                            question.logUsual(usual, for: low, logbook: logbook, now: now)
                            Haptics.play(.done)
                        } label: {
                            Text(usual.detail.isEmpty ? "Yes" : usual.detail)
                                .dsFont(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.food)
                        .accessibilityLabel("Yes, \(usual.spokenLabel.replacingOccurrences(of: "\(usual.title): ", with: ""))")
                        .accessibilityHint("Logs it as a hypo treatment at \(ClockLabel.time(at)).")
                        Button {
                            router.logLowTreatment(at: at)
                        } label: {
                            Text("Other").dsFont(.headline)
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.food)
                        .accessibilityLabel("Something else")
                        .accessibilityHint("Opens the log sheet on a hypo treatment at \(ClockLabel.time(at)).")
                    } else {
                        Button {
                            router.logLowTreatment(at: at)
                        } label: {
                            Text("Log what I had").dsFont(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.food)
                        .accessibilityHint("Opens the log sheet on a hypo treatment at \(ClockLabel.time(at)).")
                    }
                    Button {
                        question.answer(.notTreated, for: low, logbook: logbook, now: now)
                        Haptics.play(.done)
                    } label: {
                        Text("No").dsFont(.headline)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("No, it came up by itself")
                }
                .controlSize(.small)
            }
            .padding(.bottom, DS.Space.sm)
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        }
    }
}
