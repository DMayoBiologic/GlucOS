import SwiftUI

extension View {
    /// Pinch the chart to change its span: spread two fingers (or pinch out on a Mac trackpad) to
    /// zoom in to fewer hours, pinch together for more, in the same 3h / 6h / 12h / 24h steps as
    /// the control beside it (`ChartHours.pinched`). Each step lands while the fingers are still
    /// moving, and the chart springs to it as it does for a tap. Runs alongside the chart's own
    /// scrub, which is one finger.
    func chartHoursPinch(_ hours: Binding<Int>) -> some View {
        modifier(ChartHoursPinch(hours: hours))
    }
}

private struct ChartHoursPinch: ViewModifier {
    @Binding var hours: Int
    /// The span the pinch started on, so steps count from there rather than compounding.
    @State private var start: Int?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.03)
                .onChanged { value in
                    let from = start ?? hours
                    if start == nil { start = from }
                    let target = ChartHours.pinched(from: from, scale: value.magnification)
                    if target != hours { hours = target }
                }
                .onEnded { _ in start = nil }
        )
    }
}
