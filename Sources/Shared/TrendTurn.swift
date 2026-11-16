import Foundation

/// How the trend arrow moves when the trend changes in place (improvement round 39). The arrow is
/// one glyph turned to `Trend.needleAngle`, so a new trend swings it round on one short spring
/// (the `.arrival` spring, about 0.7 s, no repeat). Under Reduce Motion it doesn't travel: the old
/// direction fades out as the new one fades in. VoiceOver hears the new trend once, from one place
/// per device: the iPhone Today hero, and the Mac menu bar item (always running, so the popover
/// doesn't say it a second time).
///
/// SwiftUI screens use `.trendTurn(_:)` (Signal.swift) for the motion. The Mac menu bar item is
/// drawn frame by frame, so it uses `springProgress` and `angle` here.
enum TrendTurn: Equatable {
    /// Same direction, or nothing to point (stale, unknown, no reading): no turn.
    case none
    /// The arrow springs round to the new direction.
    case turn
    /// Reduce Motion: the old arrow fades out as the new one fades in, in place.
    case crossFade

    /// The Reduce Motion cross-fade's length, the same short fade the stale strike uses.
    static let crossFadeDuration: TimeInterval = 0.25

    /// The `.arrival` spring (`DSMotion.arrival`): response and damping fraction.
    static let response = 0.7
    static let dampingFraction = 0.72

    /// A trend the arrow can point along.
    static func points(_ trend: Trend?) -> Bool {
        guard let trend else { return false }
        return trend != .unknown
    }

    static func between(_ old: Trend?, _ new: Trend?, reduceMotion: Bool) -> TrendTurn {
        guard points(old), points(new), old != new else { return .none }
        return reduceMotion ? .crossFade : .turn
    }

    /// What VoiceOver says once when the trend turns, such as "Trend now rising quickly". Nil when
    /// nothing turned, so a new reading with the same trend, or a reading going stale, says nothing.
    static func announcement(from old: Trend?, to new: Trend?) -> String? {
        guard between(old, new, reduceMotion: false) == .turn, let new else { return nil }
        return "Trend now \(new.description.lowercased())"
    }

    /// How far through the turn the arrow is `t` seconds in: the step response of an underdamped
    /// spring with the `.arrival` response and damping. 0 at the start, a few percent past 1 at the
    /// overshoot, and settled on 1 well inside a second.
    static func springProgress(at t: TimeInterval, response: Double = Self.response,
                               dampingFraction: Double = Self.dampingFraction) -> Double {
        guard t > 0 else { return 0 }
        // Long past the end (a frame drawn at rest passes infinity): settled.
        guard t.isFinite else { return 1 }
        let zeta = min(max(dampingFraction, 0.01), 0.99)
        let omega = 2 * Double.pi / max(response, 0.01)
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return 1 - decay * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
    }

    /// The arrow's angle `t` seconds into a turn from `old` to `new`, in degrees clockwise.
    static func angle(from old: Trend, to new: Trend, at t: TimeInterval) -> Double {
        let p = springProgress(at: t)
        return old.needleAngle + (new.needleAngle - old.needleAngle) * p
    }
}
