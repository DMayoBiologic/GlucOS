import Foundation
import Combine
import UserNotifications

/// "Was it for a meal?" after a fast-acting dose with no food logged near it (the rules are in
/// `DoseMealCheck`, docs/DoseQuestion.md). Shared by the Mac and the iPhone:
/// - the device a dose was logged on schedules one quiet notification half an hour after it, with
///   Meal and Correction buttons, so it can be answered without opening the app;
/// - the popover (Mac) and the strip above the log bar (iPhone) ask while the app is open;
/// - any answer, or dismissing the question, is stored on the dose and syncs, and the notification
///   is taken back on every device as soon as the dose is answered or food is logged near it.
@MainActor
final class DoseQuestion: ObservableObject {
    static let shared = DoseQuestion()

    static let category = "glucos.dose.purpose"
    static let mealAction = "dose.meal"
    static let correctionAction = "dose.correction"
    private static let kind = "dosePurpose"
    private static let idPrefix = "glucos.dose.purpose."
    /// How long the confirmation (with Undo) stays after answering in the app.
    static let confirmationFor: TimeInterval = 10 * 60

    struct Answer: Equatable {
        let doseID: UUID
        let purpose: DosePurpose
        let at: Date
    }

    /// The answer just given in the app, for its confirmation and Undo.
    @Published private(set) var lastAnswer: Answer?

    private weak var logbook: LogbookStore?
    private var cancellables = Set<AnyCancellable>()

    /// The notification's buttons. One tap each, no unlocking needed; clearing the notification
    /// counts as dismissing the question.
    static var notificationCategory: UNNotificationCategory {
        let meal = UNNotificationAction(identifier: mealAction, title: "Meal", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "fork.knife"))
        let correction = UNNotificationAction(identifier: correctionAction, title: "Correction", options: [],
                                              icon: UNNotificationActionIcon(systemImageName: "arrow.down.right"))
        return UNNotificationCategory(identifier: category, actions: [meal, correction], intentIdentifiers: [],
                                      options: [.customDismissAction])
    }

    /// Call once, when the app starts (before a notification button can be handled).
    func start(logbook: LogbookStore) {
        guard self.logbook == nil else { return }
        self.logbook = logbook
        logbook.newLocalDose
            .sink { [weak self] dose in self?.schedule(dose) }
            .store(in: &cancellables)
        // Answered on another device, food logged since, or the dose deleted: take the question back.
        logbook.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.withdrawAnswered() } }
            .store(in: &cancellables)
        Task { await withdrawAnswered() }
    }

    // MARK: Asking

    /// The doses to ask about in the app right now, newest first.
    func pending(now: Date = Date()) -> [InsulinDose] {
        guard let logbook else { return [] }
        return DoseMealCheck.pending(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts, now: now)
    }

    /// The answer to confirm: given in the app in the last 10 minutes, while the dose is still logged.
    func confirmation(now: Date = Date()) -> (dose: InsulinDose, purpose: DosePurpose)? {
        guard let a = lastAnswer, now.timeIntervalSince(a.at) < Self.confirmationFor,
              let dose = logbook?.doses.first(where: { $0.id == a.doseID }), dose.purpose == a.purpose else { return nil }
        return (dose, a.purpose)
    }

    func answer(_ purpose: DosePurpose, doseID: UUID, inApp: Bool = true) {
        logbook?.setPurpose(purpose, forDose: doseID)
        lastAnswer = inApp ? Answer(doseID: doseID, purpose: purpose, at: Date()) : nil
    }

    /// Takes the last answer back, so the dose is asked about again.
    func undo() {
        guard let a = lastAnswer else { return }
        logbook?.setPurpose(nil, forDose: a.doseID)
        lastAnswer = nil
    }

    func clearConfirmation() { lastAnswer = nil }

    // MARK: Notifications

    private func schedule(_ dose: InsulinDose) {
        guard let logbook,
              let at = DoseMealCheck.askTime(for: dose, meals: logbook.meals, contexts: logbook.contexts, now: Date())
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "Was that dose for a meal?"
        content.body = "\(DoseMealCheck.doseLine(dose)), with no food logged near it. Tap Meal or Correction so the forecast reads it right."
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.category
        content.userInfo = ["kind": Self.kind, "doseID": dose.id.uuidString]
        // Gentle: no sound, and it never breaks through Focus.
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.idPrefix + dose.id.uuidString, content: content, trigger: trigger))
    }

    /// Removes the question, waiting or shown, for every dose that no longer needs it.
    private func withdrawAnswered() async {
        guard let logbook else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let stillAsking = Set(logbook.doses.filter {
            now.timeIntervalSince($0.timestamp) <= DoseMealCheck.askUntil
                && DoseMealCheck.isUnexplained($0, meals: logbook.meals, contexts: logbook.contexts)
        }.map { Self.idPrefix + $0.id.uuidString })
        let waiting = await center.pendingNotificationRequests().map(\.identifier)
        let shown = await center.deliveredNotifications().map(\.request.identifier)
        let stale = Array(Set(waiting + shown).filter { $0.hasPrefix(Self.idPrefix) && !stillAsking.contains($0) })
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }

    /// The dose a notification asks about, if it's one of these.
    static func doseID(in userInfo: [AnyHashable: Any]) -> UUID? {
        guard userInfo["kind"] as? String == kind, let s = userInfo["doseID"] as? String else { return nil }
        return UUID(uuidString: s)
    }

    /// A button on the notification, or its dismissal. Returns false when the notification isn't
    /// this question. A plain tap opens the app, which asks there.
    @discardableResult
    func handle(action: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = Self.doseID(in: userInfo) else { return false }
        switch action {
        case Self.mealAction: answer(.meal, doseID: id, inApp: false)
        case Self.correctionAction: answer(.correction, doseID: id, inApp: false)
        case UNNotificationDismissActionIdentifier: answer(.unsure, doseID: id, inApp: false)
        default: break
        }
        return true
    }
}
