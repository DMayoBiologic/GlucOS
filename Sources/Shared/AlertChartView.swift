import SwiftUI

/// The chart on a low, high or forecast alert (`AlertChart`): the iPhone's notification content
/// extension shows it live, the Mac renders it into the alert's picture. The reading line draws in
/// once when shown; under Reduce Motion, or when `animated` is off (a rendered picture), the
/// finished chart appears at once. VoiceOver reads it as one element: `AlertChart.spokenSummary`.
struct AlertChartView: View {
    let chart: AlertChart
    var animated = true
    /// The time labels under the chart. Off for the Mac's small picture.
    var showsTimes = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the line is drawn. Starts finished when not animated, since a rendered picture
    /// is taken before `onAppear` could change it.
    @State private var drawn: CGFloat

    init(chart: AlertChart, animated: Bool = true, showsTimes: Bool = true) {
        self.chart = chart
        self.animated = animated
        self.showsTimes = showsTimes
        _drawn = State(initialValue: animated ? 0 : 1)
    }

    var body: some View {
        let layout = chart.layout
        VStack(spacing: 4) {
            GeometryReader { geo in
                plot(layout, size: geo.size)
            }
            if showsTimes { times(layout) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glucose, last 3 hours")
        .accessibilityValue(chart.spokenSummary)
        .onAppear {
            let seconds = animated ? AlertChart.drawInSeconds(reduceMotion: reduceMotion) : 0
            if seconds > 0 {
                withAnimation(.easeOut(duration: seconds)) { drawn = 1 }
            } else {
                drawn = 1
            }
        }
        .onChange(of: reduceMotion) { _, reduce in
            // Turned on mid-draw: finish at once.
            if reduce { drawn = 1 }
        }
    }

    private func plot(_ layout: AlertChart.Layout, size: CGSize) -> some View {
        func point(_ p: AlertChart.Layout.Point) -> CGPoint {
            CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
        }
        let band = CGRect(x: 0, y: (1 - layout.highY) * size.height,
                          width: size.width, height: max(1, (layout.highY - layout.lowY) * size.height))
        let readings = Path { path in
            for run in layout.runs {
                guard let first = run.first else { continue }
                path.move(to: point(first))
                if run.count == 1 { path.addLine(to: point(first)) }
                for p in run.dropFirst() { path.addLine(to: point(p)) }
            }
        }
        let forecast = Path { path in
            guard let first = layout.forecast.first else { return }
            path.move(to: point(first))
            for p in layout.forecast.dropFirst() { path.addLine(to: point(p)) }
        }
        let gradient = ThresholdGradient.style(minMgdl: layout.minMgdl, maxMgdl: layout.maxMgdl,
                                               low: chart.lowMgdl, high: chart.highMgdl)
        let nowRange = GlucoseRange.classify(mgdl: Double(chart.history.compactMap { $0 }.last ?? 0),
                                             low: chart.lowMgdl, high: chart.highMgdl)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.mint.opacity(0.12)).frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
            if let cone = layout.cone {
                Path { path in
                    path.move(to: point(layout.now))
                    path.addLine(to: point(cone.top))
                    path.addLine(to: point(cone.bottom))
                    path.closeSubpath()
                }
                .fill(Palette.brand.opacity(0.14))
                .opacity(drawn)
            }
            forecast
                .stroke(Palette.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                .opacity(drawn)
            readings
                .trim(from: 0, to: drawn)
                .stroke(gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(nowRange.tint)
                .frame(width: 8, height: 8)
                .position(point(layout.now))
                .opacity(drawn)
        }
        .frame(width: size.width, height: size.height)
    }

    private func times(_ layout: AlertChart.Layout) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Text(chart.readingDate.addingTimeInterval(-AlertChart.historyHours * 3600), style: .time)
                    .fixedSize()
                    .frame(width: w, alignment: .leading)
                if !layout.forecast.isEmpty {
                    // Under the reading, which sits three quarters of the way along with a forecast.
                    Text("Now").fixedSize()
                        .position(x: min(max(layout.now.x * w, 20), w - 60), y: geo.size.height / 2)
                    Text("+\(chart.forecast.count * 5) min").fixedSize()
                        .frame(width: w, alignment: .trailing)
                } else {
                    Text("Now").fixedSize().frame(width: w, alignment: .trailing)
                }
            }
        }
        .frame(height: 14)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

#if os(macOS)
import AppKit

extension AlertChart {
    /// The Mac alert's picture: the chart on its own dark card, so it reads the same in the light
    /// and dark notification styles. PNG data, or nil if rendering failed.
    @MainActor
    func pictureData(size: CGSize = CGSize(width: 300, height: 200)) -> Data? {
        let view = AlertChartView(chart: self, animated: false, showsTimes: false)
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: Palette.rgb(0x1C1C1E)))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
