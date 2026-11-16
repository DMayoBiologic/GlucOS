import SwiftUI
import WidgetKit

// The Live Activity while a new sensor warms up (`GlucoseActivityState.warmUpEndsAt`): a ring that
// fills over the sensor's first hour and a countdown to its first reading. Both are the system's
// own timer views, so they keep moving on the Lock Screen without an update from the app or the
// relay, and they stop at the end of the hour. Nothing loops. When the first reading arrives the
// card cross-fades to the usual reading layout (ActivityKit animates the swap; a fade only).

/// The ring: fills from the sensor's start to its first reading. Drawn by the system from the two
/// dates, so it needs no updates between pushes.
struct WarmUpActivityRing: View {
    let state: GlucoseActivityState
    var size: CGFloat

    var body: some View {
        let end = state.warmUpEnd ?? state.warmUpStart
        ProgressView(timerInterval: state.warmUpStart...max(end, state.warmUpStart.addingTimeInterval(1)),
                     countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(Tone.brand.color)
        .frame(width: size, height: size)
        .overlay {
            Image(systemName: "sensor.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Tone.brand.color)
        }
        .accessibilityHidden(true)
    }
}

/// "12:34" counting down to the first reading.
struct WarmUpCountdown: View {
    let state: GlucoseActivityState
    /// Widgets size timer text for its widest value, so it gets a fixed width.
    var width: CGFloat = 44

    var body: some View {
        let end = state.warmUpEnd ?? Date()
        Text(timerInterval: Date.now...max(end, Date.now), countsDown: true, showsHours: false)
            .monospacedDigit()
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
    }
}

extension GlucoseActivityState {
    /// "Readings start around 9:41": stays true however long the card goes without an update.
    var warmUpLine: String {
        guard let end = warmUpEnd else { return "Readings start soon" }
        return "Readings start around \(ClockLabel.time(end))"
    }

    /// The clock time only. A Live Activity's views are drawn when an update arrives, not as the
    /// timer runs, so a "42 minutes left" worked out here would still be read out long after it
    /// stopped being true; the time it ends stays right. The countdown is the drawn timer.
    var warmUpAccessibility: String {
        guard let end = warmUpEnd else { return "Sensor warming up. Readings start soon." }
        return "Sensor warming up. Readings start around \(ClockLabel.time(end))."
    }
}

/// The Lock Screen card during warm-up: the same frame as the reading card, so the swap to the
/// first reading is a fade in place.
struct WarmUpLockScreenCard: View {
    let state: GlucoseActivityState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            WarmUpActivityRing(state: state, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sensor warming up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Readings in")
                        .font(.headline)
                    WarmUpCountdown(state: state, width: 64)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }
                Text(state.warmUpLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background { RangeField(tone: .brand, intensity: 0.5) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.warmUpAccessibility)
    }
}

/// The Apple Watch Smart Stack and CarPlay layout during warm-up.
struct WarmUpSmallCard: View {
    let state: GlucoseActivityState

    var body: some View {
        HStack(spacing: 8) {
            WarmUpActivityRing(state: state, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Warming up").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                WarmUpCountdown(state: state, width: 48)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.warmUpAccessibility)
    }
}
