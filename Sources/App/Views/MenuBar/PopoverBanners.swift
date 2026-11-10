import SwiftUI
import AppKit

/// Something in the popover that needs attention: what's wrong, what it means, and the one
/// action that fixes it.
struct PopoverNotice: Identifiable {
    enum Kind: Int, Comparable {
        // Order is priority: the numbers on screen first, then whether alerts can reach you.
        case stale, sensorEnded, notificationsBlocked, connection, sensorEnding

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    let severity: BannerSeverity
    let systemImage: String
    let title: String
    let message: String
    var action: BannerAction?
    /// Offered as "Copy Error" in the notice's context menu.
    var copyText: String?

    var id: Kind { kind }
}

extension PopoverNotice {
    /// Everything that currently needs attention, most urgent first.
    @MainActor
    static func current(store: GlucoseStore, onRefresh: @escaping () -> Void, now: Date = Date()) -> [PopoverNotice] {
        let s = store.snapshot
        var out: [PopoverNotice] = []
        if let cur = s.current, s.isStale(at: now) {
            out.append(PopoverNotice(
                kind: .stale, severity: .warning, systemImage: "clock.badge.exclamationmark.fill",
                title: "No new reading for \(PopoverFormat.age(cur.age(at: now)))",
                message: "Don't treat based on this value. Check your sensor and phone, or scan with your reader.",
                action: BannerAction(title: "Check Now", isBusy: store.isRefreshing, perform: onRefresh)))
        }
        if let sensor = s.sensor {
            let remaining = sensor.daysRemaining(at: now)
            if remaining <= 0 {
                out.append(PopoverNotice(
                    kind: .sensorEnded, severity: .critical, systemImage: "sensor.tag.radiowaves.forward.fill",
                    title: "Sensor has ended",
                    message: "Readings stop until you start a new sensor."))
            } else if remaining < 0.25 {
                out.append(PopoverNotice(
                    kind: .sensorEnding, severity: .warning, systemImage: "sensor.tag.radiowaves.forward.fill",
                    title: "Sensor ends in \(Format.days(remaining))",
                    message: "Have a replacement ready so you don't lose readings."))
            }
        }
        if store.notificationsBlocked {
            out.append(PopoverNotice(
                kind: .notificationsBlocked, severity: .critical, systemImage: "bell.slash.fill",
                title: "Glucose alerts can't reach you",
                message: "Notifications are off for GlucOS in System Settings.",
                action: BannerAction(title: "Turn On…") { NSWorkspace.shared.open(AlertManager.notificationSettingsURL) }))
        }
        if let err = s.lastError {
            out.append(PopoverNotice(
                kind: .connection, severity: store.connectionProblem?.severity ?? .warning,
                systemImage: store.connectionProblem?.systemImage ?? "exclamationmark.triangle.fill",
                title: store.connectionProblem?.title ?? "Couldn't reach LibreLinkUp",
                message: store.connectionProblem?.advice ?? err,
                action: BannerAction(title: "Retry", isBusy: store.isRefreshing, perform: onRefresh),
                copyText: err))
        }
        return out.sorted { $0.kind < $1.kind }
    }
}

/// The popover's notices. Only the most urgent is shown in full; the rest sit behind a
/// "2 more" row, so a bad moment doesn't push the reading's context off the screen.
///
/// `MenuBarView` builds the list and speaks new notices, since this view isn't in the tree while
/// there's nothing to show.
struct PopoverNotices: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notices: [PopoverNotice]

    @State private var showsAll = false

    var body: some View {
        // Nothing at all when all is well, so no gap is added to the popover's spacing.
        if let first = notices.first {
            let rest = notices.dropFirst()
            VStack(spacing: 6) {
                banner(first)
                if showsAll {
                    ForEach(rest) { banner($0) }
                }
                if !rest.isEmpty {
                    disclosure(count: rest.count, worst: rest.map(\.severity).min() ?? .warning)
                }
            }
            .transition(PopoverMotion.reveal(reduceMotion))
            .animation(PopoverMotion.standard(reduceMotion), value: notices.map(\.kind))
            .animation(PopoverMotion.standard(reduceMotion), value: showsAll)
            .onDisappear { showsAll = false }
            .onChange(of: notices.map(\.kind)) { _, new in
                if new.count <= 1 { showsAll = false }
            }
        }
    }

    private func banner(_ n: PopoverNotice) -> some View {
        StatusBanner(severity: n.severity, systemImage: n.systemImage, title: n.title,
                     message: n.message, action: n.action, density: .compact)
            .transition(PopoverMotion.reveal(reduceMotion))
            .contextMenu {
                if let text = n.copyText {
                    Button("Copy Error", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
    }

    private func disclosure(count: Int, worst: BannerSeverity) -> some View {
        Button {
            showsAll.toggle()
        } label: {
            HStack(spacing: 6) {
                if !showsAll {
                    Circle().fill(worst.tint).frame(width: 6, height: 6)
                }
                Text(showsAll ? "Show less" : "\(count) more \(count == 1 ? "notice" : "notices")")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .rotationEffect(.degrees(showsAll ? 180 : 0))
            }
            .fontWeight(.semibold).dsFont(.label)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(showsAll ? "Show fewer notices" : "\(count) more \(count == 1 ? "notice" : "notices")")
        .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
        .accessibilityHint(showsAll ? "" : "Shows the other notices")
    }
}
