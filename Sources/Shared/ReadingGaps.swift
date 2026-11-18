import Foundation

/// Gaps in readings on iPhone Today and the Mac popover. Where readings stop for `minimum` (10
/// minutes) or more and then start again, the trace breaks and a thin dashed grey bridge joins the
/// two ends, drawn in once from left to right (static under Reduce Motion). A tap on iPhone, or the
/// pointer resting on it on the Mac, shows a small card saying why, where GlucOS knows:
///
/// - the sensor was warming up (the stretch reaches into a new sensor's first hour),
/// - the sensor had ended,
/// - GlucOS kept checking but LibreLinkUp had nothing new ("No signal from LibreLinkUp"),
/// - the Mac or iPhone was asleep, so GlucOS wasn't checking,
///
/// and otherwise just "No readings". VoiceOver hears one line in the chart's summary. Plain
/// Foundation so it can be unit-tested; `GlucoseChart` draws it (`gapContext`).
///
/// LibreLinkUp fills time the app wasn't checking with one reading every 15 minutes. A step of
/// about 15 minutes between readings is that, not a gap, so it isn't marked.
enum ReadingGaps {
    /// Readings this far apart (or further) make a gap.
    static let minimum: TimeInterval = 10 * 60
    /// LibreLinkUp's history steps: 15 minutes, give or take this much, are never a gap.
    static let historyStep: TimeInterval = 15 * 60
    static let historyTolerance: TimeInterval = 90
    /// How much of a gap GlucOS must have been checking for it to say LibreLinkUp had no signal
    /// rather than that the device was asleep.
    static let checkedShare = 0.5
    /// The bridge draws in over this long, once per gap. Nothing moves under Reduce Motion.
    static let drawInDuration: TimeInterval = 0.6

    /// Which device's sleep the card names.
    enum Device: String, Sendable {
        case mac, iPhone

        var name: String { self == .mac ? "Mac" : "iPhone" }
    }

    enum Reason: Hashable, Sendable {
        case warmUp
        case sensorEnded
        case noSignal
        case asleep(Device)
        case unknown

        /// The card's title, also the end of the VoiceOver line.
        var title: String {
            switch self {
            case .warmUp: return "Sensor warming up"
            case .sensorEnded: return "Sensor ended"
            case .noSignal: return "No signal from LibreLinkUp"
            case .asleep(let d): return "\(d.name) was asleep"
            case .unknown: return "No readings"
            }
        }

        /// One sentence under the title.
        var detail: String {
            switch self {
            case .warmUp:
                return "A new sensor gives no readings during its first hour."
            case .sensorEnded:
                return "The sensor stopped giving readings when it ended."
            case .noSignal:
                return "GlucOS kept checking, but LibreLinkUp had no new readings from the sensor."
            case .asleep(let d):
                return "GlucOS wasn't checking while the \(d.name) slept, and LibreLinkUp had no readings to fill in."
            case .unknown:
                return "No readings were recorded for this stretch."
            }
        }

        var systemImage: String {
            switch self {
            case .warmUp: return "hourglass"
            case .sensorEnded: return "sensor.tag.radiowaves.forward"
            case .noSignal: return "antenna.radiowaves.left.and.right.slash"
            case .asleep: return "moon.zzz"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    /// One gap: the last reading before it and the first after.
    struct Gap: Hashable, Identifiable, Sendable {
        let start: Date
        let end: Date
        let startMgdl: Double
        let endMgdl: Double
        let reason: Reason

        var id: Date { start }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// What the reasons are worked out from.
    struct Context: Hashable, Sendable {
        var sensor: SensorInfo?
        var polls: PollLog
        var device: Device
    }

    /// The gaps among `readings` (oldest → newest), oldest first.
    static func find(in readings: [GlucoseReading], context: Context) -> [Gap] {
        guard readings.count >= 2 else { return [] }
        var out: [Gap] = []
        for i in 1..<readings.count {
            let a = readings[i - 1], b = readings[i]
            guard isGap(b.timestamp.timeIntervalSince(a.timestamp)) else { continue }
            out.append(Gap(start: a.timestamp, end: b.timestamp, startMgdl: a.mgdl, endMgdl: b.mgdl,
                           reason: reason(from: a.timestamp, to: b.timestamp, context: context)))
        }
        return out
    }

    /// Whether two readings this far apart have a gap between them.
    static func isGap(_ step: TimeInterval) -> Bool {
        guard step >= minimum else { return false }
        return abs(step - historyStep) > historyTolerance
    }

    /// Why nothing came between `start` and `end`, as far as GlucOS can tell.
    static func reason(from start: Date, to end: Date, context: Context) -> Reason {
        if let sensor = context.sensor {
            // Reaching into the new sensor's first hour (and the few minutes LibreLinkUp takes to
            // pass its first reading on): a sensor change. What came before was the old one ending.
            let warmEnd = sensor.activated.addingTimeInterval(SensorWarmUp.duration + SensorWarmUp.grace)
            if end > sensor.activated, start < warmEnd { return .warmUp }
            if sensor.lifetimeDays > 0, start >= sensor.expires.addingTimeInterval(-5 * 60) { return .sensorEnded }
        }
        // Only where the record of checks reaches back that far: before it, nobody knows.
        guard let began = context.polls.began, began <= start else { return .unknown }
        let checked = context.polls.covered(from: start, to: end)
        return checked / end.timeIntervalSince(start) >= checkedShare ? .noSignal : .asleep(context.device)
    }

    /// "2:10 pm – 2:42 pm · 32 min" for the card.
    static func span(_ gap: Gap, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        "\(ClockLabel.time(gap.start, calendar: calendar, locale: locale)) – "
            + "\(ClockLabel.time(gap.end, calendar: calendar, locale: locale)) · \(length(gap.duration))"
    }

    /// "32 min", "1 hr 5 min", "3 hr".
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// The one line VoiceOver hears in the chart's summary. Nil with no gaps.
    /// "Gap in readings from 2:10 pm to 2:42 pm: Mac was asleep." With more than one, the newest:
    /// "3 gaps in readings; the latest from 2:10 pm to 2:42 pm: No signal from LibreLinkUp."
    static func spoken(_ gaps: [Gap], calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String? {
        guard let last = gaps.last else { return nil }
        let from = ClockLabel.time(last.start, calendar: calendar, locale: locale)
        let to = ClockLabel.time(last.end, calendar: calendar, locale: locale)
        let lead = gaps.count == 1 ? "Gap in readings" : "\(gaps.count) gaps in readings; the latest"
        return "\(lead) from \(from) to \(to): \(last.reason.title)."
    }
}

/// When GlucOS was checking LibreLinkUp: each fetch, failed or not, joins the stretch before it if
/// it came soon enough after, so a stretch is time the app was awake and asking. Kept for two days
/// (the chart's longest span is a day), in UserDefaults.
struct PollLog: Codable, Hashable, Sendable {
    struct Span: Codable, Hashable, Sendable {
        var start: Date
        var end: Date
    }

    /// Oldest first, never overlapping.
    private(set) var spans: [Span] = []
    /// The first fetch ever recorded: gaps before it get no reason.
    private(set) var began: Date?

    static let keeps: TimeInterval = 48 * 3600
    /// A fetch this soon after the last one carries the stretch on (or three poll intervals, if
    /// that's longer).
    static let joins: TimeInterval = 5 * 60
    static let defaultsKey = "readingGapPollLog"

    init(spans: [Span] = [], began: Date? = nil) {
        self.spans = spans
        self.began = began ?? spans.first?.start
    }

    /// A fetch at `date`, with the app polling every `interval` seconds.
    mutating func record(_ date: Date, interval: TimeInterval = 60) {
        if began == nil { began = date }
        let join = max(Self.joins, 3 * interval)
        if var last = spans.last, date >= last.start {
            if date.timeIntervalSince(last.end) <= join {
                last.end = max(last.end, date)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: date, end: date))
            }
        } else if spans.isEmpty {
            spans.append(Span(start: date, end: date))
        }
        let cutoff = date.addingTimeInterval(-Self.keeps)
        spans.removeAll { $0.end < cutoff }
    }

    /// Seconds between `start` and `end` that GlucOS was checking.
    func covered(from start: Date, to end: Date) -> TimeInterval {
        guard end > start else { return 0 }
        return spans.reduce(0) { sum, s in
            let lo = max(s.start, start), hi = min(s.end, end)
            return hi > lo ? sum + hi.timeIntervalSince(lo) : sum
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> PollLog {
        guard let data = defaults.data(forKey: defaultsKey),
              let log = try? JSONDecoder().decode(PollLog.self, from: data) else { return PollLog() }
        return log
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Which gaps have drawn in already, so each bridge draws in once (per launch) and then holds.
struct ReadingGapDrawIn: Sendable {
    private(set) var drawn: Set<Date> = []

    /// Whether the bridge for `id` should draw in now: the first time only, and never under
    /// Reduce Motion (it's drawn whole). Either way it counts as drawn from then on.
    mutating func shouldDraw(_ id: Date, reduceMotion: Bool) -> Bool {
        let first = drawn.insert(id).inserted
        return first && !reduceMotion
    }
}
