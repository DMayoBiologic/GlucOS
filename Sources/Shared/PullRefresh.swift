import Foundation

/// The rules behind pull-to-refresh on the iPhone Today screen. Plain Foundation so `swift test`
/// covers them; the ring itself is `PhonePullRefresh` in the iPhone app.
///
/// The ring fills as the refresh's steps finish (the relay's one-minute readings, then
/// LibreLinkUp), never on a timer, so a slow step leaves it holding still instead of spinning.
/// A pull reuses the same fetches as opening the app: it joins a poll already in flight, and
/// doesn't fetch again if one has only just finished (power audit #94).
enum PullRefresh {
    /// How far past the top the list has to be pulled, in points, before letting go refreshes.
    static let armDistance: Double = 72

    /// A fetch that finished this recently, without an error, is the refresh: no second fetch.
    static let freshFor: TimeInterval = 10

    /// The sliver of ring drawn the moment a refresh starts, so letting go shows something at once.
    static let startFill: Double = 0.08

    /// How far the pull has got towards refreshing, 0…1, for the ring's track fading in.
    static func pullProgress(overscroll: Double) -> Double {
        guard overscroll.isFinite, overscroll > 0 else { return 0 }
        return min(1, overscroll / armDistance)
    }

    /// The ring's fill once `completed` of `total` steps have finished. Starts at a sliver and only
    /// reaches 1 when every step is done; never goes backwards.
    static func fill(completed: Int, of total: Int) -> Double {
        let total = max(1, total)
        let done = min(max(0, completed), total)
        return startFill + (1 - startFill) * Double(done) / Double(total)
    }

    /// Whether the pull should fetch, or whether the last fetch already is the refresh.
    static func needsFetch(fetchedAt: Date?, lastError: String?, now: Date = Date()) -> Bool {
        guard let fetchedAt, lastError == nil else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        return age < 0 || age >= freshFor
    }

    /// What the screen held before and after a refresh, to tell whether new data landed.
    struct Marker: Equatable, Sendable {
        /// The latest reading's time.
        var latest: Date?
        /// Readings kept on the phone (the relay's one-minute readings land here).
        var archived: Int
    }

    enum Outcome: Equatable, Sendable {
        /// A newer reading, or more history: the light tap.
        case newData
        /// Fetched, nothing new yet (the sensor hasn't sent another reading).
        case unchanged
        /// The fetch failed and nothing new arrived another way. The ring finishes in amber; the
        /// connection banner says what's wrong.
        case failed
    }

    static func outcome(before: Marker, after: Marker, failed: Bool) -> Outcome {
        let newer: Bool
        switch (before.latest, after.latest) {
        case (nil, .some): newer = true
        case let (.some(b), .some(a)): newer = a > b
        default: newer = false
        }
        if newer || after.archived > before.archived { return .newData }
        return failed ? .failed : .unchanged
    }
}
