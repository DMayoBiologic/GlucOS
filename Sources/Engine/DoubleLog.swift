import Foundation

// "Logged twice?" (docs/DoubleLog.md). A meal or insulin dose saved within a few minutes of one
// that looks the same is often the same one logged twice: from Siri and then the app, from the
// iPhone and then the Mac, or a second tap on Log Again Now. After it's saved, the undo toast says
// so and offers Undo, which takes the new one off again. GlucOS never blocks the save, never
// deletes anything by itself, never changes an amount, and never asks about notes, events or
// site changes.

enum DoubleLog {
    /// Entries this close in time to each other may be the same one.
    static let window: TimeInterval = 5 * 60
    /// Doses within this many units of each other (or `share` of the larger) count as the same.
    static let unitsSlack = 0.1
    /// Carbs within this many grams of each other (or `share` of the larger) count as the same.
    static let carbsSlack = 1.0
    static let share = 0.05

    /// The entry `new` looks like a second copy of, or nil. Only meals and doses are checked, only
    /// against entries of the same kind within `window` of it, and the closest in time wins. `new`
    /// itself (same id) is never its own twin, and nor is anything in `excluding` (the other
    /// entries saved with it).
    static func earlier(for new: LogEntry, in entries: [LogEntry], excluding: Set<UUID> = []) -> LogEntry? {
        guard checks(new) else { return nil }
        return entries
            .filter { $0.id != new.id && !excluding.contains($0.id) }
            .filter { abs($0.timestamp.timeIntervalSince(new.timestamp)) <= window && nearlySame($0, new) }
            .min { abs($0.timestamp.timeIntervalSince(new.timestamp)) < abs($1.timestamp.timeIntervalSince(new.timestamp)) }
    }

    /// Meals and doses. Never notes, events or site changes.
    static func checks(_ entry: LogEntry) -> Bool {
        switch entry {
        case .dose, .meal: return true
        case .siteChange, .context: return false
        }
    }

    /// The same kind of entry with about the same amount. A dose must be the same kind of insulin
    /// (and the same insulin, when both name one); a meal the same food, when both name one.
    static func nearlySame(_ a: LogEntry, _ b: LogEntry) -> Bool {
        switch (a, b) {
        case (.dose(let x), .dose(let y)):
            guard x.kind == y.kind, close(x.units, y.units, slack: unitsSlack) else { return false }
            let kx = InsulinLibrary.key(x.name), ky = InsulinLibrary.key(y.name)
            return kx.isEmpty || ky.isEmpty || kx == ky
        case (.meal(let x), .meal(let y)):
            guard close(x.carbs, y.carbs, slack: carbsSlack) else { return false }
            let fx = foodKey(x.food), fy = foodKey(y.food)
            return fx.isEmpty || fy.isEmpty || fx == fy
        default:
            return false
        }
    }

    static func close(_ a: Double, _ b: Double, slack: Double) -> Bool {
        abs(a - b) <= max(slack, share * max(abs(a), abs(b))) + 1e-9
    }

    /// "Toast, butter" and " toast,  Butter " match.
    static func foodKey(_ food: String) -> String {
        food.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// The toast's text: "Logged twice? 4 u NovoRapid", or "Logged twice? 2 entries" when a meal
    /// and its dose were both repeated. Kept short so it fits on one line.
    static func title(_ entries: [LogEntry]) -> String {
        guard entries.count == 1, let only = entries.first else { return "Logged twice? \(entries.count) entries" }
        return "Logged twice? \(only.shortTitle)"
    }

    /// What Undo does, naming the earlier entry's time so it's clear that one stays.
    static func hint(earlier: [LogEntry]) -> String {
        guard let first = earlier.min(by: { $0.timestamp < $1.timestamp }) else {
            return "Takes the new entry off again, on all your devices"
        }
        let time = first.timestamp.formatted(date: .omitted, time: .shortened)
        let noun = earlier.count == 1 ? "one" : "ones"
        return "Takes the new entry off again, on all your devices. The earlier \(noun), from \(time), stays"
    }
}
