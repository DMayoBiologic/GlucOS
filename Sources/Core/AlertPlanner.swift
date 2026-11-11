import Foundation

// Which glucose alerts are due, worked out without delivering anything. The Mac and iPhone apps
// turn each notice into a local notification; the push relay turns it into an APNs alert. Keeping
// one copy of the rules means every device alerts on the same readings, with the same wording and
// the same repeat timers. Plain Foundation, so it's unit-tested and compiles on Linux.

/// The alert switches from Settings, without the rest of the app's settings.
struct AlertPreferences: Codable, Hashable {
    var enabled = true
    /// High (above target). Very high and every low alert stay on whenever alerts are on.
    var high = true
    var rapidChange = true
    var stale = true
    var sensorExpiry = true
    var predictedLow = true
    var predictedHigh = true
    /// How far ahead a predicted low may be to alert, in minutes.
    var predictiveMinutes = 20
    var cooldownMinutes = 15
}

/// One alert to show.
struct AlertNotice: Hashable {
    enum Kind: String, CaseIterable, Codable {
        case urgentLow, low, high, veryHigh, rapidChange, stale, sensorExpiring, apiBroken
        case predictedUrgentLow, predictedLow, predictedHigh, predictedVeryHigh

        static let predicted: [Kind] = [.predictedUrgentLow, .predictedLow, .predictedHigh, .predictedVeryHigh]
    }

    let kind: Kind
    let title: String
    let body: String
    /// Urgent lows: the loudest sound and time-sensitive delivery.
    let critical: Bool

    /// The notification identifier. A newer alert of the same kind replaces the older one, on
    /// every device and whether it arrived as a local notification or a push.
    var identifier: String { "glucos.\(kind.rawValue)" }
}

struct AlertPlanner {
    private(set) var lastFired: [AlertNotice.Kind: Date] = [:]
    /// Since when no excursion has been predicted. A forecast can hover around a threshold from
    /// one reading to the next, so the repeat timer only resets after a quiet spell.
    private var quietSince: Date?

    init() {}

    /// Alerts on the actual reading, the data going quiet, the sensor and the connection.
    mutating func evaluate(_ s: GlucoseSnapshot, prefs: AlertPreferences, now: Date = Date()) -> [AlertNotice] {
        guard prefs.enabled else { return [] }
        var out: [AlertNotice] = []
        let unit = s.unit
        let cooldown = TimeInterval(prefs.cooldownMinutes * 60)

        if let r = s.current, !s.isStale(at: now) {
            let v = unit.format(mgdl: r.mgdl, withUnit: true)
            switch GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl) {
            case .urgentLow:
                fire(.urgentLow, title: "URGENT LOW — \(v)", body: "\(r.trend.description). Treat now and confirm on your phone.",
                     cooldown: 5 * 60, critical: true, now: now, into: &out)
            case .low:
                fire(.low, title: "Low glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now, into: &out)
            case .veryHigh:
                fire(.veryHigh, title: "Very high glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now, into: &out)
            case .high where prefs.high:
                fire(.high, title: "High glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now, into: &out)
            case .high:
                break
            case .inRange:
                // Reset low/high so the next excursion alerts immediately.
                for k in [AlertNotice.Kind.low, .high, .urgentLow, .veryHigh] { lastFired[k] = nil }
            }

            if prefs.rapidChange, r.trend.isRapid {
                fire(.rapidChange, title: "\(r.trend.description) — \(v)",
                     body: s.deltaMgdl.map { "\(unit.formatDelta(mgdl: $0)) since last reading" } ?? "",
                     cooldown: cooldown, now: now, into: &out)
            } else if !r.trend.isRapid {
                lastFired[.rapidChange] = nil
            }
        }

        if prefs.stale, s.isStale(at: now), s.current != nil {
            let age = s.current.map { Format.age($0.age(at: now)) } ?? "a while"
            fire(.stale, title: "No recent glucose data",
                 body: "Last reading \(age). Check your phone has signal and LibreLink is running.",
                 cooldown: 30 * 60, now: now, into: &out)
        } else {
            lastFired[.stale] = nil
        }

        if prefs.sensorExpiry, let sensor = s.sensor {
            let days = sensor.daysRemaining(at: now)
            if days < 1 {
                fire(.sensorExpiring, title: "Sensor expires soon",
                     body: "About \(Format.days(days)) left on sensor \(sensor.serial).",
                     cooldown: 6 * 3600, now: now, into: &out)
            }
        }

        if let err = s.lastError, err.contains("version") || err.contains("API may have changed") {
            fire(.apiBroken, title: "GlucOS needs attention", body: err, cooldown: 6 * 3600, now: now, into: &out)
        }
        return out
    }

    /// Heads-up alerts from the forecast: glucose is heading out of range within the lead time.
    /// Only while the reading is current and still on the right side of the threshold, so these
    /// never stand in for the alerts on actual readings above.
    mutating func evaluatePrediction(_ s: GlucoseSnapshot, forecast: GlucoseForecast?, prefs: AlertPreferences,
                                     now: Date = Date()) -> AlertNotice? {
        guard prefs.enabled, prefs.predictedLow || prefs.predictedHigh else { return nil }
        guard let r = s.current, !s.isStale(at: now), let forecast else {
            clearPredictions(now: now)
            return nil
        }
        let rules = PredictiveAlertSettings(lows: prefs.predictedLow, highs: prefs.predictedHigh,
                                            leadTime: TimeInterval(prefs.predictiveMinutes * 60),
                                            lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, highAlertsOn: prefs.high)
        guard let d = PredictiveAlertRules.evaluate(forecast, settings: rules, now: now) else {
            clearPredictions(now: now)
            return nil
        }
        quietSince = nil
        let cooldown = TimeInterval(prefs.cooldownMinutes * 60)
        let highCooldown = max(cooldown, 30 * 60)
        // Each kind keeps its own repeat timer, so a forecast hovering between two thresholds
        // can't alternate its way past them. A milder heads-up is held back while the more
        // severe one in the same direction is still recent; escalation always gets through.
        let severer: AlertNotice.Kind? = d.kind == .low ? .predictedUrgentLow : d.kind == .high ? .predictedVeryHigh : nil
        let holdFor = severer == .predictedVeryHigh ? highCooldown : cooldown
        if let severer, let last = lastFired[severer], now.timeIntervalSince(last) < holdFor { return nil }
        let unit = s.unit
        let minutes = d.minutesAway(from: now)
        let when = minutes <= 1 ? "any minute" : "in about \(minutes) min"
        let current = "Now \(unit.format(mgdl: r.mgdl, withUnit: true)) \(r.trend.arrow)."
        let threshold = unit.format(mgdl: d.thresholdMgdl, withUnit: true)
        let note = "Forecast, not a reading: check before acting."
        var out: [AlertNotice] = []
        switch d.kind {
        case .urgentLow:
            fire(.predictedUrgentLow, title: "Urgent low predicted \(when)",
                 body: "\(current) Heading below \(threshold). \(note)", cooldown: min(cooldown, 10 * 60),
                 critical: true, now: now, into: &out)
        case .low:
            fire(.predictedLow, title: "Low predicted \(when)",
                 body: "\(current) Heading below \(threshold). \(note)", cooldown: cooldown, now: now, into: &out)
        case .high:
            fire(.predictedHigh, title: "High predicted \(when)",
                 body: "\(current) Heading above \(threshold). \(note)", cooldown: highCooldown, now: now, into: &out)
        case .veryHigh:
            fire(.predictedVeryHigh, title: "Very high predicted \(when)",
                 body: "\(current) Heading above \(threshold). \(note)", cooldown: highCooldown, now: now, into: &out)
        }
        return out.first
    }

    private mutating func clearPredictions(now: Date) {
        if quietSince == nil { quietSince = now }
        guard let q = quietSince, now.timeIntervalSince(q) >= 15 * 60 else { return }
        for k in AlertNotice.Kind.predicted { lastFired[k] = nil }
    }

    private mutating func fire(_ kind: AlertNotice.Kind, title: String, body: String, cooldown: TimeInterval,
                               critical: Bool = false, now: Date, into out: inout [AlertNotice]) {
        if let last = lastFired[kind], now.timeIntervalSince(last) < cooldown { return }
        lastFired[kind] = now
        out.append(AlertNotice(kind: kind, title: title, body: body, critical: critical))
    }
}

extension PredictedExcursion {
    var alertKind: AlertNotice.Kind {
        switch self {
        case .urgentLow: return .predictedUrgentLow
        case .low: return .predictedLow
        case .high: return .predictedHigh
        case .veryHigh: return .predictedVeryHigh
        }
    }
}
