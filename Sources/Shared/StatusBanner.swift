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

    var tint: Color { tone.color }

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
///
/// Responsive: the buttons sit to the right while the text keeps a comfortable measure, and move
/// under the text when the banner is narrow. The message is never truncated.
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

    /// Follows the Text Size setting. Not private, which would make the memberwise init private.
    var textScale = DSScaledValue()

    private var tone: Tone { severity.tone }
    private var compact: Bool { density == .compact }
    private var radius: CGFloat { compact ? DS.Radius.card - 2 : DS.Radius.card }
    private var hasActions: Bool { action != nil || secondaryAction != nil }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? DS.Space.sm + 2 : DS.Space.md + 2) {
            icon
            DSAdaptiveRow(minMainWidth: compact ? 180 : 260, spacing: DS.Space.md,
                          verticalSpacing: compact ? DS.Space.sm : DS.Space.sm + 2) {
                text
                if hasActions { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lines the first text line up with the middle of the icon, at any text size.
            .padding(.top, max(0, (iconSize - DSTextStyle.headline.size(scale: textScale.scale) * 1.25) / 2))
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss \(title)")
            }
        }
        .padding(.leading, compact ? DS.Space.sm + 3 : DS.Space.md + 2)
        .padding(.trailing, compact ? DS.Space.sm + 2 : DS.Space.md)
        .padding(.vertical, compact ? DS.Space.sm + 2 : DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .tinted(tone), radius: radius) }
        .dsShadow(compact ? .low : .medium, tint: tone.color)
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title)
                .dsFont(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let message, !message.isEmpty {
                Text(message)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(severity.accessibilityPrefix + title + (message.map { ". \($0)" } ?? ""))
    }

    private var actions: some View {
        HStack(spacing: DS.Space.xs + 2) {
            if let secondaryAction { button(secondaryAction, prominent: false) }
            if let action { button(action, prominent: true) }
        }
        .fixedSize()
    }

    private var iconSize: CGFloat { compact ? 26 : 34 }

    private var icon: some View {
        let size = iconSize
        return ZStack {
            Circle().fill(tone.color.opacity(0.18))
            Circle().strokeBorder(tone.color.opacity(0.35), lineWidth: DS.Stroke.hairline)
            Image(systemName: systemImage ?? severity.defaultSymbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tone.color)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func button(_ a: BannerAction, prominent: Bool) -> some View {
        Button(action: a.perform) {
            HStack(spacing: DS.Space.xs + 1) {
                if a.isBusy {
                    ProgressView().controlSize(.mini)
                } else if let img = a.systemImage {
                    Image(systemName: img).imageScale(.small)
                }
                Text(a.title)
            }
        }
        .buttonStyle(DSButtonStyle(kind: prominent ? .tinted(tone) : .secondary, size: compact ? .small : .regular))
        .disabled(a.isDisabled || a.isBusy)
    }
}
