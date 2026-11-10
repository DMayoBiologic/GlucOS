import SwiftUI

// MARK: - Status banner

/// How much a notice matters. Picks the colour and icon from the design system, so a banner
/// looks the same in the popover, the dashboard and anywhere else.
enum BannerSeverity: Int, Comparable {
    /// Something already gone, or about to go, wrong: alerts can't reach you, the sensor ended.
    case critical = 0
    /// The numbers on screen may be wrong or old.
    case warning = 1
    /// Context about what you're looking at.
    case info = 2
    /// Something finished fine.
    case success = 3

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var tint: Color {
        switch self {
        case .critical: return Palette.crimson
        case .warning: return Palette.amber
        case .info: return Palette.brand
        case .success: return Palette.mint
        }
    }

    var defaultSymbol: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    /// Spoken before the title so VoiceOver users hear how serious it is.
    var accessibilityPrefix: String {
        switch self {
        case .critical: return "Important: "
        case .warning: return "Warning: "
        case .info, .success: return ""
        }
    }
}

/// A button on a banner.
struct BannerAction {
    var title: String
    var systemImage: String?
    var isBusy = false
    var isDisabled = false
    var perform: () -> Void
}

/// A notice: icon, a title that says what's wrong, a line on what it means, and the one action
/// that fixes it. Tinted by severity, on glass, like the rest of GlucOS.
struct StatusBanner: View {
    enum Density { case regular, compact }

    let severity: BannerSeverity
    var systemImage: String?
    let title: String
    var message: String?
    var action: BannerAction?
    var secondaryAction: BannerAction?
    /// Shows a close button when set.
    var onDismiss: (() -> Void)?
    var density: Density = .regular

    private var tint: Color { severity.tint }
    private var compact: Bool { density == .compact }
    private var radius: CGFloat { compact ? 14 : 16 }

    var body: some View {
        HStack(alignment: compact ? .top : .center, spacing: compact ? 10 : 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(compact ? .callout.weight(.semibold) : .system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 4 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(severity.accessibilityPrefix + title + (message.map { ". \($0)" } ?? ""))

            if action != nil || secondaryAction != nil {
                HStack(spacing: 6) {
                    if let secondaryAction { button(secondaryAction, prominent: false) }
                    if let action { button(action, prominent: true) }
                }
                .fixedSize()
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, compact ? 11 : 14)
        .padding(.trailing, compact ? 10 : 12)
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.07)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 0.75)
        }
        .shadow(color: tint.opacity(compact ? 0.08 : 0.14), radius: compact ? 6 : 12, y: compact ? 2 : 4)
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        let size: CGFloat = compact ? 26 : 34
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.75)
            Image(systemName: systemImage ?? severity.defaultSymbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func button(_ a: BannerAction, prominent: Bool) -> some View {
        Button(action: a.perform) {
            HStack(spacing: 5) {
                if a.isBusy {
                    ProgressView().controlSize(.mini)
                } else if let img = a.systemImage {
                    Image(systemName: img).imageScale(.small)
                }
                Text(a.title)
            }
        }
        .buttonStyle(BannerButtonStyle(tint: tint, prominent: prominent, compact: compact))
        .disabled(a.isDisabled || a.isBusy)
    }
}

/// Capsule button tinted to its banner. Prominent is the fix; the other is a quieter alternative.
struct BannerButtonStyle: ButtonStyle {
    var tint: Color
    var prominent = true
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, tint: tint, prominent: prominent, compact: compact)
    }

    private struct Body: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font((compact ? Font.caption : Font.callout).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.8)))
                .padding(.horizontal, compact ? 10 : 13)
                .padding(.vertical, compact ? 4 : 6)
                .background {
                    Capsule().fill(prominent ? tint.opacity(hovering ? 0.30 : 0.20)
                                             : Color.primary.opacity(hovering ? 0.12 : 0.07))
                }
                .overlay {
                    Capsule().strokeBorder(prominent ? tint.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 0.75)
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
