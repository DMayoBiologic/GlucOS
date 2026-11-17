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

// MARK: - Stack (round 59)

/// The banners on screen at once (docs/AlertActions.md, "In-app banner"). A second alert that
/// arrives while one shows stacks behind it with a small offset instead of replacing it; tapping
/// the stack spreads it out so each can be read, swiped away or answered.
///
/// Front first. Urgent lows always stay in front, since they matter most and can't be snoozed;
/// otherwise the newest is in front. A new alert of a kind already showing replaces that one, so a
/// repeat never stacks on itself. Dismissing never snoozes or logs anything.
struct AlertBannerStack: Equatable {
    /// At most this many at once; the oldest goes first (never an urgent low ahead of the others).
    static let maxCount = 3
    /// How many cards peek out behind the front one while it's collapsed.
    static let peekCount = 2
    /// How far each card behind sits below the one in front, in points.
    static let peekOffset: Double = 8
    /// How much smaller each card behind is drawn.
    static let peekScaleStep: Double = 0.05
    /// How much each card behind fades.
    static let peekFadeStep: Double = 0.25

    private(set) var banners: [AlertBanner] = []
    /// Spread out, one under another. Folds back on its own when one banner is left.
    private(set) var isExpanded = false

    var front: AlertBanner? { banners.first }
    var isEmpty: Bool { banners.isEmpty }
    var count: Int { banners.count }
    /// Whether there's anything to spread out.
    var canExpand: Bool { banners.count > 1 }

    /// Adds a banner that has just arrived, dropping any that have gone past their lifetime.
    mutating func add(_ banner: AlertBanner, now: Date) {
        prune(at: now)
        banners.removeAll { $0.kind == banner.kind }
        banners.insert(banner, at: 0)
        banners = banners.filter(\.isUrgent) + banners.filter { !$0.isUrgent }
        if banners.count > Self.maxCount {
            // Drop the oldest that isn't an urgent low, or the oldest if they all are.
            let victim = banners.indices.reversed().first { !banners[$0].isUrgent } ?? banners.indices.last!
            banners.remove(at: victim)
        }
        settle()
    }

    /// Takes one banner away (swiped, closed, or answered with a button).
    mutating func remove(id: String) {
        banners.removeAll { $0.id == id }
        settle()
    }

    mutating func removeAll() {
        banners = []
        settle()
    }

    /// Drops banners left alone past their lifetime. True if any went.
    @discardableResult
    mutating func prune(at now: Date) -> Bool {
        let before = banners.count
        banners.removeAll { !$0.isShowing(at: now) }
        settle()
        return banners.count != before
    }

    mutating func setExpanded(_ expanded: Bool) {
        isExpanded = expanded && canExpand
    }

    /// When the next banner runs out, for the one timer that takes it away.
    var nextExpiry: Date? {
        banners.map { $0.firedAt.addingTimeInterval(AlertBanner.lifetime) }.min()
    }

    private mutating func settle() {
        if !canExpand { isExpanded = false }
    }

    /// Where a card sits while the stack is collapsed: the front one in its place, the next
    /// `peekCount` a little lower, smaller and fainter behind it, and any others hidden.
    struct Peek: Equatable {
        var offset: Double
        var scale: Double
        var opacity: Double
    }

    static func peek(at index: Int) -> Peek {
        guard index > 0 else { return Peek(offset: 0, scale: 1, opacity: 1) }
        let step = Double(min(index, peekCount))
        return Peek(offset: peekOffset * step, scale: 1 - peekScaleStep * step,
                    opacity: index > peekCount ? 0 : 1 - peekFadeStep * step)
    }

    /// The line on the front card while others wait behind it ("1 more alert · Tap to show").
    var moreLine: String? {
        guard !isExpanded, canExpand else { return nil }
        let n = banners.count - 1
        return "\(n) more \(n == 1 ? "alert" : "alerts") · Tap to show"
    }

    static let showAllTitle = "Show all alerts"
    static let showLessTitle = "Show less"
}

// MARK: - Swipe (round 59)

/// How the banner follows a swipe. Up, it tracks the finger one to one; down, it gives a little
/// and resists, so it feels held in place. Let go far or fast enough upward and it's dismissed;
/// otherwise it springs back. Under Reduce Motion it doesn't move: it fades as you swipe instead.
enum AlertBannerSwipe {
    static let dismissDistance: Double = 30
    static let dismissFlick: Double = 80
    /// The most it gives when pulled down.
    static let downLimit: Double = 24

    static func offset(for translation: Double) -> Double {
        guard translation > 0 else { return translation }
        return downLimit * (1 - 1 / (translation / downLimit + 1))
    }

    static func dismisses(translation: Double, predicted: Double) -> Bool {
        translation < -dismissDistance || predicted < -dismissFlick
    }

    /// Reduce Motion: the banner stays put and fades as it's swiped up, never below 0.4.
    static func reducedOpacity(for translation: Double) -> Double {
        max(0.4, 1 + min(0, translation) / 150)
    }
}
