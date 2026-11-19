import Foundation

// How Alert History rows come and go while the list is open (docs/AlertHistory.md, "Rows coming
// and going"). A new alert slides in at the top of its day and the rows below glide down; an alert
// ageing out of the 7 days shrinks away and the list closes up. Under Reduce Motion both
// cross-fade in place.
//
// A row keeps its place when the other device's copy of the same alert syncs in with an earlier
// time: the merged item's id moves to that copy (`AlertHistory.items`), but the row is the same
// alert, so it must not leave and slide in again. `keys` hands each item the key its row is
// drawn under, carrying the old key across such a swap.
enum AlertHistoryRowMotion {
    /// The cross-fade used for both under Reduce Motion, seconds.
    static let reduceMotionFade: TimeInterval = 0.25
    /// How small a leaving row shrinks to (from its top edge) as it fades.
    static let removalScale: Double = 0.94

    /// The key each item's row is drawn under, by item id. An item listed before keeps its key;
    /// an item that is the same alert as one listed before (same kind, fired within
    /// `AlertHistory.sameAlert`, and that one is gone) takes over its key; anything else is new
    /// and uses its own id. No two items share a key.
    static func keys(for items: [AlertHistory.Item], previous: [AlertHistory.Item],
                     previousKeys: [UUID: UUID]) -> [UUID: UUID] {
        let newIDs = Set(items.map(\.id))
        // Earlier rows whose item has gone: a copy of the same alert may have replaced them.
        var departed = previous.filter { !newIDs.contains($0.id) }
        var keys: [UUID: UUID] = [:]
        var used = Set<UUID>()
        // Kept items first, so a key they already own is never handed to a replacement.
        for item in items where previous.contains(where: { $0.id == item.id }) {
            let key = previousKeys[item.id] ?? item.id
            keys[item.id] = key
            used.insert(key)
        }
        for item in items where keys[item.id] == nil {
            if let i = departed.firstIndex(where: {
                $0.kind == item.kind && abs($0.firedAt.timeIntervalSince(item.firedAt)) <= AlertHistory.sameAlert
            }) {
                let key = previousKeys[departed[i].id] ?? departed[i].id
                departed.remove(at: i)
                if !used.contains(key) {
                    keys[item.id] = key
                    used.insert(key)
                    continue
                }
            }
            let key = used.contains(item.id) ? UUID() : item.id
            keys[item.id] = key
            used.insert(key)
        }
        return keys
    }

    /// When the next row ages out on its own: the coming midnight, if anything listed is from the
    /// oldest day and so leaves then. Nil when nothing will leave by itself. One wake per day at
    /// most, never a repeating timer.
    static func nextAgeOut(_ items: [AlertHistory.Item], now: Date,
                           calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        let startThen = AlertHistory.start(now: midnight, calendar: calendar)
        return items.contains { $0.firedAt < startThen } ? midnight : nil
    }
}
