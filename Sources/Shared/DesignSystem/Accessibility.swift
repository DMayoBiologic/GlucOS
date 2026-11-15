import SwiftUI

// Accessibility helpers shared by every target: layouts that reflow at the largest text sizes, a
// line limit that lets text wrap instead of truncating there, and the rim that marks an urgent low
// without relying on its colour. See docs/DesignSystem.md, "Accessibility".

extension DynamicTypeSize {
    /// The five accessibility sizes (AX1–AX5) on iPhone. Always false on the Mac, which has no
    /// Dynamic Type for third-party apps (it has the app's own Text Size setting instead).
    var dsLargeText: Bool { isAccessibilitySize }
}

/// Side by side normally; stacked, leading-aligned, at the accessibility text sizes. For rows of
/// tiles or a label with a control beside it that run out of width when text is very large.
struct DSAccessibleStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.dsLargeText
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content() }
    }
}

private struct DSLineLimit: ViewModifier {
    let limit: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .lineLimit(typeSize.dsLargeText ? nil : limit)
            .fixedSize(horizontal: false, vertical: typeSize.dsLargeText)
    }
}

extension View {
    /// `lineLimit(limit)` at ordinary text sizes. At the accessibility sizes the text wraps onto
    /// as many lines as it needs instead, so nothing is cut off with "…".
    func dsLineLimit(_ limit: Int = 1) -> some View {
        modifier(DSLineLimit(limit: limit))
    }

    /// A crimson rim around a reading while it's an urgent low, so the state reads without colour
    /// vision (with the octagon in the range pill and the words "Urgent low"). Pass the card's
    /// shape so the rim follows its corners.
    func urgentRim<S: InsettableShape>(_ active: Bool, in shape: S) -> some View {
        modifier(UrgentRim(active: active, shape: shape))
    }
}

private struct UrgentRim<S: InsettableShape>: ViewModifier {
    let active: Bool
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                shape
                    .strokeBorder(Palette.crimson, lineWidth: contrast == .increased ? 3 : 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
    }
}
