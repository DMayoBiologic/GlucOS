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

    /// Readings tagged with a segment index that increments at every gap longer than
    /// `GlucoseStats.maxGap`, so the line breaks over missing data instead of bridging it.
    private var segmented: [(segment: Int, reading: GlucoseReading)] {
        var segment = 0
        var previous: Date?
        return window.map { r in
            if let previous, r.timestamp.timeIntervalSince(previous) > GlucoseStats.maxGap { segment += 1 }
            previous = r.timestamp
            return (segment, r)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = window.map(\.mgdl) + [lowMgdl, highMgdl]
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    var body: some View {
        Chart {
            RectangleMark(
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(.green.opacity(0.12))

            ForEach(segmented, id: \.reading.id) { item in
                LineMark(
                    x: .value("Time", item.reading.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: item.reading.mgdl)),
                    series: .value("Segment", item.segment)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.primary.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }

            ForEach(window.filter { $0.mgdl < lowMgdl || $0.mgdl > highMgdl }) { r in
                PointMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .symbolSize(14)
                .foregroundStyle(r.mgdl < lowMgdl ? Color.red : Color.orange)
            }

            if let last = window.last {
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(40)
                .foregroundStyle(.tint)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0f", d))
                                .font(.caption2)
                        }
                    }
                }
            }
        }
    }
}
