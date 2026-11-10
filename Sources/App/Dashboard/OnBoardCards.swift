import SwiftUI

// What's still acting right now, from the logbook: fast-acting (bolus) insulin, background (basal)
// insulin and carbs, beside where the forecast says glucose is heading. Every number is an
// estimate on typical timing curves for what was logged. None of it is advice on what to dose or eat.

/// Insulin and carbs still acting at one moment, worked out from the logbook with the engine's
/// own models. Worked out on the view's clock rather than taken from the last outlook, so the
/// numbers keep counting down even when readings stop coming in.
struct OnBoardNow {
    let insulin: InsulinActivity
    let background: BackgroundInsulinActivity
    let carbs: CarbActivity

    init(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent], at now: Date) {
        let hypo = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        insulin = InsulinActivity.compute(doses: doses, at: now)
        background = BackgroundInsulinActivity.compute(doses: doses, at: now)
        carbs = CarbActivity.compute(meals: meals, hypoTreatments: hypo, at: now)
    }

    /// People who don't take insulin only see carbs and the forecast, unless they logged some anyway.
    func showsInsulin(therapy: TherapyType) -> Bool {
        therapy != .noInsulin || insulin.doseCount > 0 || background.isActive
    }

    var isEmpty: Bool { insulin.onBoard < 0.05 && !background.isActive && carbs.onBoard < 1 }
}

/// The row of "on board" cards on the Overview, under the current reading and headline numbers.
struct OnBoardRow: View {
    let onBoard: OnBoardNow
    /// The current forecast, if there is one (`GlucoseSnapshot.currentOutlook`).
    let forecast: OutlookSnapshot?
    /// Why there's no forecast, when there isn't one.
    let noForecastReason: String?
    let therapy: TherapyType
    let unit: GlucoseUnit
    let lowMgdl: Double
    let spacing: CGFloat

    var body: some View {
        CardGrid(minColumnWidth: 210, maxColumns: 4, spacing: spacing, evenRows: true) {
            if onBoard.showsInsulin(therapy: therapy) {
                BolusOnBoardCard(insulin: onBoard.insulin)
                BasalOnBoardCard(background: onBoard.background, therapy: therapy)
            }
            CarbsOnBoardCard(carbs: onBoard.carbs)
            ForecastAheadCard(forecast: forecast, noForecastReason: noForecastReason, unit: unit, lowMgdl: lowMgdl)
        }
    }
}

// MARK: - Cards

/// Fast-acting insulin not yet acted: mealtime and correction doses, and the fast part of premixed.
private struct BolusOnBoardCard: View {
    let insulin: InsulinActivity

    var body: some View {
        let active = insulin.onBoard >= 0.05
        OnBoardCard(title: "Bolus on board", systemImage: "syringe", tint: Palette.insulin,
                    value: active ? OnBoardFormat.number(insulin.onBoard) : "0", unit: "u",
                    fraction: active && insulin.unitsGiven > 0 ? insulin.onBoard / insulin.unitsGiven : nil,
                    caption: caption(active: active), detail: active ? "of \(OutlookFormat.units(insulin.unitsGiven)) logged" : nil,
                    help: "Fast-acting insulin you've logged that hasn't acted yet, on typical timing for its type. In the forecast once GlucOS has learnt its effect.")
    }

    private func caption(active: Bool) -> String {
        guard active else { return "Nothing fast-acting still working" }
        if let peak = insulin.peakAt { return "Peaks around \(OutlookFormat.time(peak))" }
        if let done = insulin.mostlyDoneAt { return "Mostly done by \(OutlookFormat.time(done))" }
        return "Winding down"
    }
}

/// Long-acting or NPH insulin for people on injections. A pump's basal isn't logged.
private struct BasalOnBoardCard: View {
    let background: BackgroundInsulinActivity
    let therapy: TherapyType

    var body: some View {
        let help = "Background insulin isn't part of the forecast: it's assumed to be holding glucose level. The amount left is a rough estimate from the insulin's usual duration."
        if therapy == .pump && !background.isActive {
            OnBoardCard(title: "Basal", systemImage: "cross.vial", tint: Palette.brand,
                        value: "Pump", unit: nil, fraction: nil,
                        caption: "Your pump's basal isn't logged",
                        detail: "Assumed to hold glucose level",
                        help: help)
        } else if let latest = background.latest, let end = background.latestCoverEndsAt {
            OnBoardCard(title: "Basal on board", systemImage: "syringe.fill", tint: Palette.brand,
                        value: "≈ \(OnBoardFormat.number(background.onBoard))", unit: "u",
                        fraction: background.latestElapsedFraction.map { 1 - $0 },
                        caption: "\(latest.displayName) \(OutlookFormat.units(latest.units)), \(OnBoardFormat.ago(latest.timestamp, from: background.at))",
                        detail: "Usual action ends around \(OnBoardFormat.dayTime(end, from: background.at))",
                        help: help)
        } else {
            OnBoardCard(title: "Basal on board", systemImage: "syringe.fill", tint: Palette.brand,
                        value: "–", unit: nil, fraction: nil,
                        caption: "No long-acting dose logged recently",
                        detail: "Log one to see it here",
                        help: help)
        }
    }
}

private struct CarbsOnBoardCard: View {
    let carbs: CarbActivity

    var body: some View {
        let active = carbs.onBoard >= 1
        OnBoardCard(title: "Carbs on board", systemImage: "fork.knife", tint: Palette.food,
                    value: active ? "\(Int(carbs.onBoard.rounded()))" : "0", unit: "g", fraction: nil,
                    caption: caption(active: active),
                    detail: carbs.uncountedFood ? "Food logged without carbs isn't counted" : nil,
                    detailTone: carbs.uncountedFood ? .warning : .neutral,
                    help: "Logged carbs not yet absorbed, on a typical 3-hour absorption curve. In the forecast once GlucOS has learnt their effect.")
    }

    private func caption(active: Bool) -> String {
        guard active else { return "No logged carbs still absorbing" }
        if let t = carbs.mostlyAbsorbedAt { return "Mostly absorbed by \(OutlookFormat.time(t))" }
        return "Nearly absorbed"
    }
}

/// Where the forecast says glucose is heading, in grey with "≈" so it never reads as a reading.
private struct ForecastAheadCard: View {
    let forecast: OutlookSnapshot?
    let noForecastReason: String?
    let unit: GlucoseUnit
    let lowMgdl: Double

    var body: some View {
        let help = "Forecast, not a reading. About 8 in 10 past forecasts this far ahead landed in the likely range. Assumes nothing new is eaten or dosed."
        if let forecast, let headline = OutlookFormat.headlineSample(forecast) {
            let s = headline.sample
            let trendOnly = forecast.basis == .trend
            OnBoardCard(title: "Predicted in \(headline.minutes) min", systemImage: "chart.line.uptrend.xyaxis",
                        tint: Palette.stale,
                        value: OutlookFormat.approx(s.mgdl, unit: unit), unit: unit.label, fraction: nil,
                        caption: lowCaption(forecast) ?? "Likely \(OutlookFormat.range(s, unit: unit))",
                        captionTone: lowCaption(forecast) == nil ? .neutral : .warning,
                        detail: trendOnly ? "From the recent trend only" : "From trend, insulin and carbs",
                        help: help)
        } else {
            OnBoardCard(title: "Predicted", systemImage: "chart.line.uptrend.xyaxis", tint: Palette.stale,
                        value: "–", unit: nil, fraction: nil,
                        caption: noForecastReason ?? "No forecast right now", detail: nil, help: help)
        }
    }

    private func lowCaption(_ o: OutlookSnapshot) -> String? {
        if let low = o.lowExpectedAt { return "Below \(unit.format(mgdl: lowMgdl)) around \(OutlookFormat.time(low))" }
        if let possible = o.lowPossibleAt { return "A low is possible from \(OutlookFormat.time(possible))" }
        return nil
    }
}

// MARK: - Shell

/// One "on board" card: what it is, the amount, an optional meter for how much is left, and a
/// line or two of timing.
private struct OnBoardCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let unit: String?
    /// Share still to act, 0…1. Nil hides the meter.
    let fraction: Double?
    let caption: String
    var captionTone: Tone = .neutral
    let detail: String?
    var detailTone: Tone = .neutral
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm - 2) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .dsFont(.label)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(value)
                    .dsFont(.metricValueLarge)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).dsFont(.unit).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let fraction {
                OnBoardMeter(fraction: fraction, tint: tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .foregroundStyle(captionTone == .neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(captionTone.textColor))
                if let detail {
                    Text(detail)
                        .foregroundStyle(detailTone == .neutral ? AnyShapeStyle(Color.secondary.opacity(0.8)) : AnyShapeStyle(detailTone.textColor))
                }
            }
            .dsFont(.caption)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard(.standard, padding: DS.Space.md + 2)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar for the share still to act.
private struct OnBoardMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

/// The same numbers, compact, above the reading in the dashboard sidebar so they're on every page.
struct OnBoardSidebarTile: View {
    let onBoard: OnBoardNow
    let therapy: TherapyType

    var body: some View {
        let insulin = onBoard.showsInsulin(therapy: therapy)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("On board").dsFont(.eyebrow).foregroundStyle(.secondary)
            if insulin {
                row("syringe", Palette.insulin, "Bolus",
                    onBoard.insulin.onBoard >= 0.05 ? OutlookFormat.units(onBoard.insulin.onBoard) : "0 u")
                if therapy == .pump && !onBoard.background.isActive {
                    row("cross.vial", Palette.brand, "Basal", "Pump")
                } else {
                    row("syringe.fill", Palette.brand, "Basal",
                        onBoard.background.isActive ? "≈ \(OutlookFormat.units(onBoard.background.onBoard))" : "–")
                }
            }
            row("fork.knife", Palette.food, "Carbs", "\(Int(onBoard.carbs.onBoard.rounded())) g")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.sm + 2, radius: DS.Radius.card - 2)
        .help("Estimates from what you've logged, on typical timing curves. Basal isn't part of the forecast.")
        .accessibilityElement(children: .combine)
    }

    private func row(_ icon: String, _ tint: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.xs)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .dsFont(.caption)
        .lineLimit(1)
    }
}

enum OnBoardFormat {
    /// "2.4", or "12" from 10 up.
    static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0)))
    }

    /// "6 h ago", "45 min ago".
    static func ago(_ date: Date, from now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    /// "7:25 am", or "Thu 7:25 am" when it isn't today.
    static func dayTime(_ date: Date, from now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? OutlookFormat.time(date)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
