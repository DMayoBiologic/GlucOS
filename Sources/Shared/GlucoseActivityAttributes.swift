#if os(iOS)
import ActivityKit

/// The Live Activity type, shared by the iPhone app (which starts and updates it) and the widget
/// extension (which draws it). The push relay starts new ones by this type's name, so don't
/// rename it: see `activityAttributesType` in supabase/functions/relay/apns.ts.
struct GlucoseActivityAttributes: ActivityAttributes {
    typealias ContentState = GlucoseActivityState

    var name: String = "GlucOS"
}
#endif
