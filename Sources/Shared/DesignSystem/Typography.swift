import SwiftUI

// The GlucOS type scale.
//
// Numbers use SF Pro Rounded with tabular digits so values don't jitter as they update; labels
// use SF Pro. Each style has one job, so hierarchy is decided here rather than per view.
//
// macOS has no system Dynamic Type for third-party apps, so GlucOS has its own Text Size setting
// (`DSTextScale`, stored in UserDefaults under `dsTextScale`). Every `.dsFont` reads it, so the
// whole app scales together. A surface can override it with `.environment(\.dsTextScale, …)`.

enum DSTextStyle: CaseIterable, Sendable {
    /// The live reading in the dashboard hero.
    case heroValue
    /// The live reading in the popover, or another single big number.
    case display
    /// Window and page titles.
    case title
    /// Card and section titles.
    case sectionTitle
    /// Emphasised body text: a banner title, a row's main label.
    case headline
    /// Running text.
    case body
    /// Secondary running text: a banner's explanation, a row's detail.
    case callout
    /// Labels on controls and above values.
    case label
    /// Timestamps, footnotes, axis labels.
    case caption
    /// Small uppercase label over a group.
    case eyebrow
    /// A headline number in a tile.
    case metricValue
    /// A bigger headline number, for the main stats of a page.
    case metricValueLarge
    /// The unit beside a value ("mmol/L").
    case unit

    /// Point size at the standard text size.
    var baseSize: CGFloat {
        switch self {
        case .heroValue: return 64
        case .display: return 40
        case .title: return 22
        case .sectionTitle: return 15
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .label: return 11
        case .caption: return 10.5
        case .eyebrow: return 10
        case .metricValue: return 20
        case .metricValueLarge: return 28
        case .unit: return 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .heroValue, .display, .title, .sectionTitle, .metricValue, .metricValueLarge: return .bold
        case .headline, .eyebrow, .unit: return .semibold
        case .label: return .medium
        case .body, .callout, .caption: return .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .heroValue, .display, .title, .sectionTitle, .metricValue, .metricValueLarge: return .rounded
        default: return .default
        }
    }

    /// Tabular figures, so a changing number keeps its width.
    var monospacedDigits: Bool {
        switch self {
        case .heroValue, .display, .metricValue, .metricValueLarge, .caption: return true
        default: return false
        }
    }

    var tracking: CGFloat {
        switch self {
        case .eyebrow: return 0.6
        case .heroValue, .display: return -0.5
        default: return 0
        }
    }

    var uppercased: Bool { self == .eyebrow }

    /// Big numbers grow more slowly than text, so a large text size doesn't push the reading out
    /// of its card.
    fileprivate var scaleDamping: CGFloat {
        switch self {
        case .heroValue, .display: return 0.5
        case .metricValueLarge: return 0.75
        default: return 1
        }
    }

    func size(scale: CGFloat) -> CGFloat {
        let s = DSTextScale.clamp(scale)
        // Half-point steps keep neighbouring styles (caption 10.5, label 11) distinct.
        return ((baseSize * (1 + (s - 1) * scaleDamping)) * 2).rounded() / 2
    }

    func font(scale: CGFloat = 1) -> Font {
        let f = Font.system(size: size(scale: scale), weight: weight, design: design)
        return monospacedDigits ? f.monospacedDigit() : f
    }
}

/// The app's Text Size setting.
enum DSTextScale: Double, CaseIterable, Identifiable, Sendable {
    case small = 0.9
    case standard = 1.0
    case large = 1.15
    case extraLarge = 1.3

    static let defaultsKey = "dsTextScale"

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    static func clamp(_ scale: CGFloat) -> CGFloat { min(1.5, max(0.8, scale.isFinite ? scale : 1)) }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Overrides the Text Size setting for a subtree. `nil` (the default) follows the setting.
    var dsTextScale: CGFloat? {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// The Text Size setting, read once and shared, so the hundreds of `.dsFont` views on a screen
/// subscribe to one object rather than each observing UserDefaults.
final class DSTextScaleStore: ObservableObject {
    static let shared = DSTextScaleStore()

    @Published var scale: Double {
        didSet {
            guard scale != oldValue else { return }
            UserDefaults.standard.set(scale, forKey: DSTextScale.defaultsKey)
        }
    }

    private init() {
        let stored = UserDefaults.standard.object(forKey: DSTextScale.defaultsKey) as? Double
        scale = stored ?? DSTextScale.standard.rawValue
    }
}

private struct DSFontModifier: ViewModifier {
    let style: DSTextStyle
    @ObservedObject private var store = DSTextScaleStore.shared
    @Environment(\.dsTextScale) private var override

    func body(content: Content) -> some View {
        let scale = override ?? CGFloat(store.scale)
        content
            .font(style.font(scale: scale))
            .tracking(style.tracking)
            .textCase(style.uppercased ? .uppercase : nil)
    }
}

extension View {
    /// Sets text to one of the design system's styles, at the user's text size.
    func dsFont(_ style: DSTextStyle) -> some View {
        modifier(DSFontModifier(style: style))
    }
}

extension Font {
    /// A design-system font at a fixed scale, for places a modifier can't reach (Charts axis
    /// labels, attributed strings). Prefer `.dsFont(_:)` on views; it follows the Text Size setting.
    static func ds(_ style: DSTextStyle, scale: CGFloat = 1) -> Font { style.font(scale: scale) }
}

/// The current text scale, for sizing non-text elements (icons, rings) in step with text.
struct DSScaledValue: DynamicProperty {
    // Not private: a private stored property would make the implicit initialiser private too.
    @ObservedObject var store = DSTextScaleStore.shared
    @Environment(\.dsTextScale) private var override

    var scale: CGFloat { DSTextScale.clamp(override ?? CGFloat(store.scale)) }
}

/// The Text Size control, for Settings.
struct TextSizePicker: View {
    // Not private, so `TextSizePicker()` stays callable from other files.
    @ObservedObject var store = DSTextScaleStore.shared

    var body: some View {
        Picker("Text size", selection: Binding(
            get: { DSTextScale(rawValue: store.scale) ?? .standard },
            set: { store.scale = $0.rawValue })) {
            ForEach(DSTextScale.allCases) { Text($0.title).tag($0) }
        }
        .help("Makes text across GlucOS larger or smaller. Widgets follow macOS.")
    }
}
