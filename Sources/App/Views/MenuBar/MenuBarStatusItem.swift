import SwiftUI
import AppKit
import Combine

// The menu bar item: the reading in its range colour with an SF Symbol trend arrow, and optionally
// the last hour as a tiny sparkline. Stale readings turn grey, crossed through, with an amber
// warning sign and their age, the same treatment as the popover (#84).
//
// The item has to stay cheap, since it is on screen all day. It is drawn into an image only when
// its `MenuBarGlance` changes: a new reading, the moment a reading goes stale, each minute of a
// stale reading's age, or a setting. There is no tick and no animation loop. A new value rolls in
// over `DSMotion.arrival` as a short run of frames, once per reading. Losing the signal fades the
// value to grey as the strike draws in, and data returning reverses it, over `DSMotion.sweep`; the
// first reading after waiting fades in. Under Reduce Motion rolls are dropped and the stale changes
// are a quick cross-fade with the strike whole (`MenuBarGlance.Change`).
//
// SwiftUI draws a MenuBarExtra label as a monochrome template, so colour has to come from a
// non-template NSImage. The image holds a light and a dark rendering and picks one each time it is
// drawn, so it follows the menu bar's own appearance (which depends on the wallpaper, not the
// app) without being redrawn.

@MainActor
final class MenuBarStatusModel: ObservableObject {
    @Published private(set) var image: NSImage
    @Published private(set) var accessibilityLabel = "GlucOS"
    /// The item's tooltip (`MenuBarGlance.toolTip`), set on the status bar button directly.
    private(set) var toolTip = "GlucOS"

    private let store: GlucoseStore
    private let settings: AppSettings
    private var glance: MenuBarGlance?
    private var cancellables = Set<AnyCancellable>()
    private var nextChangeTimer: Timer?
    private var animation: Task<Void, Never>?

    /// Frames per second for a value change. Low on purpose: it is an 8 pt slide in the menu bar.
    private static let framesPerSecond = 24.0

    init(store: GlucoseStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
        image = NSImage(size: NSSize(width: 1, height: 1))

        // `$snapshot` fires before the value is stored, and a refresh sets it a few times in a row;
        // the debounce delivers once, after the store has settled.
        store.$snapshot
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Increase Contrast picks other colours; Reduce Motion is read when a value changes.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &cancellables)
        // A timer set while asleep may be well past due on wake.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    /// Works out the glance and redraws only if it differs from what's showing.
    func refresh(force: Bool = false, now: Date = Date()) {
        let snapshot = store.snapshot
        let next = MenuBarGlance.make(snapshot: snapshot,
                                      recent: settings.showMenuBarSparkline ? lastHour(now: now) : [],
                                      hasCredentials: settings.hasCredentials,
                                      showDelta: settings.showDeltaInMenuBar,
                                      showSparkline: settings.showMenuBarSparkline,
                                      colorByRange: settings.colorMenuBarIcon,
                                      now: now)
        scheduleNextChange(snapshot: snapshot, now: now)

        let back = settings.showForecast ? snapshot.backInRange(at: now)?.minutes : nil
        let label = Self.spokenLabel(for: next, snapshot: snapshot, backInRangeMinutes: back)
        if label != accessibilityLabel { accessibilityLabel = label }
        toolTip = MenuBarGlance.toolTip(snapshot: snapshot, hasCredentials: settings.hasCredentials,
                                        showForecast: settings.showForecast, now: now)
        StatusItemToolTip.apply(toolTip)

        guard force || next != glance else { return }
        let previous = glance
        glance = next
        show(next, from: force ? nil : previous)
    }

    // MARK: Drawing

    private func show(_ new: MenuBarGlance, from old: MenuBarGlance?) {
        animation?.cancel()
        let label = accessibilityLabel
        let change = MenuBarGlance.change(from: old, to: new)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let old, change != .none, !reduceMotion || change.keepsUnderReduceMotion else {
            image = MenuBarImage.render(new, previous: nil, change: .none, progress: 1, reduceMotion: reduceMotion,
                                        accessibilityLabel: label)
            return
        }
        // A roll is quick; going stale or coming back is a colour fade, on the sweep's timing.
        // Under Reduce Motion only the fades play, as a short cross-fade.
        let duration = reduceMotion ? 0.25 : (change.fadesColour ? DSMotion.sweep.duration : DSMotion.arrival.duration)
        let frames = max(2, Int((duration * Self.framesPerSecond).rounded()))
        let frameDelay = UInt64(duration / Double(frames) * 1_000_000_000)
        animation = Task { @MainActor [weak self] in
            for i in 1...frames {
                guard let self, !Task.isCancelled else { return }
                let last = i == frames
                let t = UnitCurve.easeInOut.value(at: Double(i) / Double(frames))
                self.image = MenuBarImage.render(new, previous: last ? nil : old, change: last ? .none : change,
                                                 progress: t, reduceMotion: reduceMotion, accessibilityLabel: label)
                if !last { try? await Task.sleep(nanoseconds: frameDelay) }
            }
        }
    }

    // MARK: Timing

    /// One timer, for the next moment the glance changes on its own (see `MenuBarGlance.nextChange`).
    private func scheduleNextChange(snapshot: GlucoseSnapshot, now: Date) {
        nextChangeTimer?.invalidate()
        nextChangeTimer = nil
        guard let date = MenuBarGlance.nextChange(snapshot: snapshot, now: now) else { return }
        let timer = Timer(fire: max(date, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        nextChangeTimer = timer
    }

    /// The archive's last hour, read from the end (it holds up to 90 days, oldest first), plus any
    /// newer readings in the snapshot.
    private func lastHour(now: Date) -> [GlucoseReading] {
        let cutoff = now.addingTimeInterval(-MenuBarGlance.sparklineWindow)
        var out: [GlucoseReading] = []
        for r in store.archive.reversed() {
            if r.timestamp < cutoff { break }
            out.append(r)
        }
        out.reverse()
        out.append(contentsOf: store.snapshot.history.filter { $0.timestamp >= cutoff })
        return out
    }

    // MARK: VoiceOver

    /// Names the app first, so VoiceOver users moving through the menu bar know whose item it is.
    /// A live reading leaves out its age, which would be out of date between readings; a stale one
    /// gives it to the minute.
    static func spokenLabel(for g: MenuBarGlance, snapshot: GlucoseSnapshot, backInRangeMinutes: Int? = nil) -> String {
        let unit = snapshot.unit
        switch g.state {
        case .notConnected: return "GlucOS, not connected"
        case .waiting: return "GlucOS, waiting for a reading"
        case .warmingUp:
            return "GlucOS, sensor warming up" + (snapshot.warmUp().map { ". \($0.headline())" } ?? "")
        case .stale:
            let age = g.ageText.map { " from \($0) ago" } ?? ""
            return "GlucOS, no new reading. Last reading \(g.valueText) \(unit.spokenLabel)\(age). Data is stale"
        case .live:
            var parts = ["GlucOS, glucose \(g.valueText) \(unit.spokenLabel)"]
            if let range = g.range { parts.append(range.label) }
            if let trend = g.trend, trend != .unknown { parts.append(trend.description) }
            if let d = g.deltaText { parts.append("change \(d.replacingOccurrences(of: "−", with: "minus "))") }
            if !g.sparkline.isEmpty, let first = g.sparkline.first, let last = g.sparkline.last {
                let hour = last - first > 0.15 ? "up" : (first - last > 0.15 ? "down" : "level")
                parts.append("\(hour) over the last hour")
            }
            var out = parts.joined(separator: ", ")
            if let backInRangeMinutes { out += ". " + BackInRangeText.spoken(minutes: backInRangeMinutes) }
            return out
        }
    }
}

// MARK: - Tooltip

/// MenuBarExtra doesn't hand a label's `.help` to its status bar button, so the tooltip is set on
/// the button itself. The button lives in the status item's own window; the popover's window is a
/// different one and is left alone.
@MainActor
enum StatusItemToolTip {
    static func apply(_ text: String) {
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            guard let button = statusButton(in: window.contentView) else { continue }
            if button.toolTip != text { button.toolTip = text }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let button = statusButton(in: sub) { return button }
        }
        return nil
    }
}

// MARK: - Image

enum MenuBarImage {
    /// Draws `glance` (with `previous` rolling out, at `progress` 0...1) into an image that picks
    /// its light or dark rendering each time the menu bar draws it.
    @MainActor
    static func render(_ glance: MenuBarGlance, previous: MenuBarGlance?, change: MenuBarGlance.Change,
                       progress: Double, reduceMotion: Bool, accessibilityLabel: String) -> NSImage {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        func cg(dark: Bool) -> CGImage? {
            let colours = MenuBarColours(dark: dark, highContrast: highContrast)
            let renderer = ImageRenderer(content: MenuBarGlanceView(glance: glance, previous: previous,
                                                                    change: change, progress: progress,
                                                                    reduceMotion: reduceMotion, colours: colours)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = scale
            return renderer.cgImage
        }
        guard let light = cg(dark: false), let dark = cg(dark: true) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let size = NSSize(width: CGFloat(light.width) / scale, height: CGFloat(light.height) / scale)
        let image = NSImage(size: size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.draw(isDark ? dark : light, in: rect)
            return true
        }
        image.isTemplate = false
        // Drawn fresh each time, so a change of menu bar appearance picks the other rendering.
        image.cacheMode = .never
        image.accessibilityDescription = accessibilityLabel
        return image
    }
}

/// Design-system colours resolved for one menu bar appearance. ImageRenderer doesn't know which
/// appearance the menu bar has, so every colour is resolved here instead of left dynamic.
struct MenuBarColours {
    let label: Color
    let secondary: Color
    let stale: Color
    let strike: Color
    let warning: Color
    let brand: Color
    private let appearance: NSAppearance

    init(dark: Bool, highContrast: Bool) {
        let name: NSAppearance.Name = switch (dark, highContrast) {
        case (true, true): .accessibilityHighContrastDarkAqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (false, false): .aqua
        }
        let app = NSAppearance(named: name) ?? NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance = app
        let resolve = { (c: NSColor) -> Color in Self.resolve(c, in: app) }
        label = resolve(.labelColor)
        secondary = resolve(.secondaryLabelColor)
        stale = resolve(NSColor(Palette.staleText))
        strike = resolve(NSColor(Palette.stale))
        warning = resolve(NSColor(Palette.amber))
        brand = resolve(NSColor(Palette.brand))
    }

    func rangeColour(_ range: GlucoseRange) -> Color {
        Self.resolve(NSColor(range.tint), in: appearance)
    }

    /// The value's colour: its range when coloured, grey when stale, plain text otherwise.
    func value(_ g: MenuBarGlance) -> Color {
        if g.state == .stale { return stale }
        if g.colored, let range = g.range { return rangeColour(range) }
        return label
    }

    private static func resolve(_ color: NSColor, in appearance: NSAppearance) -> Color {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: out)
    }
}

/// One frame of the menu bar item.
struct MenuBarGlanceView: View {
    let glance: MenuBarGlance
    let previous: MenuBarGlance?
    var change: MenuBarGlance.Change = .none
    let progress: Double
    var reduceMotion = false
    let colours: MenuBarColours

    private static let height: CGFloat = 18
    private static let rollDistance: CGFloat = 8
    private let valueFont = Font.system(size: 13, weight: .semibold).monospacedDigit()

    /// What isn't the number (the trend arrow, the warning sign, the age, the change) fades in
    /// when the state changes, rather than popping in beside a value that is still fading.
    private var extrasOpacity: Double {
        change == .none || change == .roll ? 1 : progress
    }

    var body: some View {
        HStack(spacing: 3) {
            leadingGlyph.opacity(extrasOpacity)
            value
            Group {
                if let trend = glance.trend, trend != .unknown {
                    Image(systemName: trend.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(colours.value(glance))
                }
                if let delta = glance.deltaText {
                    Text(delta)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(colours.secondary)
                }
                if let age = glance.ageText {
                    Text(age)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(colours.stale)
                }
            }
            .opacity(extrasOpacity)
            if !glance.sparkline.isEmpty {
                MenuBarSparkline(points: glance.sparkline)
                    .stroke(glance.state == .stale ? colours.strike : colours.value(glance).opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 10)
                    .padding(.leading, 1)
            }
        }
        .frame(height: Self.height)
        .fixedSize()
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch glance.state {
        case .notConnected, .waiting:
            Image(systemName: "drop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colours.label)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colours.warning)
        case .warmingUp:
            // The hour filling, a minute at a time: redrawn with the countdown, never animated.
            MenuBarWarmUpRing(fraction: glance.warmUpFraction ?? 0, track: colours.secondary.opacity(0.35),
                              tint: colours.brand)
                .frame(width: 11, height: 11)
        case .live:
            if glance.range == .urgentLow {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colours.rangeColour(.urgentLow))
            }
        }
    }

    /// The number. A new value rolls in with the previous one rolling out above or below it (a
    /// rise comes up from below, a fall drops in from above). Going stale or coming back, the old
    /// colour cross-fades into the new one in place, and the strike draws in or retracts over both.
    private var value: some View {
        let moving = previous != nil && change != .none
        let rolling = moving && !reduceMotion && previous?.valueText != glance.valueText
        let direction: CGFloat = (glance.mgdl ?? 0) >= (previous?.mgdl ?? 0) ? 1 : -1
        let shift = rolling ? (1 - progress) * Self.rollDistance * direction : 0
        let drawn = MenuBarGlance.strikeDrawn(change, state: glance.state, progress: progress, reduceMotion: reduceMotion)
        let strikeOpacity = MenuBarGlance.strikeOpacity(change, state: glance.state, progress: progress,
                                                        reduceMotion: reduceMotion)
        return ZStack {
            if moving, let previous {
                valueText(previous)
                    .offset(y: rolling ? -progress * Self.rollDistance * direction : 0)
                    .opacity(1 - progress)
            }
            valueText(glance)
                .offset(y: shift)
                .opacity(moving ? progress : 1)
        }
        .overlay {
            if drawn > 0, strikeOpacity > 0 {
                StrikeLine()
                    .trim(from: 0, to: drawn)
                    .stroke(colours.strike, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .opacity(strikeOpacity)
                    .rotationEffect(.degrees(-8))
                    .padding(.horizontal, -1)
            }
        }
        .frame(height: Self.height)
        .clipped()
    }

    private func valueText(_ g: MenuBarGlance) -> some View {
        Text(g.valueText)
            .font(valueFont)
            .foregroundStyle(colours.value(g))
    }
}

/// The menu bar's warm-up ring: a thin track with the passed part of the hour drawn over it.
struct MenuBarWarmUpRing: View {
    let fraction: Double
    let track: Color
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
    }
}

/// The last hour, left to right, 0 at the bottom.
struct MenuBarSparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count > 1 else { return p }
        let step = rect.width / CGFloat(points.count - 1)
        for (i, v) in points.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - CGFloat(v) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
