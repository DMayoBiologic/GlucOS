import SwiftUI
import AppKit

/// Fits the Mac Settings window to a newly picked tab (docs/SettingsTabs.md): after a switch, the
/// new tab's Form reports how tall its content is, and the window's height glides there with the
/// title bar held still. Snaps under Reduce Motion. The rules are `SettingsWindowFit`.
@MainActor
final class SettingsWindowFitter: ObservableObject {
    /// The Settings window, found once the view is in it.
    weak var window: NSWindow?
    /// False while the window is opening, so it opens at the size it had and never jumps, and the
    /// tab it opens on is simply there.
    @Published private(set) var settled = false

    private struct Measure { let container: Double; let needed: Double }
    private var measures: [String: Measure] = [:]
    private var pendingTab: String?
    private var fitTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    func opened() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.settled = true
        }
    }

    func closed() {
        settleTask?.cancel()
        fitTask?.cancel()
        settled = false
        pendingTab = nil
    }

    /// A different tab was picked: fit the window to it once it has measured.
    func switched(to tab: String) {
        guard settled else { return }
        pendingTab = tab
        scheduleFit()
    }

    /// The tab's scroll view: its own height and what its content wants.
    func report(tab: String, container: Double, needed: Double) {
        measures[tab] = Measure(container: container, needed: needed)
        if pendingTab == tab { scheduleFit() }
    }

    private func scheduleFit() {
        fitTask?.cancel()
        fitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SettingsWindowFit.measureDelay))
            guard !Task.isCancelled else { return }
            self?.fit()
        }
    }

    private func fit() {
        guard let tab = pendingTab, let measure = measures[tab], measure.needed > 0,
              let window, !window.inLiveResize else { return }
        pendingTab = nil
        let frame = window.frame
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let chrome = Double(frame.height - window.contentLayoutRect.height)
        let height = SettingsWindowFit.fittedHeight(window: Double(frame.height), container: measure.container,
                                                    needed: measure.needed, chrome: chrome,
                                                    screenHeight: Double(visible.height))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let step = SettingsWindowFit.step(from: Double(frame.height), to: height,
                                                settled: settled, reduceMotion: reduceMotion) else { return }
        let y = SettingsWindowFit.originY(top: Double(frame.maxY), height: height,
                                          visibleMinY: Double(visible.minY), visibleMaxY: Double(visible.maxY))
        let target = NSRect(x: frame.minX, y: y, width: frame.width, height: height)
        switch step {
        case .snap:
            window.setFrame(target, display: true)
        case .glide:
            // The same length as the content cross-fade (DSMotion.standard), so both land together.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(target, display: true)
            }
        }
    }
}

private struct SettingsWindowFitterKey: EnvironmentKey {
    static let defaultValue: SettingsWindowFitter? = nil
}

extension EnvironmentValues {
    /// The Settings window's fitter, if this view is in the Settings window.
    var settingsWindowFitter: SettingsWindowFitter? {
        get { self[SettingsWindowFitterKey.self] }
        set { self[SettingsWindowFitterKey.self] = newValue }
    }
}

extension View {
    /// Reports this tab's Form height to the Settings window's fitter. Needs macOS 15's scroll
    /// geometry; on macOS 14 tabs still cross-fade and the window keeps its height.
    func settingsTabMeasure(_ tab: String) -> some View {
        modifier(SettingsTabMeasure(tab: tab))
    }

    /// Hands the hosting window to `found` once the view is in it.
    func settingsWindowReader(_ found: @escaping (NSWindow?) -> Void) -> some View {
        background(SettingsWindowReader(found: found).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct SettingsTabMeasure: ViewModifier {
    let tab: String
    @Environment(\.settingsWindowFitter) private var fitter

    private struct Fit: Equatable { var container: Double; var needed: Double }

    func body(content: Content) -> some View {
        if let fitter {
            if #available(macOS 15.0, *) {
                content.onScrollGeometryChange(for: Fit.self) { geo in
                    Fit(container: geo.containerSize.height,
                        needed: geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom)
                } action: { _, fit in
                    fitter.report(tab: tab, container: fit.container, needed: fit.needed)
                }
            } else {
                content
            }
        } else {
            content
        }
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowView: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [found] in found(window) }
        }
    }
}
