import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The push relay is a Supabase edge function in ap-south-1, a long way from the phone. About once
// an hour a request never reaches it: the phone is waking up or changing networks, a reused
// connection has gone stale, or the app was suspended mid-request and iOS reports the elapsed time
// as a timeout (URLError -1001). The relay's own logs show every request that arrives answered in
// under 10 seconds, and the same call made again a moment later goes through. So the client retries
// a dropped call, and the app only says the relay can't be reached when it stays unreachable.

public enum RelayRetry {
    /// A network failure worth trying again: the request may never have reached the relay.
    public static func isTransient(_ error: Error) -> Bool {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let r = error as? RetryableError { return r.isTransient }
        return false
    }

    /// Waits before each retry: soon, then a little longer. Three tries in all.
    public static let delays: [TimeInterval] = [1, 3]

    /// Runs `operation`, retrying a transient failure after each of `delays`. Anything else, or the
    /// last failure, is thrown. Only for calls that are safe to repeat (a status read, a
    /// registration that carries the whole state).
    public static func run<T>(
        delays: [TimeInterval] = RelayRetry.delays,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        _ operation: () async throws -> T
    ) async throws -> T {
        var remaining = delays[...]
        while true {
            do {
                return try await operation()
            } catch {
                guard isTransient(error), let delay = remaining.popFirst() else { throw error }
                try await sleep(delay)
            }
        }
    }
}

/// An error that knows whether it's worth retrying, such as an HTTP status from the relay: 502–504
/// come from the gateway in front of the function (a cold start or a deploy) and pass by themselves.
public protocol RetryableError: Error {
    var isTransient: Bool { get }
}

public extension RetryableError {
    static func isGatewayHiccup(_ code: Int) -> Bool { [502, 503, 504].contains(code) }
}

/// Whether the app should say the relay can't be reached. One dropped call (already retried) isn't
/// news; the relay keeps sending alerts either way. The banner waits until calls have failed
/// `threshold` times in a row, or the failure isn't a network one (a wrong secret, a refusal).
public struct RelayHealth: Equatable {
    public static let threshold = 2

    public private(set) var consecutiveFailures = 0
    /// The message to show, or nil while the relay is fine or only briefly unreachable.
    public private(set) var visibleError: String?

    public init() {}

    public mutating func succeeded() {
        consecutiveFailures = 0
        visibleError = nil
    }

    /// Returns whether the failure was transient, so the caller can keep the last status.
    @discardableResult
    public mutating func failed(_ error: Error, message: String) -> Bool {
        consecutiveFailures += 1
        let transient = RelayRetry.isTransient(error)
        if !transient || consecutiveFailures >= Self.threshold { visibleError = message }
        return transient
    }
}
