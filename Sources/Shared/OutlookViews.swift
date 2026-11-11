import SwiftUI

// Compact outlook pieces for the popover and the widget. Forecast values are always neutral grey
// and marked "about" or "≈", so they never read as a reading.

extension GlucoseSnapshot {
    /// The outlook, only while it belongs to a current reading.
    func currentOutlook(at now: Date = Date()) -> OutlookSnapshot? {
        guard let outlook, !isStale(at: now), outlook.isCurrent(at: now) else { return nil }
        return outlook
    }
}

enum OutlookFormat {
    /// "≈ 6.2" for a forecast value.
    static func approx(_ mgdl: Double, unit: GlucoseUnit) -> String { "≈ \(unit.format(mgdl: mgdl))" }

    /// "5.1–7.0".
    static func range(_ s: ForecastSample, unit: GlucoseUnit) -> String {
        "\(unit.format(mgdl: s.lowerMgdl))–\(unit.format(mgdl: s.upperMgdl))"
    }

    static func units(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0))) + " u"
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// The forecast at the furthest whole half hour it reaches (30 or 60 minutes), or its end.
    static func headlineSample(_ o: OutlookSnapshot) -> (minutes: Int, sample: ForecastSample)? {
        let horizon = Int(o.horizon / 60)
        guard horizon >= 15 else { return nil }
        let minutes = horizon >= 60 ? 60 : horizon >= 30 ? 30 : horizon
        return o.sample(minutesAhead: Double(minutes)).map { (minutes, $0) }
    }
}

/// One line: "In 30 min ≈ 6.2 (5.1–7.0) · Insulin 1.8 u, mostly done by 9:40".
struct OutlookSummaryRow: View {
    let outlook: OutlookSnapshot
    let unit: GlucoseUnit
    let lowMgdl: Double
    var showsCarbs = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.md) { forecastPart; insulinPart; if showsCarbs { carbsPart } }
            HStack(spacing: DS.Space.md) { forecastPart; insulinPart }
            VStack(alignment: .leading, spacing: DS.Space.xxs) { forecastPart; insulinPart }
            forecastPart
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var forecastPart: some View {
        if let headline = OutlookFormat.headlineSample(outlook) {
            let minutes = headline.minutes, s = headline.sample
            HStack(spacing: DS.Space.xs) {
                Image(systemName: lowSoon ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                    .foregroundStyle(lowSoon ? Tone.warning.color : Palette.stale)
                    .imageScale(.small)
                Text("In \(minutes) min")
                    .foregroundStyle(.secondary)
                Text(OutlookFormat.approx(s.mgdl, unit: unit))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("(\(OutlookFormat.range(s, unit: unit)))")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .dsFont(.label)
            .lineLimit(1)
            .help("Forecast, not a reading. About 8 in 10 past forecasts landed in the range shown.")
            .accessibilityLabel("Forecast in \(minutes) minutes: about \(unit.format(mgdl: s.mgdl, withUnit: true)), likely between \(OutlookFormat.range(s, unit: unit))")
        }
    }

    private var lowSoon: Bool { outlook.lowExpectedAt != nil }

    @ViewBuilder private var insulinPart: some View {
        if outlook.showsInsulin, let iob = outlook.insulinOnBoard {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "syringe").foregroundStyle(Palette.insulin).imageScale(.small)
                Text(OutlookFormat.units(iob)).fontWeight(.semibold).monospacedDigit()
                if let done = outlook.insulinMostlyDoneAt {
                    Text("until ~\(OutlookFormat.time(done))").foregroundStyle(.secondary)
                }
            }
            .dsFont(.label)
            .lineLimit(1)
            .help("Fast-acting insulin still to act, and when it will have mostly finished, on typical timing for the insulin logged.")
        }
    }

    @ViewBuilder private var carbsPart: some View {
        if outlook.showsCarbs, let cob = outlook.carbsOnBoard {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "fork.knife").foregroundStyle(Palette.food).imageScale(.small)
                Text("\(Int(cob.rounded())) g").fontWeight(.semibold).monospacedDigit()
            }
            .dsFont(.label)
            .lineLimit(1)
            .help("Logged carbs still being absorbed, on typical timing.")
        }
    }
}

// MARK: - Mornings

extension MorningConfidence {
    var tone: Tone {
        switch self {
        case .high: return .success
        case .moderate: return .info
        case .low: return .neutral
        }
    }
}

enum MorningFormat {
    /// "Includes your usual rise after waking (woke 6:41 am): about +1.2 mmol/L by the end of the
    /// forecast. Moderate confidence."
    static func todayLine(_ m: MorningAdjustmentSnapshot, unit: GlucoseUnit) -> String {
        let woke = "woke \(ClockLabel.time(m.wokeAt))"
        guard abs(m.addedMgdl) >= 1 else {
            return "Includes your usual post-wake change (\(woke)), which is small from here. \(m.confidence.title)."
        }
        let sign = m.addedMgdl > 0 ? "+" : "−"
        let kind = m.addedMgdl > 0 ? "rise" : "fall"
        return "Includes your usual \(kind) after waking (\(woke)): about \(sign)\(unit.format(mgdl: abs(m.addedMgdl), withUnit: true)) by the end of the forecast. \(m.confidence.title)."
    }
}
