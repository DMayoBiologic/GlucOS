import Foundation

/// How a drawn forecast gets from one shape to the next, and how much of it is drawn while it
/// draws in. Plain values so the motion can be unit-tested; `ForecastMotion` (Motion.swift) drives
/// it on screen. Nothing here touches the forecast itself, only what's drawn of it on the way.
enum ForecastMorph {
    /// The forecast part way from `from` to `to`, at `t` (0 = `from`, 1 = `to`, clamped).
    ///
    /// Points pair up by how far ahead they are (the first with the first, and so on), so a new
    /// forecast slides along with its starting reading and bends into its new shape. When one
    /// forecast is longer, the other's last point stands in for the missing ones: a horizon that
    /// grows reaches out from the old end, one that shrinks pulls back into the new end. Points
    /// that land on (or before) the one ahead of them are dropped, so the line never doubles back
    /// and the end state is exactly `to`.
    static func blend(from: [ForecastSample], to: [ForecastSample], t: Double) -> [ForecastSample] {
        guard !from.isEmpty, !to.isEmpty else { return to }
        let t = min(max(t, 0), 1)
        if t == 1 { return to }
        let count = max(from.count, to.count)
        var out: [ForecastSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let a = from[min(i, from.count - 1)]
            let b = to[min(i, to.count - 1)]
            let p = mix(a, b, t)
            if let last = out.last, p.date <= last.date { continue }
            out.append(p)
        }
        return out
    }

    /// The part of `forecast` drawn so far while it draws in from its starting reading: `progress`
    /// 0 is just the start, 1 the whole forecast (clamped). The drawn end is interpolated between
    /// samples, so the line and its range grow smoothly rather than five minutes at a time.
    static func revealed(_ forecast: [ForecastSample], progress: Double) -> [ForecastSample] {
        guard let first = forecast.first, let last = forecast.last, forecast.count > 1 else { return forecast }
        let progress = min(max(progress, 0), 1)
        if progress == 1 { return forecast }
        let cutoff = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) * progress)
        var out: [ForecastSample] = [first]
        for (prev, next) in zip(forecast, forecast.dropFirst()) {
            if next.date <= cutoff {
                out.append(next)
                continue
            }
            let span = next.date.timeIntervalSince(prev.date)
            if span > 0, cutoff > prev.date {
                out.append(mix(prev, next, cutoff.timeIntervalSince(prev.date) / span))
            }
            break
        }
        return out
    }

    /// How long a new forecast takes to fade in over the old one under Reduce Motion, matching
    /// `DSMotion.ambient.reducedAnimation`: a short opacity change that moves nothing.
    static let crossFadeDuration: TimeInterval = 0.25

    /// Whether a new forecast should cross-fade in over the one drawn (Reduce Motion): only when
    /// both exist and they differ. A forecast appearing or going just changes.
    static func crossFades(from: [ForecastSample], to: [ForecastSample]) -> Bool {
        !from.isEmpty && !to.isEmpty && from != to
    }

    /// How opaque the old and new forecast are `progress` of the way through a cross-fade
    /// (0 = only the old one, 1 = only the new one, clamped). They always add up to one, so the
    /// band never looks doubled or briefly empty.
    static func crossFadeOpacities(_ progress: Double) -> (previous: Double, current: Double) {
        let t = min(max(progress, 0), 1)
        return (1 - t, t)
    }

    private static func mix(_ a: ForecastSample, _ b: ForecastSample, _ t: Double) -> ForecastSample {
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return ForecastSample(
            date: a.date.addingTimeInterval(b.date.timeIntervalSince(a.date) * t),
            mgdl: lerp(a.mgdl, b.mgdl),
            lowerMgdl: lerp(a.lowerMgdl, b.lowerMgdl),
            upperMgdl: lerp(a.upperMgdl, b.upperMgdl))
    }
}

/// A forecast fading out under the one now drawn, while Reduce Motion is on (`ForecastMotion`):
/// `previous` at `1 - progress` opacity, the current forecast at `progress`. `.none` when nothing
/// is fading, which is every chart outside that quarter of a second.
struct ForecastCrossFade: Equatable {
    var previous: [ForecastSample]
    var progress: Double

    static let none = ForecastCrossFade(previous: [], progress: 1)

    var isActive: Bool { !previous.isEmpty && progress < 1 }
}
