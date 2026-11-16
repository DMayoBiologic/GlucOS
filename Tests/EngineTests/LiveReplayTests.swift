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
// GLUCOS_REPLAY_VERBOSE=1 also prints what each relearn picked (2: the range widening; 3: every
// insulin-and-carb forecast and every forecast with a log after it, as forecast/actual at 15, 30,
// 45, 60, 90 and 120 minutes, `*` marking a point with a log in between; clean trend-only
// forecasts are left out), and
// GLUCOS_REPLAY_GAIN=0.5 forces the trend's strength, to compare against what the tuner chose.
//
// GLUCOS_REPLAY_OPENS=/path/opens.json ([unix seconds, ...], e.g. the iPhone's forecast_checks
// issued_at) replays a device that is only open now and then, as the iPhone is: its history is
// LibreLinkUp's 15-minute graph plus the few live readings it saw while open (kept one per
// 5-minute slot, as `HistoryArchive` does), and it shows a forecast only at those times.

final class LiveReplayTests: XCTestCase {
    func testReplayHistoryAsTheAppsWouldHaveLivedIt() throws {
        guard let dir = ProcessInfo.processInfo.environment["GLUCOS_REPLAY_DIR"] else {
            throw XCTSkip("Set GLUCOS_REPLAY_DIR to replay real history.")
        }
        let history = try ReplayHistory(directory: URL(fileURLWithPath: dir))
        var replay = LiveReplay(history: history)
        if let path = ProcessInfo.processInfo.environment["GLUCOS_REPLAY_OPENS"] {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [Double] ?? []
            replay.opens = raw.map { Date(timeIntervalSince1970: $0) }.sorted()
        }
        let result = replay.run()
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
    /// When set, the device is open only at these times (see GLUCOS_REPLAY_OPENS).
    var opens: [Date]?
    /// How long the device is taken to stay open, live readings and all, around each open.
    var openFor: ClosedRange<TimeInterval> = -180...120
    /// An occasional device that still has every reading (from the relay), not just LibreLinkUp's.
    var fullHistory = ProcessInfo.processInfo.environment["GLUCOS_REPLAY_FULL"] == "1"

    /// What a device that's open only at `opens` has in its history: LibreLinkUp's 15-minute
    /// graph, plus live readings while open, one per 5-minute slot.
    static func occasionalArchive(_ readings: [GlucoseReading], opens: [Date],
                                  openFor: ClosedRange<TimeInterval>) -> [GlucoseReading] {
        var slots = Set<Int>()
        var out: [GlucoseReading] = []
        var o = 0
        for r in readings {
            while o < opens.count, opens[o].addingTimeInterval(openFor.upperBound) < r.timestamp { o += 1 }
            let open = o < opens.count && r.timestamp.timeIntervalSince(opens[o]) >= openFor.lowerBound
            let minute = Int(r.timestamp.timeIntervalSince1970 / 60)
            guard open || minute % 15 == 0 else { continue }
            if slots.insert(Int(r.timestamp.timeIntervalSince1970 / 300)).inserted { out.append(r) }
        }
        return out
    }

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
            // Insulin-and-carb forecasts with carbs from a logged meal still being absorbed, and
            // those with insulin acting alone (`ForecastLimitation.insulinOnly`), told apart from
            // the logbook so runs from before the split can be compared.
            lines.append("")
            lines.append("insulin-and-carb forecasts, clean points, after a meal or with insulin alone")
            let carbTimes = meals.filter { $0.carbs > 0 }.map(\.timestamp)
            let reach = CarbAbsorptionCurve.standard.totalDuration
            for (label, withCarbs) in [("after a meal", true), ("insulin only", false)] {
                for m in minutes {
                    let pts = ledger.records.filter { r in
                        r.basis == .trendInsulinCarbs
                            && carbTimes.contains { $0 <= r.issuedAt && r.issuedAt.timeIntervalSince($0) < reach } == withCarbs
                    }.flatMap { r in r.points.filter { $0.minutes == m && !$0.afterLog && $0.actual != nil }.map { (r, $0) } }
                    guard pts.count >= 3 else { continue }
                    lines.append(Self.row(label, m, "clean", pts))
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
            // How the range held up day by day, at the horizons the Insights card shows: the figure
            // the widening is meant to keep at about 8 in 10 as the errors change.
            lines.append("")
            lines.append("inside the range by day, clean points (UTC day: 15 / 30 / 60 min, n, mean 30-min range width mg/dL)")
            let day = DateFormatter(); day.dateFormat = "MM-dd"; day.timeZone = TimeZone(identifier: "UTC")
            let byDay = Dictionary(grouping: ledger.records) { day.string(from: $0.issuedAt) }
            for key in byDay.keys.sorted() {
                let cells = [15, 30, 60].map { m -> String in
                    let pts = byDay[key]!.flatMap { $0.points.filter { $0.minutes == m && !$0.afterLog && $0.actual != nil } }
                    guard !pts.isEmpty else { return "   -" }
                    return String(format: "%3.0f%%", Double(pts.filter { $0.insideRange == true }.count) / Double(pts.count) * 100)
                }
                let n = byDay[key]!.flatMap { $0.points.filter { [15, 30, 60].contains($0.minutes) && !$0.afterLog && $0.actual != nil } }.count
                let widths = byDay[key]!.flatMap { $0.points.filter { $0.minutes == 30 && !$0.afterLog && $0.actual != nil }.map { $0.upper - $0.lower } }
                let width = widths.isEmpty ? "-" : String(format: "%.0f", widths.reduce(0, +) / Double(widths.count))
                lines.append("\(key)  \(cells.joined(separator: " / "))  \(n)  \(width)")
            }
            if ProcessInfo.processInfo.environment["GLUCOS_REPLAY_VERBOSE"] == "3" {
                let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC")
                for r in ledger.records where r.basis == .trendInsulinCarbs || r.points.contains(where: \.afterLog) {
                    let pts = r.points.filter { [15, 30, 45, 60, 90, 120].contains($0.minutes) }.map {
                        "\($0.minutes):\(Int($0.mgdl))/\($0.actual.map { String(Int($0)) } ?? "-")\($0.afterLog ? "*" : "")"
                    }.joined(separator: " ")
                    lines.append("\(f.string(from: r.issuedAt)) \(r.basis == .trend ? "trend" : "model") s\(Int(r.startMgdl)) tr\(String(format: "%.1f", r.trendPerMinute)) \(r.limitations.joined(separator: ",")) | \(pts)")
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
        let truth = history.readings
        let readings = opens.map { fullHistory ? truth : Self.occasionalArchive(truth, opens: $0, openFor: openFor) } ?? truth
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
        // Issue times: every reading, or (an occasional device) the reading it had when opened.
        let issues: [(Int, Date)] = opens.map { opens in
            opens.compactMap { t in readings.lastIndex { $0.timestamp <= t }.map { ($0, t) } }
        } ?? readings.indices.map { ($0, readings[$0].timestamp) }
        for (i, now) in issues where now >= start {
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
            if ProcessInfo.processInfo.environment["GLUCOS_REPLAY_VERBOSE"] == "4", case .failure(let e) = outlook.forecast {
                print("no forecast \(now): \(e.reason)")
            }
            if let f = outlook.glucoseForecast,
               ledger.note(f, device: "replay", tuned: model.tuning.isTuned, now: now) {
                lastIssued = now
            }
        }
        // Scored against every reading: the app scores later, once LibreLinkUp's history is in.
        ledger.score(readings: GlucoseSeries(truth, sorted: true), logTimes: logTimes,
                     now: last.timestamp.addingTimeInterval(4 * 3600))
        return Result(ledger: ledger, logTimes: logTimes, meals: history.meals, doses: history.doses)
    }
}
