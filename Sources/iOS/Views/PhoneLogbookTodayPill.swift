import SwiftUI

/// Where the Logbook list is scrolled, read once per frame for the Today pill (`LogbookToday`).
struct LogbookScrollSpot: Equatable {
    let offset: Double
    let viewport: Double
}

/// The Logbook's "Today" pill (round 91): a small capsule under the navigation bar once the list has
/// scrolled well away from the top. A tap springs the list back to the newest day. It drops in from
/// the top and fades; under Reduce Motion it just appears and goes, and the list moves at once.
/// VoiceOver reads it as one button, "Back to today".
struct LogbookTodayPill: View {
    /// What the list's first section is tagged with, so a tap brings the chips back too.
    static let topID = "logbook.top"

    let target: Date?
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        let now = Date()
        // The landing plays the tap (`Haptics` .choice), as a jump from the calendar does.
        Button(action: action) {
            Label(LogbookToday.title(target: target, now: now), systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
                .dsFont(.label)
                .foregroundStyle(Palette.brand)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs + 2)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.brand.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        .accessibilityLabel(LogbookToday.accessibilityLabel(target: target, now: now))
    }
}
