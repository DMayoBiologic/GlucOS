import Foundation

/// "Check now" on a gap in readings (`ReadingGaps`) that someone can act on. When the newest gap's
/// card on iPhone Today or the Mac popover says "No signal from LibreLinkUp" or "Can't connect to
/// LibreLinkUp", it carries a Check Now button. A tap runs one fetch through the app's usual
/// refresh (joining one already in flight), with a small spinner that turns into a check mark, and
/// the card then says what came back: "Connected, new reading 6.1", "Connected, no new reading
/// yet", or the connection problem in plain words.
///
/// One tap per 30 seconds: after a check the button waits, saying for how long. It never adds a
/// background wake or changes polling; it's one fetch, on a tap, while the app is open. Followers
/// (who get readings from the relay, not LibreLinkUp) never see it. Plain Foundation so it can be
/// unit-tested; `GlucoseStore.checkNow()` runs it and `GlucoseChart` draws it.
enum ReadingGapCheck {
    /// A check can run again this long after the last tap.
    static let cooldown: TimeInterval = 30
    /// The spinner holds at least this long, so a fast fetch doesn't just flicker.
    static let minimumSpin: TimeInterval = 0.6
    /// Mac: how long the card waits for the pointer to move from the bridge onto it.
    static let hoverGrace: TimeInterval = 0.25
    /// VoiceOver's action on the chart while the newest gap offers a check.
    static let voiceOverActionName = "Check now"

    /// What the chart needs to draw the button: the store's state, and what a tap runs.
    struct Control {
        let status: Status
        let run: () -> Void
    }

    /// Whether a gap with this reason gets the button: only the ones where checking again helps.
    static func offers(_ reason: ReadingGaps.Reason) -> Bool {
        reason == .noSignal || reason == .cantConnect
    }

    /// Whether `gap`'s card gets the button: an actionable reason, and the newest gap on the chart
    /// (an older one has long been followed by readings, so checking says nothing about it).
    static func offers(_ gap: ReadingGaps.Gap, among gaps: [ReadingGaps.Gap]) -> Bool {
        offers(gap.reason) && gap.id == gaps.last?.id
    }

    /// What a check found.
    enum Outcome: Hashable, Sendable {
        /// A reading newer than the one before the tap: its value, already in the shown unit.
        case newReading(String)
        /// Connected, but LibreLinkUp had nothing newer.
        case upToDate
        /// The fetch failed: the problem's title, in plain words.
        case failed(String)

        var line: String {
            switch self {
            case .newReading(let value): return "Connected, new reading \(value)"
            case .upToDate: return "Connected, no new reading yet"
            case .failed(let problem): return problem
            }
        }

        var succeeded: Bool {
            if case .failed = self { return false }
            return true
        }

        var systemImage: String { succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
    }

    /// The check's state, kept by the store so it survives the card closing and opening again.
    struct Status: Hashable, Sendable {
        /// When the button was last tapped. Nil: never this launch.
        var tappedAt: Date?
        var running = false
        /// The last check's result, until the next one starts.
        var outcome: Outcome?

        /// Seconds until the button works again (0 when it does).
        func wait(at now: Date) -> TimeInterval {
            guard let tappedAt else { return 0 }
            return max(0, cooldown - now.timeIntervalSince(tappedAt))
        }

        func canCheck(at now: Date) -> Bool { !running && wait(at: now) <= 0 }

        /// The button's words: "Check Now", "Checking…", "Check again in 12 s".
        func buttonTitle(at now: Date) -> String {
            if running { return "Checking…" }
            let left = wait(at: now)
            guard left > 0 else { return outcome == nil ? "Check Now" : "Check Again" }
            return "Check again in \(Int(left.rounded(.up))) s"
        }

        /// What VoiceOver hears once a check finishes.
        var announcement: String? { outcome?.line }

        /// A tap at `now`, if it's allowed: running, with the last result cleared.
        mutating func start(at now: Date) -> Bool {
            guard canCheck(at: now) else { return false }
            tappedAt = now
            running = true
            outcome = nil
            return true
        }

        mutating func finish(_ outcome: Outcome) {
            running = false
            self.outcome = outcome
        }
    }

    /// What a finished fetch found. `before` is the newest reading's time when the tap came;
    /// `latest` is the newest reading now; `problem` is the fetch's failure in plain words, if any.
    static func outcome(before: Date?, latest: GlucoseReading?, problem: String?,
                        unit: GlucoseUnit) -> Outcome {
        if let latest, before.map({ latest.timestamp > $0 }) ?? true {
            // New, even if the fetch around it then hit a problem: the reading is what matters.
            return .newReading(unit.format(mgdl: latest.mgdl))
        }
        if let problem, !problem.isEmpty { return .failed(problem) }
        return .upToDate
    }
}
