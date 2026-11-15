import Foundation

// "Did you treat this low?" (docs/LowTreatmentQuestion.md)
//
// A low that comes back up with nothing logged reads, to everything that learns from the logbook,
// as glucose rising by itself: the forecasts shown during it are scored as if nothing changed, the
// range widens to cover the rebound, and the low treatment usual (#89) never learns what was eaten.
// Most lows are treated, and most treatments go unlogged when the user is busy fixing the low.
//
// So once a low has recovered, and glucose has stayed up for a quarter of an hour, GlucOS asks once
// whether it was treated: one tap logs the usual low treatment at the time it was most likely
// eaten. It never asks during the low, nor while glucose is still heading back down. "No" and
// dismissing are kept in the logbook (`LowAnswer`) and sync, so no device asks about that low again.

/// A stretch of readings below the low line. Dips back below within `LowTreatmentCheck.bounceGap`
/// of coming up are the same low.
struct LowEpisode: Hashable, Sendable {
    /// The first reading below the line.
    let start: Date
    /// The first reading back at or above it. Nil while the low is still going.
    let end: Date?
    /// The lowest reading.
    let nadirAt: Date
    let nadirMgdl: Double
}

/// What the user said about a low that had no treatment logged: kept in the logbook and synced,
/// so the question is asked at most once per low, on any device. A "yes" needs no record: the
/// treatment it logs answers it.
struct LowAnswer: Codable, Identifiable, Hashable {
    enum Answer: String, Codable, Hashable {
        /// It came back up by itself.
        case notTreated
        /// The question was closed.
        case dismissed

        /// An answer a newer version wrote reads as dismissed, so the record still decodes.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Answer(rawValue: raw) ?? .dismissed
        }
    }

    var id = UUID()
    /// The low it answers, as this device saw it.
    var lowStart: Date
    var lowEnd: Date
    var answer: Answer
    /// When it was answered.
    var answeredAt: Date

    init(id: UUID = UUID(), lowStart: Date, lowEnd: Date, answer: Answer, answeredAt: Date) {
        self.id = id
        self.lowStart = lowStart
        self.lowEnd = lowEnd
        self.answer = answer
        self.answeredAt = answeredAt
    }

    /// The same low: the two overlap. Devices can see slightly different readings (a phone reading
    /// the sensor itself), so the times needn't match exactly.
    func covers(_ low: LowEpisode) -> Bool {
        let end = low.end ?? .distantFuture
        return lowStart <= end.addingTimeInterval(LowTreatmentCheck.matchSlack)
            && lowEnd >= low.start.addingTimeInterval(-LowTreatmentCheck.matchSlack)
    }
}

enum LowTreatmentCheck {
    /// Shorter dips (one reading, a compression blip) aren't asked about.
    static let minimumLength: TimeInterval = 15 * 60
    /// A dip back below within this long of coming up is the same low.
    static let bounceGap: TimeInterval = 15 * 60
    /// Glucose has to stay up this long before asking, so the question never lands mid-low.
    static let settledFor: TimeInterval = 15 * 60
    /// Lows that ended longer ago than this aren't asked about: the answer is hazy by then, and the
    /// forecast checks it corrects have mostly been scored.
    static let askUntil: TimeInterval = 2 * 3600
    /// Food or a hypo treatment tag from this long before the low started…
    static let treatedBefore: TimeInterval = 20 * 60
    /// …to this long after it ended counts as treating it.
    static let treatedAfter: TimeInterval = 10 * 60
    /// Fast carbs take about this long to turn glucose around, so the treatment is logged this long
    /// before the lowest reading (never before the low started).
    static let leadToNadir: TimeInterval = 10 * 60
    /// How far back readings are read for lows.
    static let lookBack: TimeInterval = 6 * 3600
    /// How far apart two devices' views of the same low may be.
    static let matchSlack: TimeInterval = 10 * 60

    /// The lows in `readings` from the last `lookBack`, oldest first.
    static func episodes(readings: [GlucoseReading], lowMgdl: Double, now: Date) -> [LowEpisode] {
        let since = now.addingTimeInterval(-lookBack)
        let sorted = readings.filter { $0.timestamp >= since && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        var out: [LowEpisode] = []
        var start: Date?
        var nadir: GlucoseReading?
        var lastBelow: Date?
        for r in sorted {
            if r.mgdl < lowMgdl {
                if start == nil {
                    // Back below soon after coming up: the same low carries on.
                    if let prev = out.last, let end = prev.end, r.timestamp.timeIntervalSince(end) <= bounceGap {
                        out.removeLast()
                        start = prev.start
                        nadir = GlucoseReading(timestamp: prev.nadirAt, mgdl: prev.nadirMgdl, trend: .unknown)
                    } else {
                        start = r.timestamp
                        nadir = nil
                    }
                }
                if nadir == nil || r.mgdl < nadir!.mgdl { nadir = r }
                lastBelow = r.timestamp
            } else if let s = start, let n = nadir {
                out.append(LowEpisode(start: s, end: r.timestamp, nadirAt: n.timestamp, nadirMgdl: n.mgdl))
                start = nil
                nadir = nil
            }
        }
        if let s = start, let n = nadir {
            out.append(LowEpisode(start: s, end: nil, nadirAt: n.timestamp, nadirMgdl: n.mgdl))
        }
        return out.filter { e in
            let last = e.end ?? lastBelow ?? e.start
            return last.timeIntervalSince(e.start) >= minimumLength
        }
    }

    /// Food, or a hypo treatment tag, logged around the low.
    static func isTreated(_ low: LowEpisode, meals: [MealEntry], contexts: [ContextEvent]) -> Bool {
        let from = low.start.addingTimeInterval(-treatedBefore)
        let to = (low.end ?? .distantFuture).addingTimeInterval(treatedAfter)
        if meals.contains(where: { $0.timestamp >= from && $0.timestamp <= to }) { return true }
        return contexts.contains { $0.tags.contains(.hypoTreatment) && $0.timestamp >= from && $0.timestamp <= to }
    }

    /// The low to ask about now, if any: the latest one, over, with glucose up and staying up for
    /// `settledFor`, ended at most `askUntil` ago, with no treatment logged and no answer yet.
    /// `glucose` is where glucose is now; while it's low or heading low nothing is asked.
    static func pending(readings: [GlucoseReading], glucose: UsualGlucose, meals: [MealEntry],
                        contexts: [ContextEvent], answers: [LowAnswer], now: Date) -> LowEpisode? {
        guard glucose.mgdl != nil, !glucose.isLowOrHeadingLow else { return nil }
        guard let low = episodes(readings: readings, lowMgdl: glucose.lowMgdl, now: now).last,
              let end = low.end else { return nil }
        let since = now.timeIntervalSince(end)
        guard since >= settledFor, since <= askUntil else { return nil }
        // Every reading since it ended has stayed at or above the line.
        guard !readings.contains(where: { $0.timestamp > end && $0.timestamp <= now && $0.mgdl < glucose.lowMgdl }) else {
            return nil
        }
        guard !isTreated(low, meals: meals, contexts: contexts), !answers.contains(where: { $0.covers(low) }) else {
            return nil
        }
        return low
    }

    /// When the treatment was most likely taken: ten minutes before the lowest reading, but not
    /// before the low began.
    static func treatmentTime(for low: LowEpisode) -> Date {
        max(low.start, low.nadirAt.addingTimeInterval(-leadToNadir))
    }

    /// The usual low treatment (#89) to offer, read the same way as the log sheet's "Treat a low" tile.
    static func usualTreatment(meals: [MealEntry], contexts: [ContextEvent], now: Date) -> UsualEntry? {
        UsualEntries.lowTreatment(meals.filter { UsualEntries.isHypoTreatment($0, contexts: contexts) }, now: now)
    }

    /// What one tap logs: the usual treatment's food, tagged as a hypo treatment, at `time`. The
    /// same two entries the log sheet saves for a low treatment, with fresh ids.
    static func entries(for usual: UsualEntry, at time: Date) -> (meal: MealEntry, context: ContextEvent) {
        let items = usual.items.map { list in
            list.map { item -> MealItem in
                var copy = item
                copy.id = UUID()
                return copy
            }
        }
        let meal = MealEntry(timestamp: time, carbs: usual.carbs, food: usual.food, items: items?.isEmpty == true ? nil : items)
        return (meal, ContextEvent(timestamp: time, tags: [.hypoTreatment]))
    }

    /// "You went low at 9:12 pm and were back up by 9:40 pm."
    static func lowLine(_ low: LowEpisode) -> String {
        guard let end = low.end else { return "You went low at \(ClockLabel.time(low.start))." }
        return "You went low at \(ClockLabel.time(low.start)) and were back up by \(ClockLabel.time(end))."
    }

    static let question = "Did you treat it?"
    static let detail = "Nothing is logged for it. Logging it helps the forecast and Insights read the rise."

    /// The confirmation after logging: "Logged jelly beans at 9:20 pm as a hypo treatment."
    static func logged(_ meal: MealEntry) -> String {
        let what = meal.food.isEmpty ? LogFormat.grams(meal.carbs) + " of carbs" : meal.food
        return "Logged \(what) at \(ClockLabel.time(meal.timestamp)) as a hypo treatment."
    }

    static func answered(_ answer: LowAnswer.Answer) -> String {
        switch answer {
        case .notTreated: return "Marked as not treated."
        case .dismissed: return "Won't ask about this low again."
        }
    }
}
