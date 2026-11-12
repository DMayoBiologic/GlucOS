import Foundation
import Combine

/// Keeps this device's logbook in step with the others signed in to the same LibreLinkUp
/// account, through Supabase. Offline-first: the logbook is always read and written locally,
/// and this pushes and pulls in the background (a couple of seconds after each change, every
/// minute while the app runs, and when it comes to the foreground).
@MainActor
final class LogbookSyncService: ObservableObject {
    enum Status: Equatable {
        /// Turned off in Settings.
        case off
        /// No LibreLinkUp account to sign in with.
        case needsAccount
        case syncing
        case synced
        case failed(String)
    }

    @Published private(set) var status: Status = .needsAccount
    /// Last successful sync.
    @Published private(set) var lastSynced: Date?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { requestSync() } else { status = .off }
        }
    }

    /// Scored forecasts to send along with each sync, so accuracy can be followed over time.
    weak var forecastLedger: ForecastLedgerStore?

    /// Entries waiting to be pushed.
    var pendingCount: Int { logbook.syncState.pending.count }

    private let logbook: LogbookStore
    private let settings: AppSettings
    private let device: String
    private var client = LogbookSyncClient()
    private var session: LogbookSyncSession?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var isSyncing = false
    private var syncAgain = false
    /// LibreLinkUp locks accounts that log in too often, so failed sign-ins back off.
    private var nextSignInAttempt = Date.distantPast
    private var signInFailures = 0
    /// Sessions refused straight after signing in. Stops a loop of LibreLinkUp logins if the
    /// server keeps refusing them.
    private var refusedSessions = 0
    /// The login last used to sign in, to tell an account change from any other setting.
    private var credentialsKey: String

    private static let enabledKey = "logbookSyncEnabled"
    private static let sessionKey = "logbookSyncSession"
    static let interval: TimeInterval = 60

    init(logbook: LogbookStore, settings: AppSettings = .shared, device: String) {
        self.logbook = logbook
        self.settings = settings
        self.device = device
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        credentialsKey = Self.credentialsKey(settings)
        if let raw = Keychain.get(Self.sessionKey), let data = raw.data(using: .utf8) {
            session = try? JSONDecoder().decode(LogbookSyncSession.self, from: data)
        }
        lastSynced = logbook.syncState.lastSynced.map { Date(timeIntervalSince1970: $0) }
        if !enabled { status = .off }

        logbook.localChanges
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.requestSync() } }
            .store(in: &cancellables)
        // A new account or password: sign in again (soon, so typing doesn't trigger logins).
        settings.objectWillChange
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.accountMayHaveChanged() } }
            .store(in: &cancellables)
    }

    /// Syncs now and then every minute. Call when the app launches or comes to the foreground.
    func start() {
        requestSync()
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func requestSync() {
        Task { await sync() }
    }

    /// Signs out of sync, e.g. when the LibreLinkUp account is signed out. The local logbook stays.
    func signOut() {
        setSession(nil)
        status = enabled ? .needsAccount : .off
    }

    private static func credentialsKey(_ s: AppSettings) -> String {
        "\(s.email.lowercased())\u{0}\(s.password)\u{0}\(s.region)"
    }

    private func accountMayHaveChanged() {
        let key = Self.credentialsKey(settings)
        guard key != credentialsKey else { return }
        credentialsKey = key
        if let s = session, s.email.caseInsensitiveCompare(settings.email) != .orderedSame || !settings.hasCredentials {
            setSession(nil)
        }
        // A changed login deserves a fresh try straight away.
        nextSignInAttempt = .distantPast
        signInFailures = 0
        refusedSessions = 0
        requestSync()
    }

    // MARK: Sync

    func sync() async {
        guard enabled else { status = .off; return }
        if isSyncing { syncAgain = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            if syncAgain {
                syncAgain = false
                requestSync()
            }
        }
        guard settings.hasCredentials else {
            status = .needsAccount
            return
        }
        if status != .synced { status = .syncing }
        do {
            var s = try await validSession()
            do {
                try await exchange(s)
            } catch LogbookSyncClient.SyncError.sessionExpired {
                // The access token was refused early (revoked, or the clock is off): refresh once.
                s = try await client.refresh(s)
                setSession(s)
                try await exchange(s)
            }
            lastSynced = Date()
            refusedSessions = 0
            logbook.updateSyncState { state, _ in state.lastSynced = Date().timeIntervalSince1970 }
            status = .synced
        } catch LogbookSyncClient.SyncError.sessionExpired {
            setSession(nil)
            refusedSessions += 1
            if refusedSessions <= 1 {
                status = .failed("Signed out of sync. Signing in again…")
                syncAgain = true
            } else {
                status = .failed("The sync server isn't accepting this device's sign-in. Retrying later.")
                Diagnostics.shared.report(DiagnosticEvent(feature: Self.diagnosticFeature, step: "sign-in", code: "session-refused",
                                                          message: "The sync server isn't accepting this device's sign-in."))
                nextSignInAttempt = Date().addingTimeInterval(15 * 60)
                lastSignInError = "The sync server isn't accepting this device's sign-in. Retrying later."
            }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(Self.describe(error))
            Self.report(error)
        }
    }

    nonisolated static let diagnosticFeature = "logbook.sync"

    /// An error report for a failed sync, unless it's LibreLinkUp refusing the login (the person's
    /// to fix), a sign-in still backing off from an earlier failure (already reported), or offline.
    private static func report(_ error: Error) {
        guard !DiagnosticEvent.isNoise(error) else { return }
        var e = DiagnosticEvent(feature: diagnosticFeature, step: "sync", error: error, message: describe(error))
        if let sync = error as? LogbookSyncClient.SyncError {
            switch sync {
            case .loginRejected: return
            case .http(0, _): return
            case .http(let code, _): e.code = "HTTP \(code)"
            case .sessionExpired: e.code = "session-expired"
            case .badResponse: e.code = "bad-response"
            }
        }
        Diagnostics.shared.report(e)
    }

    /// Pull what changed elsewhere, then push what changed here.
    private func exchange(_ s: LogbookSyncSession) async throws {
        let userID = s.userID
        logbook.updateSyncState { state, contents in
            _ = LogbookMerge.adopt(userID: userID, contents: contents, state: &state)
        }

        let full = logbook.syncState.needsFullPull(now: Date())
        var since = full ? 0 : logbook.syncState.cursor
        while true {
            let page = try await client.pull(since: since, session: s)
            logbook.applyRemote(page)
            guard page.count >= 500, let last = page.last?.rev else { break }
            since = last
        }
        if full { logbook.updateSyncState { state, _ in state.lastFullPull = Date().timeIntervalSince1970 } }

        // Push in batches; anything changed meanwhile stays pending for the next round.
        for _ in 0..<20 {
            let out = LogbookMerge.outgoing(logbook.syncContents, state: logbook.syncState, device: device)
            guard !out.isEmpty else { break }
            try await client.push(out, session: s)
            logbook.updateSyncState { state, _ in LogbookMerge.pushed(out, state: &state) }
            if out.count < 500 { break }
        }
        await uploadForecasts(s)
    }

    nonisolated static let forecastDiagnosticFeature = "forecast.upload"

    /// Sends settled forecasts. A failure here never fails the logbook sync; they wait for the next one.
    private func uploadForecasts(_ s: LogbookSyncSession) async {
        guard let ledger = forecastLedger else { return }
        for _ in 0..<5 {
            let out = ledger.pendingUpload()
            guard !out.isEmpty else { return }
            do {
                try await client.pushForecasts(out, session: s)
                ledger.markUploaded(out)
            } catch {
                if !DiagnosticEvent.isNoise(error) {
                    Diagnostics.shared.report(DiagnosticEvent(feature: Self.forecastDiagnosticFeature, step: "push",
                                                              error: error, message: Self.describe(error)))
                }
                return
            }
            if out.count < 200 { return }
        }
    }

    private func validSession() async throws -> LogbookSyncSession {
        if var s = session, s.email.caseInsensitiveCompare(settings.email) == .orderedSame {
            if s.expiresSoon() {
                do {
                    s = try await client.refresh(s)
                    setSession(s)
                } catch LogbookSyncClient.SyncError.sessionExpired {
                    setSession(nil)
                    return try await signIn()
                }
            }
            return s
        }
        return try await signIn()
    }

    private func signIn() async throws -> LogbookSyncSession {
        guard Date() >= nextSignInAttempt else {
            throw LogbookSyncClient.SyncError.http(0, lastSignInError ?? "Couldn't sign in to sync. Retrying soon.")
        }
        do {
            let s = try await client.signIn(email: settings.email, password: settings.password,
                                            region: settings.region, clientVersion: settings.clientVersion)
            signInFailures = 0
            lastSignInError = nil
            setSession(s)
            return s
        } catch {
            signInFailures += 1
            // 2, 4, 8 … minutes, at most an hour.
            nextSignInAttempt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(min(signInFailures, 6)))))
            lastSignInError = Self.describe(error)
            throw error
        }
    }

    private var lastSignInError: String?

    private func setSession(_ s: LogbookSyncSession?) {
        session = s
        if let s, let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            Keychain.set(raw, for: Self.sessionKey)
        } else {
            Keychain.delete(Self.sessionKey)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LogbookSyncClient.SyncError { return e.localizedDescription }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Offline. Changes will sync when you're back online."
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach the sync server. Changes are kept and will sync later."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Display

    /// "Up to date · 2 min ago", "3 changes waiting", "Offline…".
    var summary: String {
        switch status {
        case .off: return "Off. This device's logbook stays on this device."
        case .needsAccount: return "Sign in to LibreLinkUp to sync."
        case .syncing: return lastSynced == nil ? "Syncing for the first time…" : "Syncing…"
        case .synced:
            let n = pendingCount
            if n > 0 { return "\(n) change\(n == 1 ? "" : "s") waiting to sync" }
            return lastSynced.map { "Up to date · \(Self.ago($0))" } ?? "Up to date"
        case .failed(let m): return m
        }
    }

    var isProblem: Bool {
        if case .failed = status { return true }
        return false
    }

    private static func ago(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
