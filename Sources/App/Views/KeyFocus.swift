import SwiftUI
#if os(macOS)
import AppKit
#endif

// Keyboard navigation on the Mac (docs/KeyboardNavigation.md). A screen (the menu bar popover,
// Insights, the Logbook) holds one `@FocusState` and calls `.keyNavigation($focus)`. Each card,
// chip or button in it calls `.keyStop(...)`: it joins the Tab loop even with the system's
// "Keyboard navigation" setting off, draws the focus ring while the keyboard is in use, and does
// its click action on Return or Space. The stops tell the screen where they are (a preference, in
// layout order), so ↑ ↓ ← → move the ring between them by the rules in `KeyNavigation`.
//
// The Insights cards are shared with the iPhone, where both modifiers do nothing.

/// What kind of thing a stop is, which decides how it joins the Tab loop.
enum KeyStopKind {
    /// A card or a row: always focusable, with the ring.
    case card
    /// A button or chip. Focusable with the ring; when the system's Keyboard navigation setting
    /// is on, the button is in the Tab loop already, so it isn't made focusable twice.
    case control
    /// Already focusable by itself (the popover's chart, a text field, the Logbook table): it
    /// only joins the arrow keys' order and keeps its own focus look.
    case native
}

#if os(iOS)
extension View {
    func keyNavigation(_ focus: FocusState<String?>.Binding) -> some View { self }

    func keyStop(_ id: String, row: String? = nil, kind: KeyStopKind = .card, radius: CGFloat = DS.Radius.card,
                 keeps: Set<KeyNavigation.Move> = [], enabled: Bool = true, action: (() -> Void)? = nil) -> some View { self }

    func keyCycle<V: Hashable>(_ selection: Binding<V>, through options: [V]) -> some View { self }
}
#else

/// Whether the focus ring shows: the keyboard brings it up, a click puts it away
/// (`FocusRingVisibility`), so clicking a card never leaves a ring round it.
@MainActor
final class KeyFocusRing: ObservableObject {
    static let shared = KeyFocusRing()

    @Published private(set) var visible = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        // Local monitors are called on the main thread, and only see GlucOS's own events.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    /// An arrow key moved the ring (the key press is seen by the monitor too; this covers a move
    /// made before the monitor started).
    func show() {
        if !visible { visible = true }
    }

    private func handle(_ event: NSEvent) {
        let input: FocusRingVisibility.Input = event.type == .keyDown ? .key(event.keyCode) : .click
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chord = flags.contains(.command) || flags.contains(.control)
        if let show = FocusRingVisibility.after(input, modifiers: chord), show != visible {
            visible = show
        }
    }
}

/// The screen's focus, handed down to its stops.
struct KeyFocusContext {
    let focus: FocusState<String?>.Binding
    /// Every stop on the screen, in layout order.
    let stops: [KeyStop]
}

private struct KeyFocusContextKey: EnvironmentKey {
    static let defaultValue: KeyFocusContext? = nil
}

extension EnvironmentValues {
    var keyFocus: KeyFocusContext? {
        get { self[KeyFocusContextKey.self] }
        set { self[KeyFocusContextKey.self] = newValue }
    }
}

/// Every stop on the screen, in layout order.
struct KeyStopsKey: PreferenceKey {
    static let defaultValue: [KeyStop] = []
    static func reduce(value: inout [KeyStop], nextValue: () -> [KeyStop]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// The screen that holds the stops: ↑ ↓ ← → move the focus ring between them.
    func keyNavigation(_ focus: FocusState<String?>.Binding) -> some View {
        modifier(KeyNavigationScreen(focus: focus))
    }

    /// A place the focus ring can land. `row` groups stops side by side, so ← → move along them.
    /// `action` is what a click does, for Return and Space. `radius` is the corner radius of the
    /// thing it rings. `enabled` false leaves the view as it is (for a card that may draw nothing).
    func keyStop(_ id: String, row: String? = nil, kind: KeyStopKind = .card, radius: CGFloat = DS.Radius.card,
                 keeps: Set<KeyNavigation.Move> = [], enabled: Bool = true, action: (() -> Void)? = nil) -> some View {
        modifier(KeyStopModifier(stop: KeyStop(id, row: row, keeps: keeps), kind: kind, radius: radius,
                                 enabled: enabled, action: action))
    }

    /// ← → step `selection` through `options` (a segmented period picker made one stop), then
    /// let the ring move on along the row at either end.
    func keyCycle<V: Hashable>(_ selection: Binding<V>, through options: [V]) -> some View {
        onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty,
                  let i = options.firstIndex(of: selection.wrappedValue) else { return .ignored }
            let j = press.key == .leftArrow ? i - 1 : i + 1
            guard options.indices.contains(j) else { return .ignored }
            selection.wrappedValue = options[j]
            return .handled
        }
    }
}

private struct KeyNavigationScreen: ViewModifier {
    let focus: FocusState<String?>.Binding
    @State private var stops: [KeyStop] = []

    func body(content: Content) -> some View {
        content
            .environment(\.keyFocus, KeyFocusContext(focus: focus, stops: stops))
            .onPreferenceChange(KeyStopsKey.self) { new in
                MainActor.assumeIsolated { if new != stops { stops = new } }
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                // ⌘←, ⌥← and the like belong to shortcuts (chart panning, periods).
                guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
                let move: KeyNavigation.Move
                switch press.key {
                case .upArrow: move = .up
                case .downArrow: move = .down
                case .leftArrow: move = .left
                default: move = .right
                }
                guard let next = KeyNavigation.target(from: focus.wrappedValue, move, in: stops) else { return .ignored }
                KeyFocusRing.shared.show()
                focus.wrappedValue = next
                return .handled
            }
            .onAppear { KeyFocusRing.shared.start() }
    }
}

private struct KeyStopModifier: ViewModifier {
    let stop: KeyStop
    let kind: KeyStopKind
    let radius: CGFloat
    let enabled: Bool
    let action: (() -> Void)?

    @Environment(\.keyFocus) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var ring = KeyFocusRing.shared
    @FocusState private var isFocused: Bool

    /// A button the system already puts in the Tab loop isn't made focusable a second time.
    private var makesFocusable: Bool {
        switch kind {
        case .card: return true
        case .control: return !NSApplication.shared.isFullKeyboardAccessEnabled
        case .native: return false
        }
    }

    func body(content: Content) -> some View {
        if enabled, let context {
            let shows = isFocused && ring.visible && kind != .native
            content
                .modifier(FocusableIf(on: makesFocusable))
                // The stop draws its own ring; a system-focusable button would draw a second.
                .focusEffectDisabled(kind != .native)
                .focused(context.focus, equals: stop.id)
                .focused($isFocused)
                .overlay {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
                        .padding(-3)
                        .opacity(shows ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shows)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onKeyPress(keys: [.return, .space], phases: .down) { press in
                    guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                    if let action {
                        action()
                        return .handled
                    }
                    // A card with nothing of its own to do: Return goes into it.
                    guard press.key == .return, let inside = KeyNavigation.firstInside(stop.id, in: context.stops) else {
                        return .ignored
                    }
                    context.focus.wrappedValue = inside
                    return .handled
                }
                // This stop first, then any inside it (the sides of a card), in layout order.
                .transformPreference(KeyStopsKey.self) { $0 = KeyStop.card(stop, holding: $0) }
        } else {
            content
        }
    }
}

/// `.focusable()`, or nothing.
private struct FocusableIf: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.focusable()
        } else {
            content
        }
    }
}

extension View {
    /// Esc does `action` (closes a sheet whose own buttons don't take Esc). A hidden button with
    /// the cancel shortcut, so it works wherever the focus is in the sheet.
    func closesOnEscape(_ action: @escaping () -> Void) -> some View {
        background {
            Button("Close", action: action)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
#endif
