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
            applySettings()
            record(s)
            let host = await client.currentRegionHost
            statusLine = "Connected to \(host)"
        } catch {
            snapshot.lastError = error.localizedDescription
            statusLine = "Error: \(error.localizedDescription)"
            publish()
        }
        alerts.evaluate(snapshot, settings: settings)
        await checkNotificationPermission()
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

    var menuBarText: String { statusItemText() }
}
