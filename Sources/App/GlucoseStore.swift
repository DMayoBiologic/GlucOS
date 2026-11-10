import Foundation
import Combine
import AppKit
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

        // Refresh promptly after sleep/wake.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &cancellables)

        // Re-render age text every 15 s even without new data.
        tick.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        record(snapshot)
    }

    func start() {
        if let t = loopTask, !t.isCancelled { return }
        alerts.requestAuthorization()
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
        do {
            let r = try await client.fetch(credentials: creds)
            var s = snapshot
            s.current = r.current
            s.history = r.history
            s.sensor = r.sensor
            s.fetchedAt = Date()
            s.lastError = nil
            snapshot = s
            connectionProblem = nil
            applySettings()
            record(s)
            let host = await client.currentRegionHost
            statusLine = "Connected to \(host)"
        } catch {
            snapshot.lastError = error.localizedDescription
            connectionProblem = ConnectionProblem(error)
            statusLine = "Error: \(error.localizedDescription)"
            publish()
        }
        alerts.evaluate(snapshot, settings: settings)
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

    private func applySettings() {
        snapshot.unit = settings.unit
        snapshot.lowMgdl = settings.lowMgdl
        snapshot.highMgdl = settings.highMgdl
        publish()
    }

    private func publish() {
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Derived for the menu bar

    var menuBarText: String {
        guard snapshot.current != nil else { return "––" }
        var t = snapshot.compactText
        if settings.showDeltaInMenuBar, let d = snapshot.deltaMgdl {
            t += " " + snapshot.unit.formatDelta(mgdl: d)
        }
        return t
    }
}
