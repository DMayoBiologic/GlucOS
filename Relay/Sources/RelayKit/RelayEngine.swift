import Foundation

/// Fetches readings for the relay. A protocol so tests can feed it readings.
protocol GlucoseFetching: Sendable {
    func fetch(_ account: RelayRegistration.Account) async throws -> LibreLinkUpClient.Result
}

/// The real thing: the same LibreLinkUp client the apps use.
final class LibreLinkUpFetcher: GlucoseFetching, @unchecked Sendable {
    private let client = LibreLinkUpClient(region: nil, clientVersion: "4.16.0", sensorLifetimeDays: 15)

    func fetch(_ a: RelayRegistration.Account) async throws -> LibreLinkUpClient.Result {
        await client.configure(region: a.region, clientVersion: a.clientVersion, sensorLifetimeDays: a.sensorLifetimeDays)
        return try await client.fetch(credentials: .init(email: a.email, password: a.password))
    }
}

/// The relay's work, one fetch at a time: alerts first, then the Live Activity.
actor RelayEngine {
    static let version = "1.0.0"
    /// iOS ends a Live Activity after 8 hours. The relay ends it a little before and starts the
    /// next one, so the Lock Screen card never just disappears.
    static let rotateAfter: TimeInterval = 7 * 3600 + 40 * 60
    /// Resend the card at least this often, even when nothing changed, so a missed push heals.
    static let activityRefresh: TimeInterval = 10 * 60
    static let startRetry: TimeInterval = 15 * 60
    static let maxStartAttempts = 3

    private let config: RelayConfig
    private let sender: PushSending?
    private let fetcher: GlucoseFetching
    private let store: StateStore?
    private let clock: @Sendable () -> Date

    private(set) var state: RelayState
    private var planner = AlertPlanner()
    private var model = OutlookModel.empty
    private var isTicking = false
    private var wakeEarly = false

    init(config: RelayConfig, sender: PushSending?, fetcher: GlucoseFetching, store: StateStore?,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.sender = sender
        self.fetcher = fetcher
        self.store = store
        self.clock = clock
        state = store?.load() ?? RelayState()
    }

    // MARK: Loop

    func run() async {
        while !Task.isCancelled {
            await tick()
            // Sleep in short steps so a new registration gets an immediate fetch.
            let deadline = clock().addingTimeInterval(config.pollInterval)
            while clock() < deadline && !wakeEarly && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            wakeEarly = false
        }
    }

    // MARK: API

    func register(_ r: RelayRegistration) async -> RelayStatus {
        let now = clock()
        if let t = r.deviceToken, !t.isEmpty { state.deviceToken = t }
        if let t = r.pushToStartToken, !t.isEmpty { state.pushToStartToken = t }
        if let env = r.apnsEnvironment { state.sandbox = env == "sandbox" }
        if let d = r.display { state.display = d }
        if let a = r.alerts { state.alerts = a }

        if r.signedOut == true {
            state.account = nil
            state.readings = []
            state.current = nil
            state.sensor = nil
            state.lastError = nil
            await endActivity(now: now)
        } else if let a = r.account {
            if state.account?.email.lowercased() != a.email.lowercased() {
                // Another person's readings: start again.
                state.readings = []
                state.current = nil
                state.sensor = nil
                planner = AlertPlanner()
                model = .empty
            }
            if state.account != a { wakeEarly = true }
            state.account = a
        }

        if let ended = r.endedActivityID, state.activity?.id == ended {
            // The phone ended it, or it was swiped away. Don't put it back until the phone
            // starts another one.
            state.activity = nil
            state.pendingStart = false
        }
        if let id = r.activityID, let token = r.activityToken, !token.isEmpty {
            let startedAt = state.activity?.id == id ? state.activity!.startedAt : now
            state.activity = .init(id: id, token: token, startedAt: startedAt)
            state.pendingStart = false
            state.startAttempts = 0
            state.lastActivityState = nil
            wakeEarly = true
        }
        if let enabled = r.liveActivityEnabled {
            state.liveActivityEnabled = enabled
            if !enabled { await endActivity(now: now) }
        }
        save()
        return status()
    }

    func status() -> RelayStatus {
        RelayStatus(version: Self.version,
                    lastFetchAt: state.lastFetchAt?.timeIntervalSince1970,
                    lastReadingAt: state.current?.timestamp.timeIntervalSince1970,
                    lastError: state.lastError,
                    lastPushAt: state.lastPushAt?.timeIntervalSince1970,
                    lastPushError: sender == nil ? "APNs key not configured on the relay" : state.lastPushError,
                    hasAccount: state.account != nil,
                    hasDeviceToken: state.deviceToken != nil && sender != nil,
                    hasPushToStartToken: state.pushToStartToken != nil,
                    activityID: state.activity?.id,
                    activityStartedAt: state.activity?.startedAt.timeIntervalSince1970,
                    liveActivityEnabled: state.liveActivityEnabled,
                    alertsEnabled: state.alerts.enabled)
    }

    func sendTest() async -> RelayStatus {
        if let token = state.deviceToken {
            _ = await push(PushRequest(deviceToken: token, type: .alert, topic: config.bundleID, priority: 10,
                                       payload: PushPayload.test(), collapseID: "glucos.test",
                                       expiration: clock().addingTimeInterval(600), sandbox: state.sandbox),
                           onInvalid: { $0.deviceToken = nil })
        } else {
            state.lastPushError = "The phone hasn't registered for notifications yet"
        }
        save()
        return status()
    }

    // MARK: Tick

    func tick() async {
        guard !isTicking, let account = state.account else { return }
        isTicking = true
        defer { isTicking = false }
        let now = clock()

        do {
            let r = try await fetcher.fetch(account)
            var incoming = r.history
            if let c = r.current { incoming.append(c) }
            state.merge(incoming, now: now)
            if let c = r.current { state.current = c }
            if let s = r.sensor { state.sensor = s }
            state.lastError = nil
        } catch {
            state.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        state.lastFetchAt = now

        var snapshot = state.snapshot()
        let recent = state.readings.filter { now.timeIntervalSince($0.timestamp) <= 3600 }
        let outlook = OutlookEngine.outlook(readings: recent, doses: [], meals: [], contexts: [], model: model, now: now)
        if snapshot.current != nil { snapshot.outlook = outlook.snapshot(lowMgdl: snapshot.lowMgdl) }
        relearnIfDue(now: now)

        var notices = planner.evaluate(snapshot, prefs: state.alerts, now: now)
        if let p = planner.evaluatePrediction(snapshot, forecast: outlook.glucoseForecast, prefs: state.alerts, now: now) {
            notices.append(p)
        }
        if let token = state.deviceToken {
            for n in notices {
                _ = await push(PushRequest(deviceToken: token, type: .alert, topic: config.bundleID, priority: 10,
                                           payload: PushPayload.alert(n, criticalSound: config.criticalAlerts),
                                           collapseID: n.identifier, expiration: now.addingTimeInterval(15 * 60),
                                           sandbox: state.sandbox),
                               onInvalid: { $0.deviceToken = nil })
            }
        }

        await updateActivity(snapshot, urgent: !notices.isEmpty, now: now)
        save()
    }

    /// The forecast's accuracy bands, learnt from the relay's own recent readings. The relay has
    /// no logbook, so its forecast is always trend-only.
    private func relearnIfDue(now: Date) {
        guard now.timeIntervalSince(model.learnedAt) > 3 * 3600, state.readings.count > 24 else { return }
        model = OutlookEngine.learn(readings: state.readings, doses: [], meals: [], contexts: [],
                                    low: state.display.lowMgdl, high: state.display.highMgdl, now: now)
    }

    // MARK: Live Activity

    private func updateActivity(_ snapshot: GlucoseSnapshot, urgent: Bool, now: Date) async {
        guard state.liveActivityEnabled,
              let content = GlucoseActivityState.make(from: snapshot, readings: state.readings, source: "relay", now: now)
        else { return }

        if let a = state.activity {
            if now.timeIntervalSince(a.startedAt) >= Self.rotateAfter, state.pushToStartToken != nil {
                await endActivity(now: now)
                state.pendingStart = true
                state.startAttempts = 0
                state.lastStartAttempt = nil
            } else {
                let changed = content != state.lastActivityState
                let due = state.lastActivityPushAt.map { now.timeIntervalSince($0) >= Self.activityRefresh } ?? true
                guard changed || due else { return }
                let rangeChanged = state.lastActivityState.map { $0.range != content.range } ?? true
                let priority = urgent || rangeChanged || content.range != .inRange ? 10 : 5
                guard let payload = try? PushPayload.activityUpdate(content, now: now) else { return }
                let result = await push(PushRequest(deviceToken: a.token, type: .liveactivity, topic: config.bundleID,
                                                    priority: priority, payload: payload, collapseID: nil,
                                                    expiration: content.staleDate, sandbox: state.sandbox),
                                        onInvalid: { $0.activity = nil })
                if result == .delivered {
                    state.lastActivityState = content
                    state.lastActivityPushAt = now
                }
                return
            }
        }

        guard state.pendingStart, let token = state.pushToStartToken, state.startAttempts < Self.maxStartAttempts,
              state.lastStartAttempt.map({ now.timeIntervalSince($0) >= Self.startRetry }) ?? true,
              let payload = try? PushPayload.activityStart(content, now: now) else { return }
        state.startAttempts += 1
        state.lastStartAttempt = now
        // The new activity's own update token reaches the phone, which registers it here.
        _ = await push(PushRequest(deviceToken: token, type: .liveactivity, topic: config.bundleID, priority: 10,
                                   payload: payload, collapseID: nil, expiration: now.addingTimeInterval(600),
                                   sandbox: state.sandbox),
                       onInvalid: { $0.pushToStartToken = nil })
    }

    private func endActivity(now: Date) async {
        guard let a = state.activity else { return }
        state.activity = nil
        state.lastActivityState = nil
        guard let payload = try? PushPayload.activityEnd(nil, now: now) else { return }
        _ = await push(PushRequest(deviceToken: a.token, type: .liveactivity, topic: config.bundleID, priority: 10,
                                   payload: payload, collapseID: nil, expiration: nil, sandbox: state.sandbox),
                       onInvalid: { _ in })
    }

    // MARK: Plumbing

    @discardableResult
    private func push(_ request: PushRequest, onInvalid: (inout RelayState) -> Void) async -> PushResult {
        guard let sender else { return .failed("no APNs key") }
        let result = await sender.send(request)
        switch result {
        case .delivered:
            state.lastPushAt = clock()
            state.lastPushError = nil
        case .tokenInvalid(let reason):
            state.lastPushError = "\(request.type.rawValue): \(reason)"
            onInvalid(&state)
        case .failed(let reason):
            state.lastPushError = "\(request.type.rawValue): \(reason)"
        }
        return result
    }

    private func save() { store?.save(state) }
}
