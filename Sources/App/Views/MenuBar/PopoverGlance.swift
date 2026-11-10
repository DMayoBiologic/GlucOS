import SwiftUI

/// Time in range over a chosen period, plus the last dose and meal. Second in the hierarchy:
/// the hero says "now", this says "lately".
///
/// Collapsed it's one bar and one legend line. "Details" (⌘I) adds average, variability,
/// GMI or range, and sensor life, so the popover stays short until you ask for more.
struct PopoverSummaryCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("popoverGlanceWindow") private var windowRaw = GlanceWindow.day.rawValue

    /// The remembered preference. What's drawn is `expanded && there are stats to show`.
    var expanded: Bool
    var showsShortcuts: Bool
    var onToggleDetails: () -> Void
    var onOpenDashboard: () -> Void

    private var s: GlucoseSnapshot { store.snapshot }
    private var window: GlanceWindow { GlanceWindow(rawValue: windowRaw) ?? .day }

    var body: some View {
        let st = store.glanceStats(window)
        let isExpanded = expanded && st != nil
        VStack(alignment: .leading, spacing: 10) {
            header(canExpand: st != nil, isExpanded: isExpanded)

            if let st {
                VStack(alignment: .leading, spacing: 8) {
                    TimeInRangeBar(stats: st, height: 8)
                        .accessibilityHidden(true)   // the legend below says the same in words
                    legend(st)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time in range, \(window.spokenLabel)")
                .accessibilityValue("\(Format.percent(st.timeInRange)) in range, \(Format.percent(st.timeBelowRange)) below, \(Format.percent(st.timeAboveRange)) above")
                .help("Targets: over 70% in range, under 4% below, under 25% above")

                if isExpanded {
                    details(st)
                        .transition(PopoverMotion.reveal(reduceMotion))
                }
            } else {
                Text("No readings in the \(window.spokenLabel) yet.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PopoverRecentActivity(onOpen: onOpenDashboard)
        }
        .dsCard(.standard)
        .animation(PopoverMotion.standard(reduceMotion), value: expanded)
        .animation(PopoverMotion.standard(reduceMotion), value: windowRaw)
    }

    // MARK: Header

    private func header(canExpand: Bool, isExpanded expanded: Bool) -> some View {
        HStack(spacing: 6) {
            periodMenu
            Spacer(minLength: 4)
            Button(action: onToggleDetails) {
                HStack(spacing: 3) {
                    Text("Details")
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .fontWeight(.semibold).dsFont(.label)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(expanded ? 0.09 : 0.05), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .help(expanded ? "Hide details (⌘I)" : "Show average, variability and sensor life (⌘I)")
            .accessibilityLabel("Details")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .overlay(alignment: .bottom) {
                if showsShortcuts { ShortcutBadge(text: "⌘I").offset(y: 15) }
            }
        }
    }

    /// The period as a compact menu in the eyebrow, rather than a second segmented control.
    private var periodMenu: some View {
        Menu {
            Picker("Summary period", selection: $windowRaw) {
                ForEach(GlanceWindow.allCases) { w in
                    Text(w.menuLabel).tag(w.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "target").imageScale(.small)
                Text(window.spokenLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .dsFont(.eyebrow)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Summary period")
        .accessibilityLabel("Summary period")
        .accessibilityValue(window.spokenLabel)
    }

    // MARK: Collapsed

    private func legend(_ st: GlucoseStats) -> some View {
        HStack(spacing: 0) {
            legendItem("In range", st.timeInRange, GlucoseRange.inRange.tint, emphasised: true)
            legendItem("Below", st.timeBelowRange, GlucoseRange.low.tint)
            legendItem("Above", st.timeAboveRange, GlucoseRange.high.tint)
        }
    }

    private func legendItem(_ title: String, _ value: Double, _ color: Color, emphasised: Bool = false) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(Format.percent(value))
                .fontWeight(.bold)
                .dsFont(emphasised ? .headline : .callout)
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
            Text(title)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Expanded

    private func details(_ st: GlucoseStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tile("Average", s.unit.format(mgdl: st.meanMgdl), unit: s.unit.label,
                     help: "Mean glucose over the \(window.spokenLabel)")
                tile("Variability", Format.percent(st.coefficientOfVariation), unit: "CV",
                     warn: st.coefficientOfVariation > 0.36,
                     help: "Coefficient of variation over the \(window.spokenLabel). 36% or less is considered stable.")
                if window == .fortnight {
                    tile("GMI", String(format: "%.1f%%", st.gmiPercent), unit: "est. A1c",
                         help: "Glucose Management Indicator, an estimate of A1c from 14 days of readings")
                } else {
                    tile("Range", "\(s.unit.format(mgdl: st.minMgdl))–\(s.unit.format(mgdl: st.maxMgdl))",
                         unit: s.unit.label,
                         help: "Lowest and highest reading over the \(window.spokenLabel)")
                }
            }

            if st.spanHours < window.hours * 0.85 {
                Label("Based on \(coverage(st.spanHours)) of readings so far", systemImage: "info.circle")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sensor = s.sensor {
                SensorRow(sensor: sensor)
            }
        }
    }

    private func coverage(_ hours: Double) -> String {
        if hours < 24 { return "\(max(1, Int(hours.rounded()))) hours" }
        let days = hours / 24
        return days < 1.95 ? "1 day" : "\(Int(days.rounded(.down))) days"
    }

    private func tile(_ title: String, _ value: String, unit: String, warn: Bool = false, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.medium).dsFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .dsFont(.sectionTitle)
                .foregroundStyle(warn ? Tone.warning.textColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(unit)
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .padding(.vertical, DS.Space.sm - 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .inset, radius: PopoverLayout.tileRadius) }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unit == "CV" ? value + (warn ? ", above the 36% target" : "") : "\(value) \(unit)")
    }
}

/// Sensor life as a ring plus the expiry time.
private struct SensorRow: View {
    let sensor: SensorInfo

    var body: some View {
        let remaining = sensor.daysRemaining()
        let fraction = sensor.lifetimeDays > 0 ? min(1, max(0, remaining / Double(sensor.lifetimeDays))) : 0
        let expiringSoon = remaining < 1
        let tint: Color = expiringSoon ? Tone.warning.color : Palette.brand
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(fraction: fraction, tint: tint, lineWidth: 3)
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(remaining <= 0 ? "Sensor ended" : "Sensor · \(Format.days(remaining)) left")
                    .fontWeight(.semibold).dsFont(.headline)
                    .monospacedDigit()
                    .foregroundStyle(expiringSoon ? Tone.warning.textColor : Color.primary)
                Text("Expires \(sensor.expires.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .padding(.vertical, DS.Space.sm - 1)
        .background { DSSurface(style: .inset, radius: PopoverLayout.tileRadius) }
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
            VStack(spacing: 8) {
                DSDivider()
                Button(action: onOpen) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HStack(spacing: 12) {
                            if let d = recent.dose {
                                chip(systemImage: "syringe.fill",
                                     title: "\(LogFormat.units(d.units)) \(d.displayName)",
                                     age: context.date.timeIntervalSince(d.timestamp),
                                     tint: Palette.insulin)
                            }
                            if let m = recent.meal {
                                chip(systemImage: "fork.knife",
                                     title: mealTitle(m),
                                     age: context.date.timeIntervalSince(m.timestamp),
                                     tint: Palette.food)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .fontWeight(.semibold).dsFont(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the logbook in the Dashboard")
                .accessibilityLabel(accessibilityLabel(recent))
                .accessibilityHint("Opens the Dashboard")
            }
        }
    }

    private func mealTitle(_ m: MealEntry) -> String {
        if m.carbs > 0 { return m.food.isEmpty ? LogFormat.grams(m.carbs) : "\(LogFormat.grams(m.carbs)) \(m.food)" }
        return m.food.isEmpty ? "Meal" : m.food
    }

    private func chip(systemImage: String, title: String, age: TimeInterval, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .fontWeight(.semibold).dsFont(.label)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .fontWeight(.semibold).dsFont(.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(PopoverFormat.ageAgo(age))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 140, alignment: .leading)
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
