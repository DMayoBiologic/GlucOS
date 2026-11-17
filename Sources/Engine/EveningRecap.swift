import Foundation

// The evening recap: one opt-in notification a day, at a time the person picks (9 pm unless they
// change it), with that day's time in range, lows, highs and average glucose. Tapping it opens
// Insights on a "Today" card with the same figures (docs/EveningRecap.md).
//
// Method:
// 1. The figures run from local midnight to the newest reading at or before the recap time, read
//    the way "Today so far" reads them (`TodaySoFar.figures`): 5-minute buckets, an hour of the day
//    gone, and readings in half of its 15-minute slots. Otherwise there's no recap that day.
// 2. A low is a run below the low threshold of 15 minutes or more, a high a run above the high
//    threshold of 15 minutes or more, a gap of over 30 minutes ending either (`TodaySoFar.lowSpans`
//    and `highSpans`, as the Insights Lows and Highs cards count them).
// 3. A local notification's words are fixed when it's scheduled, so each app schedules today's
//    recap again whenever a reading moves the figures (at most once per 5 minutes of readings).
//    What fires is the latest figures it had, and its subtitle says which hours they cover, so a
//    phone that stopped refreshing at 6 pm says "Midnight to 6 pm" rather than pretending.
//
// Observational only, like Insights: it reports the day and never suggests a change to insulin or
// settings. Plain Foundation, so it's unit-tested.

struct EveningRecap: Hashable {
    /// Local midnight of the day the recap covers.
    let day: Date
    /// Minutes after midnight the figures run to (the newest reading's clock time).
    let minute: Int
    /// Share of 5-minute buckets inside the target, 0...1.
    let timeInRange: Double
    let meanMgdl: Double
    let lows: Int
    let highs: Int

    /// 9 pm.
    static let defaultMinute = 21 * 60
    /// The notification's identifier: one pending recap at a time, replaced on every update.
    static let identifier = "glucos.recap"
    /// `userInfo["kind"]` on the notification, so a tap can be told apart from an alert's.
    static let kind = "recap"

    // MARK: Compute

    /// Today's figures up to `minute` after midnight (or to `now`, if that's earlier), or nil when
    /// today doesn't have enough readings yet.
    static func compute(readings: [GlucoseReading], low: Double, high: Double, minute: Int = defaultMinute,
                        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> EveningRecap? {
        let day = calendar.startOfDay(for: now)
        let end = min(now, time(minute, on: now, calendar: calendar))
        guard let newest = readings.last(where: { $0.timestamp <= end && $0.mgdl > 0 }),
              newest.timestamp >= day else { return nil }
        let span = newest.timestamp.timeIntervalSince(day)
        guard span >= Double(TodaySoFar.minimumMinutes) * 60 else { return nil }
        let todays = readings.filter { $0.timestamp >= day && $0.timestamp <= newest.timestamp && $0.mgdl > 0 }
        guard let f = TodaySoFar.figures(todays, from: day, span: span, low: low, high: high) else { return nil }
        let points = buckets(todays, from: day)
        return EveningRecap(day: day, minute: Int(span / 60), timeInRange: f.timeInRange, meanMgdl: f.meanMgdl,
                            lows: f.lows, highs: TodaySoFar.highSpans(points, high: high).count)
    }

    /// Readings averaged into 5-minute buckets from `start`, in time order, as `TodaySoFar` does.
    static func buckets(_ readings: [GlucoseReading], from start: Date) -> [(Date, Double)] {
        let size = Double(TodaySoFar.bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.timestamp >= start {
            let key = Int((r.timestamp.timeIntervalSince(start) / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        return sums.keys.sorted().map { k in
            (start.addingTimeInterval(Double(k) * size), sums[k]!.sum / Double(sums[k]!.n))
        }
    }

    // MARK: Schedule

    /// A stored time of day, kept inside the day. Nil (never set) or out of range is 9 pm.
    static func sanitized(_ minute: Int?) -> Int {
        guard let minute, (0..<1440).contains(minute) else { return defaultMinute }
        return minute
    }

    /// When today's recap goes out, or nil once that time has passed (the next one is scheduled
    /// from tomorrow's readings).
    static func fireDate(minute: Int, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let at = time(minute, on: now, calendar: calendar)
        return at > now ? at : nil
    }

    /// The clock time `minute` after midnight on the day of `date`, by the clock (so 9 pm is still
    /// 9 pm on the day daylight saving starts or ends).
    static func time(_ minute: Int, on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let m = sanitized(minute)
        let day = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)
            ?? day.addingTimeInterval(Double(m) * 60)
    }

    /// What the scheduler last scheduled from, so a reading that changes nothing schedules nothing:
    /// the newest reading floored to 5 minutes, the day, the target, the unit and the time.
    struct Key: Hashable {
        var day: Date
        var newest: Date?
        var low: Double
        var high: Double
        var unit: GlucoseUnit
        var minute: Int
    }

    static func key(readings: [GlucoseReading], low: Double, high: Double, unit: GlucoseUnit, minute: Int,
                    now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 300).rounded(.down) * 300) }
        return Key(day: calendar.startOfDay(for: now), newest: newest, low: low, high: high, unit: unit,
                   minute: sanitized(minute))
    }
}

// MARK: - Words

/// The notification's and the Today card's words. Values use the person's unit; times read as
/// people say them ("8:55 pm").
enum EveningRecapText {
    static let title = "Evening recap"
    /// The Insights card's title.
    static let cardTitle = "Today"

    /// "Midnight to 8:55 pm": the hours the figures cover, on the notification's subtitle.
    static func period(_ r: EveningRecap) -> String {
        "Midnight to \(DayPatternText.clock(r.minute / 5 * 5))"
    }

    /// "78% in range, average 7.4 mmol/L. 1 low and no highs."
    static func body(_ r: EveningRecap, unit: GlucoseUnit) -> String {
        "\(Format.percent(r.timeInRange)) in range, average \(unit.format(mgdl: r.meanMgdl, withUnit: true)). \(counts(r))."
    }

    /// "1 low and no highs", capitalised: "No lows and 2 highs".
    static func counts(_ r: EveningRecap) -> String {
        let s = "\(count(r.lows, "low")) and \(count(r.highs, "high"))"
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// "no lows", "1 low", "3 lows".
    static func count(_ n: Int, _ noun: String) -> String {
        n == 0 ? "no \(noun)s" : (n == 1 ? "1 \(noun)" : "\(n) \(noun)s")
    }

    /// A tile's figure: "None" or the count.
    static func countValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    /// The whole recap for VoiceOver.
    static func spoken(_ r: EveningRecap, unit: GlucoseUnit) -> String {
        "Today, \(period(r).lowercased()). \(Int((r.timeInRange * 100).rounded())) percent in range, average \(unit.format(mgdl: r.meanMgdl)) \(unit.label). \(counts(r))."
    }

    /// "9 pm", "8:30 pm": the time in Settings' footer.
    static func time(_ minute: Int) -> String { DayPatternText.clock(EveningRecap.sanitized(minute)) }

    /// The footer under the switch in Settings.
    static func settingsFooter(minute: Int) -> String {
        "At \(time(minute)) each day: time in range, lows, highs and the average since midnight. Observations, not advice."
    }
}
