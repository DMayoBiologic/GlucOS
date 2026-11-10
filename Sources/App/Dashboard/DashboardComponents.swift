import SwiftUI
import AppKit

// Building blocks shared by the dashboard's sections.

struct CardTitle: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let sub: String?
    let tint: Color?
    let helpText: String?

    init(_ title: String, _ value: String, sub: String? = nil, tint: Color? = nil, help: String? = nil) {
        self.title = title
        self.value = value
        self.sub = sub
        self.tint = tint
        self.helpText = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let sub { Text(sub).font(.caption2).foregroundStyle(tint ?? Color.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct HistoryNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Disclaimer: View {
    var body: some View {
        Text("Not a medical device. Confirm on your phone before treating.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

extension View {
    func dashboardCard() -> some View {
        glassCard(padding: 18, radius: 18)
    }
}

// MARK: - Banner

/// A full-width notice pinned to the top of the dashboard: stale data, or browsing the past.
struct DashboardBanner: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.08))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Change vs the previous period

/// "▲ 4 pts" style change. `goodWhenUp` nil means the direction isn't good or bad.
struct DeltaLabel: View {
    let text: String
    let delta: Double
    var goodWhenUp: Bool?

    var body: some View {
        let up = delta > 0
        let flat = abs(delta) < 0.0001
        let tint: Color = {
            guard let goodWhenUp, !flat else { return .secondary }
            return up == goodWhenUp ? GlucoseRange.inRange.tint : .orange
        }()
        HStack(spacing: 2) {
            Image(systemName: flat ? "equal" : (up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"))
                .imageScale(.small)
            Text(text).monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flat ? "no change from the previous period"
                                 : "\(up ? "up" : "down") \(text) from the previous period")
    }
}

enum DeltaFormat {
    /// Change in a fraction, as percentage points: "4 pts".
    static func points(_ delta: Double) -> String {
        let pts = abs(delta * 100)
        return pts < 1 && pts > 0 ? String(format: "%.1f pts", pts) : String(format: "%.0f pts", pts)
    }

    static func glucose(_ deltaMgdl: Double, unit: GlucoseUnit) -> String {
        unit.format(mgdl: abs(deltaMgdl))
    }
}

// MARK: - Sparkline

/// A tiny glucose trace with the target band behind it, coloured by range like the main chart.
/// Grey when the data is stale.
struct GlucoseSparkline: View {
    /// Oldest → newest.
    let readings: [GlucoseReading]
    let domain: ClosedRange<Date>
    let lowMgdl: Double
    let highMgdl: Double
    var stale = false
    var lineWidth: CGFloat = 1.5
    var showsBand = true

    var body: some View {
        GeometryReader { geo in
            let values = readings.map(\.mgdl)
            if let lo = values.min(), let hi = values.max() {
                let minV = min(lo, lowMgdl) - 5
                let maxV = max(hi, highMgdl) + 5
                let span = max(1, maxV - minV)
                let total = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
                let w = geo.size.width, h = geo.size.height
                let y: (Double) -> CGFloat = { CGFloat(1 - ($0 - minV) / span) * h }
                let x: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(domain.lowerBound) / total) * w }
                ZStack {
                    if showsBand {
                        Rectangle()
                            .fill((stale ? Palette.stale : GlucoseRange.inRange.tint).opacity(0.10))
                            .frame(height: max(1, y(lowMgdl) - y(highMgdl)))
                            .position(x: w / 2, y: (y(lowMgdl) + y(highMgdl)) / 2)
                    }
                    Path { p in
                        var previous: Date?
                        for r in readings {
                            let pt = CGPoint(x: x(r.timestamp), y: y(r.mgdl))
                            if let previous, r.timestamp.timeIntervalSince(previous) <= 30 * 60 {
                                p.addLine(to: pt)
                            } else {
                                p.move(to: pt)
                            }
                            previous = r.timestamp
                        }
                    }
                    .stroke(stale
                            ? AnyShapeStyle(Palette.stale)
                            : AnyShapeStyle(ThresholdGradient.style(minMgdl: minV, maxMgdl: maxV, low: lowMgdl, high: highMgdl)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Range breakdown bar

struct MiniRangeBar: View {
    let breakdown: RangeBreakdown

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(breakdown.rows.reversed().filter { $0.fraction > 0.001 }) { row in
                    Rectangle()
                        .fill(row.range.reportColor)
                        .frame(width: max(1, geo.size.width * row.fraction))
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - Window

/// Reaches the hosting NSWindow for what SwiftUI can't set on macOS 14 (floating level).
struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = level
            // Full-screen and Split View work like any other document-style window.
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}
