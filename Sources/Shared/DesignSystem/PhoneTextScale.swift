#if os(iOS)
import SwiftUI

/// The design system's sizes are tuned for the Mac, where body text is 13 pt. On iPhone they
/// follow Dynamic Type instead, starting from iOS's 17 pt body at the default size.
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
        default: return 1.5
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.dsTextScale, scale)
    }
}
#endif
