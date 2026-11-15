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
    /// What the clock last changed on screen (`clockKey`).
    private var lastClockKey: ClockKey?

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

        // Age text and the stale state move on without new data. Checked every 15 s, but every view
        // watching the store (the popover, the dashboard and its charts) re-renders on a send, so
        // only send when something time-based would read differently: the menu bar text, going
        // stale, or the reading's age in whole minutes. Screens with a ticking age have their own
        // `TimelineView`s.
        tick.sink { [weak self] now in
            guard let self else { return }
            let key = self.clockKey(at: now)
            guard key != self.lastClockKey else { return }
            self.lastClockKey = key
            self.objectWillChange.send()
        }
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
        if settings.hasCredentials && settings.alertsEnabled && !UserDefaults.standard.bool(forKey: "phoneSetupPending") {
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
            if connectionProblem != nil { connectionProblem = nil }
            record(s)
            refreshOutlook()
            applySettings()
            let host = await client.currentRegionHost
            setStatusLine("Connected to \(host)")
        } catch {
            guard !accountChanged() else { return }
            snapshot.lastError = error.localizedDescription
            let problem = ConnectionProblem(error)
            if problem != connectionProblem { connectionProblem = problem }
            setStatusLine("Error: \(error.localizedDescription)")
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
        let blocked = settings.alertsEnabled && allowed == false
        // @Published sends on every assignment, and every view watching the store redraws.
        if blocked != notificationsBlocked { notificationsBlocked = blocked }
    }

    private func setStatusLine(_ line: String) {
        if line != statusLine { statusLine = line }
    }

    /// What a view showing the reading's age or the menu bar text would draw now.
    private struct ClockKey: Equatable {
        var menuBar: String
        var stale: Bool
        var ageMinutes: Int
    }

    private func clockKey(at now: Date) -> ClockKey {
        ClockKey(menuBar: statusItemText(at: now), stale: snapshot.isStale(at: now),
                 ageMinutes: snapshot.current.map { Int($0.age(at: now) / 60) } ?? -1)
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

    /// Adds readings that came from elsewhere (the iPhone gets the push relay's one-minute readings)
    /// to the archive, where they fill the 5-minute slots LibreLinkUp's 15-minute graph leaves
    /// empty. An hour or more of new ones makes the next outlook relearn from them. Returns how
    /// many were added.
    @discardableResult
    func mergeHistory(_ readings: [GlucoseReading], now: Date = Date()) -> Int {
        let before = historyArchive.readings.count
        guard historyArchive.merge(readings, now: now) else { return 0 }
        let added = max(0, historyArchive.readings.count - before)
        archive = historyArchive.readings
        historyArchive.save()
        if added >= Self.relearnAfterFilledSlots { outlook.historyFilledIn() }
        return added
    }

    /// An hour of 5-minute slots.
    static let relearnAfterFilledSlots = 12

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
        refreshTodayGlance()
        SharedStore.save(snapshot)
        reloadChangedWidgets()
        onPublish?(snapshot)
    }

    /// What the widgets last drew from, so a publish that changes nothing they show reloads nothing.
    private var widgetSignature: WidgetReload.Signature?

    /// Reloads only the widget timelines this snapshot changes (power audit, #94): a logbook edit
    /// or forecast relearn that leaves the forecast where it was no longer wakes every widget, and
    /// Time in Range and Sensor, which read the 90-day archive, reload at most once per 15 minutes
    /// of readings.
    private func reloadChangedWidgets() {
        let signature = WidgetReload.signature(snapshot)
        let groups = WidgetReload.groups(from: widgetSignature, to: signature)
        widgetSignature = signature
        for group in WidgetReload.Group.allCases where groups.contains(group) {
            for kind in group.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
    }

    private struct TodayKey: Hashable {
        var key: TodaySoFarCache.Key
        var unit: GlucoseUnit
    }
    private var todayKey: TodayKey?

    /// Today so far for the large widget, worked out again only when its inputs move (every five
    /// minutes of readings, a new day, a new target or unit). Same window as the Insights card.
    private func refreshTodayGlance(now: Date = Date()) {
        let days = UserDefaults.standard.object(forKey: "insights.dayPatternDays") as? Int
        let window = days.flatMap(DayPattern.Window.init(rawValue:)) ?? .fortnight
        let key = TodayKey(key: TodaySoFarCache.key(readings: archive, window: window, low: settings.lowMgdl,
                                                    high: settings.highMgdl, now: now),
                           unit: settings.unit)
        guard key != todayKey else { return }
        todayKey = key
        snapshot.today = TodaySoFar.compute(readings: archive, window: window, low: settings.lowMgdl,
                                            high: settings.highMgdl, now: now)?
            .glance(unit: settings.unit, now: now)
    }

    #if os(macOS)
    // MARK: Derived for the menu bar

    var menuBarText: String { statusItemText() }
    #endif
}
