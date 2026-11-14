import SwiftUI

// The iPhone's cards. Same surfaces, colours and type as the Mac popover: the reading's range
// decides the hue, a stale reading turns grey and is crossed through, and forecasts are always
// grey and marked "≈".

// MARK: - Hero

/// The stage (docs/Redesign.md §7.1): the reading on the screen's range field rather than in a
/// card. Range pill and streak, the value with its needle, the range rail with the forecast's ghost
/// marker, the forecast note, and the freshness meter. A new reading rolls the value, swings the
/// needle, glides the rail marker and sends one ripple out of the needle.
struct PhoneHeroCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let textScale = DSScaledValue()
    /// Bumped on each new reading to play one soft ripple around the card, like the Mac popover.
    @State private var ripple = 0

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let stale = s.isStale(at: now)
            let tone = s.displayTone(at: now)
            let outlook = settings.showForecast && !stale ? s.currentOutlook(at: now) : nil
            let headline = outlook.flatMap(OutlookFormat.headlineSample)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    if let range = s.range {
                        RangeBadge(range: range, stale: stale)
                            .id(stale ? "stale" : range.label)
                            .transition(.push(from: (s.current?.trend.isFalling ?? false) ? .top : .bottom))
                    }
                    if let streak = s.rangeStreak(at: now), streak.duration >= 5 * 60 {
                        Text("for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.streak(streak.duration))")
                            .dsFont(.label)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
                .dsAnimation(.standard, value: s.range)
                if let cur = s.current {
                    HStack(alignment: .center, spacing: DS.Space.md) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            valueRow(cur, stale: stale, tint: tone.color)
                            trendRow(cur, stale: stale)
                        }
                        Spacer(minLength: DS.Space.sm)
                        TrendDial(trend: stale ? .unknown : cur.trend, tint: tone.color, size: 80)
                            .opacity(stale ? 0.6 : 1)
                            .readingRipple(trigger: ripple, in: Circle(), tint: tone.color)
                            .accessibilityHidden(true)
                    }
                    RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: stale,
                              forecastMgdl: headline?.sample.mgdl, thickness: 6, unit: s.unit)
                        .padding(.vertical, DS.Space.xxs)
                    if let outlook, headline != nil || outlook.lowExpectedAt != nil {
                        ForecastNote(unit: s.unit, headline: headline.map { (minutes: $0.minutes, mgdl: $0.sample.mgdl) },
                                     lowExpectedAt: outlook.lowExpectedAt, readingDate: cur.timestamp)
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    freshness(cur, stale: stale, now: now)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            // An urgent low gets a rim as well as its colour, so it reads without colour vision.
            .padding(s.range == .urgentLow && !stale ? DS.Space.md : 0)
            .overlay {
                if s.range == .urgentLow && !stale {
                    RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous)
                        .strokeBorder(Palette.crimson, lineWidth: 2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(s.current == nil ? store.statusLine
                                : s.accessibilitySummary(at: now) + forecastSentence(outlook, headline: headline))
            .accessibilityAddTraits(.updatesFrequently)
            .contextMenu {
                Button("Copy Reading", systemImage: "doc.on.doc") { store.copyReadingToClipboard() }
                Button("Refresh Now", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            }
        }
        .onChange(of: s.current?.timestamp) { old, new in
            guard old != nil, new != nil, old != new, !reduceMotion else { return }
            ripple += 1
        }
        // A tap you can feel when a new reading, with the app open, crosses into a low (warning)
        // or comes back into range (success). Nothing on first load or for other changes.
        .sensoryFeedback(trigger: s.range) { old, new in
            guard let old, let new, old != new else { return nil }
            switch new {
            case .low, .urgentLow: return .warning
            case .inRange: return .success
            case .high, .veryHigh: return nil
            }
        }
    }

    /// Before the first reading: the shape of the card with a placeholder number, so the screen
    /// doesn't jump when it arrives, and what's happening in words. A connection problem has its
    /// own banner above with the fix.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
                Text("–.–")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                Text(s.unit.label).dsFont(.callout).fontWeight(.semibold).foregroundStyle(.tertiary)
            }
            HStack(spacing: DS.Space.xs) {
                if store.connectionProblem == nil { ProgressView().controlSize(.small) }
                Text(store.connectionProblem == nil && store.isRefreshing ? "Getting your latest reading…" : store.statusLine)
            }
            .dsFont(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
            Text(s.unit.format(mgdl: cur.mgdl))
                .font(.system(size: (96 * (1 + (textScale.scale - 1) * 0.4)).rounded(), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tint))
                // The line draws across as the data goes stale (docs/Redesign.md §4.3).
                .staleStrike(stale)
                .contentTransition(.numericText(value: cur.mgdl))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(s.unit.label)
                .dsFont(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private func trendRow(_ cur: GlucoseReading, stale: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            if stale {
                Text("Trend unavailable").foregroundStyle(.secondary)
            } else {
                TrendSymbol(trend: cur.trend)
                Text(cur.trend.description)
                if let d = s.deltaMgdl {
                    Text(s.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: d))
                }
            }
        }
        .dsFont(.headline)
    }

    /// What the forecast note says, for VoiceOver. Empty when no note is shown.
    private func forecastSentence(_ outlook: OutlookSnapshot?,
                                  headline: (minutes: Int, sample: ForecastSample)?) -> String {
        guard let outlook, let cur = s.current else { return "" }
        if let low = outlook.lowExpectedAt {
            return ". Low expected in about \(ForecastNote.roundedMinutes(low.timeIntervalSince(cur.timestamp))) minutes"
        }
        guard let headline else { return "" }
        return ". Forecast about \(s.unit.format(mgdl: headline.sample.mgdl)) in \(headline.minutes) minutes"
    }

    private func tint(stale: Bool) -> Color { stale ? Tone.warning.color : Palette.neutral }

    private func freshness(_ cur: GlucoseReading, stale: Bool, now: Date) -> some View {
        HStack(spacing: DS.Space.xs) {
            if stale {
                Image(systemName: "clock.badge.exclamationmark")
            } else {
                LiveDot(live: true).padding(.trailing, 2)
            }
            FreshnessMeter(readingDate: cur.timestamp, stale: stale, tint: tint(stale: stale), width: 36)
                .padding(.trailing, DS.Space.xxs)
            Text(stale ? "Last reading \(PopoverFormat.ageAgo(cur.age(at: now)))" : "Updated \(PopoverFormat.ageAgo(cur.age(at: now)))")
            Text("· \(ClockLabel.dayTime(cur.timestamp, now: now))").foregroundStyle(.tertiary)
        }
        .dsFont(.caption)
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .monospacedDigit()
    }
}

// MARK: - On board

/// What's still acting and where glucose is heading, as three tiles under the reading: fast-acting
/// insulin, carbs and the forecast. Worked out on the view's clock from the logbook, like the Mac's
/// Overview, so the numbers keep counting down between readings. Estimates only, never advice.
struct PhoneOnBoardCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let onBoard = OnBoardNow(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts, at: now)
            let s = store.snapshot
            HStack(alignment: .top, spacing: DS.Space.sm) {
                if onBoard.showsInsulin(therapy: settings.therapy) {
                    insulinTile(onBoard, now: now)
                }
                carbsTile(onBoard, now: now)
                forecastTile(s.currentOutlook(at: now), unit: s.unit, lowMgdl: s.lowMgdl, stale: s.isStale(at: now))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func insulinTile(_ o: OnBoardNow, now: Date) -> some View {
        let active = o.insulin.onBoard >= 0.05
        var caption = "None acting"
        if active {
            if let peak = o.insulin.peakAt, peak > now { caption = "Peaks \(ClockLabel.time(peak))" }
            else if let done = o.insulin.mostlyDoneAt { caption = "Done ~\(ClockLabel.time(done))" }
            else { caption = "Winding down" }
        }
        let basal = o.background.isActive ? "Basal ≈ \(OnBoardFormatPhone.number(o.background.onBoard)) u" : nil
        return OnBoardTile(title: "Insulin", systemImage: "syringe", tint: Palette.insulin,
                           value: active ? OnBoardFormatPhone.number(o.insulin.onBoard) : "0", unit: "u",
                           fraction: active && o.insulin.unitsGiven > 0 ? o.insulin.onBoard / o.insulin.unitsGiven : nil,
                           caption: caption, detail: basal,
                           accessibility: active ? "Insulin on board, \(OnBoardFormatPhone.number(o.insulin.onBoard)) units. \(caption)" : "No fast-acting insulin on board")
    }

    private func carbsTile(_ o: OnBoardNow, now: Date) -> some View {
        let active = o.carbs.onBoard >= 1
        var caption = "None absorbing"
        if active {
            caption = o.carbs.mostlyAbsorbedAt.map { "Done ~\(ClockLabel.time($0))" } ?? "Nearly absorbed"
        }
        return OnBoardTile(title: "Carbs", systemImage: "fork.knife", tint: Palette.food,
                           value: active ? "\(Int(o.carbs.onBoard.rounded()))" : "0", unit: "g", fraction: nil,
                           caption: caption, detail: o.carbs.uncountedFood ? "Some food has no carbs" : nil,
                           accessibility: active ? "Carbs on board, \(Int(o.carbs.onBoard.rounded())) grams. \(caption)" : "No carbs on board")
    }

    @ViewBuilder
    private func forecastTile(_ outlook: OutlookSnapshot?, unit: GlucoseUnit, lowMgdl: Double, stale: Bool) -> some View {
        if let outlook, let headline = OutlookFormat.headlineSample(outlook) {
            let s = headline.sample
            let low = outlook.lowExpectedAt
            OnBoardTile(title: "In \(headline.minutes) min", systemImage: low == nil ? "chart.line.uptrend.xyaxis" : "exclamationmark.triangle.fill",
                        tint: Palette.stale, valueTint: low == nil ? nil : Tone.warning.textColor,
                        value: OutlookFormat.approx(s.mgdl, unit: unit), unit: nil, fraction: nil,
                        caption: low.map { "Low ~\(ClockLabel.time($0))" } ?? OutlookFormat.range(s, unit: unit),
                        captionTone: low == nil ? .neutral : .warning,
                        detail: (outlook.basis == .trend ? "Trend" : "Trend + logbook") + (outlook.morning != nil ? " + morning" : outlook.basis == .trend ? " only" : ""),
                        accessibility: "Forecast, not a reading. In \(headline.minutes) minutes about \(unit.format(mgdl: s.mgdl, withUnit: true)), likely \(OutlookFormat.range(s, unit: unit))\(low.map { ". Low expected around \(ClockLabel.time($0))" } ?? "")")
        } else {
            OnBoardTile(title: "Forecast", systemImage: "chart.line.uptrend.xyaxis", tint: Palette.stale,
                        value: "–", unit: nil, fraction: nil,
                        caption: stale ? "Needs a new reading" : "Not available", detail: nil,
                        accessibility: "No forecast right now")
        }
    }
}

enum OnBoardFormatPhone {
    /// "2.4", or "12" from 10 up.
    static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0)))
    }
}

private struct OnBoardTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    var valueTint: Color? = nil
    let value: String
    let unit: String?
    let fraction: Double?
    let caption: String
    var captionTone: Tone = .neutral
    let detail: String?
    let accessibility: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(valueTint ?? tint)
            }
            .dsFont(.label)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xxs) {
                Text(value)
                    .dsFont(.metricValueLarge)
                    .foregroundStyle(valueTint ?? tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit { Text(unit).dsFont(.unit).foregroundStyle(.secondary) }
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 4)
            }
            Spacer(minLength: 0)
            Text(caption)
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(captionTone == .neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(captionTone.textColor))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let detail {
                Text(detail).dsFont(.caption).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard(.standard, padding: DS.Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Chart

/// The trace with logged insulin and food marked along the bottom, the forecast past "Now", and a
/// one-line forecast summary under it. Replaces the separate Outlook card, so the forecast's
/// number sits next to the line it describes.
struct PhoneChartCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    private static let choices = [3, 6, 12, 24]

    var body: some View {
        let s = store.snapshot
        let hours = Double(settings.chartHours)
        let outlook = settings.showForecast ? s.currentOutlook() : nil
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Eyebrow(title: "Glucose", systemImage: "chart.xyaxis.line")
                SlidingSegments(selection: $settings.chartHours, options: Self.choices) { "\($0)h" }
                    .frame(maxWidth: 200)
                    .sensoryFeedback(.selection, trigger: settings.chartHours)
                    .accessibilityLabel("Chart hours")
            }
            GlucoseChart(readings: store.readings(lastHours: hours), unit: s.unit, lowMgdl: s.lowMgdl,
                         highMgdl: s.highMgdl, hours: hours, showAxes: true, interactive: true,
                         forecast: outlook?.forecast ?? [], events: events(hours: hours),
                         timeLabelCount: hours <= 3 ? 4 : 6, marksNow: true)
                .frame(height: 260)
                // Switching 3h / 6h / 12h / 24h glides the trace to its new scale.
                .dsAnimation(.standard, value: settings.chartHours)
            legend(outlook)
            if let outlook { forecastLine(outlook, unit: s.unit) }
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private func events(hours: Double) -> [ChartLogMarker] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        var out: [ChartLogMarker] = []
        for d in logbook.doses where d.timestamp >= cutoff {
            out.append(ChartLogMarker(id: d.id, date: d.timestamp, systemImage: d.viaPump ? "cross.vial.fill" : "syringe.fill",
                                  tint: Palette.insulin,
                                  label: "\(LogFormat.units(d.units)) \(d.displayName) at \(ClockLabel.time(d.timestamp))"))
        }
        for c in logbook.contexts where c.isWake && c.timestamp >= cutoff {
            out.append(ChartLogMarker(id: c.id, date: c.timestamp, systemImage: ContextTag.wokeUp.systemImage,
                                      tint: Palette.context, lane: 2,
                                      label: "Woke up at \(ClockLabel.time(c.timestamp))"))
        }
        for m in logbook.meals where m.timestamp >= cutoff {
            out.append(ChartLogMarker(id: m.id, date: m.timestamp, systemImage: "fork.knife", tint: Palette.food, lane: 1,
                                  label: m.carbs > 0 ? "\(LogFormat.grams(m.carbs)) carbs at \(ClockLabel.time(m.timestamp))"
                                                     : "Food at \(ClockLabel.time(m.timestamp))"))
        }
        return out
    }

    @ViewBuilder
    private func legend(_ outlook: OutlookSnapshot?) -> some View {
        HStack(spacing: DS.Space.md) {
            LegendText(color: Palette.insulin, text: "Insulin")
            LegendText(color: Palette.food, text: "Food")
            if outlook != nil {
                HStack(spacing: DS.Space.xs) {
                    Capsule().fill(Palette.stale).frame(width: 12, height: 2)
                    Text("Forecast")
                }
                .dsFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func forecastLine(_ outlook: OutlookSnapshot, unit: GlucoseUnit) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let low = outlook.lowExpectedAt {
                Label("Low expected around \(ClockLabel.time(low))", systemImage: "exclamationmark.triangle.fill")
                    .dsFont(.label)
                    .foregroundStyle(Tone.warning.textColor)
            }
            if let morning = outlook.morning {
                Label(MorningFormat.todayLine(morning, unit: unit), systemImage: ContextTag.wokeUp.systemImage)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Forecast from \(outlook.basis.title.lowercased()). An estimate, not a reading: never use it to decide a dose.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - At a glance

struct PhoneGlanceCard: View {
    @EnvironmentObject var store: GlucoseStore
    @State private var window: GlanceWindow = .day

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Eyebrow(title: "At a glance", systemImage: "circle.dashed")
                Picker("Period", selection: $window) {
                    ForEach(GlanceWindow.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            if let stats = store.glanceStats(window) {
                let unit = store.snapshot.unit
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    TimeInRangeRing(stats: stats, lineWidth: 11, drawsIn: true)
                        .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        StatTile("Average", value: unit.format(mgdl: stats.meanMgdl), unit: unit.label) { EmptyView() }
                        HStack(spacing: DS.Space.lg) {
                            StatTile("GMI", value: String(format: "%.1f", stats.gmiPercent), unit: "%") { EmptyView() }
                            StatTile("CV", value: Format.percent(stats.coefficientOfVariation),
                                     tone: stats.coefficientOfVariation > 0.36 ? .warning : .neutral) { EmptyView() }
                        }
                    }
                }
                TimeInRangeBar(stats: stats)
                HStack {
                    LegendText(color: GlucoseRange.low.tint, text: "Below \(Format.percent(stats.timeBelowRange))")
                    Spacer()
                    LegendText(color: GlucoseRange.inRange.tint, text: "In range \(Format.percent(stats.timeInRange))")
                    Spacer()
                    LegendText(color: GlucoseRange.high.tint, text: "Above \(Format.percent(stats.timeAboveRange))")
                }
            } else {
                Text("Readings will appear here as GlucOS collects them.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }
}

private struct LegendText: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).monospacedDigit()
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Sensor

struct PhoneSensorCard: View {
    let sensor: SensorInfo

    var body: some View {
        let days = sensor.daysRemaining()
        let fraction = days / Double(max(1, sensor.lifetimeDays))
        let tone: Tone = days < 1 ? .critical : days < 2 ? .warning : .neutral
        HStack(spacing: DS.Space.md) {
            ProgressRing(fraction: fraction, tint: tone == .neutral ? Palette.brand : tone.color, lineWidth: 5, drawsIn: true)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Sensor").dsFont(.label).foregroundStyle(.secondary)
                Text("\(Format.days(days)) left")
                    .dsFont(.headline)
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.textColor))
            }
            Spacer()
            Text("Ends \(ClockLabel.dayTime(sensor.expires, now: Date()))")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
