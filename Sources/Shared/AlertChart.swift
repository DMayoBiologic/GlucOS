import Foundation

/// The small chart on a low, high or forecast alert: the last 3 hours of readings, the forecast
/// line with its likely range, and the target band. It rides in the notification's `userInfo`
/// under `chart`, from the apps' own alerts and from the relay's pushes (`alertChart` in the
/// relay's core.ts), so the iPhone's notification content extension draws pushed and local alerts
/// alike and the Mac renders its picture attachment from the same values. The fields are the Live
/// Activity card's (`GlucoseActivityState`), so both sides build it from what they already have.
/// Plain numbers only, a few hundred bytes. Plain Foundation, so it's unit-tested.
struct AlertChart: Codable, Hashable {
    /// When the newest reading was taken, seconds since 1970.
    var readingAt: Double
    /// `GlucoseUnit.rawValue`.
    var unit: String
    var lowMgdl: Double
    var highMgdl: Double
    /// One value per 5 minutes, oldest first, ending at the reading. Nil: no reading in that slot.
    var history: [Int?]
    /// The forecast's central line every 5 minutes after the reading. Empty without a forecast.
    var forecast: [Int] = []
    /// The likely range at the forecast's end.
    var forecastLower: Int?
    var forecastUpper: Int?

    static let userInfoKey = "chart"
    static let step: TimeInterval = 5 * 60
    static let historyHours: Double = 3

    /// Fewer readings than this and there's no line worth drawing: the alert goes without a chart.
    static let minimumReadings = 2

    init(readingAt: Double, unit: String, lowMgdl: Double, highMgdl: Double, history: [Int?],
         forecast: [Int] = [], forecastLower: Int? = nil, forecastUpper: Int? = nil) {
        self.readingAt = readingAt
        self.unit = unit
        self.lowMgdl = lowMgdl
        self.highMgdl = highMgdl
        self.history = history
        self.forecast = forecast
        self.forecastLower = forecastLower
        self.forecastUpper = forecastUpper
    }

    /// The chart for the card the app already builds for its Live Activity. Nil while there are
    /// too few readings, or while the card is a warm-up countdown.
    init?(state: GlucoseActivityState) {
        guard state.warmUpEndsAt == nil,
              state.history.compactMap({ $0 }).count >= Self.minimumReadings else { return nil }
        self.init(readingAt: state.readingAt, unit: state.unit, lowMgdl: state.lowMgdl,
                  highMgdl: state.highMgdl, history: state.history, forecast: state.forecast,
                  forecastLower: state.forecastLower, forecastUpper: state.forecastUpper)
    }

    // MARK: userInfo

    /// For `UNMutableNotificationContent.userInfo`: plain JSON values, as a push carries them.
    var userInfoValue: Any? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The chart a notification carries, if any, and only if it's one worth drawing.
    init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo[Self.userInfoKey], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let chart = try? JSONDecoder().decode(AlertChart.self, from: data),
              chart.history.compactMap({ $0 }).count >= Self.minimumReadings,
              chart.lowMgdl < chart.highMgdl else { return nil }
        self = chart
    }

    // MARK: What it shows

    var glucoseUnit: GlucoseUnit { GlucoseUnit(rawValue: unit) ?? .mmol }
    var readingDate: Date { Date(timeIntervalSince1970: readingAt) }

    /// The readings, dated, with gaps left out.
    var readings: [GlucoseReading] {
        let n = history.count
        return history.enumerated().compactMap { i, v in
            guard let v else { return nil }
            return GlucoseReading(timestamp: readingDate.addingTimeInterval(-Double(n - 1 - i) * Self.step),
                                  mgdl: Double(v), trend: .unknown)
        }
    }

    /// Where the forecast ends, with its likely range.
    var forecastEnd: ForecastSample? {
        guard let last = forecast.last else { return nil }
        let mgdl = Double(last)
        return ForecastSample(date: readingDate.addingTimeInterval(Double(forecast.count) * Self.step), mgdl: mgdl,
                              lowerMgdl: Double(forecastLower ?? last), upperMgdl: Double(forecastUpper ?? last))
    }

    /// VoiceOver's one description of the chart, in the same words as the app's own charts.
    var spokenSummary: String {
        ChartSummary.sentence(.init(readings: readings, lowMgdl: lowMgdl, highMgdl: highMgdl, unit: glucoseUnit,
                                    hours: Self.historyHours, forecastEnd: forecastEnd))
    }

    // MARK: Layout

    /// The chart in unit coordinates: x from 0 (3 hours ago) to 1 (the forecast's end, or the
    /// reading without one), y from 0 (bottom) to 1 (top). The view only scales these.
    struct Layout: Equatable {
        struct Point: Equatable {
            var x: Double
            var y: Double
        }

        /// The reading line, split where readings are missing. A lone reading is a one-point run.
        var runs: [[Point]]
        /// The forecast line, starting at the reading. Empty without a forecast.
        var forecast: [Point]
        /// The likely range: a cone from the reading to the range at the forecast's end.
        var cone: (top: Point, bottom: Point)?
        /// The target band's bottom and top.
        var lowY: Double
        var highY: Double
        /// The reading itself, where the line ends and the forecast starts.
        var now: Point
        /// The y range drawn, mg/dL.
        var minMgdl: Double
        var maxMgdl: Double

        static func == (a: Layout, b: Layout) -> Bool {
            a.runs == b.runs && a.forecast == b.forecast && a.cone?.top == b.cone?.top
                && a.cone?.bottom == b.cone?.bottom && a.lowY == b.lowY && a.highY == b.highY
                && a.now == b.now && a.minMgdl == b.minMgdl && a.maxMgdl == b.maxMgdl
        }
    }

    /// Room kept above and below the highest and lowest values, mg/dL.
    static let padding = 10.0
    /// The y range never shrinks below this, so a flat line doesn't fill the chart with noise.
    static let minimumSpan = 90.0
    /// What any sensor can report.
    static let floorMgdl = 40.0
    static let ceilingMgdl = 400.0

    var layout: Layout {
        let slots = max(history.count, 1)
        let historySpan = Double(slots - 1) * Self.step
        let span = historySpan + Double(forecast.count) * Self.step
        func x(_ slot: Int) -> Double { span > 0 ? Double(slot) * Self.step / span : 1 }

        var values = history.compactMap { $0 }.map(Double.init) + forecast.map(Double.init)
        if let l = forecastLower { values.append(Double(l)) }
        if let u = forecastUpper { values.append(Double(u)) }
        values += [lowMgdl, highMgdl]
        var lo = max(Self.floorMgdl, (values.min() ?? lowMgdl) - Self.padding)
        var hi = min(Self.ceilingMgdl, (values.max() ?? highMgdl) + Self.padding)
        if hi - lo < Self.minimumSpan {
            let grow = (Self.minimumSpan - (hi - lo)) / 2
            lo = max(Self.floorMgdl, lo - grow)
            hi = min(Self.ceilingMgdl, lo + Self.minimumSpan)
        }
        func y(_ mgdl: Double) -> Double { min(1, max(0, (mgdl - lo) / (hi - lo))) }

        var runs: [[Layout.Point]] = []
        var run: [Layout.Point] = []
        for (i, v) in history.enumerated() {
            if let v { run.append(.init(x: x(i), y: y(Double(v)))) }
            else if !run.isEmpty { runs.append(run); run = [] }
        }
        if !run.isEmpty { runs.append(run) }

        let nowX = x(slots - 1)
        let nowValue = history.last.flatMap { $0 }.map(Double.init) ?? Double(history.compactMap { $0 }.last ?? 0)
        let now = Layout.Point(x: nowX, y: y(nowValue))
        var forecastLine: [Layout.Point] = []
        var cone: (top: Layout.Point, bottom: Layout.Point)?
        if !forecast.isEmpty {
            forecastLine = [now] + forecast.enumerated().map { i, v in .init(x: x(slots + i), y: y(Double(v))) }
            if let l = forecastLower, let u = forecastUpper, u > l {
                cone = (.init(x: 1, y: y(Double(u))), .init(x: 1, y: y(Double(l))))
            }
        }
        return Layout(runs: runs, forecast: forecastLine, cone: cone, lowY: y(lowMgdl), highY: y(highMgdl),
                      now: now, minMgdl: lo, maxMgdl: hi)
    }

    // MARK: Motion

    /// How long the line takes to draw in when the alert is opened. Reduce Motion: no draw-in,
    /// the finished chart appears at once.
    static func drawInSeconds(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.6 }
}
