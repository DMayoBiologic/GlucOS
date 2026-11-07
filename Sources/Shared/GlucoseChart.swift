import SwiftUI
import Charts

/// Line chart of readings with the target band shaded. Compiled into both the app and the widget.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var hours: Double = 12
    var showAxes: Bool = true

    private var window: [GlucoseReading] {
        guard let last = readings.last else { return [] }
        let cutoff = last.timestamp.addingTimeInterval(-hours * 3600)
        return readings.filter { $0.timestamp >= cutoff }
    }

    private var yDomainMgdl: ClosedRange<Double> {
        let values = window.map(\.mgdl) + [lowMgdl, highMgdl]
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return lo...hi
    }

    private var yDomain: ClosedRange<Double> {
        unit.value(fromMgdl: yDomainMgdl.lowerBound)...unit.value(fromMgdl: yDomainMgdl.upperBound)
    }

    private func color(for mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    var body: some View {
        let window = self.window
        let floor = yDomain.lowerBound
        Chart {
            // Target band, with hairline edges so it still reads in Increase Contrast.
            RectangleMark(
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(Color.green.opacity(0.10))

            RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Color.green.opacity(0.5))
            RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Color.green.opacity(0.5))

            // Soft fill under the trace, like Health and Stocks.
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }

            ForEach(window) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            ForEach(window.filter { $0.mgdl < lowMgdl || $0.mgdl > highMgdl }) { r in
                PointMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .symbolSize(12)
                .foregroundStyle(color(for: r.mgdl))
            }

            // Current reading: solid dot with a soft halo.
            if let last = window.last {
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(160)
                .foregroundStyle(color(for: last.mgdl).opacity(0.22))
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(36)
                .foregroundStyle(color(for: last.mgdl))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if showAxes {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour())
                        .font(.caption2)
                }
            }
        }
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0f", d))
                                .font(.caption2)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Glucose, last \(Int(hours)) hours")
    }
}
