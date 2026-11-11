#if os(iOS)
import ActivityKit

/// The Live Activity type, shared by the iPhone app (which starts and updates it) and the widget
/// extension (which draws it). The push relay starts new ones by this type's name, so don't
/// rename it: see `activityAttributesType` in supabase/functions/relay/apns.ts.
struct GlucoseActivityAttributes: ActivityAttributes {
    typealias ContentState = GlucoseActivityState

    /// Whose readings: "GlucOS" on the owner's own card, the share's label on a follower's.
    var name: String = "GlucOS"
    /// Set on a card following someone else's share (the share's id); nil on the owner's own.
    /// The relay sends it when it starts a follower's card, so an old app that doesn't know it
    /// would just ignore it.
    var followID: String? = nil
}
#endif
