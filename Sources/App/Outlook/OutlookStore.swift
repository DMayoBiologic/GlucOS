import Foundation
import Combine

/// Keeps the outlook (forecast, insulin and carbs still acting) up to date for the app.
///
/// The quick part runs on every new reading and every logbook change. The slow part (learning
/// effects from history, checking past forecasts, finding recurring patterns) runs off the main
/// thread when the logbook changes or every few hours, and its result is kept for the quick part.
@MainActor
final class OutlookStore: ObservableObject {
    @Published private(set) var outlook: Outlook?
    @Published private(set) var model: OutlookModel = .empty
    @Published private(set) var isLearning = false
    /// The forecasts this device showed, scored against what happened.
    let ledger = ForecastLedgerStore()

    /// Relearn at least this often, so new history counts.
    static let relearnInterval: TimeInterval = 3 * 3600

    private var learnTask: Task<Void, Never>?
    private var learnedFingerprint: Int?

    /// Works out the outlook for now. Cheap: only the last hour of readings is used.
    @discardableResult
    func update(archive: [GlucoseReading], snapshot: GlucoseSnapshot, logbook: LogbookStore?,
                now: Date = Date()) -> Outlook? {
        var recent = archive.suffix(40).filter { now.timeIntervalSince($0.timestamp) <= 3600 }
        // The snapshot's newest reading may not be in the archive's 5-minute slots yet.
        if let current = snapshot.current, !recent.contains(where: { $0.timestamp == current.timestamp }) {
            recent.append(current)
            recent.sort { $0.timestamp < $1.timestamp }
        }
        let o = OutlookEngine.outlook(readings: recent, doses: logbook?.doses ?? [], meals: logbook?.meals ?? [],
                                      contexts: logbook?.contexts ?? [], model: model, now: now)
        outlook = o
        ledger.update(forecast: o.glucoseForecast, tuned: model.tuning.isTuned, archive: archive,
                      current: snapshot.current, logTimes: Self.logTimes(logbook), now: now)
        return o
    }

    /// When anything that changes glucose was logged. A wake-up isn't one: the forecast models it.
    private static func logTimes(_ logbook: LogbookStore?) -> [Date] {
        guard let logbook else { return [] }
        return logbook.doses.map(\.timestamp) + logbook.meals.map(\.timestamp)
            + logbook.contexts.filter { !$0.isWake }.map(\.timestamp)
    }

    /// Starts relearning in the background if the logs changed or the last run is old.
    func relearnIfNeeded(archive: [GlucoseReading], logbook: LogbookStore?, low: Double, high: Double,
                         now: Date = Date(), onFinish: @escaping @MainActor () -> Void) {
        var h = Hasher()
        h.combine(logbook?.doses ?? [])
        h.combine(logbook?.meals ?? [])
        h.combine(logbook?.contexts ?? [])
        h.combine(low)
        h.combine(high)
        let fingerprint = h.finalize()
        let fresh = now.timeIntervalSince(model.learnedAt) < Self.relearnInterval
        guard learnTask == nil, !(fresh && fingerprint == learnedFingerprint), !archive.isEmpty else { return }

        let doses = logbook?.doses ?? [], meals = logbook?.meals ?? [], contexts = logbook?.contexts ?? []
        isLearning = true
        learnTask = Task.detached(priority: .utility) { [archive] in
            let m = OutlookEngine.learn(readings: archive, doses: doses, meals: meals, contexts: contexts,
                                        low: low, high: high, now: now)
            await MainActor.run {
                self.model = m
                self.learnedFingerprint = fingerprint
                self.isLearning = false
                self.learnTask = nil
                onFinish()
            }
        }
    }
}
