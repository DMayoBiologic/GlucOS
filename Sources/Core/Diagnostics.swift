import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Error reports: when something fails (a sensor read, a LibreLinkUp fetch, logbook sync, the push
// relay), the app sends a short structured report to the GlucOS Supabase project so problems are
// seen without screenshots. On by default, off in Settings › Diagnostics. A report never carries
// glucose values, logbook entries, the LibreLinkUp login or the sensor's serial: only what failed,
// the error code, the app and OS versions, the device model and (for sensor problems) the sensor
// type. See docs/Diagnostics.md.

/// One error report.
struct DiagnosticEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Seconds since 1970.
    var occurredAt: Double = Date().timeIntervalSince1970
    /// What was being done, dotted lower case: "sensor.nfc", "linkup.fetch", "logbook.sync", "relay".
    var feature: String
    /// The step within it: "read-memory", "fetch", "register".
    var step: String
    /// A short machine-readable code: "NFC 100", "HTTP 503", "URLError -1001", "bad-crc".
    var code: String?
    /// What the person saw.
    var message: String
    /// The technical detail behind it (the sensor read's "Details" line, an error's description).
    var detail: String?
    /// Anything else that helps: sensor type and region, mode. Never personal data.
    var context: [String: String] = [:]
    /// The same problem happened this many more times since it was last reported.
    var repeats = 0
    /// Sent with the Send Report button rather than automatically.
    var userSent = false
    /// What the person added when sending it themselves.
    var note: String?

    /// Groups repeats of the same problem.
    var key: String { [feature, step, code ?? ""].joined(separator: "|") }

    /// Limits every field and strips anything that looks like an email address.
    func scrubbed() -> DiagnosticEvent {
        var e = self
        e.feature = Self.clip(feature, 64)
        e.step = Self.clip(step, 64)
        e.code = code.map { Self.clip(Self.scrub($0), 64) }
        e.message = Self.clip(Self.scrub(message), 500)
        e.detail = detail.map { Self.clip(Self.scrub($0), 2000) }
        e.note = note.map { Self.clip(Self.scrub($0), 1000) }
        var ctx = [String: String]()
        for (k, v) in context.sorted(by: { $0.key < $1.key }).prefix(20) {
            ctx[Self.clip(k, 40)] = Self.clip(Self.scrub(v), 200)
        }
        e.context = ctx
        return e
    }

    static func scrub(_ s: String) -> String {
        s.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>",
                               options: .regularExpression)
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }
}

extension DiagnosticEvent {
    /// A report for a thrown error, with its domain and code as the report's code.
    init(feature: String, step: String, error: Error, message: String? = nil, context: [String: String] = [:]) {
        self.init(feature: feature, step: step, code: Self.code(for: error),
                  message: message ?? error.localizedDescription, detail: String(describing: error), context: context)
    }

    /// "HTTP 503", "URLError -1001", "NSCocoaErrorDomain 4865": short enough to group by.
    static func code(for error: Error) -> String {
        if let u = error as? URLError { return "URLError \(u.code.rawValue)" }
        let ns = error as NSError
        // Swift errors bridge to "<Module>.<Type>" with the case's index; the type name is the useful part.
        let domain = ns.domain.split(separator: ".").last.map(String.init) ?? ns.domain
        return "\(domain) \(ns.code)"
    }

    /// Errors that say nothing about GlucOS: no network, or the work was cancelled.
    static func isNoise(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled, .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return true
            default: return false
            }
        }
        return false
    }
}

/// The device a batch of reports came from.
struct DiagnosticDevice: Codable, Equatable {
    /// A random id made on first use, so reports from one install can be grouped. Not tied to any account.
    var installID: String
    /// "ios" or "macos".
    var platform: String
    /// The app or extension's bundle id.
    var app: String
    var appVersion: String
    var build: String
    var osVersion: String
    /// "iPhone16,2", "Mac15,6".
    var model: String

    static func current(installID: String, bundle: Bundle = .main) -> DiagnosticDevice {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #else
        let platform = "other"
        #endif
        return DiagnosticDevice(
            installID: installID, platform: platform,
            app: bundle.bundleIdentifier ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            model: modelIdentifier())
    }

    static func modelIdentifier() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            return String(cString: buf)
        }
        #endif
        // On iPhone (and the simulator, where it's the Mac's arch) this is the hardware model.
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// What the app posts to the `diagnostics` edge function.
struct DiagnosticBatch: Codable, Equatable {
    var device: DiagnosticDevice
    var events: [DiagnosticEvent]
}

/// Sends error reports, holding them on disk while offline.
///
/// Automatic reports (`report`) respect the Settings switch and send each problem at most once an
/// hour; repeats in between are counted and go with the next report of it. `send` is the Send
/// Report button: it goes even with automatic reports off, since the person chose to send it.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    static let enabledKey = "diagnosticsEnabled"
    static let endpoint = URL(string: "https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/diagnostics/v1/report")!
    /// The same problem is reported automatically at most this often.
    static let repeatInterval: TimeInterval = 3600
    static let maxQueued = 50
    static let maxPerBatch = 20

    typealias Transport = (URLRequest) async throws -> Int

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let queueURL: URL?
    private let transport: Transport
    private let clock: () -> Date
    private let bundle: Bundle
    private var queue: [DiagnosticEvent]
    private var lastSent = [String: Double]()
    private var suppressed = [String: Int]()
    private var latest = [String: DiagnosticEvent]()
    private var flushing = false

    init(defaults: UserDefaults = .standard,
         queueURL: URL? = Diagnostics.defaultQueueURL(),
         bundle: Bundle = .main,
         clock: @escaping () -> Date = Date.init,
         transport: Transport? = nil) {
        self.defaults = defaults
        self.queueURL = queueURL
        self.bundle = bundle
        self.clock = clock
        self.transport = transport ?? Diagnostics.urlSessionTransport
        if let url = queueURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            queue = saved
        } else {
            queue = []
        }
    }

    /// Settings › Diagnostics. On unless turned off.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { locked { queue.removeAll(where: { !$0.userSent }); save() } }
        }
    }

    var installID: String {
        locked {
            if let id = defaults.string(forKey: "diagnosticsInstallID") { return id }
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: "diagnosticsInstallID")
            return id
        }
    }

    /// Reports waiting to be sent.
    var pending: [DiagnosticEvent] { locked { queue } }

    /// The most recent problem in a feature, reported or not, for the Send Report button.
    func latest(feature: String) -> DiagnosticEvent? { locked { latest[feature] } }

    /// Reports a problem automatically, unless reports are off or it was reported in the last hour.
    func report(_ event: DiagnosticEvent) {
        let now = clock().timeIntervalSince1970
        let go: Bool = locked {
            latest[event.feature] = event
            guard isEnabled else { return false }
            if let last = lastSent[event.key], now - last < Self.repeatInterval {
                suppressed[event.key, default: 0] += 1
                return false
            }
            var e = event.scrubbed()
            e.repeats = suppressed.removeValue(forKey: event.key) ?? 0
            lastSent[event.key] = now
            enqueue(e)
            return true
        }
        if go { Task { await flush() } }
    }

    func report(feature: String, step: String, error: Error, message: String? = nil, context: [String: String] = [:]) {
        guard !DiagnosticEvent.isNoise(error) else { return }
        report(DiagnosticEvent(feature: feature, step: step, error: error, message: message, context: context))
    }

    /// The Send Report button. Returns whether the report reached the server (it's kept and
    /// retried if not).
    @discardableResult
    func send(_ event: DiagnosticEvent, note: String?) async -> Bool {
        var e = event
        e.id = UUID()
        e.userSent = true
        e.repeats = 0
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        e.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let id = e.id
        locked { enqueue(e.scrubbed()) }
        await flush()
        return locked { !queue.contains { $0.id == id } }
    }

    /// Sends what's queued. Called after each report and when the app starts.
    func flush() async {
        let batch: [DiagnosticEvent]? = locked {
            guard !flushing, !queue.isEmpty else { return nil }
            flushing = true
            return Array(queue.prefix(Self.maxPerBatch))
        }
        guard let batch else { return }
        var delivered = false
        do {
            var req = URLRequest(url: Self.endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(DiagnosticBatch(device: .current(installID: installID, bundle: bundle), events: batch))
            let code = try await transport(req)
            // 4xx other than rate limiting means the server won't ever take these: drop them.
            delivered = (200..<300).contains(code) || ((400..<500).contains(code) && code != 429)
        } catch {
            delivered = false
        }
        let more: Bool = locked {
            flushing = false
            guard delivered else { return false }
            let ids = Set(batch.map(\.id))
            queue.removeAll { ids.contains($0.id) }
            save()
            return !queue.isEmpty
        }
        if more { await flush() }
    }

    // MARK: Private

    private func enqueue(_ e: DiagnosticEvent) {
        queue.append(e)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        save()
    }

    private func save() {
        guard let url = queueURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(queue).write(to: url, options: .atomic)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func defaultQueueURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GlucOS", isDirectory: true)
            .appendingPathComponent("diagnostics-queue.json")
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private static let urlSessionTransport: Transport = { req in
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}
