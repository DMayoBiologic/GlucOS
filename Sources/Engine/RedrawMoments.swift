import Foundation

// SwiftUI's `TimelineView(.explicit(dates))` draws its content straight away with the *first*
// date in the list as `context.date`, even when that date is still in the future. A list of only
// future redraw moments therefore renders the view as if it were already that moment: the Mac
// popover showed "Your sensor has ended" a day and a half early, with the live reading called
// "Yesterday", because its first moment was the sensor's end (docs/SensorEnd.md). Every explicit
// schedule whose `context.date` is read goes through here, so its first entry is now.

enum RedrawMoments {
    /// `now`, then the moments after it in order, without duplicates. Moments at or before `now`
    /// are dropped: `now` already covers them.
    static func explicit(_ moments: [Date], now: Date) -> [Date] {
        [now] + Array(Set(moments.filter { $0 > now })).sorted()
    }
}

extension GlucoseSnapshot {
    /// When the Mac popover's hero slot draws again on its own (`RedrawMoments.explicit`): now,
    /// a warm-up running out, the sensor reaching its end, and a last reading from after the end
    /// going stale (the sensor has stopped).
    func heroRedrawMoments(at now: Date = Date()) -> [Date] {
        var out: [Date] = []
        if let warmUp = warmUp(at: now) { out.append(warmUp.endsAt.addingTimeInterval(SensorWarmUp.grace)) }
        if let ends = sensor?.expires {
            out.append(ends.addingTimeInterval(1))
            if let cur = current, cur.timestamp >= ends {
                out.append(cur.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter + 1))
            }
        }
        return RedrawMoments.explicit(out, now: now)
    }
}
