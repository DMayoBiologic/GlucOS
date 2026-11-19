import Foundation

/// The Logbook's way back to today (round 91). On iPhone a small "Today" pill rises under the
/// navigation bar once the list has scrolled well away from the top, and a tap springs the list back
/// so the newest day's header sits at the top. On the Mac a Today toolbar button (⌘T) does the same
/// for the table. Plain numbers and words so the rules are tested; the views only animate them.
/// docs/LogbookSearch.md "Back to today".
enum LogbookToday {
    /// The pill shows once the list has scrolled this many screen heights from the top…
    static let showAt = 0.8
    /// …and goes again once it's back within this many, so it doesn't flicker at one spot.
    static let hideAt = 0.4
    /// Never shows above this many points, however short the screen.
    static let minimumShow = 360.0

    /// Whether the pill should be showing, scrolled `offset` points from the top of a list whose
    /// visible height is `viewport`. `showing` is what it shows now: the two lines differ, so a
    /// list resting near one of them doesn't make the pill blink.
    static func shows(offset: Double, viewport: Double, showing: Bool) -> Bool {
        let height = max(viewport, 1)
        let on = max(minimumShow, height * showAt)
        let off = max(minimumShow / 2, height * hideAt)
        return offset > (showing ? off : on)
    }

    /// The day the pill goes back to: the newest day the list shows (today, when anything was
    /// logged today). Nil when nothing is listed.
    static func target(shownDays: some Sequence<Date>) -> Date? {
        shownDays.max()
    }

    /// "Today" when the list's newest day is today, "Latest" when the newest listed day is older
    /// (nothing logged yet today, or a search that leaves today out).
    static func title(target: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let target, !calendar.isDate(target, inSameDayAs: now) else { return "Today" }
        return "Latest"
    }

    /// What VoiceOver reads for the pill or the Mac button: one label, no separate hint.
    static func accessibilityLabel(target: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        title(target: target, now: now, calendar: calendar) == "Today" ? "Back to today" : "Back to the latest entries"
    }

    /// The Mac toolbar button's tooltip.
    static let macHelp = "Back to today (⌘T)"
}
