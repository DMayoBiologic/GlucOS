import Charts
import SwiftUI

/// Under the target-range editor in Settings (iPhone and Mac, round 54): today's readings so far on
/// a small chart with the range being set as its band, and how much of today that range counts as
/// in range. Moving a limit slides the band and its lines on the `.targetRangeGlide` curve (#207)
/// while the figure rolls to its new value (`RollingFigure`); readings recolour with the band. One
/// movement per change, never looping; instant under Reduce Motion. The trace is worked out off the
/// main thread once per new reading, so stepping a limit only recounts the figure. Hidden until
/// today has half an hour of readings. VoiceOver hears one line: the figure for the range as set.
struct TargetRangePreviewChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var height: CGFloat = 84

    @State private var preview: TargetRangePreview?

    /// A new reading or a new day redraws the trace; a new range never does.
    private struct TraceKey: Equatable {
        let count: Int
        let newest: Date?
        let day: Date
    }

    private var traceKey: TraceKey {
        TraceKey(count: readings.count, newest: readings.last?.timestamp,
                 day: Calendar.autoupdatingCurrent.startOfDay(for: Date()))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let preview { content(preview) }
        }
        .task(id: traceKey) {
            let r = readings
            preview = await Task.detached(priority: .userInitiated) { TargetRangePreview.today(r) }.value
        }
    }

    private func content(_ p: TargetRangePreview) -> some View {
        let tir = p.timeInRange(low: lowMgdl, high: highMgdl)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today with this range")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                RollingFigure(tir) { "\(Format.percent($0)) in range" }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(GlucoseRange.inRange.tint)
            }
            chart(p)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.spoken(low: lowMgdl, high: highMgdl))
    }

    private func chart(_ p: TargetRangePreview) -> some View {
        let low = unit.value(fromMgdl: lowMgdl)
        let high = unit.value(fromMgdl: highMgdl)
        let mg = p.yDomain
        let all = p.points
        let line = ThresholdGradient.style(minMgdl: all.map(\.mgdl).min() ?? lowMgdl,
                                           maxMgdl: all.map(\.mgdl).max() ?? highMgdl,
                                           low: lowMgdl, high: highMgdl)
        return Chart {
            RectangleMark(
                xStart: .value("Start", p.start), xEnd: .value("End", p.end),
                yStart: .value("Low", low), yEnd: .value("High", high)
            )
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.14))
            RuleMark(y: .value("Low", low))
                .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.low.tint.opacity(0.7))
            RuleMark(y: .value("High", high))
                .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.high.tint.opacity(0.7))

            ForEach(Array(p.segments.enumerated()), id: \.offset) { i, run in
                ForEach(run, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Glucose", unit.value(fromMgdl: point.mgdl)),
                        series: .value("Run", i)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: p.start...p.end)
        .chartYScale(domain: unit.value(fromMgdl: mg.lowerBound)...unit.value(fromMgdl: mg.upperBound))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .targetRangeGlide(lowMgdl: lowMgdl, highMgdl: highMgdl)
    }
}
