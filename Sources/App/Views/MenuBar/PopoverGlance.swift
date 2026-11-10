import SwiftUI

/// Time in range and summary stats over a chosen period, plus sensor life. Second in the
/// hierarchy: the hero says "now", this says "lately".
struct PopoverGlanceCard: View {
    @EnvironmentObject var store: GlucoseStore
    @AppStorage("popoverGlanceWindow") private var windowRaw = GlanceWindow.day.rawValue

    private var s: GlucoseSnapshot { store.snapshot }
    private var window: GlanceWindow { GlanceWindow(rawValue: windowRaw) ?? .day }

    var body: some View {
        let st = store.glanceStats(window)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Eyebrow(title: "At a glance", systemImage: "target")
                Picker("Summary period", selection: $windowRaw) {
                    ForEach(GlanceWindow.allCases) { w in
                        Text(w.shortLabel).tag(w.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("Summary period")
            }

            if let st {
                HStack(alignment: .center, spacing: 14) {
                    TimeInRangeRing(stats: st, lineWidth: 9)
                        .frame(width: 82, height: 82)
                    VStack(alignment: .leading, spacing: 7) {
                        legendRow("In range", Format.percent(st.timeInRange), GlucoseRange.inRange.tint,
                                  help: "Target is over 70%")
                        legendRow("Below", Format.percent(st.timeBelowRange), GlucoseRange.low.tint,
                                  help: "Target is under 4%")
                        legendRow("Above", Format.percent(st.timeAboveRange), GlucoseRange.high.tint,
                                  help: "Target is under 25%")
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Time in range, \(window.spokenLabel)")
                .accessibilityValue("\(Format.percent(st.timeInRange)) in range, \(Format.percent(st.timeBelowRange)) below, \(Format.percent(st.timeAboveRange)) above")

                HStack(spacing: 8) {
                    tile("Average", s.unit.format(mgdl: st.meanMgdl), systemImage: "chart.bar.fill",
                         help: "Mean glucose over the \(window.spokenLabel)")
                    tile("CV", Format.percent(st.coefficientOfVariation), systemImage: "waveform",
                         warn: st.coefficientOfVariation > 0.36,
                         help: "Variability over the \(window.spokenLabel). 36% or less is considered stable.")
                    if window == .fortnight {
                        tile("GMI", String(format: "%.1f%%", st.gmiPercent), systemImage: "drop.halffull",
                             help: "Glucose Management Indicator, an estimate of A1c from 14 days of readings")
                    } else {
                        tile("Range", "\(s.unit.format(mgdl: st.minMgdl))–\(s.unit.format(mgdl: st.maxMgdl))",
                             systemImage: "arrow.up.and.down",
                             help: "Lowest and highest reading over the \(window.spokenLabel)")
                    }
                }

                if st.spanHours < window.hours * 0.85 {
                    Label("Based on \(coverage(st.spanHours)) of readings so far", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No readings in the \(window.spokenLabel) yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sensor = s.sensor {
                Divider().opacity(0.5)
                SensorRow(sensor: sensor)
            }
        }
        .glassCard(padding: 12)
    }

    private func coverage(_ hours: Double) -> String {
        if hours < 24 { return "\(max(1, Int(hours.rounded()))) hours" }
        let days = hours / 24
        return days < 1.95 ? "1 day" : "\(Int(days.rounded(.down))) days"
    }

    private func legendRow(_ title: String, _ value: String, _ color: Color, help: String) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(color.gradient).frame(width: 4, height: 14)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .help(help)
    }

    private func tile(_ title: String, _ value: String, systemImage: String, warn: Bool = false, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// Sensor life as a ring plus the expiry time.
private struct SensorRow: View {
    let sensor: SensorInfo

    var body: some View {
        let remaining = sensor.daysRemaining()
        let fraction = sensor.lifetimeDays > 0 ? min(1, max(0, remaining / Double(sensor.lifetimeDays))) : 0
        let expiringSoon = remaining < 1
        let tint: Color = expiringSoon ? .orange : Palette.brand
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(fraction: fraction, tint: tint, lineWidth: 3)
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(remaining <= 0 ? "Sensor ended" : "Sensor · \(Format.days(remaining)) left")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(expiringSoon ? Color.orange : Color.primary)
                Text("Expires \(sensor.expires.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .help("Serial \(sensor.serial)")
        .accessibilityElement(children: .combine)
    }
}

/// The latest insulin dose and meal from the logbook, so "did I already bolus?" is answered
/// without opening the dashboard. Hidden when nothing was logged in the last 12 hours.
struct PopoverRecentActivity: View {
    @EnvironmentObject var logbook: LogbookStore
    var onOpen: () -> Void

    var body: some View {
        let recent = logbook.recentActivity()
        if recent.dose != nil || recent.meal != nil {
            Button(action: onOpen) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 8) {
                        if let d = recent.dose {
                            chip(systemImage: "syringe.fill",
                                 title: "\(LogFormat.units(d.units)) \(d.displayName)",
                                 age: context.date.timeIntervalSince(d.timestamp),
                                 tint: Palette.brand)
                        }
                        if let m = recent.meal {
                            chip(systemImage: "fork.knife",
                                 title: mealTitle(m),
                                 age: context.date.timeIntervalSince(m.timestamp),
                                 tint: GlucoseRange.high.tint)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassCard(padding: 10)
            .help("Open the logbook in the Dashboard")
            .accessibilityLabel(accessibilityLabel(recent))
            .accessibilityHint("Opens the Dashboard")
        }
    }

    private func mealTitle(_ m: MealEntry) -> String {
        if m.carbs > 0 { return m.food.isEmpty ? LogFormat.grams(m.carbs) : "\(LogFormat.grams(m.carbs)) \(m.food)" }
        return m.food.isEmpty ? "Meal" : m.food
    }

    private func chip(systemImage: String, title: String, age: TimeInterval, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(PopoverFormat.ageAgo(age))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 150, alignment: .leading)
    }

    private func accessibilityLabel(_ recent: (dose: InsulinDose?, meal: MealEntry?)) -> String {
        var parts: [String] = []
        let now = Date()
        if let d = recent.dose {
            parts.append("Last dose \(LogFormat.number(d.units)) units \(d.displayName), \(PopoverFormat.ageAgo(now.timeIntervalSince(d.timestamp)))")
        }
        if let m = recent.meal {
            parts.append("Last meal \(m.carbs > 0 ? "\(LogFormat.number(m.carbs)) grams" : m.food), \(PopoverFormat.ageAgo(now.timeIntervalSince(m.timestamp)))")
        }
        return parts.joined(separator: ". ")
    }
}
