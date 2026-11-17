import SwiftUI

/// The popover's top card while a new sensor warms up (`SensorWarmUp`), in place of the old
/// sensor's last reading: a ring filling over the hour with the minutes left inside, and when the
/// first reading is due. The same countdown as iPhone Today.
///
/// Redrawn only at the moments the countdown reads differently (once a minute, then at the end of
/// the warm-up), with one short ease per step and none under Reduce Motion. Nothing loops.
struct PopoverWarmUpCard: View {
    @EnvironmentObject var store: GlucoseStore
    let warmUp: SensorWarmUp
    var onRefresh: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverLayout.heroRadius, style: .continuous)
    }

    var body: some View {
        TimelineView(.explicit(warmUp.changeMoments(from: Date()))) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        let minutes = warmUp.minutesLeft(at: now)
        return HStack(alignment: .center, spacing: DS.Space.md) {
            WarmUpRing(fraction: warmUp.fraction(at: now), minutes: minutes, size: 64)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Sensor warming up")
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                Text(warmUp.headline(at: now))
                    .dsFont(.headline)
                    .contentTransition(.numericText(value: Double(minutes)))
                    .fixedSize(horizontal: false, vertical: true)
                Text(minutes > 0
                     ? "First reading around \(ClockLabel.time(warmUp.endsAt)). It fades in here when it arrives."
                     : "LibreLinkUp can take a few minutes to pass on the first reading.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .dsAnimation(.standard, value: minutes)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .hero(.brand), radius: PopoverLayout.heroRadius) }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(warmUp.spoken(at: now))
        .accessibilityAddTraits([.isHeader, .updatesFrequently])
        .accessibilityAction(named: "Refresh", onRefresh)
        .contextMenu {
            Button("Refresh Now", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(store.isRefreshing)
        }
    }
}

/// The popover's top card once the sensor has ended (`SensorEnd.Ended`, docs/SensorEnd.md), in
/// place of its last reading: what happened and how to start a new one, the same as iPhone Today.
/// The new sensor's warm-up card fades in over it when LibreLinkUp reports the start.
struct PopoverSensorEndedCard: View {
    @EnvironmentObject var store: GlucoseStore
    let ended: SensorEnd.Ended
    let now: Date
    var onRefresh: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverLayout.heroRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SensorEndedContent(ended: ended, now: now, unit: store.shownUnit, titleFont: .headline, iconSize: 48)
            Button(action: onRefresh) {
                Label(store.isRefreshing ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .hero(.warning), radius: PopoverLayout.heroRadius) }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SensorEndedContent.spoken(ended, now: now, unit: store.shownUnit))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Check Again", onRefresh)
        .contextMenu {
            Button("Refresh Now", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(store.isRefreshing)
        }
    }
}
