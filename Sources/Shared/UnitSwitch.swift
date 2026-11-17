import Foundation

/// Switching between mg/dL and mmol/L, kept free of SwiftUI so it can be unit-tested.
///
/// The figures on the iPhone's Today and Insights screens and in the Mac popover cross-morph to the
/// new unit rather than snapping. Units are changed in Settings, which covers those screens (a
/// sheet on iPhone, its own window on the Mac), so a change made there is held until the screen is
/// back in view: when the Settings sheet goes away on iPhone, and once the popover has come in on
/// the Mac. Then the figures and chart axes morph once, VoiceOver hears the new unit once, and
/// under Reduce Motion they simply change. Display only: readings are stored in mg/dL and nothing
/// that is worked out from them changes.
enum UnitSwitch {
    /// What the screens should show after the chosen unit is `chosen`: the unit already on screen
    /// while the change is held, otherwise the chosen one.
    static func shown(current: GlucoseUnit, chosen: GlucoseUnit, held: Bool) -> GlucoseUnit {
        held ? current : chosen
    }

    /// What VoiceOver says when the screens move from `old` to `new`, or nil when nothing changed,
    /// so the unit is announced once per switch.
    static func announcement(from old: GlucoseUnit, to new: GlucoseUnit) -> String? {
        guard old != new else { return nil }
        // Spelt out, as `GlucoseUnit.spokenLabel` does, since "mmol/L" is read letter by letter.
        switch new {
        case .mmol: return "Now showing millimoles per litre"
        case .mgdl: return "Now showing milligrams per decilitre"
        }
    }

    /// How long after the Mac popover opens before a held change morphs: once its sections have
    /// come in (`PopoverStagger`), so the old figures are seen before they change.
    static let popoverRevealDelay: TimeInterval = 0.6
}
