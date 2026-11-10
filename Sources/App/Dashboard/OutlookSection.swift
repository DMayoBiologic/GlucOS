import SwiftUI
import Charts

/// Dashboard page: where glucose may be heading, the insulin and carbs still acting, how
/// accurate past forecasts have been, what GlucOS has learnt from the logs, and recurring
/// times of day for lows and highs. Every number here is an estimate and says so.
struct OutlookSection: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var outlookStore: OutlookStore
    @EnvironmentObject var settings: AppSettings
    let onLog: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // Worked out before the page, which re-runs its content when the window resizes.
        let snapshot = store.snapshot
        let unit = snapshot.unit
        let outlook = outlookStore.outlook
        let current = snapshot.currentOutlook(at: now)
        let recent = GlucoseAnalytics.slice(store.archive, from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(60))
        let model = outlookStore.model
        DashboardPage { layout in
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                SectionHeader("Next Few Hours", systemImage: "chart.line.uptrend.xyaxis",
                              subtitle: subtitle(current)) {
                    if outlookStore.isLearning {
                        HStack(spacing: DS.Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Learning from your history…").dsFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if recent.isEmpty {
                    EmptyStateView(systemImage: "drop", title: "No Recent Readings",
                                   message: "The forecast starts once readings are coming in.")
                } else {
                    GlucoseChart(readings: recent, unit: unit, lowMgdl: snapshot.lowMgdl, highMgdl: snapshot.highMgdl,
                                 hours: 3, interactive: true, forecast: current?.forecast ?? [])
                        .frame(height: layout.chartHeight(reserving: 420, minimum: 220, maximum: 380))
                    legend(current)
                }
                if let current {
                    ForecastTiles(outlook: current, snapshot: snapshot, now: now)
                } else if let reason = snapshot.outlook?.unavailableReason ?? (snapshot.isStale(at: now) ? ForecastUnavailable.stale(age: 0).message : nil) {
                    StatusBanner(severity: .info, systemImage: "info.circle", title: "No forecast right now", message: reason,
                                 density: .compact)
                }
                if let o = outlook, !o.limitations.isEmpty, current != nil {
                    LimitationList(limitations: o.limitations)
                }
            }
            .dashboardCard()

            CardGrid(minColumnWidth: 360, maxColumns: 2, spacing: layout.gutter) {
                if let o = outlook {
                    InsulinActivityCard(insulin: o.insulin, carbs: o.carbs, now: now, onLog: onLog)
                }
                AccuracyCard(calibration: model.calibration, unit: unit)
            }

            CardGrid(minColumnWidth: 360, maxColumns: 2, spacing: layout.gutter) {
                LearntEffectsCard(profile: model.profile, unit: unit)
                RecurringPatternsCard(patterns: model.patterns, hasHistory: store.archive.count > 200)
            }

            HistoryNote(text: "Forecasts assume nothing new is eaten or dosed, and that background insulin (long-acting or a pump's basal) holds glucose level. Timing uses typical curves for each insulin type. GlucOS never suggests a dose.")
            Disclaimer()
        }
    }

    private func subtitle(_ o: OutlookSnapshot?) -> String {
        guard let o else { return "Where glucose may be heading, from the trend and what you've logged" }
        let mins = Int(o.horizon / 60)
        return "Estimate for the next \(mins) minutes, from \(o.basis.title.lowercased())"
    }

    @ViewBuilder
    private func legend(_ o: OutlookSnapshot?) -> some View {
        HStack(spacing: DS.Space.lg) {
            LegendItem(color: GlucoseRange.inRange.tint, label: "Readings")
            if o?.forecast.isEmpty == false {
                LegendItem(color: Palette.stale, label: "Forecast", detail: "dashed")
                LegendItem(color: Palette.stale.opacity(0.35), label: "Likely range", detail: "8 in 10 past forecasts landed inside")
            }
        }
    }
}

// MARK: - Tiles

private struct ForecastTiles: View {
    let outlook: OutlookSnapshot
    let snapshot: GlucoseSnapshot
    let now: Date

    var body: some View {
        let unit = snapshot.unit
        CardGrid(minColumnWidth: 150, maxColumns: 4, spacing: DS.Space.md, evenRows: true) {
            ForEach([15, 30, 60, 120], id: \.self) { m in
                if let s = outlook.sample(minutesAhead: Double(m)) {
                    StatTile("In \(m < 60 ? "\(m) min" : "\(m / 60) h")", value: OutlookFormat.approx(s.mgdl, unit: unit),
                             unit: unit.label, caption: "Likely \(OutlookFormat.range(s, unit: unit))",
                             tone: .stale, boxed: true,
                             help: "Forecast, not a reading. About 8 in 10 past forecasts this far ahead landed in the likely range.")
                }
            }
        }
        if let low = outlook.lowExpectedAt {
            StatusBanner(severity: .warning, systemImage: "arrow.down.right",
                         title: "Heading low",
                         message: "The forecast goes below \(unit.format(mgdl: snapshot.lowMgdl, withUnit: true)) around \(OutlookFormat.time(low)). It's an estimate: check your reading and follow your usual plan.",
                         density: .compact)
        } else if let possible = outlook.lowPossibleAt {
            StatusBanner(severity: .info, systemImage: "arrow.down.right",
                         title: "A low is possible",
                         message: "The likely range reaches below \(unit.format(mgdl: snapshot.lowMgdl, withUnit: true)) from around \(OutlookFormat.time(possible)).",
                         density: .compact)
        }
    }
}

private struct LimitationList: View {
    let limitations: [ForecastLimitation]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(limitations, id: \.self) { l in
                Label(l.message, systemImage: l.forcesTrendOnly ? "exclamationmark.circle" : "info.circle")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Insulin and carbs still acting

private struct InsulinActivityCard: View {
    let insulin: InsulinActivity
    let carbs: CarbActivity
    let now: Date
    let onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader("Insulin Still Acting", systemImage: "syringe",
                          subtitle: "Fast-acting insulin you've logged, on typical timing for its type")
            if insulin.doseCount == 0 && insulin.curve.allSatisfy({ $0.remaining < 0.01 }) {
                EmptyStateView(systemImage: "syringe", title: "Nothing Acting",
                               message: insulin.backgroundInsulinLogged
                                   ? "No fast-acting insulin in the last 6 hours. Long-acting insulin isn't shown here."
                                   : "Log fast-acting insulin to see how much is still working and when it winds down.",
                               actionTitle: "Log…", action: onLog)
            } else {
                CardGrid(minColumnWidth: 120, maxColumns: 3, spacing: DS.Space.md, evenRows: true) {
                    StatTile("On board", value: OutlookFormat.units(insulin.onBoard), caption: "of \(OutlookFormat.units(insulin.unitsGiven)) logged",
                             tone: .custom(Palette.insulin), boxed: true,
                             help: "Units not yet acted, from doses still working.")
                    StatTile("Peak", value: insulin.peakAt.map(OutlookFormat.time) ?? "Passed",
                             caption: insulin.peakAt == nil ? "Now winding down" : "Strongest effect", boxed: true)
                    StatTile("Mostly done", value: insulin.mostlyDoneAt.map(OutlookFormat.time) ?? "Done",
                             caption: insulin.finishedAt.map { "Fully by \(OutlookFormat.time($0))" }, boxed: true,
                             help: "When less than 10% of what was given (or 0.1 u) is left.")
                }
                ActivityChart(curve: insulin.curve, now: now, color: Palette.insulin, unitLabel: "u")
                    .frame(height: 140)
            }
            if carbs.mealCount > 0 {
                DSDivider()
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "fork.knife").foregroundStyle(Palette.food)
                    Text("\(Int(carbs.onBoard.rounded())) g of carbs still being absorbed")
                        .dsFont(.callout)
                    Spacer(minLength: 0)
                    if let t = carbs.mostlyAbsorbedAt {
                        Text("mostly by \(OutlookFormat.time(t))").dsFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if carbs.uncountedFood {
                Label("Food was logged without carbs recently, so it isn't counted here.", systemImage: "info.circle")
                    .dsFont(.caption).foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }
}

private struct ActivityChart: View {
    let curve: [ActivitySample]
    let now: Date
    let color: Color
    let unitLabel: String

    var body: some View {
        Chart {
            ForEach(curve, id: \.date) { s in
                AreaMark(x: .value("Time", s.date), y: .value("On board", s.remaining))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(s.date <= now ? 0.35 : 0.18), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.date), y: .value("On board", s.remaining))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: s.date <= now ? [] : [3, 3]))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading) {
                    Text("Now").dsFont(.caption).foregroundStyle(.secondary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour()).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(LogFormat.number(d)) \(unitLabel)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityLabel("Insulin on board over time")
    }
}

// MARK: - Accuracy

private struct AccuracyCard: View {
    let calibration: ForecastCalibration?
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader("How Accurate It's Been", systemImage: "scope",
                          subtitle: "Past forecasts replayed against what actually happened (last 30 days)")
            if let cal = calibration, !cal.byBasis.isEmpty {
                ForEach(ForecastBasis.allCases, id: \.self) { basis in
                    if let stats = cal.stats(for: basis) {
                        Text(basis.title).dsFont(.headline)
                        Grid(alignment: .leading, horizontalSpacing: DS.Space.lg, verticalSpacing: DS.Space.xs) {
                            GridRow {
                                Text("Ahead").foregroundStyle(.secondary)
                                Text("Typical error").foregroundStyle(.secondary)
                                Text("Assuming no change").foregroundStyle(.secondary)
                                Text("Checks").foregroundStyle(.secondary)
                            }
                            .dsFont(.caption)
                            ForEach(stats.filter { $0.minutes <= 120 }, id: \.minutes) { s in
                                GridRow {
                                    Text("\(s.minutes) min")
                                    Text("±\(unit.format(mgdl: s.meanAbsoluteError))")
                                        .fontWeight(s.beatsNaive ? .semibold : .regular)
                                        .foregroundStyle(s.beatsNaive ? Color.primary : Color.secondary)
                                    Text(s.naiveError.isFinite ? "±\(unit.format(mgdl: s.naiveError))" : "–")
                                        .foregroundStyle(.secondary)
                                    Text("\(s.samples)").foregroundStyle(.secondary)
                                }
                                .dsFont(.callout)
                                .monospacedDigit()
                            }
                        }
                        let allowed = cal.allowedHorizon(for: basis)
                        Text(allowed.map { $0 > 0 ? "Shown up to \(Int($0 / 60)) minutes ahead, as far as it beats assuming no change." : "Not shown: it hasn't beaten assuming no change." }
                             ?? "Needs \(ForecastCalibration.minimumSamples)+ checks before it can be relied on, so a cautious range is used.")
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                EmptyStateView(systemImage: "scope", title: "Not Checked Yet",
                               message: "Once there's a few days of readings, GlucOS replays its forecasts against what happened and uses that to set the range and how far ahead to look.")
            }
        }
        .dashboardCard()
    }
}

// MARK: - What it's learnt

private struct LearntEffectsCard: View {
    let profile: EffectProfile
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader("What It's Learnt", systemImage: "brain",
                          subtitle: profile.days > 0 ? "From \(profile.intervals) clean half-hours over \(profile.days) days" : "From your readings and logs")
            row(title: "Glucose fall as insulin acts", effect: profile.insulin, reliable: profile.reliableInsulin != nil,
                per: "per unit", scale: 1, examplesNoun: "doses")
            row(title: "Glucose rise as carbs absorb", effect: profile.carbs, reliable: profile.reliableCarbs != nil,
                per: "per 10 g", scale: 10, examplesNoun: "meals")
            Text("These are fitted from your history so the forecast can turn insulin and carbs into a glucose change. They aren't settings, change with time, illness and activity, and must never be used to work out a dose.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard()
    }

    @ViewBuilder
    private func row(title: String, effect: LearnedEffect?, reliable: Bool, per: String, scale: Double, examplesNoun: String) -> some View {
        DSAdaptiveRow {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).dsFont(.body)
                if let e = effect {
                    Text("From \(e.examples) \(examplesNoun)\(reliable ? "" : ": not consistent enough to use yet")")
                        .dsFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Needs at least \(EffectProfileLearner.minimumExamples) logged \(examplesNoun) with clean readings")
                        .dsFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = effect, reliable {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("≈ \(unit.format(mgdl: e.value * scale)) \(unit.label)")
                        .fontWeight(.semibold).dsFont(.callout).monospacedDigit()
                    Text("\(per), ± \(unit.format(mgdl: e.standardError * scale))")
                        .dsFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                TonePill(text: effect == nil ? "Not enough data" : "Learning", tone: .neutral)
            }
        }
    }
}

// MARK: - Recurring patterns

private struct RecurringPatternsCard: View {
    let patterns: [RecurringPattern]
    let hasHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader("Recurring Times", systemImage: "repeat",
                          subtitle: "Times of day when lows or highs keep happening (last 14 days)")
            if patterns.isEmpty {
                EmptyStateView(systemImage: "checkmark.circle", title: hasHistory ? "Nothing Recurring" : "Not Enough History",
                               message: hasHistory ? "No time of day had lows on 1 in 4 days, or highs on 2 in 5, over the last two weeks."
                                                   : "Needs at least a week of readings.")
            } else {
                ForEach(patterns) { p in
                    DSAdaptiveRow {
                        HStack(spacing: DS.Space.sm) {
                            Capsule().fill((p.kind == .low ? GlucoseRange.low : GlucoseRange.high).tint.gradient)
                                .frame(width: 4, height: 28)
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(p.windowTitle()).fontWeight(.semibold).dsFont(.body)
                                Text(p.summary).dsFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TonePill(text: Format.percent(p.share), tone: .glucose(p.kind == .low ? .low : .high))
                    }
                }
                Text("Observations only. Worth raising with your diabetes team if a pattern keeps showing up.")
                    .dsFont(.caption).foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }
}
