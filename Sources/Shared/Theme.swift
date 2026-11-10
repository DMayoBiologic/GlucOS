import SwiftUI
import AppKit

// GlucOS design system: palette and the glucose-specific pieces (trend dial, time-in-range ring,
// ambient glow). Tokens live in DesignSystem/Tokens.swift, the type scale in Typography.swift,
// semantic colour in Tone.swift and generic components in Components.swift.
//
// Colour is status: every range has one hue, used for the number, the chart line, the ambient
// glow behind the reading and the time-in-range ring. Stale data is always neutral grey, so an
// old reading can never look like a reassuring one.

// MARK: - Palette

enum Palette {
    /// A colour with separate light and dark appearances, and optionally its own values when
    /// Increase Contrast is on.
    static func dynamic(light: NSColor, dark: NSColor,
                        highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case NSAppearance.Name.darkAqua?: return dark
            case NSAppearance.Name.accessibilityHighContrastAqua?: return highContrastLight ?? light
            case NSAppearance.Name.accessibilityHighContrastDarkAqua?: return highContrastDark ?? dark
            default: return light
            }
        })
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    // Range hues, for lines, fills, icons and big numbers (3:1 or better). With Increase
    // Contrast, light mode uses the darker text values everywhere.
    static let mint = dynamic(light: rgb(0x0E9F6E), dark: rgb(0x34D399), highContrastLight: rgb(0x047857))
    static let amber = dynamic(light: rgb(0xD97706), dark: rgb(0xFBBF24), highContrastLight: rgb(0xB45309))
    static let coral = dynamic(light: rgb(0xE5484D), dark: rgb(0xFF6B6B), highContrastLight: rgb(0xC62A2F))
    static let crimson = dynamic(light: rgb(0xC81E4B), dark: rgb(0xFF4D79), highContrastLight: rgb(0xBE123C))
    static let magenta = dynamic(light: rgb(0xC2257A), dark: rgb(0xF472B6), highContrastLight: rgb(0xA21C64))

    // Text-safe versions: 4.5:1 or better on window and card backgrounds in both appearances.
    static let mintText = dynamic(light: rgb(0x047857), dark: rgb(0x34D399), highContrastDark: rgb(0x6EE7B7))
    static let amberText = dynamic(light: rgb(0xB45309), dark: rgb(0xFBBF24), highContrastDark: rgb(0xFCD34D))
    static let coralText = dynamic(light: rgb(0xC62A2F), dark: rgb(0xFF6B6B), highContrastDark: rgb(0xFCA5A5))
    static let crimsonText = dynamic(light: rgb(0xBE123C), dark: rgb(0xFF4D79), highContrastDark: rgb(0xFDA4AF))
    static let magentaText = dynamic(light: rgb(0xA21C64), dark: rgb(0xF472B6), highContrastDark: rgb(0xF9A8D4))

    /// Old data. Deliberately colourless so it can never read as "fine".
    static let stale = dynamic(light: rgb(0x8E8E93), dark: rgb(0x8E8E93), highContrastLight: rgb(0x6E6E73))
    static let staleText = dynamic(light: rgb(0x6E6E73), dark: rgb(0x98989D),
                                   highContrastLight: rgb(0x48484A), highContrastDark: rgb(0xC7C7CC))
    /// Status-free chrome.
    static let neutral = dynamic(light: rgb(0x6E6E73), dark: rgb(0x98989D))

    /// Brand accent, for chrome that isn't a glucose value.
    static let brand = dynamic(light: rgb(0x2563EB), dark: rgb(0x60A5FA), highContrastLight: rgb(0x1D4ED8))
    static let brandText = dynamic(light: rgb(0x1D4ED8), dark: rgb(0x60A5FA), highContrastDark: rgb(0x93C5FD))
    static let brandGradient = LinearGradient(colors: [dynamic(light: rgb(0x0EA5E9), dark: rgb(0x38BDF8)),
                                                       dynamic(light: rgb(0x6366F1), dark: rgb(0x818CF8))],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Text and icons on the brand gradient.
    static let onBrand = Color.white

    // Logbook categories. Kept clear of the range hues so an overlay never reads as a reading.
    static let insulin = dynamic(light: rgb(0x4F46E5), dark: rgb(0x818CF8))
    static let food = dynamic(light: rgb(0xC2410C), dark: rgb(0xFB923C))
    static let site = dynamic(light: rgb(0x7C3AED), dark: rgb(0xA78BFA))
    static let context = dynamic(light: rgb(0x0F766E), dark: rgb(0x2DD4BF))
}

extension GlucoseRange {
    /// The range's hue. Also what `color` returns, so every older call site picks it up.
    var tint: Color {
        switch self {
        case .urgentLow: return Palette.crimson
        case .low: return Palette.coral
        case .inRange: return Palette.mint
        case .high: return Palette.amber
        case .veryHigh: return Palette.magenta
        }
    }

    /// The dark-appearance hue as an NSColor, for AppKit drawing on the menu bar.
    var nsTint: NSColor {
        switch self {
        case .urgentLow: return Palette.rgb(0xFF4D79)
        case .low: return Palette.rgb(0xFF6B6B)
        case .inRange: return Palette.rgb(0x34D399)
        case .high: return Palette.rgb(0xFBBF24)
        case .veryHigh: return Palette.rgb(0xF472B6)
        }
    }
}

extension GlucoseSnapshot {
    /// The colour the current reading should be shown in: neutral when stale or missing.
    func displayTint(at now: Date = Date()) -> Color { displayTone(at: now).color }
}

// MARK: - Threshold gradient

/// Colours a glucose trace by range as it crosses the thresholds.
///
/// Swift Charts stretches a line's gradient over the bounding box of that line's series, so the
/// stops are placed relative to the series' own lowest and highest value (bottom = 0, top = 1),
/// with hard edges at each threshold.
enum ThresholdGradient {
    static func style(minMgdl: Double, maxMgdl: Double, low: Double, high: Double) -> LinearGradient {
        let span = maxMgdl - minMgdl
        guard span > 0.5 else {
            let c = GlucoseRange.classify(mgdl: minMgdl, low: low, high: high).tint
            return LinearGradient(colors: [c, c], startPoint: .bottom, endPoint: .top)
        }
        func loc(_ mgdl: Double) -> CGFloat { CGFloat(min(1, max(0, (mgdl - minMgdl) / span))) }
        // Bands from bottom to top, each [start, end) in mg/dL.
        let bands: [(from: Double, to: Double, color: Color)] = [
            (-.infinity, 54, GlucoseRange.urgentLow.tint),
            (54, low, GlucoseRange.low.tint),
            (low, high, GlucoseRange.inRange.tint),
            (high, 250, GlucoseRange.high.tint),
            (250, .infinity, GlucoseRange.veryHigh.tint),
        ]
        var stops: [Gradient.Stop] = []
        for band in bands where band.to > minMgdl && band.from < maxMgdl {
            stops.append(.init(color: band.color, location: loc(max(band.from, minMgdl))))
            stops.append(.init(color: band.color, location: loc(min(band.to, maxMgdl))))
        }
        if stops.isEmpty {
            let c = GlucoseRange.classify(mgdl: minMgdl, low: low, high: high).tint
            stops = [.init(color: c, location: 0), .init(color: c, location: 1)]
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }
}

// MARK: - Ambient glow

/// Soft, range-tinted light behind the current reading. Reads as "how am I doing" before the
/// number does. Flattens to a plain wash under Reduce Transparency.
struct AmbientGlow: View {
    var tint: Color
    var intensity: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.26 * intensity), tint.opacity(0.06 * intensity)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if !reduceTransparency {
                RadialGradient(colors: [tint.opacity(0.38 * intensity), .clear],
                               center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 220)
                RadialGradient(colors: [tint.opacity(0.18 * intensity), .clear],
                               center: UnitPoint(x: 0.95, y: 1.0), startRadius: 0, endRadius: 180)
            }
        }
        .dsAnimation(.ambient, value: tint)
    }
}

// MARK: - Glass card

/// The original card modifier, now a standard `dsCard`. Kept so existing call sites don't move.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = DS.Radius.card

    func body(content: Content) -> some View {
        content.dsCard(.standard, padding: padding, radius: radius)
    }
}

extension View {
    func glassCard(padding: CGFloat = 14, radius: CGFloat = DS.Radius.card) -> some View {
        modifier(GlassCard(padding: padding, radius: radius))
    }
}

// MARK: - Section label

/// Small uppercase eyebrow above a card's content.
struct Eyebrow: View {
    let title: String
    var systemImage: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            if let trailing {
                Text(trailing)
                    .textCase(nil)
                    .tracking(0)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
        .dsFont(.eyebrow)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Trend dial

/// The trend as a ring with an arrow that rotates to the actual rate of change.
struct TrendDial: View {
    let trend: Trend
    var tint: Color
    var size: CGFloat = 56

    private var angle: Double {
        switch trend {
        case .risingQuickly: return -90
        case .rising: return -45
        case .flat, .unknown: return 0
        case .falling: return 45
        case .fallingQuickly: return 90
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [tint.opacity(0.9), tint.opacity(0.25), tint.opacity(0.9)],
                                    center: .center),
                    lineWidth: max(2, size * 0.05))
            if trend == .unknown {
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: size * 0.42, weight: .heavy))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(angle))
                    .dsAnimation(.emphasized, value: angle)
            }
            if trend.isRapid {
                Circle()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    .padding(-4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(trend.description)
    }
}

// MARK: - Time in range ring

/// Concentric-style donut: below / in range / above, with the in-range share in the middle.
struct TimeInRangeRing: View {
    /// Fractions bottom (urgent low) to top (very high). Need not sum to exactly 1.
    let segments: [(fraction: Double, color: Color)]
    let inRange: Double
    var lineWidth: CGFloat = 10
    var showsLabel: Bool = true
    var caption: String = "in range"

    init(stats: GlucoseStats, lineWidth: CGFloat = 10, showsLabel: Bool = true) {
        segments = [(stats.timeBelowRange, GlucoseRange.low.tint),
                    (stats.timeInRange, GlucoseRange.inRange.tint),
                    (stats.timeAboveRange, GlucoseRange.high.tint)]
        inRange = stats.timeInRange
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    init(segments: [(fraction: Double, color: Color)], inRange: Double, lineWidth: CGFloat = 10, showsLabel: Bool = true) {
        self.segments = segments
        self.inRange = inRange
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    private var arcs: [(start: Double, end: Double, color: Color)] {
        let visible = segments.filter { $0.fraction > 0.001 }
        let total = max(0.0001, visible.reduce(0) { $0 + $1.fraction })
        let gap = visible.count > 1 ? 0.012 : 0
        var out: [(start: Double, end: Double, color: Color)] = []
        var cursor = 0.0
        for seg in visible {
            let len = seg.fraction / total
            let start = cursor + gap / 2
            let end = max(start + 0.002, cursor + len - gap / 2)
            out.append((start: start, end: end, color: seg.color))
            cursor += len
        }
        return out
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showsLabel {
                VStack(spacing: -1) {
                    Text(Format.percent(inRange))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(caption)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .padding(lineWidth)
            }
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel("Time in range")
        .accessibilityValue("\(Format.percent(inRange)) in range")
    }
}

// MARK: - Progress ring

/// Thin ring for sensor life and similar countdowns.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Pill button

/// Round, translucent icon button used in the popover's floating toolbar.
struct PillIconButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(Palette.onBrand) : AnyShapeStyle(Color.primary))
                .frame(minWidth: 32, minHeight: 30)
                .padding(.horizontal, prominent ? DS.Space.sm + 2 : 0)
                .background {
                    if prominent {
                        Capsule().fill(Palette.brandGradient)
                    } else {
                        Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
                    }
                }
                .overlay {
                    if contrast == .increased && !prominent {
                        Capsule().strokeBorder(Color.primary.opacity(0.4), lineWidth: DS.Stroke.hairline)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .dsAnimation(.quick, value: configuration.isPressed)
                .dsAnimation(.quick, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
