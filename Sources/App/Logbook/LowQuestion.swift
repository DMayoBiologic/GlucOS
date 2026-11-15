import Foundation
import Combine

/// "Did you treat this low?" once a low has come back up with nothing logged for it (the rules are
/// in `LowTreatmentCheck`, docs/LowTreatmentQuestion.md). Shared by the Mac popover and the strip
/// above the iPhone log bar. It only ever asks in the app, never as a notification: after a low the
/// last thing wanted is another buzz.
/// - **Yes** logs the usual low treatment (#89) at the time it was most likely eaten, as the log
///   sheet would: food tagged as a hypo treatment, never a dose.
/// - **Something else** opens the log sheet on a hypo treatment at that time.
/// - **No**, or closing it, is kept in the logbook (`LowAnswer`) and syncs, so no device asks again.
/// Each answer is confirmed with Undo for ten minutes.
@MainActor
final class LowQuestion: ObservableObject {
    static let shared = LowQuestion()

    /// How long the confirmation (with Undo) stays after answering.
    static let confirmationFor: TimeInterval = 10 * 60

    enum Outcome: Equatable {
        case logged(mealID: UUID, contextID: UUID)
        case answered(LowAnswer.Answer, answerID: UUID)
    }

    struct Confirmation: Equatable {
        let outcome: Outcome
        let text: String
        let at: Date
    }

    @Published private(set) var lastAnswer: Confirmation?

    /// The readings a low is looked for in: the last 12 hours and the latest.
    static func readings(_ snapshot: GlucoseSnapshot) -> [GlucoseReading] {
        var out = snapshot.history
        if let c = snapshot.current, !out.contains(where: { $0.timestamp == c.timestamp }) { out.append(c) }
        return out
    }

    /// The low to ask about now, if any.
    func pending(logbook: LogbookStore, snapshot: GlucoseSnapshot, settings: AppSettings,
                 now: Date = Date()) -> LowEpisode? {
        LowTreatmentCheck.pending(readings: Self.readings(snapshot),
                                  glucose: UsualGlucose.current(snapshot, settings: settings, now: now),
                                  meals: logbook.meals, contexts: logbook.contexts, answers: logbook.lowAnswers, now: now)
    }

    /// The usual low treatment to offer on the button, if the user has one.
    func usual(logbook: LogbookStore, now: Date = Date()) -> UsualEntry? {
        LowTreatmentCheck.usualTreatment(meals: logbook.meals, contexts: logbook.contexts, now: now)
    }

    /// The answer to confirm: given in the last ten minutes, while what it did still stands.
    func confirmation(logbook: LogbookStore, now: Date = Date()) -> Confirmation? {
        guard let c = lastAnswer, now.timeIntervalSince(c.at) < Self.confirmationFor else { return nil }
        switch c.outcome {
        case .logged(let mealID, _):
            return logbook.meals.contains { $0.id == mealID } ? c : nil
        case .answered(_, let id):
            return logbook.lowAnswers.contains { $0.id == id } ? c : nil
        }
    }

    /// Yes: logs the usual treatment at the time it was most likely taken.
    func logUsual(_ usual: UsualEntry, for low: LowEpisode, logbook: LogbookStore, now: Date = Date()) {
        let time = min(LowTreatmentCheck.treatmentTime(for: low), now)
        let (meal, context) = LowTreatmentCheck.entries(for: usual, at: time)
        logbook.save(.meal(meal))
        logbook.save(.context(context))
        lastAnswer = Confirmation(outcome: .logged(mealID: meal.id, contextID: context.id),
                                  text: LowTreatmentCheck.logged(meal), at: now)
    }

    /// No, or closed.
    func answer(_ answer: LowAnswer.Answer, for low: LowEpisode, logbook: LogbookStore, now: Date = Date()) {
        logbook.answerLow(low, answer, now: now)
        guard let saved = logbook.lowAnswers.last(where: { $0.covers(low) }) else { return }
        lastAnswer = Confirmation(outcome: .answered(answer, answerID: saved.id),
                                  text: LowTreatmentCheck.answered(answer), at: now)
    }

    /// Takes the answer back, so the question shows again.
    func undo(logbook: LogbookStore) {
        guard let c = lastAnswer else { return }
        lastAnswer = nil
        switch c.outcome {
        case .logged(let mealID, let contextID):
            logbook.delete(ids: [mealID, contextID])
            // Not a delete the logbook's own Undo banner should offer to put back.
            logbook.clearUndo()
        case .answered(_, let id):
            logbook.removeLowAnswer(id: id)
        }
    }

    func clearConfirmation() {
        lastAnswer = nil
    }
}
