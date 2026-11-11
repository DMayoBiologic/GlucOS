import SwiftUI

// Surfaces: the glass every card, tile, banner and hero sits on.
//
// Accessibility is built in rather than left to each view:
// - Reduce Transparency swaps the material for an opaque fill, so text never sits on a blurred
//   wallpaper.
// - Increase Contrast thickens and darkens borders and drops shadows.

enum DSCardStyle: Equatable {
    /// The everyday card.
    case standard
    /// A quieter well inside a card: tiles, grouped rows.
    case inset
    /// A card washed with a tone, for notices and highlighted content.
    case tinted(Tone)
    /// The reading's hero surface, with the range-coloured ambient glow.
    case hero(Tone)

    var elevation: DSElevation {
        switch self {
        case .standard: return .low
        case .inset: return .none
        case .tinted: return .low
        case .hero: return .medium
        }
    }

    fileprivate var tone: Tone? {
        switch self {
        case .tinted(let t), .hero(let t): return t
        case .standard, .inset: return nil
        }
    }
}

/// The background shape of a surface on its own, for views that lay out their own padding.
struct DSSurface: View {
    var style: DSCardStyle = .standard
    var radius: CGFloat = DS.Radius.card
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    private var increased: Bool { contrast == .increased }

    var body: some View {
        ZStack {
            switch style {
            case .standard:
                if reduceTransparency {
                    shape.fill(Palette.controlBackground)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.primary.opacity(0.035))
                }
            case .inset:
                shape.fill(Color.primary.opacity(increased ? 0.08 : 0.045))
            case .tinted(let tone):
                if reduceTransparency {
                    shape.fill(Palette.controlBackground)
                } else {
                    shape.fill(.regularMaterial)
                }
                shape.fill(LinearGradient(colors: [tone.color.opacity(0.20), tone.color.opacity(0.06)],
                                          startPoint: .leading, endPoint: .trailing))
            case .hero(let tone):
                if reduceTransparency {
                    shape.fill(Palette.controlBackground)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
                AmbientGlow(tint: tone.color).clipShape(shape)
            }
        }
        .overlay { border }
    }

    @ViewBuilder
    private var border: some View {
        let width = increased ? DS.Stroke.increased : DS.Stroke.hairline
        switch style {
        case .standard:
            if increased {
                shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: width)
            } else {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.primary.opacity(0.06)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: width)
            }
        case .inset:
            if increased { shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: width) }
        case .tinted(let tone), .hero(let tone):
            if increased {
                shape.strokeBorder(tone.color, lineWidth: width)
            } else {
                shape.strokeBorder(LinearGradient(colors: [tone.color.opacity(0.5), tone.color.opacity(0.1)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: width)
            }
        }
    }
}

private struct DSCardModifier: ViewModifier {
    let style: DSCardStyle
    let padding: CGFloat?
    let radius: CGFloat?
    @Environment(\.dsDensity) private var density

    func body(content: Content) -> some View {
        let r = radius ?? (style == .inset ? DS.Radius.tile : density.cardRadius)
        content
            .padding(padding ?? (style == .inset ? DS.Space.md : density.cardPadding))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { DSSurface(style: style, radius: r) }
            .dsShadow(style.elevation, tint: style.tone.flatMap { $0 == .neutral ? nil : $0.color })
    }
}

extension View {
    /// Puts the view on a design-system surface, padded for the current density.
    func dsCard(_ style: DSCardStyle = .standard, padding: CGFloat? = nil, radius: CGFloat? = nil) -> some View {
        modifier(DSCardModifier(style: style, padding: padding, radius: radius))
    }
}

/// A hairline separator that strengthens under Increase Contrast.
struct DSDivider: View {
    var vertical = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.08))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
