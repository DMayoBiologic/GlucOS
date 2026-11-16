import Charts
import SwiftUI

/// One Logbook day as a small glucose chart: the day's trace (`DayChart.segments`, a line per run
/// of readings) on its target band, midnight to midnight, with what was logged marked along the
/// bottom. Opened from the day's time-in-range bar on the iPhone Logbook and from the Day column on
/// the Mac. A picture only: it doesn't scrub, and nothing on it moves once it is there. Hidden
/// from VoiceOver; whoever shows it says `DayChartText.spoken` instead.
struct DayMiniChart: View {
    let start: Date
    let segments: [[DayChartPoint]]
    let markers: [ChartLogMarker]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var height: CGFloat = 116

    private var end: Date { DayChart.end(of: start) }

    private var yDomain: ClosedRange<Double> {
        let values = segments.joined().map(\.mgdl) + [lowMgdl, highMgdl]
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    /// The hours labelled along the bottom: 6 am, noon, 6 pm.
    private var hourTicks: [Date] {
        [6, 12, 18].compactMap { Calendar.autoupdatingCurrent.date(byAdding: .hour, value: $0, to: start) }
    }

    var body: some View {
        let yd = yDomain
        let all = Array(segments.joined())
        let line = ThresholdGradient.style(minMgdl: all.map(\.mgdl).min() ?? lowMgdl,
                                           maxMgdl: all.map(\.mgdl).max() ?? highMgdl,
                                           low: lowMgdl, high: highMgdl)
        Chart {
            RectangleMark(
                xStart: .value("Start", start), xEnd: .value("End", end),
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.12))
            RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.5))
            RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.5))

            ForEach(Array(segments.enumerated()), id: \.offset) { i, run in
                ForEach(run, id: \.date) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                        series: .value("Run", i)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
                // A run of one reading still shows, as a dot.
                if run.count == 1, let p = run.first {
                    PointMark(x: .value("Time", p.date), y: .value("Glucose", unit.value(fromMgdl: p.mgdl)))
                        .symbolSize(10)
                        .foregroundStyle(GlucoseRange.classify(mgdl: p.mgdl, low: lowMgdl, high: highMgdl).tint)
                }
            }

            ForEach(markers) { m in
                PointMark(x: .value("Time", m.date), y: .value("Logged", markerY(lane: m.lane, yd: yd)))
                    .symbol { DayMarkerSymbol(marker: m) }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: yd)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: hourTicks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour(), centered: false)
                    .font(.caption2)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Markers sit in rows along the bottom of the chart, a meal above a dose logged with it.
    private func markerY(lane: Int, yd: ClosedRange<Double>) -> Double {
        let span = yd.upperBound - yd.lowerBound
        return yd.lowerBound + span * (0.07 + 0.11 * Double(lane))
    }
}

/// A logged dose, meal or wake-up on a day chart: the Today chart's marker, a size smaller.
private struct DayMarkerSymbol: View {
    let marker: ChartLogMarker

    var body: some View {
        Image(systemName: marker.systemImage)
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(marker.tint))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

extension ChartLogMarker {
    /// What was logged on the day starting at `start`, as markers for its chart.
    static func day(_ entries: [LogEntry], start: Date) -> [ChartLogMarker] {
        let end = DayChart.end(of: start)
        var doses: [InsulinDose] = [], meals: [MealEntry] = [], contexts: [ContextEvent] = []
        for e in entries where e.timestamp >= start && e.timestamp < end {
            switch e {
            case .dose(let d): doses.append(d)
            case .meal(let m): meals.append(m)
            case .context(let c): contexts.append(c)
            case .siteChange: break
            }
        }
        return logbook(doses: doses, meals: meals, contexts: contexts, since: start)
    }
}
