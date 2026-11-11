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
    @Published private(set) var relayError: String?
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
                await self?.syncRelay()
            }
        }
        liveActivity.onActivityEnded = { [weak self] id in
            var r = RelayRegistration()
            r.endedActivityID = id
            Task { @MainActor in await self?.send(r) }
        }
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
            Task {
                await store.refresh()
                await showLiveActivity(canStart: true)
                await syncRelay()
            }
        case .background:
            isForeground = false
            store.stop()
            BackgroundRefresh.schedule()
        default:
            break
        }
    }

    /// A background app refresh: fetch once, update the card, and alert if the relay isn't.
    func backgroundRefresh() async {
        await store.refresh()
        await showLiveActivity(canStart: false)
        await syncRelay()
    }

    func deviceTokenArrived(_ token: String) {
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        pushRegistrationError = nil
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
        guard let state = GlucoseActivityState.make(from: store.snapshot, readings: readings) else { return }
        await liveActivity.show(state, wantsPushUpdates: relaySettings.isConfigured, canStart: canStart)
    }

    // MARK: Relay

    /// Sends the relay everything it needs, if anything changed since the last time.
    func syncRelay(force: Bool = false) async {
        guard relaySettings.isConfigured else {
            relayStatus = nil
            relayError = nil
            return
        }
        let s = store.settings
        var r = RelayRegistration()
        r.deviceToken = deviceToken
        r.pushToStartToken = pushToStartToken
        r.liveActivityEnabled = liveActivityEnabled
        r.apnsEnvironment = apnsEnvironment
        r.display = .init(unit: s.unit.rawValue, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl)
        r.alerts = s.alertPreferences
        if s.hasCredentials {
            r.account = .init(email: s.email, password: s.password, region: s.region,
                              clientVersion: s.clientVersion, sensorLifetimeDays: s.sensorLifetimeDays)
        } else {
            r.signedOut = true
        }
        guard force || r != lastRegistration || relayStatus == nil else { return }
        if await send(r) { lastRegistration = r }
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
            relayError = error.localizedDescription
            relayStatus = nil
            return false
        }
    }

    func refreshRelayStatus() async {
        guard let client = relaySettings.client else { return }
        lastStatusCheck = Date()
        do { apply(try await client.status()) } catch {
            relayError = error.localizedDescription
            relayStatus = nil
        }
    }

    /// Keeps the relay's status fresh while the app is fetching, at most once a minute.
    private func refreshRelayStatusIfDue() async {
        guard relaySettings.isConfigured, Date().timeIntervalSince(lastStatusCheck) >= 60 else { return }
        await refreshRelayStatus()
    }

    func sendRelayTest() async {
        guard let client = relaySettings.client else { return }
        do { apply(try await client.sendTest()) } catch { relayError = error.localizedDescription }
    }

    private func apply(_ status: RelayStatus) {
        // While the relay is fetching and can reach this phone it sends the alerts, even when the
        // app is closed, and `deliversLocally` stands down so they don't arrive twice.
        relayStatus = status
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
