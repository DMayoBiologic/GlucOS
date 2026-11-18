import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The in-app alert banner (docs/AlertActions.md, "In-app banner"): a low or high alert that fires
// while GlucOS is in front slides down from the top of the screen (iPhone) or window (Mac popover
// and dashboard) with the reading and the notification's own buttons, instead of the system banner.
// The notification still plays its sound and goes in Notification Center, and a haptic plays.

// MARK: - Center

/// Holds the banner on screen, decides whether an alert arriving now can be shown in the app, and
/// runs its buttons. One per app.
@MainActor
final class AlertBannerCenter: ObservableObject {
    static let shared = AlertBannerCenter()

    /// Every banner on screen, front first. A second alert stacks behind the first (round 59).
    @Published private(set) var stack = AlertBannerStack()

    /// The banner in front.
    var banner: AlertBanner? { stack.front }

    /// What a banner button does: exactly what the same button does on the notification. Set at
    /// launch by each app (iPhone: `PhoneAlertActions.handle`; Mac: `MacAlertActions.handle`).
    var perform: (@MainActor (AlertNotifications.Tap) async -> Void)?

    /// The views that can show a banner right now (`alertBannerHost()`). On the Mac each one's
    /// window, so a closed popover or a dashboard behind another app doesn't count.
    private var hosts: [UUID: HostWindow] = [:]
    private var expiry: Task<Void, Never>?

    #if os(macOS)
    struct HostWindow { weak var window: NSWindow? }
    #else
    struct HostWindow {}
    #endif

    /// An alert is being presented while the app runs. True when it's now showing as the in-app
    /// banner, so the caller leaves the system banner off (keeping the sound and the list); false
    /// for anything that isn't the user's own low or high alert, or when no banner can be seen.
    func present(title: String, body: String, userInfo: [AnyHashable: Any], at date: Date) -> Bool {
        // A test alert keeps the system banner: that's what it's testing (docs/TestAlert.md).
        guard !TestAlert.isTest(userInfo),
              let banner = AlertBanner(kind: userInfo["kind"] as? String,
                                       isFollowerCopy: userInfo["followID"] != nil,
                                       title: title, body: body, firedAt: date),
              canShow else { return false }
        show(banner)
        return true
    }

    /// Hides one banner (swiped up, closed, or tapped). Never snoozes or logs anything; the
    /// notification stays in Notification Center. The next one behind comes forward.
    func dismiss(_ id: String) {
        stack.remove(id: id)
        scheduleExpiry()
    }

    /// Hides them all.
    func dismissAll() {
        stack.removeAll()
        scheduleExpiry()
    }

    /// Spreads the stack out, or folds it back.
    func setExpanded(_ expanded: Bool) {
        stack.setExpanded(expanded)
    }

    /// A tap on a banner itself: with others waiting behind it, spreads the stack out; otherwise
    /// dismisses it, as before.
    func tapBanner(_ id: String) {
        if !stack.isExpanded, stack.canExpand, stack.front?.id == id {
            setExpanded(true)
        } else {
            dismiss(id)
        }
    }

    /// A banner button: records it in the Logbook like a notification button, hides that banner,
    /// then does what the notification's button does.
    func tap(_ button: AlertBanner.Button, on banner: AlertBanner) {
        guard let tap = banner.tap(button) else { return }
        AlertLogRecorder.shared.tapped(tap, userInfo: ["kind": banner.kind.rawValue], firedAt: banner.firedAt)
        dismiss(banner.id)
        Task { await perform?(tap) }
    }

    func hostAppeared(_ id: UUID) { if hosts[id] == nil { hosts[id] = HostWindow() } }
    func hostDisappeared(_ id: UUID) { hosts[id] = nil }

    #if os(macOS)
    func host(_ id: UUID, isIn window: NSWindow?) {
        hosts[id] = HostWindow(window: window)
    }
    #endif

    /// Whether a banner shown now would be seen: the app is in front and a host is on screen.
    private var canShow: Bool {
        #if os(macOS)
        guard NSApp.isActive else { return false }
        return hosts.values.contains { host in
            guard let w = host.window else { return false }
            return w.isVisible && w.occlusionState.contains(.visible)
        }
        #else
        return UIApplication.shared.applicationState == .active && !hosts.isEmpty
        #endif
    }

    private func show(_ new: AlertBanner) {
        stack.add(new, now: Date())
        #if os(iOS)
        Haptics.play(.alertBanner)
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
        AccessibilityNotification.Announcement(new.announcement).post()
        scheduleExpiry()
    }

    /// One timer, at the next banner's end, to take it away if it's left alone: nothing polls.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let end = stack.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.stack.prune(at: Date())
            self.scheduleExpiry()
        }
    }
}

extension AlertBanner {
    /// The tap this button stands for, the same as `AlertNotifications.button` returns for the
    /// notification's button.
    func tap(_ button: Button) -> AlertNotifications.Tap? {
        switch button {
        case .treat: return kind.treatment.map { .treat(kind, $0) }
        case .snooze: return kind.snoozeLevel == nil ? nil : .snooze(kind)
        }
    }
}

// MARK: - Host

extension View {
    /// Where the in-app alert banner slides in: the top of the iPhone's screen, the Mac popover
    /// and the dashboard window.
    func alertBannerHost() -> some View { modifier(AlertBannerHost()) }
}

private struct AlertBannerHost: ViewModifier {
    @ObservedObject private var center = AlertBannerCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                AlertBannerStackView(center: center, reduceMotion: reduceMotion)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.top, DS.Space.sm)
            }
            #if os(macOS)
            .background(HostWindowReader { center.host(id, isIn: $0) })
            #endif
            .onAppear { center.hostAppeared(id) }
            .onDisappear { center.hostDisappeared(id) }
    }
}

/// The banners, front first (round 59). Collapsed, the ones behind peek out a few points below
/// the front card, smaller and fainter, and only the front one can be touched. Spread out, they sit
/// one under another with a Show less button. Cards move with a spring as they arrive, leave, or
/// spread; under Reduce Motion every change cross-fades instead.
private struct AlertBannerStackView: View {
    @ObservedObject var center: AlertBannerCenter
    let reduceMotion: Bool
    @State private var heights: [String: CGFloat] = [:]

    private var stack: AlertBannerStack { center.stack }

    var body: some View {
        ZStack(alignment: .top) {
            cards
                // Reduce Motion: no sliding between places; the whole stack cross-fades.
                .id(reduceMotion ? stackKey : "stack")
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.identity)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation, value: stack)
        .onPreferenceChange(AlertBannerHeights.self) { heights = $0 }
    }

    private var stackKey: String {
        (stack.isExpanded ? "open:" : "shut:") + stack.banners.map(\.id).joined(separator: ",")
    }

    private var cards: some View {
        let banners = stack.banners
        return ZStack(alignment: .top) {
            ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                let slot = spot(at: index)
                let isFront = index == 0
                let interactive = stack.isExpanded || isFront
                AlertBannerView(banner: banner,
                                moreLine: isFront ? stack.moreLine : nil,
                                onTap: { center.tap($0, on: banner) },
                                onBannerTap: { center.tapBanner(banner.id) },
                                onDismiss: { center.dismiss(banner.id) },
                                onShowAll: isFront && stack.moreLine != nil ? { center.setExpanded(true) } : nil)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: AlertBannerHeights.self,
                                                   value: [banner.id: proxy.size.height])
                        }
                    }
                    .scaleEffect(slot.scale, anchor: .top)
                    .opacity(slot.opacity)
                    .offset(y: slot.offset)
                    .zIndex(Double(banners.count - index))
                    .allowsHitTesting(interactive)
                    .accessibilityHidden(!interactive)
                    // A new alert slides down into the front; one that's dismissed carries on up
                    // and out. Under Reduce Motion the stack cross-fades instead (above).
                    .transition(reduceMotion ? AnyTransition.opacity
                                             : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
            if stack.isExpanded {
                Button(AlertBannerStack.showLessTitle) { center.setExpanded(false) }
                    .buttonStyle(.ds(.secondary))
                    .offset(y: expandedOffset(at: banners.count))
                    .zIndex(Double(banners.count + 1))
                    .transition(.opacity)
            }
        }
    }

    private func spot(at index: Int) -> AlertBannerStack.Peek {
        if stack.isExpanded {
            return AlertBannerStack.Peek(offset: expandedOffset(at: index), scale: 1, opacity: 1)
        }
        return AlertBannerStack.peek(at: index)
    }

    /// Spread out: each card sits under the ones above it.
    private func expandedOffset(at index: Int) -> Double {
        stack.banners.prefix(index).reduce(0) { total, banner in
            total + Double(heights[banner.id] ?? 0) + Double(DS.Space.sm)
        }
    }
}

private struct AlertBannerHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

#if os(macOS)
/// Hands the host's window to the center, so it can tell whether the banner would be seen.
private struct HostWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowView: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [found] in found(window) }
        }
    }
}
#endif

// MARK: - Banner

/// The banner itself: the alert's title (with the reading) and body, its buttons, and a close
/// button. Tapping the banner or swiping it up dismisses it; its buttons do what the notification's
/// do. It never loops or pulses.
struct AlertBannerView: View {
    let banner: AlertBanner
    /// "1 more alert · Tap to show" on the front card while others wait behind it.
    var moreLine: String? = nil
    let onTap: (AlertBanner.Button) -> Void
    /// A tap on the banner itself: spreads a stack out, or dismisses a lone banner.
    let onBannerTap: () -> Void
    let onDismiss: () -> Void
    /// Spreads the stack out, for VoiceOver; nil when there's nothing behind.
    var onShowAll: (() -> Void)? = nil

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    private var tone: Tone {
        if banner.isUrgent { return .critical }
        return banner.isLow ? .glucose(.low) : .glucose(.high)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        let increased = contrast == .increased
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                // Wiggles once as the alert arrives, the way it's heading (round 48). Still under
                // Reduce Motion.
                Image(systemName: banner.isLow ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(tone.color)
                    .symbolWiggleOnAppear(banner.isLow ? .down : .up)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(banner.title)
                        .dsFont(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !banner.body.isEmpty {
                        Text(banner.body)
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(banner.accessibilityLabel)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AlertBanner.dismissTitle)
                .accessibilityHint(AlertBanner.dismissHint)
            }
            if let moreLine {
                Text(moreLine)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: DS.Space.sm) {
                ForEach(banner.buttons, id: \.title) { button in
                    Button(button.title) { onTap(button) }
                        .buttonStyle(.ds(button == .treat ? .tinted(tone) : .secondary))
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: 520, alignment: .leading)
        .background {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(tone.color.opacity(0.12)) }
        }
        .overlay {
            shape.strokeBorder(tone.color.opacity(increased ? 1 : 0.45),
                               lineWidth: increased ? DS.Stroke.increased : DS.Stroke.hairline)
        }
        .clipShape(shape)
        .dsShadow(.high)
        .contentShape(shape)
        // Follows the finger up one to one and gives a little, resisting, when pulled down
        // (round 59). Let go far or fast enough upward and it's dismissed, carrying on up and out;
        // otherwise it springs back. Under Reduce Motion it stays put and fades as it's swiped.
        .offset(y: reduceMotion ? 0 : AlertBannerSwipe.offset(for: drag))
        .opacity(reduceMotion ? AlertBannerSwipe.reducedOpacity(for: drag) : 1)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if AlertBannerSwipe.dismisses(translation: value.translation.height,
                                                  predicted: value.predictedEndTranslation.height) {
                        onDismiss()
                    } else {
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation) {
                            drag = 0
                        }
                    }
                }
        )
        .onTapGesture(perform: onBannerTap)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAction(named: AlertBanner.dismissTitle, onDismiss)
        .modifier(ShowAllAction(moreLine: moreLine, onShowAll: onShowAll))
    }
}

/// VoiceOver: with others behind the front banner, says how many and offers to show them all.
private struct ShowAllAction: ViewModifier {
    let moreLine: String?
    let onShowAll: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let moreLine, let onShowAll {
            content
                .accessibilityValue(moreLine.components(separatedBy: " · ").first ?? moreLine)
                .accessibilityAction(named: AlertBannerStack.showAllTitle, onShowAll)
        } else {
            content
        }
    }
}
