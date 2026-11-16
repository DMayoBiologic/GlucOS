import Foundation

/// Every haptic the iPhone app plays, named by what it means rather than how it feels, so the same
/// moment always feels the same wherever it happens. The table is in docs/Redesign.md (§7.3) and the
/// rules in docs/DesignSystem.md rule 7. Plain Foundation so it can be unit-tested; `Haptics` (in
/// HapticFeedback.swift) plays them.
///
/// Haptics are kept for moments that mean something. Routine refreshes, first loads, dismissing a
/// card and plain navigation stay silent.
enum HapticEvent: String, CaseIterable, Sendable {
    /// Picked something: a chip, a tile, a stepper, chart hours, a setup step.
    case choice
    /// Something you asked for finished: logged, saved, answered, exported, sent, signed in.
    case done
    /// Undo put something back (or took it away again).
    case undone
    /// Pull to refresh brought new readings.
    case newData
    /// Scrubbing the chart crossed the low or high line.
    case scrubRangeEdge
    /// Scrubbing the chart passed something logged.
    case scrubLogged
    /// A new reading, with the app open, crossed into a low.
    case enteredLow
    /// A new reading came back into range.
    case backInRange
    /// A low or high alert fired with the app open, and its banner slid in (docs/AlertActions.md).
    case alertBanner
    /// A follower's check-in came back "okay".
    case followerOkay
    /// A follower's check-in came back "needs help", or went unanswered.
    case followerNeedsHelp

    /// How an event feels. Only the system's own feedback styles, so iOS's System Haptics switch
    /// (Settings › Sounds & Haptics) silences every one of them.
    enum Feel: Equatable, Sendable {
        case selection
        case success
        case warning
        case lightImpact(intensity: Double)
    }

    var feel: Feel {
        switch self {
        case .choice: return .selection
        case .done, .backInRange, .followerOkay: return .success
        case .enteredLow, .alertBanner, .followerNeedsHelp: return .warning
        case .undone, .newData: return .lightImpact(intensity: 0.8)
        case .scrubRangeEdge: return .lightImpact(intensity: 0.9)
        case .scrubLogged: return .lightImpact(intensity: 0.6)
        }
    }

    /// Which one wins when two land together: a warning about glucose beats an outcome, an outcome
    /// beats an acknowledgement, and a scrub tick gives way to anything.
    var priority: Int {
        switch self {
        case .enteredLow, .alertBanner, .followerNeedsHelp: return 3
        case .done, .backInRange, .followerOkay: return 2
        case .choice, .undone, .newData: return 1
        case .scrubRangeEdge, .scrubLogged: return 0
        }
    }

    /// Ticks follow a finger (picking, stepping, scrubbing), so a quick run of them is expected and
    /// each one still plays.
    var isTick: Bool {
        switch self {
        case .choice, .scrubRangeEdge, .scrubLogged: return true
        default: return false
        }
    }
}

/// Keeps haptics from stacking into a double buzz. Within `quietGap` of the last one played, a new
/// event only plays if it matters more (a low warning still comes through right after a
/// pull-to-refresh tap; the tap after a warning doesn't). Ticks after ticks only need `tickGap`,
/// so stepping or scrubbing quickly still ticks each time.
struct HapticGate: Sendable {
    static let quietGap: TimeInterval = 0.4
    static let tickGap: TimeInterval = 0.06

    private var last: HapticEvent?
    private var lastAt: Date?

    init() {}

    /// Whether `event` should play at `now`; if it does, it becomes the last one played.
    mutating func admit(_ event: HapticEvent, at now: Date) -> Bool {
        if let last, let lastAt {
            let gap = now.timeIntervalSince(lastAt)
            // A clock that went backwards says nothing about how close they are.
            if gap >= 0 {
                if event.isTick && last.isTick {
                    if gap < Self.tickGap { return false }
                } else if gap < Self.quietGap, event.priority <= last.priority {
                    return false
                }
            }
        }
        last = event
        lastAt = now
        return true
    }
}
