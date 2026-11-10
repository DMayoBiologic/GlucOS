import Foundation

// What the iPhone app and the push relay (Relay/) say to each other over HTTPS. Shared so both
// sides encode the same JSON. Every request carries `Authorization: Bearer <relay secret>`.
//
//   POST /v1/register   RelayRegistration  → RelayStatus   (send only what changed)
//   GET  /v1/status                        → RelayStatus
//   POST /v1/test                          → RelayStatus   (sends a test alert push)
//   GET  /health                           → "ok"          (no secret, for the host's health check)

/// What the phone tells the relay. Every field is optional: nil means "unchanged".
struct RelayRegistration: Codable, Hashable {
    /// APNs device token (hex), for alert pushes.
    var deviceToken: String?
    /// ActivityKit push-to-start token (hex), so the relay can start a new Live Activity when
    /// the old one reaches iOS's 8-hour limit.
    var pushToStartToken: String?
    /// The running Live Activity's update token (hex) and id.
    var activityToken: String?
    var activityID: String?
    /// The phone ended (or the user dismissed) the Live Activity with this id.
    var endedActivityID: String?
    /// Keep a Live Activity on the Lock Screen.
    var liveActivityEnabled: Bool?
    /// "production" (TestFlight and App Store builds) or "sandbox" (debug builds from Xcode).
    var apnsEnvironment: String?
    var account: Account?
    /// The app signed out: forget the account and stop fetching.
    var signedOut: Bool?
    var display: Display?
    var alerts: AlertPreferences?

    struct Account: Codable, Hashable {
        var email: String
        var password: String
        var region: String
        var clientVersion: String
        var sensorLifetimeDays: Int
    }

    struct Display: Codable, Hashable {
        /// `GlucoseUnit.rawValue`.
        var unit: String
        var lowMgdl: Double
        var highMgdl: Double
    }

    init() {}
}

/// What the relay reports back, for the app's Settings.
struct RelayStatus: Codable, Hashable {
    var version: String
    /// Seconds since 1970.
    var lastFetchAt: Double?
    var lastReadingAt: Double?
    var lastError: String?
    var lastPushAt: Double?
    var lastPushError: String?
    var hasAccount: Bool
    var hasDeviceToken: Bool
    var hasPushToStartToken: Bool
    var activityID: String?
    var activityStartedAt: Double?
    var liveActivityEnabled: Bool
    var alertsEnabled: Bool

    /// The relay is fetching and has a way to reach the phone, so the phone can leave alerts to it.
    func isDeliveringAlerts(at now: Date = Date()) -> Bool {
        guard hasAccount, hasDeviceToken, alertsEnabled, lastError == nil,
              let fetched = lastFetchAt else { return false }
        return now.timeIntervalSince1970 - fetched < 5 * 60
    }
}
