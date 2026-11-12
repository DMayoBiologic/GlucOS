import Foundation

// What the iPhone app and the push relay (supabase/functions/relay) say to each other over HTTPS.
// The relay's TypeScript types in engine.ts mirror these; keep the two in step. Shared so both
// sides encode the same JSON. Every request carries `Authorization: Bearer <relay secret>`.
//
//   POST /v1/register   RelayRegistration  → RelayStatus   (send only what changed)
//   GET  /v1/status                        → RelayStatus
//   POST /v1/test                          → RelayStatus   (sends a test alert push)
//   POST /v1/readings   RelayReadings      → RelayStatus   (readings the phone read from the sensor)
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
    /// The phone reads the sensor over Bluetooth and alerts by itself, so the relay doesn't push
    /// the owner's alerts while the phone's readings keep arriving. Followers are alerted as usual.
    var phoneDeliversAlerts: Bool?

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
    /// When the relay last got readings the phone read from the sensor.
    var lastPhoneReadingAt: Double?

    /// The relay is fetching and has a way to reach the phone, so the phone can leave alerts to it.
    func isDeliveringAlerts(at now: Date = Date()) -> Bool {
        guard hasAccount, hasDeviceToken, alertsEnabled, lastError == nil,
              let fetched = lastFetchAt else { return false }
        return now.timeIntervalSince1970 - fetched < 5 * 60
    }
}

/// Readings the phone read from the sensor itself, for the Lock Screen card and followers while
/// LibreLink (and so LibreLinkUp) has none.
struct RelayReadings: Codable, Hashable {
    struct Reading: Codable, Hashable {
        /// Seconds since 1970.
        var t: Double
        var mgdl: Double
        /// `Trend.rawValue`.
        var trend: Int
    }
    var readings: [Reading]

    init(_ readings: [GlucoseReading]) {
        self.readings = readings.map { .init(t: $0.timestamp.timeIntervalSince1970, mgdl: $0.mgdl, trend: $0.trend.rawValue) }
    }
}
