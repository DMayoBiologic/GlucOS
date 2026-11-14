import Foundation
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import WidgetKit

/// Owns the poll loop. Fetches from LibreLinkUp, writes the shared snapshot for the widget,
/// reloads widget timelines, and runs alerts.
@MainActor
final class GlucoseStore: ObservableObject {
    @Published private(set) var snapshot: GlucoseSnapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var statusLine: String = "Starting…"
    /// True when alerts are on but macOS is blocking GlucOS notifications.
    @Published private(set) var notificationsBlocked = false
    /// The last fetch's failure in plain words, with what to do about it. Nil when connected.
    @Published private(set) var connectionProblem: ConnectionProblem?
    /// Every reading kept on disk (up to 90 days), oldest → newest. Feeds the dashboard window.
    @Published private(set) var archive: [GlucoseReading]

    let settings = AppSettings.shared
    let alerts = AlertManager()
    /// Forecast and insulin/carbs still acting. Recomputed on every reading and logbook change.
    let outlook = OutlookStore()

    /// The logbook, for the outlook. Set once at launch.
    weak var logbook: LogbookStore? {
        didSet {
            logbookObserver = logbook?.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.refreshOutlook()
                    self.publish()
                    self.alerts.evaluatePrediction(self.snapshot, forecast: self.outlook.outlook?.glucoseForecast,
                                                   settings: self.settings)
                }
            refreshOutlook()
        }
    }
    private var logbookObserver: AnyCancellable?

    private var client: LibreLinkUpClient
    private var loopTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private var historyArchive: HistoryArchive

    init() {
        snapshot = SharedStore.load() ?? .empty
        historyArchive = HistoryArchive.load()
        archive = historyArchive.readings
        client = LibreLinkUpClient(region: settings.region,
                                   clientVersion: settings.clientVersion,
                                   sensorLifetimeDays: settings.sensorLifetimeDays)

        // Keep the snapshot's display settings in sync (the widget reads them from the snapshot).
        settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        #if os(macOS)
        // Refresh promptly after sleep/wake.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &cancellables)
        #else
        // iOS suspends the poll loop in the background; catch up as soon as the app is back.
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &cancellables)
        #endif

        // Re-render age text every 15 s even without new data.
        tick.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The widget's refresh button.
        WidgetBridge.observeRefreshRequests { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }

        record(snapshot)
    }

    func start() {
        if let t = loopTask, !t.isCancelled { return }
        #if os(iOS)
        // Not cold at launch on iPhone: the first-run setup asks with an explanation, and
        // following someone asks when the first follow is added.
        if settings.hasCredentials && !UserDefaults.standard.bool(forKey: "phoneSetupPending") {
            alerts.requestAuthorization()
        }
        #else
        alerts.requestAuthorization()
        #endif
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let secs = max(30, self?.settings.pollIntervalSeconds ?? 60)
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            }
        }
    }

    func stop() { loopTask?.cancel() }

    /// Called when credentials/region/version change in Settings.
    func reconnect() {
        Task {
            await client.configure(region: settings.region,
                                   clientVersion: settings.clientVersion,
                                   sensorLifetimeDays: settings.sensorLifetimeDays)
            await client.invalidateSession()
            await refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard settings.hasCredentials else {
            statusLine = "Add your LibreLinkUp login in Settings"
            snapshot.lastError = nil
            connectionProblem = nil
            publish()
            return
        }
        isRefreshing = true
        lastAttempt = Date()
        defer { isRefreshing = false }

        let creds = LibreLinkUpClient.Credentials(email: settings.email, password: settings.password)
        /// The account was signed out or switched while this fetch was in flight.
        func accountChanged() -> Bool {
            !settings.hasCredentials || settings.email != creds.email || settings.password != creds.password
        }
        do {
            let r = try await client.fetch(credentials: creds)
            guard !accountChanged() else { return }
            var s = snapshot
            s.current = r.current
            s.history = r.history
            s.sensor = r.sensor
            s.fetchedAt = Date()
            s.lastError = nil
            snapshot = s
            connectionProblem = nil
            record(s)
            refreshOutlook()
            applySettings()
            let host = await client.currentRegionHost
            statusLine = "Connected to \(host)"
        } catch {
            guard !accountChanged() else { return }
            snapshot.lastError = error.localizedDescription
            connectionProblem = ConnectionProblem(error)
            statusLine = "Error: \(error.localizedDescription)"
            if connectionProblem?.isWorthReporting == true {
                Diagnostics.shared.report(feature: ConnectionProblem.diagnosticFeature, step: "fetch", error: error,
                                          context: ["region": settings.region, "clientVersion": settings.clientVersion])
            }
            publish()
        }
        alerts.evaluate(snapshot, settings: settings)
        alerts.evaluatePrediction(snapshot, forecast: outlook.outlook?.glucoseForecast, settings: settings)
        await checkNotificationPermission()
    }

    /// Saves the account, signs in from scratch and fetches once. Returns the problem, or nil
    /// once readings are coming in. Used by onboarding and Settings → Account.
    func signIn(email: String, password: String, region: String) async -> ConnectionProblem? {
        settings.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.region = region
        settings.password = password
        await client.configure(region: settings.region,
                               clientVersion: settings.clientVersion,
                               sensorLifetimeDays: settings.sensorLifetimeDays)
        await client.invalidateSession()
        // Let a poll that's already in flight (with the old account) finish first.
        while isRefreshing { try? await Task.sleep(nanoseconds: 150_000_000) }
        await refresh()
        return connectionProblem
    }

    /// Forgets the password and clears readings from the old account, keeping display settings.
    func signOut() {
        settings.password = ""
        Task { await client.invalidateSession() }
        var s = GlucoseSnapshot.empty
        s.unit = settings.unit
        s.lowMgdl = settings.lowMgdl
        s.highMgdl = settings.highMgdl
        snapshot = s
        connectionProblem = nil
        statusLine = "Signed out"
        publish()
    }

    /// Carries out a fix offered next to a connection problem.
    func apply(_ fix: ConnectionProblem.Fix) {
        switch fix {
        case .updateClientVersion(let version):
            settings.clientVersion = version
            reconnect()
        case .retry, .waitAndRetry, .checkNetwork:
            Task { await refresh() }
        case .checkCredentials, .useLibreLinkUpApp:
            break
        }
    }

    func checkNotificationPermission() async {
        let allowed = await AlertManager.notificationsAllowed()
        notificationsBlocked = settings.alertsEnabled && allowed == false
    }

    /// Adds a snapshot's readings to the on-disk archive. Recording only; nothing reads it back
    /// into the snapshot, the widget or alerts.
    private func record(_ s: GlucoseSnapshot) {
        var incoming = s.history
        if let current = s.current { incoming.append(current) }
        guard historyArchive.merge(incoming) else { return }
        archive = historyArchive.readings
        historyArchive.save()
    }

    /// Works out the outlook for the latest reading and puts it in the snapshot (the caller
    /// publishes). Starts relearning from history in the background when that's due.
    private func refreshOutlook(now: Date = Date()) {
        guard snapshot.current != nil else {
            snapshot.outlook = nil
            return
        }
        let o = outlook.update(archive: archive, snapshot: snapshot, logbook: logbook, now: now)
        snapshot.outlook = o?.snapshot(lowMgdl: settings.lowMgdl)
        outlook.relearnIfNeeded(archive: archive, logbook: logbook, low: settings.lowMgdl,
                                high: settings.highMgdl, now: now) { [weak self] in
            guard let self else { return }
            self.refreshOutlook()
            self.publish()
            // A relearnt model can change the forecast, so check it now rather than at the next fetch.
            self.alerts.evaluatePrediction(self.snapshot, forecast: self.outlook.outlook?.glucoseForecast,
                                           settings: self.settings)
        }
    }

    private func applySettings() {
        snapshot.unit = settings.unit
        snapshot.lowMgdl = settings.lowMgdl
        snapshot.highMgdl = settings.highMgdl
        publish()
    }

    /// Called after every change to the snapshot. The iPhone app updates its Live Activity here.
    var onPublish: ((GlucoseSnapshot) -> Void)?

    private func publish() {
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        onPublish?(snapshot)
    }

    #if os(macOS)
    // MARK: Derived for the menu bar

    var menuBarText: String { statusItemText() }
    #endif
}
