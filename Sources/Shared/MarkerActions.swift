import Foundation

/// The peek card's actions for something logged on the glucose chart: keep holding a marker on
/// iPhone Today past the peek, or right-click one in the Mac popover, and its callout opens with
/// Edit and Log Again Now under what was logged. Plain Foundation so it can be unit-tested;
/// `GlucoseChart` draws it and the screen around it does what's picked.
///
/// How it shares the chart with the other touches (docs/DesignSystem.md, rule 8):
/// - iPhone: a tap is still the callout, and a hold still peeks at `MarkerPeek.holdDuration`.
///   Held on past `pinAfter` without moving, the peek turns into the card, with a light tap, and
///   it stays when the finger lifts. Lifting before then puts the peek away, as before. Moving
///   first is still a scrub, and nothing snaps (`ScrubSnap.arms`) because the finger never moved.
/// - Mac: right-clicking a marker opens the card instead of the yesterday-line menu; a right-click
///   anywhere else is that menu, as before. A left click is still the callout.
/// - The card never logs anything by itself. Log Again Now needs its own tap or click, and logs the
///   same entry at the current time (`LogEntry.copied`, which never changes an amount). Edit opens
///   the log sheet on the entry, where nothing changes until Save.
enum MarkerActions {
    enum Action: String, CaseIterable, Equatable, Sendable {
        case edit, logAgainNow

        var title: String {
            switch self {
            case .edit: return "Edit"
            case .logAgainNow: return "Log Again Now"
            }
        }

        var systemImage: String {
            switch self {
            case .edit: return "pencil"
            case .logAgainNow: return "arrow.clockwise"
            }
        }
    }

    /// How the open callout looks: what a tap shows (details and Open in Logbook), or the peek
    /// card's actions.
    enum Style: Equatable, Sendable {
        case details, actions
    }

    /// How long a finger stays on a marker, from touch-down, before the peek turns into the card.
    /// Long enough after the peek (0.3 s) that a quick look and let go still just peeks.
    static let pinAfter: TimeInterval = 0.75

    /// VoiceOver's action on a marker that opens the card.
    static let voiceOverActionName = "Edit or Log Again"

    /// What the card offers for a marker. Waking up isn't something to log twice in a row, so a
    /// wake-up only offers Edit.
    static func actions(for kind: MarkerPop.Kind?) -> [Action] {
        kind == .wake ? [.edit] : [.edit, .logAgainNow]
    }

    /// Whether a finger that went down on a marker `heldFor` seconds ago, and moved `dx`, `dy`,
    /// has held long enough for the card.
    static func pins(heldFor: TimeInterval, dx: Double, dy: Double) -> Bool {
        heldFor >= pinAfter && MarkerPeek.isHolding(dx: dx, dy: dy)
    }

    /// For VoiceOver, on each button: "Opens this meal in the log sheet.", "Logs this meal again
    /// at the current time."
    static func hint(_ action: Action, kind: MarkerPop.Kind?) -> String {
        let what = noun(kind)
        switch action {
        case .edit: return "Opens this \(what) in the log sheet."
        case .logAgainNow: return "Logs this \(what) again at the current time."
        }
    }

    /// Said after Log Again Now: "Meal logged again at 3:05 pm."
    static func loggedAgain(kind: MarkerPop.Kind?, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        "\(kind?.title ?? "Entry") logged again at \(ClockLabel.time(date, calendar: calendar))."
    }

    private static func noun(_ kind: MarkerPop.Kind?) -> String {
        switch kind {
        case .meal: return "meal"
        case .treatment: return "treatment"
        case .insulin: return "dose"
        case .wake: return "wake-up"
        case nil: return "entry"
        }
    }
}
