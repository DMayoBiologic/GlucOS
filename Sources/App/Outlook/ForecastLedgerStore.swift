import Foundation
import Combine

/// Keeps the log of forecasts this device showed (`ForecastLedger`) on disk, scores them as
/// readings arrive, and hands settled ones to logbook sync for upload. Owned by `OutlookStore`.
@MainActor
final class ForecastLedgerStore: ObservableObject {
    /// The last 7 days of shown forecasts, and the 3 weeks before, so the Outlook page can show
    /// whether accuracy is improving.
    @Published private(set) var lastWeek: LiveAccuracy = .empty
    @Published private(set) var weeksBefore: LiveAccuracy = .empty
    /// The Insights card: the last 7 days at 15, 30 and 60 minutes against no change. Nil until
    /// there are enough checks.
    @Published private(set) var scorecard: ForecastScorecard?
    /// The same figures for only the forecasts this version showed. Nil until it has shown one.
    @Published private(set) var sinceUpdate: ForecastSinceUpdate?
    /// How much wider to draw the range, from how the forecasts shown here did.
    @Published private(set) var rangeScale: ForecastRangeScale = .unchanged
    /// How far ahead the forecast may be drawn, from how this device's forecasts did against no change.
    @Published private(set) var liveHorizon: ForecastLiveHorizon = .unlimited

    private(set) var ledger: ForecastLedger
    private var lastScored = Date.distantPast

    /// The installed version ("1.2.0"), kept on each recorded forecast.
    static let appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    static let device: String = {
        #if os(macOS)
        return "Mac"
        #else
        return "iPhone"
        #endif
    }()

    private static var url: URL? { SharedStore.containerURL?.appendingPathComponent("forecast-log.json") }
    private static let writeQueue = DispatchQueue(label: "au.com.declanmayo.glucos.forecast-log", qos: .utility)

    init() {
        ledger = Self.load()
        summarise()
    }

    /// Records the forecast being shown now (at most one per 15 minutes) and scores earlier ones.
    func update(forecast: GlucoseForecast?, tuned: Bool, archive: [GlucoseReading], current: GlucoseReading?,
                logTimes: @autoclosure () -> [Date], now: Date = Date()) {
        var changed = false
        if let forecast { changed = ledger.note(forecast, device: Self.device, tuned: tuned, appVersion: Self.appVersion, now: now) }
        // Scoring needs only a minute's resolution.
        if changed || now.timeIntervalSince(lastScored) >= 60 {
            lastScored = now
            // Only readings from the oldest forecast still waiting onwards matter.
            let oldest = ledger.records.first { !$0.settled }?.issuedAt ?? now
            var recent = archive.filter { $0.timestamp >= oldest.addingTimeInterval(-600) }
            if let current, !recent.contains(where: { $0.timestamp == current.timestamp }) { recent.append(current) }
            if ledger.score(readings: GlucoseSeries(recent), logTimes: logTimes(), now: now) { changed = true }
            if ledger.prune(now: now) { changed = true }
        }
        if changed {
            save()
            summarise()
        }
    }

    /// Settled forecasts not yet uploaded.
    func pendingUpload(limit: Int = 200) -> [ForecastRecord] { ledger.pendingUpload(limit: limit) }

    func markUploaded(_ records: [ForecastRecord]) {
        ledger.markUploaded(Set(records.map(\.id)))
        save()
    }

    private func summarise(now: Date = Date()) {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        // This device's own forecasts: what was shown here.
        lastWeek = ledger.accuracy(from: weekAgo, to: now.addingTimeInterval(3600), device: Self.device)
        weeksBefore = ledger.accuracy(from: now.addingTimeInterval(-28 * 86_400), to: weekAgo, device: Self.device)
        let card = ForecastScorecard(lastWeek)
        if card != scorecard { scorecard = card }
        var since: ForecastSinceUpdate?
        if let version = Self.appVersion {
            let first = ledger.firstRecord(device: Self.device, appVersion: version)
            let mine = ledger.accuracy(from: max(weekAgo, first ?? weekAgo), to: now.addingTimeInterval(3600),
                                       device: Self.device, appVersion: version)
            since = ForecastSinceUpdate(accuracy: mine, version: version, since: first,
                                        coversWeek: first.map { $0 <= weekAgo } ?? false)
        }
        if since != sinceUpdate { sinceUpdate = since }
        let scale = ledger.rangeScale(now: now)
        if scale != rangeScale { rangeScale = scale }
        let horizon = ledger.liveHorizon(device: Self.device, now: now)
        if horizon != liveHorizon { liveHorizon = horizon }
    }

    private static func load() -> ForecastLedger {
        guard let url, let data = try? Data(contentsOf: url) else { return ForecastLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ForecastLedger.self, from: data)) ?? ForecastLedger()
    }

    private func save() {
        guard let url = Self.url else { return }
        let copy = ledger
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(copy) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
