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

    @Published private(set) var banner: AlertBanner?

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
        guard let banner = AlertBanner(kind: userInfo["kind"] as? String,
                                       isFollowerCopy: userInfo["followID"] != nil,
                                       title: title, body: body, firedAt: date),
              canShow else { return false }
        show(banner)
        return true
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        banner = nil
    }

    /// A banner button: records it in the Logbook like a notification button, hides the banner,
    /// then does what the notification's button does.
    func tap(_ button: AlertBanner.Button) {
        guard let banner, let tap = banner.tap(button) else { return }
        AlertLogRecorder.shared.tapped(tap, userInfo: ["kind": banner.kind.rawValue], firedAt: banner.firedAt)
        dismiss()
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
        banner = new
        #if os(iOS)
        Haptics.play(.alertBanner)
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
        AccessibilityNotification.Announcement(new.announcement).post()
        // One timer to take it away if it's left alone: nothing polls.
        expiry?.cancel()
        let id = new.id
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, new.firedAt.addingTimeInterval(AlertBanner.lifetime).timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.banner?.id == id else { return }
            self.banner = nil
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
                ZStack(alignment: .top) {
                    if let banner = center.banner {
                        AlertBannerView(banner: banner, onTap: center.tap, onDismiss: center.dismiss)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.top, DS.Space.sm)
                            .id(banner.id)
                            // Slides down once; under Reduce Motion it cross-fades instead.
                            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation,
                           value: center.banner?.id)
            }
            #if os(macOS)
            .background(HostWindowReader { center.host(id, isIn: $0) })
            #endif
            .onAppear { center.hostAppeared(id) }
            .onDisappear { center.hostDisappeared(id) }
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
    let onTap: (AlertBanner.Button) -> Void
    let onDismiss: () -> Void

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
        // Follows the finger up, and springs back if it's let go early. Never down past its place.
        .offset(y: min(0, drag))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -30 || value.predictedEndTranslation.height < -80 {
                        onDismiss()
                    } else {
                        withAnimation(reduceMotion ? nil : DSMotion.quick.animation) { drag = 0 }
                    }
                }
        )
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAction(named: AlertBanner.dismissTitle, onDismiss)
    }
}
