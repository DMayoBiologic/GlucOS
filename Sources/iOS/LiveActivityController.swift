import ActivityKit
import Foundation

/// Starts, updates and ends the Lock Screen Live Activity, and reports its push tokens.
///
/// While the app is open it updates the activity itself on every reading. Once the phone is
/// locked iOS suspends the app, so from then on the push relay updates it over APNs with the
/// activity's push token (reported through `onActivityToken`), and starts the next one with the
/// push-to-start token when iOS's 8-hour limit comes round.
@MainActor
final class LiveActivityController: ObservableObject {
    typealias GlucoseActivity = Activity<GlucoseActivityAttributes>

    /// Live Activities are allowed for GlucOS in iOS Settings.
    @Published private(set) var systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    var onActivityToken: ((_ activityID: String, _ token: String) -> Void)?
    var onPushToStartToken: ((String) -> Void)?
    var onActivityEnded: ((_ activityID: String) -> Void)?

    /// This controller looks after the owner's own card only. Cards following someone else's
    /// share (`followID` set) belong to `FollowStore`.
    nonisolated private static func isOwn(_ a: GlucoseActivity) -> Bool { a.attributes.followID == nil }
    private var ownActivities: [GlucoseActivity] { GlucoseActivity.activities.filter(LiveActivityController.isOwn) }

    private var tracked = Set<String>()
    private var observers: [Task<Void, Never>] = []
    private var lastSent: GlucoseActivityState?
    private var requesting = false

    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                self?.systemEnabled = enabled
            }
        })
        observers.append(Task { [weak self] in
            for await data in GlucoseActivity.pushToStartTokenUpdates {
                self?.onPushToStartToken?(data.hexString)
            }
        })
        // Activities the relay starts by push arrive here, even with the app in the background.
        observers.append(Task { [weak self] in
            for await activity in GlucoseActivity.activityUpdates where LiveActivityController.isOwn(activity) {
                self?.track(activity)
            }
        })
        ownActivities.forEach(track)
    }

    private var current: GlucoseActivity? {
        ownActivities.last { $0.activityState == .active || $0.activityState == .stale }
    }

    private func track(_ activity: GlucoseActivity) {
        guard tracked.insert(activity.id).inserted else { return }
        let id = activity.id
        Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                self?.onActivityToken?(id, token.hexString)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                if state == .ended || state == .dismissed {
                    self.tracked.remove(id)
                    self.onActivityEnded?(id)
                }
                self.refreshRunning()
            }
        }
        refreshRunning()
    }

    private func refreshRunning() {
        isRunning = current != nil
    }

    /// Shows `state` on the Lock Screen, starting the activity if there isn't one. Starting only
    /// works while the app is in the foreground; updating works any time it runs.
    func show(_ state: GlucoseActivityState, wantsPushUpdates: Bool, canStart: Bool) async {
        guard systemEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.staleDate,
                                      relevanceScore: state.range == .inRange ? 50 : 100)
        // Only ever one GlucOS card.
        let all = ownActivities.filter { $0.activityState == .active || $0.activityState == .stale }
        for extra in all.dropLast() {
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        if let activity = all.last {
            guard state != lastSent || activity.activityState == .stale else { return }
            await activity.update(content)
            lastSent = state
            return
        }
        guard canStart, !requesting else { return }
        requesting = true
        defer { requesting = false }
        do {
            let activity: GlucoseActivity
            do {
                activity = try GlucoseActivity.request(attributes: GlucoseActivityAttributes(), content: content,
                                                       pushType: wantsPushUpdates ? .token : nil)
            } catch where wantsPushUpdates {
                // A build without the push entitlement can still show a local-only card.
                activity = try GlucoseActivity.request(attributes: GlucoseActivityAttributes(), content: content,
                                                       pushType: nil)
            }
            lastSent = state
            lastError = nil
            track(activity)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Ends the owner's Live Activity (the switch was turned off, or the account signed out).
    /// Cards following other people stay.
    func endAll() async {
        for activity in ownActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        lastSent = nil
        refreshRunning()
    }
}

extension Data {
    /// APNs and ActivityKit tokens as the hex string APNs expects.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
