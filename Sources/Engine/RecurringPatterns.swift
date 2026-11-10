import Foundation

// Times of day when lows or highs keep happening. Observations from the stored readings only:
// "lows were common between 2 and 4 am on 5 of the last 14 nights". Nothing here says why, or
// what to change.

struct RecurringPattern: Hashable, Identifiable {
    enum Kind: String, Hashable { case low, high }

    let kind: Kind
    /// Hour of day the window starts and ends (end exclusive, may wrap past midnight).
    let startHour: Int
    let endHour: Int
    /// Days with the excursion in this window, and days with enough data in it.
    let days: Int
    let daysWithData: Int

    var id: String { "\(kind.rawValue)-\(startHour)-\(endHour)" }
    var share: Double { daysWithData > 0 ? Double(days) / Double(daysWithData) : 0 }
    var hours: Int { (endHour - startHour + 24) % 24 == 0 ? 24 : (endHour - startHour + 24) % 24 }

    /// "2 am – 4 am".
    func windowTitle(calendar: Calendar = .current) -> String {
        func label(_ h: Int) -> String {
            var c = DateComponents()
            c.hour = h % 24
            c.minute = 0
            let date = calendar.date(from: c) ?? Date()
            return date.formatted(.dateTime.hour())
        }
        return "\(label(startHour)) – \(label(endHour))"
    }

    var summary: String {
        let what = kind == .low ? "Lows" : "Highs"
        return "\(what) on \(days) of the last \(daysWithData) days"
    }
}

enum RecurringPatternFinder {
    static let days = 14
    /// A window needs data on at least this many days.
    static let minimumDaysWithData = 7
    /// …and the excursion on at least this many of them,
    static let minimumDays = 3
    /// …making up at least this share.
    static let lowShare = 0.25
    static let highShare = 0.4
    /// An hour counts as low with at least two readings below the low threshold (about 10+
    /// minutes), or one below the urgent-low level.
    static let urgentLow = 54.0
    /// An hour counts as high when at least half its readings are above the high threshold.
    static let highFraction = 0.5

    /// Readings in an hour for it to count as covered (about one every 15 minutes or closer).
    static let readingsPerCoveredHour = 3

    /// Whether the finder has enough recent data to judge: some hour of the day covered on at
    /// least `minimumDaysWithData` days. Without it, "nothing recurring" would mean "can't tell".
    static func hasEnoughHistory(readings: [GlucoseReading], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let cells = self.cells(readings: readings, now: now, calendar: calendar)
        var dataDays = [Set<Int>](repeating: [], count: 24)
        for (day, hours) in cells {
            for (hour, values) in hours where values.count >= readingsPerCoveredHour { dataDays[hour].insert(day) }
        }
        return dataDays.contains { $0.count >= minimumDaysWithData }
    }

    /// Recent readings by [day index][hour].
    private static func cells(readings: [GlucoseReading], now: Date, calendar: Calendar) -> [Int: [Int: [Double]]] {
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))
        var cells: [Int: [Int: [Double]]] = [:]
        for r in readings where r.timestamp >= start && r.timestamp <= now {
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: r.timestamp)).day ?? 0
            let hour = calendar.component(.hour, from: r.timestamp)
            cells[day, default: [:]][hour, default: []].append(r.mgdl)
        }
        return cells
    }

    static func find(readings: [GlucoseReading], low: Double, high: Double, now: Date = Date(),
                     calendar: Calendar = .current) -> [RecurringPattern] {
        let cells = self.cells(readings: readings, now: now, calendar: calendar)
        guard !cells.isEmpty else { return [] }

        // Per hour: which days had data, which had a low, which a high.
        var dataDays = [Set<Int>](repeating: [], count: 24)
        var lowDays = [Set<Int>](repeating: [], count: 24)
        var highDays = [Set<Int>](repeating: [], count: 24)
        for (day, hours) in cells {
            for (hour, values) in hours where values.count >= readingsPerCoveredHour {
                dataDays[hour].insert(day)
                let below = values.filter { $0 < low }.count
                if below >= 2 || values.contains(where: { $0 < urgentLow }) { lowDays[hour].insert(day) }
                if Double(values.filter { $0 > high }.count) / Double(values.count) >= highFraction { highDays[hour].insert(day) }
            }
        }

        let lows = windows(kind: .low, flagged: lowDays, data: dataDays, share: lowShare)
        let highs = windows(kind: .high, flagged: highDays, data: dataDays, share: highShare)
        return (lows.sorted { $0.share > $1.share } + highs.sorted { $0.share > $1.share })
    }

    /// Joins neighbouring qualifying hours (across midnight too) into windows, and counts the days
    /// with the excursion anywhere in each window.
    static func windows(kind: RecurringPattern.Kind, flagged: [Set<Int>], data: [Set<Int>], share: Double) -> [RecurringPattern] {
        func qualifies(_ h: Int) -> Bool {
            data[h].count >= minimumDaysWithData && flagged[h].count >= minimumDays
                && Double(flagged[h].count) / Double(data[h].count) >= share
        }
        let q = (0..<24).map(qualifies)
        guard q.contains(true) else { return [] }
        if q.allSatisfy({ $0 }) {
            return [pattern(kind, hours: Array(0..<24), flagged: flagged, data: data)]
        }
        // Start scanning just after a non-qualifying hour so a window over midnight stays whole.
        let firstGap = q.firstIndex(of: false) ?? 0
        var out: [RecurringPattern] = []
        var run: [Int] = []
        for offset in 1...24 {
            let h = (firstGap + offset) % 24
            if q[h] {
                run.append(h)
            } else if !run.isEmpty {
                out.append(pattern(kind, hours: run, flagged: flagged, data: data))
                run = []
            }
        }
        if !run.isEmpty { out.append(pattern(kind, hours: run, flagged: flagged, data: data)) }
        return out
    }

    private static func pattern(_ kind: RecurringPattern.Kind, hours: [Int], flagged: [Set<Int>], data: [Set<Int>]) -> RecurringPattern {
        let days = hours.reduce(into: Set<Int>()) { $0.formUnion(flagged[$1]) }
        let covered = hours.reduce(into: Set<Int>()) { $0.formUnion(data[$1]) }
        return RecurringPattern(kind: kind, startHour: hours.first ?? 0, endHour: ((hours.last ?? 0) + 1) % 24,
                                days: days.count, daysWithData: covered.count)
    }
}
