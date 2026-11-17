import Foundation

/// The rules behind opening a Logbook entry in the edit sheet (docs/LogbookSearch.md "Editing an
/// entry"). Plain Foundation so `swift test` covers them; the views are `PhoneLogbookView`,
/// `PhoneLogbookCard`, `PhoneLogbookDetail` and the root's log sheet on the iPhone, and
/// `DashboardView`'s inline editor on the Mac.
///
/// On the iPhone the sheet zooms out of what was tapped (a row, a grouped row or the opened
/// card) and shrinks back into it on dismiss. On the Mac the editor cross-fades in place over the
/// dashboard instead of dropping down from the title bar. Under Reduce Motion both are a plain
/// cross-fade. Either way it plays once per open and close, and nothing loops (power audit #94).
/// With VoiceOver on, focus lands on the sheet's title once it has arrived.
enum LogbookEditMorph {
    /// What the entry was opened from. Each surface keys its own zoom source, so a row on the
    /// home screen's Logbook card and the same entry's row in the full Logbook underneath never
    /// share one (two sources with one id leave the zoom guessing which to grow from).
    enum Surface: String, CaseIterable, Sendable {
        /// A row on the home screen's Logbook card.
        case homeCard
        /// A row in the full Logbook.
        case row
        /// The full Logbook's opened card (`PhoneLogbookDetail`), from its Edit button.
        case openCard
        /// A grouped meal-and-insulin row, from its menu (`LogbookGrouping`).
        case group
    }

    /// The zoom source for an entry (or group) on a surface. Stable for the entry, so the sheet
    /// finds its way back to the row on dismiss even after the list has redrawn.
    static func sourceID(_ surface: Surface, _ id: UUID) -> String {
        "logbook-edit.\(surface.rawValue).\(id.uuidString)"
    }

    /// How the sheet gets from the row to open.
    enum Style: Equatable, Sendable {
        /// iPhone: zooms out of the row and back into it. Mac: fades and settles from a hair smaller.
        case morph
        /// Reduce Motion: a plain cross-fade, nothing moves or scales.
        case crossFade

        init(reduceMotion: Bool) { self = reduceMotion ? .crossFade : .morph }
    }

    /// The Mac editor's fade in and out, in seconds.
    static func fadeDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0.2 : 0.24 }

    /// The scale the Mac editor fades in from, and back to as it fades out: 1 under Reduce Motion,
    /// so it only fades.
    static func macStartScale(reduceMotion: Bool) -> Double { reduceMotion ? 1 : 0.97 }

    /// How dark the Mac dashboard gets behind the open editor.
    static let macScrimOpacity: Double = 0.18

    /// How long after the sheet opens VoiceOver focus moves to its title: once the zoom (or fade)
    /// has landed, so VoiceOver doesn't read a view that's still moving.
    static func titleFocusDelay(reduceMotion: Bool) -> Double { reduceMotion ? 0.25 : 0.55 }
}
