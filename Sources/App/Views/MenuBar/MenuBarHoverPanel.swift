import SwiftUI
import AppKit
import Combine

// The menu bar item's hover preview: rest the pointer on the reading for `hoverDelay` and a small
// panel drops in below it with the last two hours, the trend and how long ago the reading was
// taken (`MenuBarHoverPreview`). It fades in and out over a few frames (at once under Reduce
// Motion, as a still image), goes on any click (the click still opens the popover), and never
// opens while the popover is open. The panel ignores the mouse, never becomes key and is hidden
// from VoiceOver, so focus and the keyboard stay where they were; the item's own VoiceOver label
// already says everything in it. Settings › General › Menu Bar turns it off.
//
// Power: nothing runs until the pointer is on the item. A tracking area wakes it, one one-shot
// timer waits out the delay, and the card is drawn once per opening (again only if a new reading
// lands while it is open). There is no tick.

@MainActor
final class MenuBarHoverController {
    private let store: GlucoseStore
    private let settings: AppSettings
    /// Builds the preview at the moment it opens (the readings, plus the tooltip's notes).
    private let makePreview: (Date) -> MenuBarHoverPreview?

    private var phase: MenuBarHoverPreview.Phase = .idle
    private weak var button: NSStatusBarButton?
    private var tracker: HoverTrackingView?
    private var delay: Timer?
    private var panel: HoverPanel?
    private var hosting: NSHostingView<MenuBarHoverCard>?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    /// Bumped on each show and hide, so a fade-out finishing late doesn't close a newer opening.
    private var generation = 0

    init(store: GlucoseStore, settings: AppSettings, makePreview: @escaping (Date) -> MenuBarHoverPreview?) {
        self.store = store
        self.settings = settings
        self.makePreview = makePreview
        // A new reading while the card is open redraws it once. Turning the setting off closes it.
        store.$snapshot
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.redrawIfShowing() }
            .store(in: &cancellables)
        settings.$showMenuBarHoverPreview
            .removeDuplicates()
            .sink { [weak self] on in if !on { self?.handle(.interaction) } }
            .store(in: &cancellables)
    }

    /// Finds the status bar button and puts a tracking view on it. Cheap to call again: it only
    /// does anything when the button is new (the label reappearing gives a fresh one).
    func attach() {
        guard let found = StatusItemToolTip.button(), found !== button else { return }
        tracker?.removeFromSuperview()
        button = found
        let view = HoverTrackingView(frame: found.bounds)
        view.autoresizingMask = [.width, .height]
        view.onEnter = { [weak self] in self?.handle(.pointerEntered) }
        view.onExit = { [weak self] in self?.handle(.pointerExited) }
        found.addSubview(view)
        tracker = view
    }

    // MARK: State

    private var allowed: Bool {
        settings.showMenuBarHoverPreview && !Self.popoverIsOpen && store.snapshot.current != nil
    }

    static var popoverIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtra") }
    }

    private func handle(_ event: MenuBarHoverPreview.Event) {
        let old = phase
        let new = MenuBarHoverPreview.next(old, on: event, allowed: allowed)
        phase = new
        guard new != old else { return }
        switch new {
        case .idle, .dismissed:
            delay?.invalidate()
            delay = nil
            if old == .showing { hide() }
            if new == .idle { stopWatching() } else { startWatching() }
        case .pending:
            startWatching()
            let timer = Timer(timeInterval: MenuBarHoverPreview.hoverDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.delayElapsed) }
            }
            RunLoop.main.add(timer, forMode: .common)
            delay = timer
        case .showing:
            delay = nil
            if !show() { phase = .idle; stopWatching() }
        }
    }

    /// While the pointer is on the item: any click or key closes the card, and so does the popover
    /// (or any other window) coming forward, which also covers ⌘-opening it from the keyboard.
    private func startWatching() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(.interaction) }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.interaction) }
        }) { monitors.append(global) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.interaction) }
        })
    }

    private func stopWatching() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: Panel

    /// Draws the card and fades the panel in under the button. False if there is nothing to show.
    private func show() -> Bool {
        guard let button, let window = button.window, let preview = makePreview(Date()) else { return false }
        generation += 1
        let card = MenuBarHoverCard(preview: preview)
        let panel = self.panel ?? makePanel()
        if let hosting { hosting.rootView = card } else {
            let view = NSHostingView(rootView: card)
            view.setAccessibilityElement(false)
            hosting = view
            (panel.contentView as? NSVisualEffectView)?.addSubview(view)
        }
        guard let hosting else { return false }
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(Self.frame(size: size, under: anchor, screen: window.screen ?? NSScreen.main), display: false)

        let fades = MenuBarHoverPreview.fades(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.alphaValue = fades ? 0 : 1
        panel.orderFrontRegardless()
        if fades {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MenuBarHoverPreview.fadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        return true
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let mine = generation
        guard MenuBarHoverPreview.fades(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = MenuBarHoverPreview.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func redrawIfShowing() {
        guard phase == .showing, let hosting, let panel else { return }
        guard let preview = makePreview(Date()) else { handle(.interaction); return }
        hosting.rootView = MenuBarHoverCard(preview: preview)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> HoverPanel {
        let panel = HoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.setAccessibilityElement(false)
        panel.contentView = effect
        self.panel = panel
        return panel
    }

    /// Centred under the item, 4 pt below the menu bar, kept on screen.
    static func frame(size: NSSize, under anchor: NSRect, screen: NSScreen?) -> NSRect {
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 4 - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - 6 - size.width)
            origin.y = max(origin.y, visible.minY + 6)
        }
        return NSRect(origin: origin, size: size)
    }
}

/// A panel that never takes the keyboard or the key window from anything.
final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Watches the pointer over the status bar button without taking its clicks.
final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: - Card

/// The preview card. Static: nothing in it animates, so it is the same still image with or
/// without Reduce Motion; only the panel's fade differs.
struct MenuBarHoverCard: View {
    let preview: MenuBarHoverPreview

    private var valueColour: Color { preview.isStale ? Palette.staleText : preview.range.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(preview.valueText)
                    .strikethrough(preview.isStale, color: Palette.stale)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(valueColour)
                Text(preview.unitText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let trend = preview.trend {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(trend.needleAngle))
                        .foregroundStyle(valueColour)
                }
                Spacer(minLength: 8)
                if preview.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                }
                Text(preview.ageText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(preview.isStale ? Palette.staleText : .secondary)
            }
            HoverChart(preview: preview)
                .frame(height: 54)
            HStack {
                Text("2 h ago")
                Spacer()
                Text(preview.trendText)
                Spacer()
                Text("Now")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if let movement = preview.movementText {
                Text(movement)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(preview.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 232)
        .accessibilityHidden(true)
    }
}

/// The two hours as a line over the target band, with the latest reading as a dot.
private struct HoverChart: View {
    let preview: MenuBarHoverPreview

    var body: some View {
        Canvas { ctx, size in
            func pt(_ p: MenuBarHoverPreview.Point) -> CGPoint {
                CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
            }
            let band = CGRect(x: 0, y: (1 - preview.bandHigh) * size.height,
                              width: size.width, height: max(1, (preview.bandHigh - preview.bandLow) * size.height))
            ctx.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Palette.mint.opacity(0.14)))

            var line = Path()
            for p in preview.points {
                if p.startsSegment { line.move(to: pt(p)) } else { line.addLine(to: pt(p)) }
            }
            let stroke = preview.isStale ? Palette.stale : Color.primary.opacity(0.75)
            ctx.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            if let last = preview.points.last {
                let c = pt(last)
                let dot = CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: dot), with: .color(preview.isStale ? Palette.stale : last.range.tint))
            }
        }
    }
}
