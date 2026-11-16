import SwiftUI

// "Meal 1 h 40 m ago · 45 g" under the chart, on iPhone Today and in the Mac popover
// (`LastLogged`). A tap opens that entry in the Logbook. It says only what was logged.

/// The line, or nothing when nothing was logged in the last 12 hours. Redraws once a minute, on the
/// minute the entry's age ticks over, and never animates on its own: the figure rolls once when it
/// changes, and just changes under Reduce Motion.
struct LastLoggedLine: View {
    let entries: [LogEntry]
    let open: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let last = LastLogged.latest(entries, now: Date())
        Group {
            if let last {
                // Ticks from the entry's own time, so "1 m ago" arrives on the minute rather than up
                // to a minute late. A newer entry redraws this view through `entries`.
                TimelineView(.periodic(from: last.timestamp, by: 60)) { ctx in
                    let now = max(ctx.date, Date())
                    if now.timeIntervalSince(last.timestamp) <= LastLogged.window {
                        line(last, now: now)
                    }
                }
                .transition(.opacity)
            }
        }
        // In and out once as the first entry arrives or the last one ages past 12 hours.
        .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: last?.entryID)
    }

    private func line(_ last: LastLogged, now: Date) -> some View {
        Button { open(last.entryID) } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: Self.symbol(last.kind))
                    .imageScale(.small)
                    .foregroundStyle(Self.tint(last.kind))
                    .accessibilityHidden(true)
                Text(last.text(now: now))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: false))
                    .animation(reduceMotion ? nil : DSMotion.quick.animation, value: last.text(now: now))
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .dsFont(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in the Logbook")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(last.spoken(now: now))
        .accessibilityHint("Opens it in the Logbook")
        .accessibilityAddTraits(.isButton)
    }

    static func symbol(_ kind: LastLogged.Kind) -> String {
        switch kind {
        case .meal: return "fork.knife"
        case .dose: return "syringe.fill"
        case .site: return "cross.vial.fill"
        case .event: return "circle.fill"
        }
    }

    static func tint(_ kind: LastLogged.Kind) -> Color {
        switch kind {
        case .meal: return Palette.food
        case .dose: return Palette.insulin
        case .site: return Palette.site
        case .event: return Palette.context
        }
    }
}
