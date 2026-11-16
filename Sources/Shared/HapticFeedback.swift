#if os(iOS)
import SwiftUI
import UIKit

/// The one place the iPhone app plays haptics. Every call goes through the shared `HapticGate`,
/// so two moments landing together never buzz twice, and only through the system's feedback
/// generators, which iOS silences when System Haptics is off. Never Core Haptics or a vibrate.
///
/// Imperative (a button's action): `Haptics.play(.done)`.
/// Declarative (a value changed): `.haptic(trigger: value) { old, new in … }`.
enum Haptics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gate = HapticGate()

    /// Whether `event` may play now. Taken by the event that plays, so call it once per event.
    static func admit(_ event: HapticEvent, at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.admit(event, at: now)
    }

    /// Plays `event` unless the gate holds it back.
    static func play(_ event: HapticEvent) {
        guard admit(event) else { return }
        switch event.feel {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .lightImpact(let intensity):
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: intensity)
        }
    }
}

extension HapticEvent.Feel {
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .success: return .success
        case .warning: return .warning
        case .lightImpact(let intensity): return .impact(weight: .light, intensity: intensity)
        }
    }
}

extension View {
    /// Plays the event `event(old, new)` names when `trigger` changes, through the shared gate.
    /// Return nil for changes that shouldn't be felt.
    func haptic<T: Equatable>(trigger: T, _ event: @escaping (_ old: T, _ new: T) -> HapticEvent?) -> some View {
        sensoryFeedback(trigger: trigger) { old, new -> SensoryFeedback? in
            guard let e = event(old, new), Haptics.admit(e) else { return nil }
            return e.feel.sensoryFeedback
        }
    }

    /// Plays `event` each time `trigger` changes, through the shared gate.
    func haptic<T: Equatable>(_ event: HapticEvent, trigger: T) -> some View {
        haptic(trigger: trigger) { _, _ in event }
    }
}
#endif
