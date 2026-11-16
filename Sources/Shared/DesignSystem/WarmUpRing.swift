import SwiftUI

/// A ring that fills as the warm-up passes, with the minutes left inside.
struct WarmUpRing: View {
    /// 0...1 of the hour passed.
    let fraction: Double
    let minutes: Int
    var size: CGFloat = 96

    var body: some View {
        let line = max(6, size / 12)
        ZStack {
            Circle()
                .stroke(Tone.brand.color.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(Tone.brand.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .dsAnimation(.standard, value: fraction)
            VStack(spacing: 0) {
                if minutes > 0 {
                    Text("\(minutes)")
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(minutes)))
                    Text("min")
                        .font(.system(size: size * 0.13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "sensor.fill")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(Tone.brand.color)
                }
            }
            .dsAnimation(.standard, value: minutes)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
