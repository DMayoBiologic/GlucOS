import XCTest
@testable import GlucOSEngine

// Replays real history the way the apps live through it, to check a forecast change before it
// ships: walking forward one reading at a time, relearning every 3 hours from what was known
// then, showing (and logging) one forecast every 15 minutes, widening the range from that log,
// and scoring each forecast against the readings that followed. It prints the same figures as
// `glucos.forecast_accuracy`.
//
// Skipped unless GLUCOS_REPLAY_DIR names a folder with:
//   readings.json  [[unix seconds, mg/dL], ...]
//   log.json       {"doses": [{"t", "kind", "u"}], "meals": [{"t", "c", "f"}], "contexts": [{"t", "tags"}]}
//
//     GLUCOS_REPLAY_DIR=/path swift test --filter LiveReplayTests
//
// GLUCOS_REPLAY_VERBOSE=1 also prints what each relearn picked (2: the range widening), and
// GLUCOS_REPLAY_GAIN=0.5 forces the trend's strength, to compare against what the tuner chose.

final class LiveReplayTests: XCTestCase {
    func testReplayHistoryAsTheAppsWouldHaveLivedIt() throws {
        guard let dir = ProcessInfo.processInfo.environment["GLUCOS_REPLAY_DIR"] else {
            throw XCTSkip("Set GLUCOS_REPLAY_DIR to replay real history.")
        }
        let history = try ReplayHistory(directory: URL(fileURLWithPath: dir))
        let result = LiveReplay(history: history).run()
        print(result.report())
    }
}

struct ReplayHistory {
    var readings: [GlucoseReading]
    var doses: [InsulinDose]
    var meals: [MealEntry]
    var contexts: [ContextEvent]

    init(directory: URL) throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("readings.json")))
        readings = (raw as? [[Double]] ?? []).map {
            GlucoseReading(timestamp: Date(timeIntervalSince1970: $0[0]), mgdl: $0[1], trend: .flat)
        }.sorted { $0.timestamp < $1.timestamp }
        let log = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("log.json")))
            as? [String: [[String: Any]]] ?? [:]
        func date(_ d: [String: Any]) -> Date { Date(timeIntervalSince1970: d["t"] as? Double ?? 0) }
        doses = (log["doses"] ?? []).compactMap { d in
            guard let kind = InsulinKind(rawValue: d["kind"] as? String ?? "") else { return nil }
            return InsulinDose(timestamp: date(d), units: d["u"] as? Double ?? 0, kind: kind)
        }
        meals = (log["meals"] ?? []).map { MealEntry(timestamp: date($0), carbs: $0["c"] as? Double ?? 0, food: $0["f"] as? String ?? "") }
        contexts = (log["contexts"] ?? []).map { c in
            ContextEvent(timestamp: date(c), tags: Set((c["tags"] as? [String] ?? []).compactMap(ContextTag.init(rawValue:))))
        }
    }
}

struct LiveReplay {
    var history: ReplayHistory
    var relearnEvery: TimeInterval = 3 * 3600
    /// Forecasts start once this much history has built up.
    var warmUp: TimeInterval = 24 * 3600

    struct Result {
        var ledger: ForecastLedger
        var logTimes: [Date]
        var meals: [MealEntry]
        var doses: [InsulinDose]

        func report() -> String {
            var lines = ["basis              min  kind    n    mae   naive  bias   inside"]
            let minutes = [15, 30, 45, 60, 90, 120]
            for basis in ForecastBasis.allCases {
                for clean in [true, false] {
                    for m in minutes {
                        let pts = ledger.records.filter { $0.basis == basis }.flatMap { r in
                            r.points.filter { $0.minutes == m && $0.afterLog != clean && $0.actual != nil }.map { (r, $0) }
                        }
                        guard pts.count >= 3 else { continue }
                        lines.append(Self.row("\(basis.rawValue)", m, clean ? "clean" : "after", pts))
                    }
                }
            }
            lines.append("")
            lines.append("all clean points, by time since the last meal or fast dose at issue")
            let events = (meals.filter { $0.carbs > 0 }.map(\.timestamp)
                          + doses.filter { $0.kind != .long && $0.kind != .intermediate }.map(\.timestamp)).sorted()
            for (label, range) in [("<30", 0.0..<30.0), ("30-60", 30.0..<60.0), ("60-120", 60.0..<120.0),
                                   ("120-240", 120.0..<240.0), (">240", 240.0..<1e9)] {
                for m in [15, 30, 45, 60] {
                    let pts = ledger.records.flatMap { r -> [(ForecastRecord, ForecastRecord.Point)] in
                        let last = events.last { $0 <= r.issuedAt }
                        let since = last.map { r.issuedAt.timeIntervalSince($0) / 60 } ?? 1e9
                        guard range.contains(since) else { return [] }
                        return r.points.filter { $0.minutes == m && !$0.afterLog && $0.actual != nil }.map { (r, $0) }
                    }
                    guard pts.count >= 3 else { continue }
                    lines.append(Self.row("since \(label)", m, "clean", pts))
                }
            }
            lines.append("")
            for m in [15, 30, 45, 60] {
                let pts = ledger.records.flatMap { r in r.points.filter { $0.minutes == m && !$0.afterLog && $0.actual != nil }.map { (r, $0) } }
                if !pts.isEmpty { lines.append(Self.row("ALL", m, "clean", pts)) }
            }
            if let lastIssue = ledger.records.last?.issuedAt {
                let from = lastIssue.addingTimeInterval(-2 * 86_400)
                for m in [15, 30, 45, 60] {
                    let pts = ledger.records.filter { $0.issuedAt >= from }.flatMap { r in
                        r.points.filter { $0.minutes == m && !$0.afterLog && $0.actual != nil }.map { (r, $0) }
                    }
                    if pts.count >= 3 { lines.append(Self.row("LAST 2 DAYS", m, "clean", pts)) }
                }
            }
            return lines.joined(separator: "\n")
        }

        static func row(_ label: String, _ m: Int, _ kind: String, _ pts: [(ForecastRecord, ForecastRecord.Point)]) -> String {
            let n = Double(pts.count)
            let mae = pts.map { abs($0.1.actual! - $0.1.mgdl) }.reduce(0, +) / n
            let naive = pts.map { abs($0.1.actual! - $0.0.startMgdl) }.reduce(0, +) / n
            let bias = pts.map { $0.1.actual! - $0.1.mgdl }.reduce(0, +) / n
            let inside = Double(pts.filter { $0.1.insideRange == true }.count) / n * 100
            func f(_ x: Double) -> String { String(format: "%6.1f", x) }
            return "\(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%3d", m))  \(kind.padding(toLength: 6, withPad: " ", startingAt: 0)) \(String(format: "%4d", pts.count)) \(f(mae)) \(f(naive)) \(f(bias)) \(f(inside))%"
        }
    }

    func run() -> Result {
        let readings = history.readings
        guard let first = readings.first, let last = readings.last else {
            return Result(ledger: ForecastLedger(), logTimes: [], meals: [], doses: [])
        }
        let logTimes = (history.doses.map(\.timestamp) + history.meals.map(\.timestamp)
                        + history.contexts.filter { !$0.isWake }.map(\.timestamp)).sorted()
        var ledger = ForecastLedger()
        var model = OutlookModel.empty
        var lastLearn = Date.distantPast
        var lastIssued = Date.distantPast
        let start = first.timestamp.addingTimeInterval(warmUp)
        for (i, r) in readings.enumerated() where r.timestamp >= start {
            let now = r.timestamp
            guard now.timeIntervalSince(lastIssued) >= ForecastLedger.spacing else { continue }
            let known = Array(readings[...i])
            let doses = history.doses.filter { $0.timestamp <= now }
            let meals = history.meals.filter { $0.timestamp <= now }
            let contexts = history.contexts.filter { $0.timestamp <= now }
            if now.timeIntervalSince(lastLearn) >= relearnEvery {
                model = OutlookEngine.learn(readings: known, doses: doses, meals: meals, contexts: contexts,
                                            low: 70, high: 180, now: now, calendar: utc)
                lastLearn = now
                if let g = ProcessInfo.processInfo.environment["GLUCOS_REPLAY_GAIN"].flatMap(Double.init) {
                    model.tuning.tuning.trendGain = g
                }
                if ProcessInfo.processInfo.environment["GLUCOS_REPLAY_VERBOSE"] == "1" {
                    let t = model.tuning
                    print("learn \(now): checks \(t.checks) std \(t.standardError) tuned \(t.tunedError) \(t.tuning.summary)",
                          "fresh", model.calibration?.freshModel?.map { "\($0.minutes):\($0.samples) \(Int($0.meanAbsoluteError))/\(Int($0.naiveError))" } ?? [])
                }
            }
            // The app scores its log on every reading and widens the range from it.
            ledger.score(readings: GlucoseSeries(known, sorted: true), logTimes: logTimes.filter { $0 <= now }, now: now)
            model.rangeScale = ledger.rangeScale(now: now)
            if ProcessInfo.processInfo.environment["GLUCOS_REPLAY_VERBOSE"] == "2", lastLearn == now {
                print("scale \(now) \(model.rangeScale.byBasis) \(model.rangeScale.byHorizon.mapValues { $0.sorted { $0.key < $1.key }.map { "\($0.key):\(String(format: "%.2f", $0.value))" } })")
            }
            let recent = known.filter { $0.timestamp >= now.addingTimeInterval(-3 * 3600) }
            let outlook = OutlookEngine.outlook(readings: recent, doses: doses, meals: meals, contexts: contexts,
                                                model: model, now: now)
            if let f = outlook.glucoseForecast,
               ledger.note(f, device: "replay", tuned: model.tuning.isTuned, now: now) {
                lastIssued = now
            }
        }
        ledger.score(readings: GlucoseSeries(readings, sorted: true), logTimes: logTimes,
                     now: last.timestamp.addingTimeInterval(4 * 3600))
        return Result(ledger: ledger, logTimes: logTimes, meals: history.meals, doses: history.doses)
    }
}
