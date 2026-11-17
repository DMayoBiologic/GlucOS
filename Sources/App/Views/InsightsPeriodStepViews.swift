import SwiftUI

// Stepping Insights back through earlier periods, on iPhone and Mac (docs/InsightsPeriodStep.md).
// The screen holds how many periods back it is; each card with a period reads it from the
// environment, works itself out on the readings up to its own stepped end, and shows a caption
// naming the dates. The rules are in `InsightsPeriodStep` (Engine), which is unit-tested.

/// Where Insights is stepped to: how many periods before the latest, and which way the last step
/// went, so captions slide in from the side the period came from.
struct InsightsStep: Equatable, Sendable {
    /// 0 is the latest. Never below 0.
    var back = 0
    /// -1 after a step earlier, +1 after a step later, 0 before any step.
    var direction = 0

    static let latest = InsightsStep()
}

private struct InsightsStepKey: EnvironmentKey {
    static let defaultValue = InsightsStep.latest
}

extension EnvironmentValues {
    /// The period step set by iPhone and Mac Insights. The latest everywhere else, so widgets,
    /// the popover and the evening recap are unchanged.
    var insightsStep: InsightsStep {
        get { self[InsightsStepKey.self] }
        set { self[InsightsStepKey.self] = newValue }
    }
}

/// A card's line while it shows an earlier period: "7 days · 27 Oct – 2 Nov 2026". It slides in
/// from the side the period came from as the figures roll; a cross-fade under Reduce Motion.
/// Nothing on the latest, where the card's own picker says the period.
struct InsightsStepCaption: View {
    let days: Int
    /// The card's latest: its newest reading, or now for At a glance.
    let latest: Date?
    @Environment(\.insightsStep) private var step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let latest, step.back > 0 {
                let end = InsightsPeriodStep.end(latest: latest, days: days, back: step.back)
                if let text = InsightsPeriodStep.caption(days: days, end: end, back: step.back) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityHidden(true)
                        Text(text).monospacedDigit()
                    }
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .id(text)
                    .transition(reduceMotion ? .opacity
                                : .push(from: step.direction < 0 ? .leading : .trailing))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(InsightsPeriodStep.spokenCaption(days: days, end: end, back: step.back) ?? text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// iPhone: the strip at the top of Insights that says which period the cards show, with buttons
/// for earlier and later and a way back to the latest. VoiceOver hears it as one adjustable
/// control: swipe up for a later period, down for an earlier one.
struct InsightsStepControl: View {
    let step: InsightsStep
    let canGoEarlier: Bool
    let move: (Int) -> Void
    let toLatest: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoEarlier)
            VStack(alignment: .leading, spacing: 0) {
                Text(InsightsPeriodStep.label(back: step.back))
                    .dsFont(.label)
                    .contentTransition(.numericText(countsDown: step.direction > 0))
                    .monospacedDigit()
                Text(step.back == 0 ? "Swipe right for earlier periods" : "Each card steps by its own period")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if step.back > 0 {
                Button("Latest", action: toLatest)
                    .dsFont(.label)
                    .transition(.opacity)
            }
            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(step.back == 0)
        }
        .font(.body.weight(.semibold))
        .tint(Palette.brand)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Period")
        .accessibilityValue(InsightsPeriodStep.label(back: step.back))
        .accessibilityHint("Swipe up or down to show a later or earlier period. Each card steps by its own length.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Show Latest") { toLatest() }
    }
}

extension InsightsCard {
    /// Where this card's period ends at `step`, for a shared picture's footer; nil on the latest
    /// or for a card that keeps the latest.
    @MainActor
    func stepEnd(_ step: InsightsStep, newestReading: Date?, firstReading: Date?) -> Date? {
        guard step.back > 0, stepsWithPeriod,
              let days = InsightsPeriodStep.days(for: InsightsShare.period(for: self, firstReading: firstReading)) else { return nil }
        let latest = self == .glance ? Date() : newestReading
        return latest.map { InsightsPeriodStep.end(latest: $0, days: days, back: step.back) }
    }
}
