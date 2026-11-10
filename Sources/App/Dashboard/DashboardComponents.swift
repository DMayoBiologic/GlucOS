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
    /// The dashboard's glass card. Fills the height it's offered, so cards side by side in a
    /// `CardGrid` row line up top and bottom.
    func dashboardCard() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(padding: 18, radius: 18)
    }
}

// MARK: - Card grid

/// Lays cards out in as many equal columns as fit, at least `minColumnWidth` each, and always
/// fills the width: a short last row shares the full width rather than leaving a hole. Cards in
/// a row are given the row's height so they line up.
struct CardGrid: Layout {
    var minColumnWidth: CGFloat = 300
    var maxColumns = 3
    var spacing: CGFloat = 16

    private func columns(for width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        // SwiftUI can probe a layout with an infinite width; Int(.infinity) would trap.
        guard width.isFinite else { return max(1, min(count, maxColumns)) }
        let fit = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        return max(1, min(count, maxColumns, fit))
    }

    /// Indices of the subviews in each row.
    private func rows(count: Int, columns: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: columns).map { $0..<min(count, $0 + columns) }
    }

    private func itemWidth(_ width: CGFloat, inRowOf n: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n))
    }

    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [(Range<Int>, CGFloat)] {
        let cols = columns(for: width, count: subviews.count)
        return rows(count: subviews.count, columns: cols).map { row in
            let w = itemWidth(width, inRowOf: row.count)
            let h = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
            return (row, h)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = minColumnWidth * CGFloat(min(maxColumns, max(1, subviews.count)))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let heights = rowHeights(subviews, width: width).map { $0.1 }
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, width: bounds.width) {
            let w = itemWidth(bounds.width, inRowOf: row.count)
            var x = bounds.minX
            for i in row {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: height))
                x += w + spacing
            }
            y += height + spacing
        }
    }
}

// MARK: - Notices

/// Something the dashboard needs to tell you, shown as a `StatusBanner` above the section.
struct DashboardNotice: Identifiable {
    /// Stable for the same problem, so dismissing hides only that one.
    let id: String
    let severity: BannerSeverity
    var systemImage: String?
    let title: String
    var message: String?
    var action: BannerAction?
    var secondaryAction: BannerAction?
    /// Critical notices and the ones about the data on screen can't be dismissed.
    var dismissible = false
}

/// The stack of notices at the top of the dashboard, most serious first.
struct DashboardNoticeStack: View {
    let notices: [DashboardNotice]
    @Binding var dismissed: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = notices.filter { !dismissed.contains($0.id) }.sorted { $0.severity < $1.severity }
        VStack(spacing: 8) {
            ForEach(shown) { n in
                StatusBanner(severity: n.severity, systemImage: n.systemImage, title: n.title, message: n.message,
                             action: n.action, secondaryAction: n.secondaryAction,
                             onDismiss: n.dismissible ? { dismiss(n.id) } : nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, shown.isEmpty ? 0 : 20)
        .padding(.top, shown.isEmpty ? 0 : 14)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: shown.map(\.id))
    }

    private func dismiss(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { _ = dismissed.insert(id) }
    }
}

/// A short-lived message that slides up from the bottom of the window, for things like a
/// failed export. Replaces the unstyled system alert.
struct DashboardToast: Identifiable, Equatable {
    let id = UUID()
    let severity: BannerSeverity
    let title: String
    var message: String?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
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

/// Tracks the dashboard's NSWindow for what SwiftUI can't do on macOS 14: floating above other
/// windows, and entering or leaving full screen from a button.
@MainActor
final class DashboardWindowState: ObservableObject {
    @Published private(set) var isFullScreen = false
    private weak var window: NSWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = false }
            },
        ]
    }

    func toggleFullScreen() {
        guard let window else { return }
        // A floating window can't go full screen cleanly; drop to normal level first.
        if !window.styleMask.contains(.fullScreen) { window.level = .normal }
        window.toggleFullScreen(nil)
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// Reaches the hosting NSWindow to set its level, allow full screen, and hand it to
/// `DashboardWindowState`.
struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool
    var state: DashboardWindowState?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        let state = state
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if !window.styleMask.contains(.fullScreen) { window.level = level }
            // Full-screen and Split View work like any other document-style window.
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            MainActor.assumeIsolated { state?.attach(window) }
        }
    }
}
