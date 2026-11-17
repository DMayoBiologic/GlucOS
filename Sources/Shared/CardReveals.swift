import Foundation

/// Which cards on one visit to a screen have already risen in, and the stagger for cards that
/// come into view together. Keep one per visit in `@State` on the screen (a new visit starts a new
/// one), so a card never rises in twice on the same visit, even if its view is rebuilt (the Edit
/// list on iPhone Insights, a re-sort under Reduce Motion).
/// Main thread only, like the views that use it.
final class CardReveals {
    private var revealed: Set<AnyHashable> = []
    private var batchStart: Date = .distantPast
    private var batchCount = 0

    /// Cards that start rising within this long of the first share one stagger.
    static let batchWindow: TimeInterval = 0.3
    /// The step between cards in a batch, and the most steps a card waits.
    static let step: TimeInterval = 0.06
    static let maxSteps = 4

    init() {}

    func hasRevealed(_ id: AnyHashable) -> Bool { revealed.contains(id) }

    /// Marks `id` revealed and says how long it waits before rising: the next step of the
    /// current batch, or no wait if it starts a new one. Nil if it has already risen in.
    func claim(_ id: AnyHashable, now: Date = Date()) -> TimeInterval? {
        guard revealed.insert(id).inserted else { return nil }
        if now.timeIntervalSince(batchStart) > Self.batchWindow {
            batchStart = now
            batchCount = 0
        }
        defer { batchCount += 1 }
        return Double(min(batchCount, Self.maxSteps)) * Self.step
    }
}
