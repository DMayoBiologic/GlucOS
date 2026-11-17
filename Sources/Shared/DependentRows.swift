import Foundation

/// Settings rows that only show while a switch or picker above them allows it: the alert options
/// under Glucose alerts, Warn me ahead by under the predicted alerts, the sync status under Sync
/// logbook, your insulins under Insulin. Kept free of SwiftUI so it can be unit-tested; the views
/// are in `Sources/App/Views/DependentRowsViews.swift` (docs/SettingsDependentRows.md).
///
/// Turning the switch expands the rows with a slight fade and the rows below slide down to make
/// room (or the reverse), instead of jumping. Under Reduce Motion the rows are simply there or gone.
/// When rows appear, VoiceOver says which, once, after it has read the switch's new value.
enum DependentRows {
    enum Change: Equatable, Sendable {
        /// The rows under the switch stayed as they were (e.g. turning on Predicted highs while
        /// Predicted lows already shows Warn me ahead by).
        case none
        /// The rows came into view.
        case reveal
        /// The rows went away.
        case hide
    }

    /// What happened to the dependent rows when the switch changed.
    static func change(wasShown: Bool, isShown: Bool) -> Change {
        switch (wasShown, isShown) {
        case (false, true): return .reveal
        case (true, false): return .hide
        default: return .none
        }
    }

    /// Whether the change should move (expand/collapse with a fade) or just happen.
    static func glides(_ change: Change, reduceMotion: Bool) -> Bool {
        change != .none && !reduceMotion
    }

    /// How long to wait before the VoiceOver announcement, so it follows the switch's own
    /// "on" rather than cutting it off.
    static let announcementDelay: TimeInterval = 0.4

    /// Names listed in an announcement before the rest are counted.
    static let namedLimit = 3

    /// What VoiceOver says when rows appear: "Now showing Warn me ahead by.",
    /// "Now showing Sync status and Sync now.", "Now showing High, Rising or falling quickly and
    /// 6 more settings." Nothing when rows go away or nothing changed: the switch's own value says
    /// that, and focus stays on the switch.
    static func announcement(_ change: Change, rows: [String]) -> String? {
        let names = rows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard change == .reveal, !names.isEmpty else { return nil }
        let listed: String
        if names.count <= namedLimit {
            listed = join(names)
        } else {
            let rest = names.count - 2
            listed = "\(names[0]), \(names[1]) and \(rest) more settings"
        }
        return "Now showing \(listed)."
    }

    private static func join(_ names: [String]) -> String {
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
