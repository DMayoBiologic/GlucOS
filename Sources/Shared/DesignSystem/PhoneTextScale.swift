#if os(iOS)
import SwiftUI

/// The design system's sizes are tuned for the Mac, where body text is 13 pt. On iPhone they
/// follow Dynamic Type instead, starting from iOS's 17 pt body at the default size, and keep
/// growing through the five accessibility sizes (AX5 body is about 29 pt, like iOS's own). Layouts
/// that would run out of width there reflow with `DSAccessibleStack` and `dsLineLimit`.
struct PhoneTextScale: ViewModifier {
    @Environment(\.dynamicTypeSize) private var size

    private var scale: CGFloat {
        switch size {
        case .xSmall: return 1.1
        case .small: return 1.15
        case .medium: return 1.22
        case .large: return 1.3
        case .xLarge: return 1.38
        case .xxLarge: return 1.44
        case .xxxLarge: return 1.5
        case .accessibility1: return 1.65
        case .accessibility2: return 1.8
        case .accessibility3: return 1.95
        case .accessibility4: return 2.1
        case .accessibility5: return 2.25
        @unknown default: return 1.5
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.dsTextScale, scale)
    }
}
#endif
