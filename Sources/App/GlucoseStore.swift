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

    let settings = AppSettings.shared
    let alerts = AlertManager()

    private var client: LibreLinkUpClient
    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var lastPublished: GlucoseSnapshot?

    /// Consecutive failed fetches; drives exponential backoff so a broken network or an
    /// Abbott outage doesn't mean a login attempt every minute.
    private var consecutiveFailures = 0
    /// Set when retrying can't help (wrong password). Auto-polling stops until Reconnect, so
    /// we don't get the account locked by repeating a bad login.
    private(set) var pausedForCredentials = false
    private var lastErrorNeedsAttention = false

    static let maxBackoff: TimeInterval = 15 * 60
    private var cancellables = Set<AnyCancellable>()
    private var tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    init() {
        snapshot = SharedStore.load() ?? .empty
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
            .sink { [weak self] _ in self?.wakeLoop() }
            .store(in: &cancellables)

        // Re-render age text every 15 s even without new data.
        tick.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        if let t = loopTask, !t.isCancelled { return }
        alerts.requestAuthorization()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                await self.sleep(seconds: self.nextDelay())
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        wakeLoop()
    }

    /// Seconds until the next automatic poll.
    func nextDelay() -> TimeInterval {
        let base = TimeInterval(max(30, settings.pollIntervalSeconds))
        guard consecutiveFailures > 0 else { return base }
        let backoff = base * pow(2, Double(min(consecutiveFailures, 10) - 1))
        return min(max(base, backoff), Self.maxBackoff)
    }

    /// Interruptible sleep: `wakeLoop()` (wake from sleep, reconnect) ends it early.
    private func sleep(seconds: TimeInterval) async {
        let t = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        sleepTask = t
        await t.value
        sleepTask = nil
    }

    private func wakeLoop() {
        sleepTask?.cancel()
    }

    /// Called when credentials/region/version change in Settings.
    func reconnect() {
        Task {
            await client.configure(region: settings.region,
                                   clientVersion: settings.clientVersion,
                                   sensorLifetimeDays: settings.sensorLifetimeDays)
            await client.invalidateSession()
            consecutiveFailures = 0
            pausedForCredentials = false
            if sleepTask != nil {
                wakeLoop()     // the poll loop refreshes now and restarts its (possibly backed-off) timer
            } else {
                await refresh(userInitiated: true)
            }
        }
    }

    /// - Parameter userInitiated: a button press. Bypasses the credentials pause.
    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else { return }
        guard settings.hasCredentials else {
            statusLine = "Add your LibreLinkUp login in Settings"
            snapshot.lastError = nil
            publish()
            return
        }
        guard userInitiated || !pausedForCredentials else { return }
        isRefreshing = true
        lastAttempt = Date()
        defer { isRefreshing = false }

        let creds = LibreLinkUpClient.Credentials(email: settings.email, password: settings.password)
        do {
            let r = try await fetchAdoptingClientVersion(creds)
            var s = snapshot
            let current = r.current ?? s.current
            s.history = GlucoseSnapshot.mergeHistory(previous: s.history, graph: r.history, current: current)
            s.current = current
            s.sensor = r.sensor ?? s.sensor
            s.fetchedAt = Date()
            s.lastError = nil
            snapshot = s
            consecutiveFailures = 0
            pausedForCredentials = false
            lastErrorNeedsAttention = false
            applySettings()
            let host = await client.currentRegionHost
            statusLine = "Connected to \(host)"
        } catch {
            consecutiveFailures += 1
            let clientError = error as? LibreLinkUpClient.ClientError
            pausedForCredentials = clientError?.stopsPolling ?? false
            lastErrorNeedsAttention = clientError?.needsAttention ?? false
            snapshot.lastError = error.localizedDescription
            if pausedForCredentials {
                statusLine = "Paused — fix the login in Settings, then Save & Connect"
            } else {
                statusLine = "Error — retrying in \(Format.duration(nextDelay()))"
            }
            publish()
        }
        alerts.evaluate(snapshot, settings: settings, needsAttention: lastErrorNeedsAttention)
    }

    /// Abbott rejects clients older than a minimum version and tells us which one it wants.
    /// Adopt it (only ever upgrading) and retry once, instead of failing until the user edits
    /// the header by hand.
    private func fetchAdoptingClientVersion(_ creds: LibreLinkUpClient.Credentials) async throws -> LibreLinkUpClient.Result {
        do {
            return try await client.fetch(credentials: creds)
        } catch LibreLinkUpClient.ClientError.versionTooOld(let minimum)
                    where minimum.compare(settings.clientVersion, options: .numeric) == .orderedDescending {
            settings.clientVersion = minimum
            await client.configure(region: settings.region,
                                   clientVersion: minimum,
                                   sensorLifetimeDays: settings.sensorLifetimeDays)
            return try await client.fetch(credentials: creds)
        }
    }

    private func applySettings() {
        snapshot.unit = settings.unit
        snapshot.lowMgdl = settings.lowMgdl
        snapshot.highMgdl = settings.highMgdl
        publish()
    }

    /// Writes the snapshot and reloads widgets — but only when something the widget shows has
    /// changed. WidgetKit budgets reloads; burning one per poll on identical data is wasteful.
    private func publish() {
        var comparable = snapshot
        comparable.fetchedAt = .distantPast
        guard comparable != lastPublished else { return }
        guard SharedStore.save(snapshot) else { return }
        lastPublished = comparable
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Derived for the menu bar

    var menuBarText: String {
        guard snapshot.current != nil else { return "––" }
        var t = snapshot.compactText
        if settings.showDeltaInMenuBar, let d = snapshot.deltaMgdl {
            t += " " + snapshot.unit.formatDelta(mgdl: d)
        }
        if snapshot.isStale() { t += " ⚠︎" }
        return t
    }
}
