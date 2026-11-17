import SwiftUI

// Settings rows that show and hide under a switch: they expand with a slight fade and the rows
// below slide, rather than jump. Instant under Reduce Motion. VoiceOver hears which rows appeared.
// Rules in `DependentRows` (Sources/Shared/DependentRows.swift); docs/SettingsDependentRows.md.

extension Binding {
    /// This binding, with each change made inside a design-system animation so the rows that
    /// depend on it expand or collapse and the rows below slide. `shown` says whether those rows
    /// are on screen; `rows` names them for VoiceOver, read after the change. With Reduce Motion
    /// the rows simply appear or go.
    func revealingRows(shown: @escaping () -> Bool,
                       rows: @escaping () -> [String] = { [] },
                       reduceMotion: Bool) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                let wasShown = shown()
                withAnimation(DSMotion.standard.animation(reduceMotion: reduceMotion)) {
                    wrappedValue = newValue
                }
                let change = DependentRows.change(wasShown: wasShown, isShown: shown())
                guard let text = DependentRows.announcement(change, rows: rows()) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + DependentRows.announcementDelay) {
                    AccessibilityNotification.Announcement(text).post()
                }
            }
        )
    }
}

extension View {
    /// A row (or group of rows) that comes and goes under a switch: fades in and out while the
    /// list makes room. The animation itself comes from `revealingRows`, so under Reduce Motion
    /// nothing fades.
    func dependentRow() -> some View {
        transition(.opacity)
    }
}
