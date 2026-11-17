import SwiftUI

/// The small up or down figure an Insights card shows beside a number while "Compare to previous
/// period" is on (`InsightsDelta`, docs/InsightsCompare.md): an arrow and the size of the change,
/// green when it went the better way, amber when worse, grey when neither. Shows nothing without a
/// previous period. VoiceOver hears the change in words (`InsightsDelta.spoken`); cards that read
/// as one stop append those words to their own value.
struct InsightsDeltaBadge: View {
    let delta: InsightsDelta?
    /// Written before the figure, "In range", when the badge isn't next to its number.
    var label: String? = nil
    /// What VoiceOver names the figure, when it isn't `label`: "Average".
    var spokenLabel: String? = nil
    /// "the previous 14 days", for the spoken words.
    var previous: String = ""

    var body: some View {
        if let delta {
            HStack(spacing: DS.Space.xxs) {
                if let label {
                    Text(label).foregroundStyle(.secondary)
                }
                Image(systemName: symbol(delta.direction))
                    .font(.caption2.weight(.bold))
                    .imageScale(.small)
                Text(delta.badge)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .dsFont(.caption)
            .foregroundStyle(tone(delta.verdict).textColor)
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(delta.spoken(label: spokenLabel ?? label ?? "Change", previous: previous.isEmpty ? "the previous period" : previous))
        }
    }

    private func symbol(_ d: InsightsDelta.Direction) -> String {
        switch d {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .same: return "equal"
        }
    }

    private func tone(_ v: InsightsDelta.Verdict) -> Tone {
        switch v {
        case .better: return .success
        case .worse: return .warning
        case .neutral: return .neutral
        }
    }
}

/// The "Compare to previous period" switch, read by each card.
struct InsightsCompareToggle: View {
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Toggle(isOn: Binding(get: { compare }, set: { on in
            DS.animate(.standard, reduceMotion: reduceMotion) { compare = on }
        })) {
            Text(InsightsCompare.toggleTitle)
        }
        .accessibilityHint(InsightsCompare.toggleHint)
    }
}
