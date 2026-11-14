import ActivityKit
import Foundation
import UserNotifications

/// Someone's live readings this phone follows, from a share link they sent.
struct Follow: Codable, Hashable, Identifiable {
    /// The share's id (`ShareSnapshot.followID`), also on the follower's Live Activity.
    var id: String
    var label: String
    var expiresAt: Double?
    var addedAt: Double
    /// Keep their reading on this phone's Lock Screen.
    var liveActivity: Bool = true
    /// Get their glucose alerts (lows, highs, no data) as notifications, sent by the relay.
    var alerts: Bool = true

    init(id: String, label: String, expiresAt: Double?, addedAt: Double) {
        self.id = id
        self.label = label
        self.expiresAt = expiresAt
        self.addedAt = addedAt
    }

    // Follows saved before a setting existed get its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        addedAt = try c.decode(Double.self, forKey: .addedAt)
        liveActivity = try c.decodeIfPresent(Bool.self, forKey: .liveActivity) ?? true
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? true
    }
}

/// The people this phone follows: their latest readings (fetched while GlucOS is open) and their
/// Lock Screen cards (kept live by the push relay once started, like the owner's own card).
///
/// Share tokens are kept in the Keychain; the list itself in UserDefaults.
@MainActor
final class FollowStore: ObservableObject {
    typealias GlucoseActivity = Activity<GlucoseActivityAttributes>

    @Published private(set) var follows: [Follow] = []
    @Published private(set) var snapshots: [String: ShareSnapshot] = [:]
    /// Shares the owner stopped (or that expired): shown as ended until removed.
    @Published private(set) var ended: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// The outcome of opening a share link, for an alert.
    @Published var notice: String?

    private let defaults = UserDefaults.standard
    private var tracked = Set<String>()
    private var pushToStartToken: String?
    private var timer: Task<Void, Never>?
    private var activityObserver: Task<Void, Never>?

    #if DEBUG
    private let apnsEnvironment = "sandbox"
    #else
    private let apnsEnvironment = "production"
    #endif

    /// A random id for this phone, so following again replaces its old entry on the server.
    private var installation: String {
        if let id = defaults.string(forKey: "followInstallation") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "followInstallation")
        return id
    }

    init() {
        if let data = defaults.data(forKey: "follows"), let saved = try? JSONDecoder().decode([Follow].self, from: data) {
            follows = saved
        }
    }

    var isFollowing: Bool { !follows.isEmpty }

    private func save() {
        if let data = try? JSONEncoder().encode(follows) { defaults.set(data, forKey: "follows") }
    }

    private func token(_ id: String) -> String? { Keychain.get("follow.\(id)") }

    private func client(_ id: String) -> ShareClient? { token(id).map(ShareClient.init(token:)) }

    // MARK: Adding and removing

    /// Follows the share in a link. Returns the follow, or throws if the share has ended.
    @discardableResult
    func add(token: String) async throws -> Follow {
        let snapshot = try await ShareClient(token: token).snapshot()
        Keychain.set(token, for: "follow.\(snapshot.followID)")
        var follow = follows.first { $0.id == snapshot.followID }
            ?? Follow(id: snapshot.followID, label: snapshot.label, expiresAt: snapshot.expiresAt,
                      addedAt: Date().timeIntervalSince1970)
        follow.label = snapshot.label
        follow.expiresAt = snapshot.expiresAt
        follows.removeAll { $0.id == follow.id }
        follows.insert(follow, at: 0)
        ended.remove(follow.id)
        pendingUnfollows.removeAll { $0 == follow.id }
        snapshots[follow.id] = snapshot
        save()
        // Their alerts need notifications. Asks only the first time; a no-op once answered.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await register(follow.id)
        await showActivity(for: follow, canStart: true)
        return follow
    }

    /// A share link was opened (from Messages, through the web view's Open in GlucOS button).
    func open(token: String) async {
        do {
            let f = try await add(token: token)
            notice = "You're following \(f.label). \(f.liveActivity && ActivityAuthorizationInfo().areActivitiesEnabled ? "Their reading is on your Lock Screen." : "")"
        } catch {
            notice = error.localizedDescription
        }
    }

    func remove(_ follow: Follow) async {
        // Recorded with the removal, before anything waits, so a quit part-way through still
        // retries on the next launch. The token is kept until the server has let go of this
        // phone (so it doesn't keep a follower slot, or get pushes).
        if !pendingUnfollows.contains(follow.id) { pendingUnfollows.append(follow.id) }
        follows.removeAll { $0.id == follow.id }
        snapshots[follow.id] = nil
        errors[follow.id] = nil
        ended.remove(follow.id)
        save()
        await endActivities(for: follow.id)
        await retryUnfollows()
    }

    /// Shares this phone stopped following but hasn't told the server yet.
    private var pendingUnfollows: [String] {
        get { defaults.stringArray(forKey: "pendingUnfollows") ?? [] }
        set { defaults.set(newValue, forKey: "pendingUnfollows") }
    }

    private func retryUnfollows() async {
        for id in pendingUnfollows where !follows.contains(where: { $0.id == id }) {
            guard let client = client(id) else {
                pendingUnfollows.removeAll { $0 == id }
                continue
            }
            do {
                try await client.unfollow(installation: installation)
            } catch ShareClient.ShareError.ended {
                // The share is gone, and its followers with it.
            } catch {
                continue
            }
            pendingUnfollows.removeAll { $0 == id }
            if follows.contains(where: { $0.id == id }) {
                // Followed again while this was in flight, so the unfollow may have landed after
                // the new registration: register again, and keep the token.
                await register(id)
            } else {
                Keychain.delete("follow.\(id)")
            }
        }
    }

    func setAlerts(_ on: Bool, for follow: Follow) async {
        guard let i = follows.firstIndex(where: { $0.id == follow.id }) else { return }
        follows[i].alerts = on
        save()
        var r = FollowRegistration(installation: installation)
        r.alertsEnabled = on
        r.deviceToken = deviceToken
        await send(r, to: follow.id)
    }

    func setLiveActivity(_ on: Bool, for follow: Follow) async {
        guard let i = follows.firstIndex(where: { $0.id == follow.id }) else { return }
        follows[i].liveActivity = on
        save()
        var r = FollowRegistration(installation: installation)
        r.liveActivityEnabled = on
        await send(r, to: follow.id)
        if on { await showActivity(for: follows[i], canStart: true) } else { await endActivities(for: follow.id) }
    }

    // MARK: Refreshing

    /// While GlucOS is open: every minute, fetch each followed reading and update its card.
    func start() {
        guard timer == nil else { return }
        observeActivities()
        timer = Task { [weak self] in
            await self?.retryUnfollows()
            while !Task.isCancelled {
                await self?.refresh(canStart: true)
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh(canStart: Bool) async {
        for follow in follows {
            guard let client = client(follow.id) else { continue }
            do {
                let s = try await client.snapshot()
                // Removed, or switched off the Lock Screen, while that was loading: use what's current.
                guard let i = follows.firstIndex(where: { $0.id == follow.id }) else { continue }
                snapshots[follow.id] = s
                errors[follow.id] = nil
                if follows[i].label != s.label {
                    follows[i].label = s.label
                    save()
                }
                await showActivity(for: follows[i], canStart: canStart)
            } catch ShareClient.ShareError.ended {
                guard follows.contains(where: { $0.id == follow.id }) else { continue }
                ended.insert(follow.id)
                await endActivities(for: follow.id)
            } catch {
                guard follows.contains(where: { $0.id == follow.id }) else { continue }
                errors[follow.id] = error.localizedDescription
            }
        }
    }

    // MARK: Lock Screen

    private func activities(for id: String) -> [GlucoseActivity] {
        GlucoseActivity.activities.filter {
            $0.attributes.followID == id && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    private func showActivity(for follow: Follow, canStart: Bool) async {
        guard follow.liveActivity, !ended.contains(follow.id), ActivityAuthorizationInfo().areActivitiesEnabled,
              let card = snapshots[follow.id]?.card else { return }
        let content = ActivityContent(state: card, staleDate: card.staleDate,
                                      relevanceScore: card.range == .inRange ? 40 : 90)
        let running = activities(for: follow.id)
        for extra in running.dropLast() { await extra.end(nil, dismissalPolicy: .immediate) }
        if let a = running.last {
            if a.content.state != card || a.activityState == .stale { await a.update(content) }
            return
        }
        guard canStart else { return }
        let attributes = GlucoseActivityAttributes(name: follow.label, followID: follow.id)
        do {
            let a: GlucoseActivity
            do {
                a = try GlucoseActivity.request(attributes: attributes, content: content, pushType: .token)
            } catch {
                // A build without the push entitlement can still show a card while GlucOS is open.
                a = try GlucoseActivity.request(attributes: attributes, content: content, pushType: nil)
            }
            track(a)
        } catch {
            errors[follow.id] = error.localizedDescription
        }
    }

    private func endActivities(for id: String) async {
        for a in GlucoseActivity.activities where a.attributes.followID == id {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observeActivities() {
        // Cards the relay starts by push (when iOS's 8-hour limit comes round) arrive here.
        if activityObserver == nil {
            activityObserver = Task { [weak self] in
                for await a in GlucoseActivity.activityUpdates where a.attributes.followID != nil {
                    self?.track(a)
                }
            }
        }
        GlucoseActivity.activities.filter { $0.attributes.followID != nil }.forEach(track)
    }

    private func track(_ activity: GlucoseActivity) {
        guard let followID = activity.attributes.followID, tracked.insert(activity.id).inserted else { return }
        let id = activity.id
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                var r = FollowRegistration(installation: self.installation)
                r.activityID = id
                r.activityToken = data.hexString
                await self.send(r, to: followID)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self else { return }
                self.tracked.remove(id)
                var r = FollowRegistration(installation: self.installation)
                r.endedActivityID = id
                await self.send(r, to: followID)
            }
        }
    }

    // MARK: Registration

    /// The app's push-to-start token (shared with the owner's own card), so the relay can start
    /// a follower's next card.
    func pushToStartTokenArrived(_ token: String) {
        guard token != pushToStartToken else { return }
        pushToStartToken = token
        Task { for f in follows { await register(f.id) } }
    }

    /// The phone's APNs device token (from the app delegate), for their alerts.
    private var deviceToken: String? { defaults.string(forKey: "apnsDeviceToken") }
    private var registeredDeviceToken: String?

    func deviceTokenArrived(_ token: String) {
        guard token != registeredDeviceToken else { return }
        registeredDeviceToken = token
        Task { for f in follows { await register(f.id) } }
    }

    private func register(_ id: String) async {
        var r = FollowRegistration(installation: installation)
        r.deviceToken = deviceToken
        r.alertsEnabled = follows.first { $0.id == id }?.alerts ?? true
        r.apnsEnvironment = apnsEnvironment
        r.pushToStartToken = pushToStartToken
        r.liveActivityEnabled = follows.first { $0.id == id }?.liveActivity ?? true
        // The card already on the Lock Screen, if any, so a fresh registration keeps it live.
        if let a = activities(for: id).last, let token = a.pushToken {
            r.activityID = a.id
            r.activityToken = token.hexString
        }
        await send(r, to: id)
    }

    private func send(_ r: FollowRegistration, to id: String) async {
        guard let client = client(id) else { return }
        do {
            _ = try await client.follow(r)
            errors[id] = nil
        } catch ShareClient.ShareError.ended {
            ended.insert(id)
        } catch {
            errors[id] = error.localizedDescription
        }
    }
}
