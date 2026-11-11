import SwiftUI

// The iPhone's cards. Same surfaces, colours and type as the Mac popover: the reading's range
// decides the hue, a stale reading turns grey and is crossed through, and forecasts are always
// grey and marked "≈".

// MARK: - Hero

struct PhoneHeroCard: View {
    @EnvironmentObject var store: GlucoseStore
    private let textScale = DSScaledValue()

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let stale = s.isStale(at: now)
            let tone = s.displayTone(at: now)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    if let range = s.range { RangeBadge(range: range, stale: stale) }
                    if let streak = s.rangeStreak(at: now), streak.duration >= 5 * 60 {
                        Text("for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.streak(streak.duration))")
                            .dsFont(.label)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let cur = s.current {
                    HStack(alignment: .center, spacing: DS.Space.md) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            valueRow(cur, stale: stale, tint: tone.color)
                            trendRow(cur, stale: stale)
                        }
                        Spacer(minLength: DS.Space.sm)
                        TrendDial(trend: stale ? .unknown : cur.trend, tint: tone.color, size: 72)
                            .opacity(stale ? 0.6 : 1)
                            .accessibilityHidden(true)
                    }
                    freshness(cur, stale: stale, now: now)
                } else {
                    Text(store.statusLine)
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DS.Space.lg)
                }
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { DSSurface(style: .hero(tone), radius: DS.Radius.hero) }
            .dsShadow(.medium, tint: stale ? nil : tone.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(s.current == nil ? store.statusLine : s.accessibilitySummary(at: now))
            .accessibilityAddTraits(.updatesFrequently)
            .contextMenu {
                Button("Copy Reading", systemImage: "doc.on.doc") { store.copyReadingToClipboard() }
                Button("Refresh Now", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            }
        }
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
            Text(s.unit.format(mgdl: cur.mgdl))
                .font(.system(size: (64 * (1 + (textScale.scale - 1) * 0.4)).rounded(), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tint))
                .overlay {
                    if stale {
                        Capsule().fill(Color.secondary.opacity(0.7)).frame(height: 3).rotationEffect(.degrees(-8))
                    }
                }
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
                }
            }
        }
        .dsFont(.headline)
    }

    private func freshness(_ cur: GlucoseReading, stale: Bool, now: Date) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
            Text(stale ? "Last reading \(PopoverFormat.ageAgo(cur.age(at: now)))" : "Updated \(PopoverFormat.ageAgo(cur.age(at: now)))")
            Text("· \(cur.timestamp.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
        }
        .dsFont(.caption)
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .monospacedDigit()
    }
}

// MARK: - Chart

struct PhoneChartCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let s = store.snapshot
        let hours = Double(settings.chartHours)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Eyebrow(title: "Last \(settings.chartHours) hours", systemImage: "chart.xyaxis.line")
                Picker("Hours", selection: $settings.chartHours) {
                    ForEach([3, 6, 12], id: \.self) { Text("\($0)h").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }
            GlucoseChart(readings: store.readings(lastHours: hours), unit: s.unit, lowMgdl: s.lowMgdl,
                         highMgdl: s.highMgdl, hours: hours, showAxes: true, interactive: true,
                         forecast: settings.showForecast ? (s.currentOutlook()?.forecast ?? []) : [])
                .frame(height: 220)
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }
}

// MARK: - Outlook

struct PhoneOutlookCard: View {
    @EnvironmentObject var store: GlucoseStore
    let outlook: OutlookSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Eyebrow(title: "Outlook", systemImage: "chart.line.uptrend.xyaxis", trailing: outlook.basis.title)
            OutlookSummaryRow(outlook: outlook, unit: store.snapshot.unit, lowMgdl: store.snapshot.lowMgdl)
            if let low = outlook.lowExpectedAt {
                Label("Low expected around \(OutlookFormat.time(low))", systemImage: "exclamationmark.triangle.fill")
                    .dsFont(.label)
                    .foregroundStyle(Tone.warning.textColor)
            }
            Text("A forecast, not a reading. Never use it to decide a dose.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
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
                    TimeInRangeRing(stats: stats, lineWidth: 11)
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
            ProgressRing(fraction: fraction, tint: tone == .neutral ? Palette.brand : tone.color, lineWidth: 5)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Sensor").dsFont(.label).foregroundStyle(.secondary)
                Text("\(Format.days(days)) left")
                    .dsFont(.headline)
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.textColor))
            }
            Spacer()
            Text("Ends \(sensor.expires.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
