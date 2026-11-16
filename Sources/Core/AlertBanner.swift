import Foundation

/// A low or high alert shown inside the app, sliding down from the top, when it fires while GlucOS
/// is in front (docs/AlertActions.md, "In-app banner"). It takes the place of the system banner
/// while the app is open: the sound and a haptic still play, and the notification still goes in
/// Notification Center. Its buttons are the notification's own (`AlertSnoozes.buttonTitles`), and
/// do exactly what they do there.
///
/// Plain Foundation so it can be unit-tested; `AlertBannerCenter` and `AlertBannerView` show it.
struct AlertBanner: Equatable, Identifiable {
    enum Button: Equatable {
        case treat
        case snooze

        var title: String {
            switch self {
            case .treat: return AlertSnoozes.treatTitle
            case .snooze: return AlertSnoozes.snoozeTitle
            }
        }
    }

    let kind: AlertNotice.Kind
    /// The notification's title, which carries the reading ("Low glucose — 3.6 mmol/L").
    let title: String
    /// The notification's body: the trend, or the forecast's wording for a predicted alert.
    let body: String
    let firedAt: Date

    var id: String { "\(kind.rawValue)@\(firedAt.timeIntervalSince1970)" }

    /// A banner left alone goes away after this, so a phone picked up later doesn't show an old
    /// alert as if it were new. The notification itself stays in Notification Center.
    static let lifetime: TimeInterval = 10 * 60

    /// Only the user's own low and high alerts (the ones with buttons). Everything else (rapid
    /// change, no data, sensor, connection, check-ins, a follower's copy of someone else's alert)
    /// keeps the system banner.
    init?(kind raw: String?, isFollowerCopy: Bool, title: String, body: String, firedAt: Date) {
        guard !isFollowerCopy, let raw, let kind = AlertNotice.Kind(rawValue: raw),
              kind.treatment != nil else { return nil }
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firedAt = firedAt
    }

    /// The same buttons, in the same order, as the notification. Urgent lows: Log treatment only.
    var buttons: [Button] {
        kind.snoozeLevel == nil ? [.treat] : [.treat, .snooze]
    }

    var isLow: Bool { kind.treatment == .low }
    /// Urgent lows: never snoozable, and drawn in the critical tone.
    var isUrgent: Bool { kind.snoozeLevel == nil }

    /// Whether it should still be on screen at `now`.
    func isShowing(at now: Date) -> Bool {
        now.timeIntervalSince(firedAt) < Self.lifetime
    }

    /// Read out by VoiceOver as it arrives, since it appears without focus moving to it.
    var announcement: String {
        let reading = title.replacingOccurrences(of: " — ", with: ", ")
        let detail = body.isEmpty ? "" : " \(body.hasSuffix(".") ? body : body + ".")"
        let options = buttons.map { $0 == .snooze ? "Snooze 30 minutes" : $0.title }
        return "Alert: \(reading).\(detail) \(options.joined(separator: " or ")) at the top of the screen."
    }

    /// Spoken for the banner itself when VoiceOver lands on it.
    var accessibilityLabel: String {
        let reading = title.replacingOccurrences(of: " — ", with: ", ")
        return body.isEmpty ? reading : "\(reading). \(body)"
    }

    static let dismissTitle = "Dismiss"
    static let dismissHint = "Hides this alert. It stays in Notification Center."
}
