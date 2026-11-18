import SwiftUI

/// The small card a tap (iPhone Today) or click (Mac popover) on the forecast opens
/// (`ForecastDetails`, round 73): the forecast at 30 and 60 minutes with its likely range, how often
/// that range held at each distance recently, and one line on what it was based on. Shown as a
/// popover from the chart, kept a popover on iPhone, like the reading's details card. VoiceOver
/// reads it as one element.
struct ForecastDetailsCard: View {
    let details: ForecastDetails
    let unit: GlucoseUnit

    /// Fixed, so the wrapped lines set the height and the popover never grows sideways.
    static let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.xs) {
                Capsule().fill(Palette.stale).frame(width: 12, height: 2)
                Text(ForecastDetails.title)
                    .dsFont(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            ForEach(details.horizons, id: \.minutes) { h in
                row(h)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: details.driver.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(details.driver.line)
                    .dsFont(.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ForecastDetails.footnote)
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.lg)
        .frame(width: ForecastDetailsCard.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForecastDetails.spoken(details, unit: unit))
    }

    private func row(_ h: ForecastDetails.Horizon) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(ForecastDetails.heading(h))
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)
                Text(ForecastDetails.value(h, unit: unit))
                    .dsFont(.headline)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(ForecastDetails.range(h, unit: unit))
                    .dsFont(.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(ForecastDetails.held(h))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
