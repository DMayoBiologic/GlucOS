import SwiftUI

// Buttons and chips.

// MARK: - Button

/// The GlucOS button. `.buttonStyle(.ds(.primary))`, `.ds(.tinted(.warning), size: .small)`…
struct DSButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        /// The one main action: brand gradient.
        case primary
        /// An alternative action: quiet fill.
        case secondary
        /// An action that belongs to a status, such as a banner's fix.
        case tinted(Tone)
        /// Text-only, filled on hover.
        case ghost
    }

    enum Size {
        case small, regular, large

        var textStyle: DSTextStyle {
            switch self {
            case .small: return .label
            case .regular: return .callout
            case .large: return .headline
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return DS.Space.sm + 2
            case .regular: return DS.Space.md + 1
            case .large: return DS.Space.lg
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .small: return DS.Space.xs
            case .regular: return DS.Space.xs + 2
            case .large: return DS.Space.sm
            }
        }

        var minHeight: CGFloat {
            switch self {
            case .small: return 22
            case .regular: return 28
            case .large: return 34
            }
        }
    }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size)
    }

    private struct DSButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        private var increased: Bool { contrast == .increased }

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .dsFont(size.textStyle)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .frame(minHeight: size.minHeight)
                .background { background }
                .overlay { border }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .dsAnimation(.quick, value: configuration.isPressed)
                .dsAnimation(.quick, value: hovering)
                .onHover { hovering = $0 }
        }

        private var foreground: AnyShapeStyle {
            switch kind {
            case .primary: return AnyShapeStyle(Palette.onBrand)
            case .secondary: return AnyShapeStyle(Color.primary.opacity(0.85))
            case .tinted(let tone): return AnyShapeStyle(tone.textColor)
            case .ghost: return AnyShapeStyle(Palette.brandText)
            }
        }

        @ViewBuilder
        private var background: some View {
            switch kind {
            case .primary:
                Capsule().fill(Palette.brandGradient)
                    .overlay { Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)) }
            case .secondary:
                Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.07))
            case .tinted(let tone):
                Capsule().fill(tone.color.opacity(hovering ? 0.30 : 0.18))
            case .ghost:
                Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0))
            }
        }

        @ViewBuilder
        private var border: some View {
            let width = increased ? DS.Stroke.increased : DS.Stroke.hairline
            switch kind {
            case .primary:
                if increased { Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: width) }
            case .secondary:
                Capsule().strokeBorder(Color.primary.opacity(increased ? 0.45 : 0.10), lineWidth: width)
            case .tinted(let tone):
                Capsule().strokeBorder(tone.color.opacity(increased ? 1 : 0.45), lineWidth: width)
            case .ghost:
                if increased { Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: width) }
            }
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static func ds(_ kind: DSButtonStyle.Kind = .secondary, size: DSButtonStyle.Size = .regular) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size)
    }
}

// MARK: - Chip

/// A selectable capsule: time ranges, filters, overlay toggles.
struct DSChipButtonStyle: ButtonStyle {
    var isSelected: Bool
    var tone: Tone = .brand
    var size: DSButtonStyle.Size = .small

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected, tone: tone, size: size)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let tone: Tone
        let size: DSButtonStyle.Size
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        var body: some View {
            let increased = contrast == .increased
            configuration.label
                .fontWeight(isSelected ? .semibold : .medium)
                .dsFont(size.textStyle)
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(tone.textColor) : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .frame(minHeight: size.minHeight)
                .background {
                    Capsule().fill(isSelected ? tone.color.opacity(hovering ? 0.26 : 0.18)
                                              : Color.primary.opacity(hovering ? 0.09 : 0.04))
                }
                .overlay {
                    Capsule().strokeBorder(isSelected ? tone.color.opacity(increased ? 1 : 0.4)
                                                      : Color.primary.opacity(increased ? 0.4 : 0.08),
                                           lineWidth: increased ? DS.Stroke.increased : DS.Stroke.hairline)
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .dsAnimation(.quick, value: configuration.isPressed)
                .dsAnimation(.quick, value: hovering)
                .dsAnimation(.quick, value: isSelected)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// A chip as a ready-made button.
struct DSChip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool
    var tone: Tone = .brand
    var size: DSButtonStyle.Size = .small
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(DSChipButtonStyle(isSelected: isSelected, tone: tone, size: size))
    }
}

/// One-of-many choice as a row of chips. Scrolls sideways when the row can't fit, so labels never
/// truncate or wrap.
struct DSChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var tone: Tone = .brand
    var size: DSButtonStyle.Size = .small
    let title: (Value) -> String
    /// What the group chooses ("Time range"), read by VoiceOver.
    var accessibilityTitle: String?

    var body: some View {
        let chips = ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .accessibilityElement(children: .contain)
        if let accessibilityTitle, !accessibilityTitle.isEmpty {
            chips.accessibilityLabel(accessibilityTitle)
        } else {
            chips
        }
    }

    private var row: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(options, id: \.self) { option in
                DSChip(title: title(option), isSelected: option == selection, tone: tone, size: size) {
                    selection = option
                }
            }
        }
    }
}
