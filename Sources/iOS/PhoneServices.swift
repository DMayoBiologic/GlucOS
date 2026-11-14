import Foundation
import Combine
import SwiftUI
import BackgroundTasks

/// The iPhone-only work around `GlucoseStore`: the Lock Screen Live Activity, the push relay and
/// background refresh. The store itself (fetching, history, forecast, alerts) is the same one the
/// Mac uses.
@MainActor
final class PhoneServices: ObservableObject {
    /// For the app delegate and background tasks, which can't reach the SwiftUI environment.
    static private(set) var shared: PhoneServices?

    let store: GlucoseStore
    let liveActivity = LiveActivityController()
    let relaySettings = RelaySettings.shared
    /// Brings in doses and food logged on the Mac, which the forecast here uses.
    var logbookSync: LogbookSyncService?
    /// Other people's shared readings this phone follows.
    var follows: FollowStore?

    /// Keep a Live Activity on the Lock Screen.
    @Published var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            Task {
                if liveActivityEnabled { await showLiveActivity(canStart: true) } else { await liveActivity.endAll() }
                await syncRelay()
            }
        }
    }
    @Published private(set) var relayStatus: RelayStatus?
    /// Shown in the banner and Settings only once the relay has stayed unreachable (`RelayHealth`).
    @Published private(set) var relayError: String?
    private var relayHealth = RelayHealth()
    @Published private(set) var isSyncingRelay = false
    @Published private(set) var pushRegistrationError: String?

    private var deviceToken: String? { UserDefaults.standard.string(forKey: "apnsDeviceToken") }
    private var pushToStartToken: String?
    private var lastRegistration: RelayRegistration?
    private var cancellables = Set<AnyCancellable>()
    private var isForeground = true
    private var lastStatusCheck = Date.distantPast

    #if DEBUG
    private let apnsEnvironment = "sandbox"
    #else
    private let apnsEnvironment = "production"
    #endif

    init(store: GlucoseStore) {
        self.store = store
        liveActivityEnabled = UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true
        Self.shared = self

        // Checked at delivery time: the relay's last status counts only while it's recent
        // (`isDeliveringAlerts` wants a fetch in the last 5 minutes), so if the relay goes quiet
        // the phone starts alerting by itself again.
        store.alerts.deliversLocally = { [weak self] in
            !(self?.relayStatus?.isDeliveringAlerts() ?? false)
        }
        store.onPublish = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.showLiveActivity(canStart: self.isForeground)
                await self.refreshRelayStatusIfDue()
            }
        }
        liveActivity.onActivityToken = { [weak self] id, token in
            var r = RelayRegistration()
            r.activityID = id
            r.activityToken = token
            Task { @MainActor in await self?.send(r) }
        }
        liveActivity.onPushToStartToken = { [weak self] token in
            Task { @MainActor in
                self?.pushToStartToken = token
                self?.follows?.pushToStartTokenArrived(token)
                await self?.syncRelay()
            }
        }
        liveActivity.onActivityEnded = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                var r = RelayRegistration()
                r.endedActivityID = id
                // Name the card that stays in the same request, so the relay moves to it at once.
                if let current = self.liveActivity.currentRegistration, current.id != id {
                    r.activityID = current.id
                    r.activityToken = current.token
                }
                await self.send(r)
            }
        }
        liveActivity.relayActivityID = { [weak self] in self?.relayStatus?.activityID }
        liveActivity.startObserving()

        // Account, units, thresholds and alert switches go to the relay when they change.
        store.settings.objectWillChange
            .merge(with: relaySettings.objectWillChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.syncRelay() } }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            store.start()
            logbookSync?.start()
            follows?.start()
            Task {
                await store.refresh()
                await showLiveActivity(canStart: true)
                await syncRelay()
            }
        case .background:
            isForeground = false
            store.stop()
            logbookSync?.stop()
            follows?.stop()
            BackgroundRefresh.schedule()
        default:
            break
        }
    }

    /// A background app refresh: fetch once, update the card, and alert if the relay isn't.
    func backgroundRefresh() async {
        // The logbook first, so the forecast on the Lock Screen counts what was logged on the Mac.
        await logbookSync?.sync()
        await store.refresh()
        await showLiveActivity(canStart: false)
        await syncRelay()
        await follows?.refresh(canStart: false)
    }

    func deviceTokenArrived(_ token: String) {
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        pushRegistrationError = nil
        follows?.deviceTokenArrived(token)
        Task { await syncRelay() }
    }

    func deviceTokenFailed(_ error: Error) {
        pushRegistrationError = error.localizedDescription
    }

    // MARK: Live Activity

    private func showLiveActivity(canStart: Bool) async {
        guard liveActivityEnabled, store.settings.hasCredentials else {
            if liveActivity.isRunning && !store.settings.hasCredentials { await liveActivity.endAll() }
            return
        }
        let readings = store.readings(lastHours: GlucoseActivityState.historyHours + 0.5)
        guard var state = GlucoseActivityState.make(from: store.snapshot, readings: readings) else { return }
        // Who's checking in, from the relay; while its status is unknown, whatever the card shows.
        state.checkIn = relaySettings.isConfigured
            ? (relayStatus.map { $0.checkIn } ?? liveActivity.currentCheckIn)
            : nil
        await liveActivity.show(state, wantsPushUpdates: relaySettings.isConfigured, canStart: canStart)
    }

    // MARK: Check-ins

    /// People waiting for this person to say they're okay.
    var waitingCheckIn: CheckInState? {
        guard let c = relayStatus?.checkIn, c.isWaiting else { return nil }
        return c
    }

    /// Answers everyone checking in (from the notification, the Lock Screen card or the app).
    func answerCheckIn(_ answer: CheckInAnswer.Answer) async throws {
        guard let client = relaySettings.client else { throw RelayClient.RelayError.unauthorized }
        do {
            apply(try await client.answerCheckIns(answer))
        } catch {
            Diagnostics.shared.report(feature: Self.relayDiagnosticFeature, step: "checkin.answer", error: error)
            throw error
        }
        // Off the card now, not on the relay's next tick.
        await liveActivity.setCheckIn(relayStatus?.checkIn)
        await showLiveActivity(canStart: false)
    }

    /// A check-in notification arrived: the card and the app should show it now.
    func checkInArrived() async {
        await refreshRelayStatus()
        await liveActivity.setCheckIn(relayStatus?.checkIn)
        await showLiveActivity(canStart: false)
    }

    // MARK: Relay

    /// Sends the relay everything it needs, if anything changed since the last time.
    func syncRelay(force: Bool = false) async {
        await claimRelayIfOwner()
        guard relaySettings.isConfigured else {
            relayStatus = nil
            relayHealth = RelayHealth()
            relayError = nil
            return
        }
        let s = store.settings
        var r = RelayRegistration()
        r.deviceToken = deviceToken
        r.pushToStartToken = pushToStartToken
        r.liveActivityEnabled = liveActivityEnabled
        r.apnsEnvironment = apnsEnvironment
        // The card on the Lock Screen now, every time: a token upload lost to a timeout would
        // otherwise leave the relay updating an older card (or starting a second one).
        if liveActivityEnabled, let current = liveActivity.currentRegistration {
            r.activityID = current.id
            r.activityToken = current.token
        }
        r.display = .init(unit: s.unit.rawValue, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl)
        r.alerts = s.alertPreferences
        if s.hasCredentials {
            r.account = .init(email: s.email, password: s.password, region: s.region,
                              clientVersion: s.clientVersion, sensorLifetimeDays: s.sensorLifetimeDays)
        } else {
            r.signedOut = true
        }
        let relayOnOtherCard = r.activityID != nil && relayStatus?.activityID != r.activityID
        guard force || r != lastRegistration || relayStatus == nil || relayOnOtherCard else { return }
        if await send(r) { lastRegistration = r }
    }

    /// The last claim tried: which login, when, and whether the relay said it isn't its account.
    private var lastClaim: (login: String, at: Date, notOwner: Bool)?

    /// The app doesn't carry the relay's secret, since anyone can install it from TestFlight. A
    /// phone signed in to the same LibreLinkUp account the relay fetches with is the owner's, and
    /// the relay gives it the secret. Anyone else's phone (a follower's, or someone with their own
    /// sensor) never gets it, so it can't sign the owner's relay out or take it over.
    private func claimRelayIfOwner() async {
        let s = store.settings
        guard !relaySettings.isConfigured, let url = relaySettings.url, s.hasCredentials else { return }
        let login = "\(s.email.lowercased())\n\(s.password)"
        if let last = lastClaim, last.login == login,
           last.notOwner || Date().timeIntervalSince(last.at) < 5 * 60 { return }
        switch await RelayClient.claim(baseURL: url, email: s.email, password: s.password) {
        case .secret(let secret):
            lastClaim = nil
            relaySettings.secret = secret
        case .notOwner:
            lastClaim = (login, Date(), true)
        case .unavailable:
            lastClaim = (login, Date(), false)
        }
    }

    @discardableResult
    private func send(_ r: RelayRegistration) async -> Bool {
        guard let client = relaySettings.client else { return false }
        isSyncingRelay = true
        defer { isSyncingRelay = false }
        do {
            apply(try await client.register(r))
            return true
        } catch {
            failed(error, step: "register")
            return false
        }
    }

    func refreshRelayStatus() async {
        guard let client = relaySettings.client else { return }
        lastStatusCheck = Date()
        do { apply(try await client.status()) } catch {
            failed(error, step: "status")
        }
    }

    /// A call failed even after the client's retries. A network failure keeps the last status: it
    /// still says whether the relay was fetching, and `isDeliveringAlerts` lets it lapse after 5
    /// minutes, so the phone takes over alerts by itself if the relay really has gone quiet.
    private func failed(_ error: Error, step: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let transient = relayHealth.failed(error, message: error.localizedDescription)
        relayError = relayHealth.visibleError
        Diagnostics.shared.report(feature: Self.relayDiagnosticFeature, step: step, error: error,
                                  context: ["consecutive": String(relayHealth.consecutiveFailures)])
        if !transient { relayStatus = nil }
    }

    /// Keeps the relay's status fresh while the app is fetching, at most once a minute.
    private func refreshRelayStatusIfDue() async {
        guard relaySettings.isConfigured, Date().timeIntervalSince(lastStatusCheck) >= 60 else { return }
        await refreshRelayStatus()
    }

    nonisolated static let relayDiagnosticFeature = "relay"

    func sendRelayTest() async {
        guard let client = relaySettings.client else { return }
        do { apply(try await client.sendTest()) } catch { relayError = error.localizedDescription }
    }

    private func apply(_ status: RelayStatus) {
        // While the relay is fetching and can reach this phone it sends the alerts, even when the
        // app is closed, and `deliversLocally` stands down so they don't arrive twice.
        relayStatus = status
        relayHealth.succeeded()
        relayError = nil
        lastStatusCheck = Date()
    }
}

// MARK: - Background refresh

/// Opportunistic background fetches. iOS decides when (often every 15–60 minutes, sometimes much
/// less), so this is a fallback for when there's no relay, never the main way alerts arrive.
enum BackgroundRefresh {
    static let identifier = "au.com.declanmayo.glucos.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                await PhoneServices.shared?.backgroundRefresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
