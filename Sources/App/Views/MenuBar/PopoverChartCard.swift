import SwiftUI
import AppKit

/// The recent-history chart. Hover to inspect a reading, or click the chart and step through
/// readings with the arrow keys (Home / End jump to the ends, Escape clears).
struct PopoverChartCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var showsShortcuts: Bool

    @FocusState private var chartFocused: Bool
    @State private var pinned: Date?

    private var s: GlucoseSnapshot { store.snapshot }

    /// The readings the chart is showing, oldest → newest.
    private var window: [GlucoseReading] {
        guard let last = s.history.last else { return [] }
        let cutoff = last.timestamp.addingTimeInterval(-Double(settings.chartHours) * 3600)
        return s.history.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        let window = self.window
        VStack(alignment: .leading, spacing: 10) {
            // While a reading is pinned, it takes the header's place rather than pushing the
            // chart down, so the popover doesn't change height under the pointer.
            ZStack(alignment: .leading) {
                if let date = pinned, let r = window.first(where: { $0.timestamp == date }) {
                    readout(r, in: window)
                        .transition(.opacity)
                } else {
                    header
                        .transition(.opacity)
                }
            }
            .frame(height: 24)
            .animation(PopoverMotion.quick(reduceMotion), value: pinned)
            let outlook = s.currentOutlook()
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                         hours: Double(settings.chartHours), interactive: true, pinnedDate: pinned,
                         forecast: settings.showForecast ? (outlook?.forecast ?? []) : [])
                .frame(height: 136)
                .focusable()
                .focused($chartFocused)
                .focusEffectDisabled()
                .overlay {
                    if chartFocused && pinned != nil {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .padding(-4)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.leftArrow) { step(-1, in: window) }
                .onKeyPress(.rightArrow) { step(1, in: window) }
                .onKeyPress(.home) { jump(to: window.first) }
                .onKeyPress(.end) { jump(to: window.last) }
                .onKeyPress(.escape) {
                    guard pinned != nil else { return .ignored }   // let Escape close the popover
                    pinned = nil
                    return .handled
                }
                .onChange(of: chartFocused) { _, focused in if !focused { pinned = nil } }
                .onChange(of: settings.chartHours) { _, _ in pinned = nil }
                .help("Hover to see readings, or click and use ← →")
                .accessibilityLabel("Glucose chart, last \(settings.chartHours) hours")
                .accessibilityValue(chartSummary(window))
                .accessibilityHint("Use the left and right arrow keys to step through readings")
            if let outlook, outlook.showsInsulin || (settings.showForecast && !outlook.forecast.isEmpty) {
                OutlookSummaryRow(outlook: settings.showForecast ? outlook : withoutForecast(outlook),
                                  unit: s.unit, lowMgdl: s.lowMgdl)
            }
        }
        .dsCard(.standard)
    }

    private func withoutForecast(_ o: OutlookSnapshot) -> OutlookSnapshot {
        var copy = o
        copy.forecast = []
        return copy
    }

    private var header: some View {
        HStack(spacing: 8) {
            Eyebrow(title: "Last \(settings.chartHours) hours", systemImage: "waveform.path.ecg")
                .accessibilityAddTraits(.isHeader)
            Picker("Chart range", selection: $settings.chartHours) {
                Text("3h").tag(3).accessibilityLabel("3 hours")
                Text("6h").tag(6).accessibilityLabel("6 hours")
                Text("12h").tag(12).accessibilityLabel("12 hours")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help("Chart range (⌘1, ⌘2, ⌘3)")
            .overlay(alignment: .bottom) {
                if showsShortcuts {
                    ShortcutBadge(text: "⌘1 ⌘2 ⌘3").offset(y: 16)
                }
            }
        }
    }

    private func readout(_ r: GlucoseReading, in window: [GlucoseReading]) -> some View {
        let range = GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl)
        let index = window.firstIndex(where: { $0.timestamp == r.timestamp }) ?? 0
        return HStack(spacing: 8) {
            Capsule().fill(range.tint.gradient).frame(width: 4, height: 16)
            Text(s.unit.format(mgdl: r.mgdl, withUnit: true))
                .dsFont(.sectionTitle)
                .monospacedDigit()
            Text(range.label)
                .dsFont(.label)
                .foregroundStyle(range.textTint)
            Spacer(minLength: 4)
            Text(r.timestamp.formatted(date: .omitted, time: .shortened))
                .dsFont(.label)
                .foregroundStyle(.secondary)
            Text("\(index + 1)/\(window.count)")
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background { DSSurface(style: .inset, radius: DS.Radius.control) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Keyboard stepping

    private func step(_ delta: Int, in window: [GlucoseReading]) -> KeyPress.Result {
        guard !window.isEmpty else { return .ignored }
        let target: GlucoseReading
        if let pinned, let i = window.firstIndex(where: { $0.timestamp == pinned }) {
            let j = min(window.count - 1, max(0, i + delta))
            target = window[j]
        } else {
            // First press starts from the newest reading, which is what's being compared against.
            target = window[window.count - 1]
        }
        return jump(to: target)
    }

    @discardableResult
    private func jump(to reading: GlucoseReading?) -> KeyPress.Result {
        guard let reading else { return .ignored }
        pinned = reading.timestamp
        let range = GlucoseRange.classify(mgdl: reading.mgdl, low: s.lowMgdl, high: s.highMgdl)
        VoiceOver.announce("\(s.unit.format(mgdl: reading.mgdl)) \(s.unit.spokenLabel), \(range.label), at \(reading.timestamp.formatted(date: .omitted, time: .shortened))")
        return .handled
    }

    private func chartSummary(_ window: [GlucoseReading]) -> String {
        guard let lo = window.min(by: { $0.mgdl < $1.mgdl }), let hi = window.max(by: { $0.mgdl < $1.mgdl }) else {
            return "No readings"
        }
        return "\(window.count) readings, lowest \(s.unit.format(mgdl: lo.mgdl)) at \(lo.timestamp.formatted(date: .omitted, time: .shortened)), highest \(s.unit.format(mgdl: hi.mgdl)) at \(hi.timestamp.formatted(date: .omitted, time: .shortened))"
    }
}

/// Little key-cap label shown under a control while ⌘ is held.
struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

@MainActor
enum VoiceOver {
    /// Speaks `text` if VoiceOver is running. Does nothing otherwise.
    static func announce(_ text: String) {
        guard let element = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
