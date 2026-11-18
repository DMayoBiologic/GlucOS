import Foundation

/// "Send a test alert" in Settings › Alerts (docs/TestAlert.md). A sample low alert, sent through
/// the same local notification path as a real one: the low alert's sound and interruption level,
/// its Log treatment and Snooze buttons, and a sample chart (`AlertChart`), so the iPhone's
/// notification content extension and the Mac's picture attachment both show.
///
/// It is never a real alert. It carries no `kind`, so nothing that reads one (the Logbook's alert
/// records, the alert-count preview built from them, the buttons, the in-app banner) sees it, and
/// it is marked `test` so those places can turn it away by name too (`ownKind`). Its identifier is
/// its own and never an episode's (docs/AlertEpisodes.md), so it can't join or replace a real
/// low's notification, and a real one can't replace it. It never goes near `AlertPlanner` or
/// `AlertEpisodes`, so it changes no repeat timer and opens no episode.
///
/// Plain Foundation, so it's unit-tested (TestAlertTests).
enum TestAlert {
    /// The alert it looks like: sound, interruption level and buttons are a low's.
    static let imitates: AlertNotice.Kind = .low

    static let title = "Test alert"
    static let userInfoKey = "test"
    static let identifierPrefix = "glucos.test."
    static let threadIdentifier = "glucos.test"
    /// Below this a low is urgent (`GlucoseRange.classify`); the sample stays above it.
    static let urgentLowMgdl = 54.0

    /// The Settings button, and what VoiceOver says about it.
    static let buttonTitle = "Send a Test Alert"
    static let accessibilityLabel = "Send a test alert"
    static let accessibilityHint = "Sends a sample low alert with its sound, buttons and chart. Nothing is logged or snoozed."
    /// Shown on the button for a moment after a tap, and read out by VoiceOver.
    static let sentTitle = "Test Alert Sent"
    static let sentAnnouncement = "Test alert sent. It looks and sounds like a low alert. Nothing was logged or snoozed."
    static let sentShowsFor: TimeInterval = 3

    /// A low just below the user's own low limit, never an urgent one.
    static func sampleMgdl(lowMgdl: Double) -> Double {
        min(lowMgdl - 1, max(urgentLowMgdl + 2, lowMgdl - 8)).rounded()
    }

    static func body(unit: GlucoseUnit, lowMgdl: Double) -> String {
        let v = unit.format(mgdl: sampleMgdl(lowMgdl: lowMgdl), withUnit: true)
        return "Sample low, \(v), falling. This is how a low alert looks and sounds. Nothing is logged or snoozed."
    }

    /// A fresh identifier per test, outside every episode's (`glucos.low.…`, `glucos.high.…`) and
    /// every alert kind's (`glucos.<kind>`).
    static func identifier(now: Date) -> String {
        "\(identifierPrefix)\(Int(now.timeIntervalSince1970))"
    }

    /// The low alert's buttons.
    static var categoryIdentifier: String { imitates.actionCategory ?? AlertSnoozes.snoozeAndTreatCategory }

    /// The notification's userInfo: marked as a test, with the chart, and with no `kind`.
    static func userInfo(chart: AlertChart?) -> [String: Any] {
        var info: [String: Any] = [userInfoKey: true]
        if let value = chart?.userInfoValue { info[AlertChart.userInfoKey] = value }
        return info
    }

    /// Whether a notification is a test alert.
    static func isTest(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[userInfoKey] as? Bool) == true
    }

    /// The user's own low or high alert behind a notification, the one rule every place that logs,
    /// snoozes or banners an alert goes by: nil for a test alert (even one carrying a `kind`), a
    /// follower's copy of someone else's alert, and kinds the Logbook doesn't keep.
    static func ownKind(_ userInfo: [AnyHashable: Any]) -> AlertNotice.Kind? {
        guard !isTest(userInfo), userInfo["followID"] == nil, let raw = userInfo["kind"] as? String,
              let kind = AlertNotice.Kind(rawValue: raw), AlertLog.isLogged(kind) else { return nil }
        return kind
    }

    /// A sample chart: an hour and a half sliding from mid-range to the sample low, then a forecast
    /// levelling off. Made up, so the test shows a chart even with no readings yet.
    static func chart(unit: GlucoseUnit, lowMgdl: Double, highMgdl: Double, now: Date) -> AlertChart {
        let slots = Int(AlertChart.historyHours * 60 / (AlertChart.step / 60)) + 1
        let end = sampleMgdl(lowMgdl: lowMgdl)
        let start = max(end + 20, (lowMgdl + highMgdl) / 2)
        let fall = 90.0
        let history: [Int?] = (0..<slots).map { i in
            let before = Double(slots - 1 - i) * AlertChart.step / 60
            return Int((end + (start - end) * min(before, fall) / fall).rounded())
        }
        let floor = max(urgentLowMgdl + 1, end - 8)
        let forecast = (1...12).map { k in Int(max(floor, end - Double(k) * 1.5).rounded()) }
        let last = Double(forecast.last ?? Int(end))
        return AlertChart(readingAt: now.timeIntervalSince1970.rounded(), unit: unit.rawValue,
                          lowMgdl: lowMgdl, highMgdl: highMgdl, history: history, forecast: forecast,
                          forecastLower: Int(last - 14), forecastUpper: Int(last + 22))
    }
}
