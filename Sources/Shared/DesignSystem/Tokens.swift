import SwiftUI

// GlucOS design tokens. Every surface (menu bar popover, dashboard window, widgets, settings)
// takes its spacing, corner radii, depth and motion from here, so the app keeps one rhythm and a
// change made here lands everywhere at once.
//
// Rules of thumb:
// - Spacing comes in steps of 4. Reach for `DS.Space` rather than a literal.
// - Inside a card, use `density.stackSpacing` between blocks; between cards use `density.gutter`.
// - Radii nest: a tile inside a card is one step smaller than the card.

enum DS {
    // MARK: Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        /// Buttons, chips, text fields.
        static let control: CGFloat = 8
        /// Tiles and insets that sit inside a card.
        static let tile: CGFloat = 12
        /// Cards.
        static let card: CGFloat = 16
        /// Large panels and banners in a window.
        static let panel: CGFloat = 20
        /// The hero reading.
        static let hero: CGFloat = 24
    }

    // MARK: Lines

    enum Stroke {
        /// Card and control borders.
        static let hairline: CGFloat = 0.75
        /// Borders when the user has asked for more contrast.
        static let increased: CGFloat = 1.25
    }

    typealias Motion = DSMotion
    typealias Elevation = DSElevation
}

// MARK: - Density

/// How tightly a surface packs its content. The popover is compact, the dashboard regular, and a
/// full-screen dashboard comfortable. Set it once at the root of a surface:
/// `.environment(\.dsDensity, .compact)`.
enum DSDensity: Sendable {
    case compact, regular, comfortable

    /// Padding inside a card.
    var cardPadding: CGFloat {
        switch self {
        case .compact: return DS.Space.md
        case .regular: return DS.Space.lg + 2
        case .comfortable: return DS.Space.xxl
        }
    }

    /// Space between blocks inside a card.
    var stackSpacing: CGFloat {
        switch self {
        case .compact: return DS.Space.sm
        case .regular: return DS.Space.md
        case .comfortable: return DS.Space.lg
        }
    }

    /// Space between cards.
    var gutter: CGFloat {
        switch self {
        case .compact: return DS.Space.sm + 2
        case .regular: return DS.Space.lg
        case .comfortable: return DS.Space.xxl
        }
    }

    /// Corner radius of a card at this density.
    var cardRadius: CGFloat {
        switch self {
        case .compact: return DS.Radius.card - 2
        case .regular: return DS.Radius.card
        case .comfortable: return DS.Radius.panel
        }
    }
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue: DSDensity = .regular
}

extension EnvironmentValues {
    var dsDensity: DSDensity {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}

// MARK: - Elevation

/// Depth. Cards sit low; popovers, toasts and the hero sit higher. Shadows drop away entirely when
/// Increase Contrast is on, where borders do the work instead.
enum DSElevation: Sendable {
    case none, low, medium, high

    fileprivate var radius: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 6
        case .medium: return 12
        case .high: return 22
        }
    }

    fileprivate var y: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 2
        case .medium: return 4
        case .high: return 10
        }
    }

    fileprivate var opacity: Double {
        switch self {
        case .none: return 0
        case .low: return 0.06
        case .medium: return 0.10
        case .high: return 0.16
        }
    }
}

private struct ElevationShadow: ViewModifier {
    let elevation: DSElevation
    let tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if elevation == .none || contrast == .increased {
            content
        } else {
            content.shadow(color: (tint ?? .black).opacity(elevation.opacity * (tint == nil ? 1 : 1.4)),
                           radius: elevation.radius, y: elevation.y)
        }
    }
}

extension View {
    /// A shadow at one of the standard depths. A tint makes it a coloured glow, for status surfaces.
    func dsShadow(_ elevation: DSElevation, tint: Color? = nil) -> some View {
        modifier(ElevationShadow(elevation: elevation, tint: tint))
    }
}

// MARK: - Motion

/// The four ways things move in GlucOS. Everything honours Reduce Motion through `dsAnimation`
/// and `DS.animate`, which drop the movement and keep the change.
enum DSMotion: Sendable {
    /// Presses, hovers, toggles.
    case quick
    /// Most state changes: a banner appearing, a section switching.
    case standard
    /// Something the eye should follow: a value settling, a sheet arriving.
    case emphasized
    /// Slow colour and glow changes behind the reading.
    case ambient

    var animation: Animation {
        switch self {
        case .quick: return .snappy(duration: 0.15)
        case .standard: return .smooth(duration: 0.3)
        case .emphasized: return .spring(response: 0.5, dampingFraction: 0.78)
        case .ambient: return .smooth(duration: 0.6)
        }
    }

    /// What to use when Reduce Motion is on. Colour fades stay (they don't move anything);
    /// everything else changes instantly.
    var reducedAnimation: Animation? {
        self == .ambient ? .easeInOut(duration: 0.25) : nil
    }

    func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? reducedAnimation : animation
    }
}

extension DS {
    /// `withAnimation` that respects Reduce Motion. Read `reduceMotion` from
    /// `@Environment(\.accessibilityReduceMotion)` in the calling view.
    @discardableResult
    static func animate<Result>(_ motion: DSMotion, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(motion.animation(reduceMotion: reduceMotion), body)
    }

    enum Transition {
        /// A notice sliding in from the top. Fades only, under Reduce Motion.
        static func banner(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
        }

        /// A toast rising from the bottom.
        static func toast(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
        }

        /// Content swapping in place, such as a section change.
        static func swap(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
        }
    }
}

private struct MotionAnimation<V: Equatable>: ViewModifier {
    let motion: DSMotion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` with a design-system curve that respects Reduce Motion.
    func dsAnimation<V: Equatable>(_ motion: DSMotion, value: V) -> some View {
        modifier(MotionAnimation(motion: motion, value: value))
    }
}
