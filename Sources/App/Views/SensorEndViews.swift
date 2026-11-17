import SwiftUI

// A sensor's last day and its end (docs/SensorEnd.md), shared by iPhone Today and the Mac popover.
// The timing and words are in Engine/SensorEnd.swift.

/// "Sensor day 15 of 15 · 6 h 12 min left", quiet under the reading in the sensor's last 24
/// hours. Secondary text until the last 2 hours, then the warning colour. The figure changes with
/// a numeric roll, at once under Reduce Motion; nothing repeats.
struct SensorCountdownLine: View {
    let countdown: SensorEnd.Countdown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Space.xxs + 2) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .imageScale(.small)
            Text(countdown.line)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsFont(.caption)
        .foregroundStyle(countdown.isUrgent ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .dsAnimation(.standard, value: countdown.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countdown.spoken())
    }
}

/// The sensor-ended stage, in place of the old sensor's last reading: what happened, what to do
/// next, and the last reading in small type so it can't pass for a live one. The new sensor's
/// warm-up countdown replaces it when LibreLinkUp reports the start.
struct SensorEndedContent: View {
    let ended: SensorEnd.Ended
    let now: Date
    let unit: GlucoseUnit
    /// The headline's style: `.title` on iPhone, `.headline` in the popover.
    var titleFont: DSTextStyle = .title
    var iconSize: CGFloat = 64

    var body: some View {
        DSAccessibleStack(spacing: DS.Space.md) {
            ZStack {
                Circle().fill(Tone.warning.color.opacity(0.16))
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: iconSize * 0.42, weight: .semibold))
                    .foregroundStyle(Tone.warning.color)
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(ended.endedLine(now: now))
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                Text(SensorEnd.Ended.title)
                    .dsFont(titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SensorEnd.Ended.detail)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = ended.lastReading {
                    Text("Last reading \(unit.format(mgdl: last.mgdl, withUnit: true)) · \(ClockLabel.dayTime(last.timestamp, now: now))")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, DS.Space.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole card in a sentence, for VoiceOver.
    static func spoken(_ ended: SensorEnd.Ended, now: Date, unit: GlucoseUnit) -> String {
        var out = ended.spoken(now: now)
        if let last = ended.lastReading {
            out += " Last reading \(unit.format(mgdl: last.mgdl, withUnit: true)) at \(ClockLabel.dayTime(last.timestamp, now: now))."
        }
        return out
    }
}
