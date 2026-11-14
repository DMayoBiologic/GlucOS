import SwiftUI

/// The home screen's one line about how things have been going: today's time in range with the
/// average, and the way into Insights. Replaces the At a glance, Mornings and Forecast accuracy
/// cards that used to sit in the home stack, so the logbook stays near the top.
struct PhoneInsightsRow: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        NavigationLink(value: PhoneRoute.insights) {
            HStack(spacing: DS.Space.md) {
                if let stats = store.glanceStats(.day) {
                    let unit = store.snapshot.unit
                    TimeInRangeRing(stats: stats, lineWidth: 5, showsLabel: false)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Insights").dsFont(.label).foregroundStyle(.secondary)
                        Text("\(Format.percent(stats.timeInRange)) in range · avg \(unit.format(mgdl: stats.meanMgdl)) \(unit.label)")
                            .dsFont(.headline)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("Last 24 hours").dsFont(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Insights").dsFont(.headline).foregroundStyle(.primary)
                        Text("Time in range, mornings and forecast accuracy")
                            .dsFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Space.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(.standard, padding: DS.Space.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityHint("Opens time in range by day, mornings and forecast accuracy")
    }
}

/// How things have been going: time in range over 24 hours to 14 days, each of the last seven
/// days side by side, what GlucOS has learnt about mornings, and how its forecasts turned out.
struct PhoneInsightsView: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.lg) {
                PhoneGlanceCard()
                PhoneDaysCard()
                PhoneMorningCard(outlook: store.outlook)
                PhoneForecastAccuracyCard(outlook: store.outlook)
                Text("Mornings and forecast accuracy appear once GlucOS has enough wake-ups and forecasts to report on.")
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, DS.Space.xs)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.lg)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { PhoneBackdrop(tone: .neutral) }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Each of the last seven days as a column: the share of time below, in and above range stacked
/// to 100%, with the day's time in range under it. Shows at a glance which days went well.
struct PhoneDaysCard: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        let days = PhoneDayStats.lastDays(7, readings: store.readings(lastHours: 7 * 24),
                                          low: store.snapshot.lowMgdl, high: store.snapshot.highMgdl)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: "Day by day", systemImage: "calendar", trailing: "Time in range")
            if days.contains(where: { $0.stats != nil }) {
                HStack(alignment: .bottom, spacing: DS.Space.sm) {
                    ForEach(days) { column($0) }
                }
                .frame(height: 150)
            } else {
                Text("Each day's time in range shows here once GlucOS has a day of readings.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private func column(_ day: PhoneDayStats) -> some View {
        VStack(spacing: DS.Space.xs) {
            GeometryReader { geo in
                let h = geo.size.height
                VStack(spacing: 1) {
                    if let s = day.stats {
                        segment(s.timeAboveRange, h: h, color: GlucoseRange.high.tint)
                        segment(s.timeInRange, h: h, color: GlucoseRange.inRange.tint)
                        segment(s.timeBelowRange, h: h, color: GlucoseRange.low.tint)
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
            }
            Text(day.stats.map { Format.percent($0.timeInRange) } ?? "–")
                .dsFont(.caption)
                .fontWeight(day.isToday ? .semibold : .regular)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(day.label)
                .dsFont(.caption)
                .foregroundStyle(day.isToday ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibility)
    }

    private func segment(_ fraction: Double, h: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(height: max(0, h * fraction - 1))
    }
}

/// One calendar day's readings, for the Day by day card.
struct PhoneDayStats: Identifiable {
    let id: Date
    let label: String
    let isToday: Bool
    let stats: GlucoseStats?

    var accessibility: String {
        let day = isToday ? "Today" : id.formatted(.dateTime.weekday(.wide))
        guard let s = stats else { return "\(day): no readings" }
        return "\(day): \(Format.percent(s.timeInRange)) in range, \(Format.percent(s.timeBelowRange)) below, \(Format.percent(s.timeAboveRange)) above"
    }

    /// The last `count` days, oldest first, ending today. A day with under an hour of readings has
    /// no stats, so a sensor change doesn't show as a perfect or terrible day.
    static func lastDays(_ count: Int, readings: [GlucoseReading], low: Double, high: Double,
                         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [PhoneDayStats] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [GlucoseReading]] = [:]
        for r in readings { byDay[calendar.startOfDay(for: r.timestamp), default: []].append(r) }
        return (0..<count).reversed().compactMap { back -> PhoneDayStats? in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let rs = byDay[start] ?? []
            let stats = GlucoseStats.compute(rs, low: low, high: high).flatMap { $0.spanHours >= 1 ? $0 : nil }
            return PhoneDayStats(id: start, label: back == 0 ? "Today" : start.formatted(.dateTime.weekday(.narrow)),
                                 isToday: back == 0, stats: stats)
        }
    }
}
