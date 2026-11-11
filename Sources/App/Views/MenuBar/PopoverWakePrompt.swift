import SwiftUI
import AppKit

/// Notes when the Mac is first used each morning (GlucOS launching, the screen waking, the user
/// switching back in), so the popover can suggest it as the wake-up time. Nothing is logged
/// until the user confirms.
@MainActor
final class MacWakeWatcher: ObservableObject {
    static let shared = MacWakeWatcher()

    private static let firstActiveKey = "wakeFirstActive"
    private static let dismissedKey = "wakePromptDismissed"
    private var observers: [NSObjectProtocol] = []

    var firstActive: Date? {
        let t = UserDefaults.standard.double(forKey: Self.firstActiveKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var dismissedOn: String? { UserDefaults.standard.string(forKey: Self.dismissedKey) }

    /// The wake-up logged from the popover, and when, for its confirmation and Undo.
    @Published var justLogged: (entry: ContextEvent, at: Date)?

    func start() {
        guard observers.isEmpty else { return }
        noteActive()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in MacWakeWatcher.shared.noteActive() }
            })
        }
    }

    func noteActive(now: Date = Date()) {
        if let t = WakeLog.noteActive(previous: firstActive, now: now), t != firstActive {
            UserDefaults.standard.set(t.timeIntervalSince1970, forKey: Self.firstActiveKey)
            objectWillChange.send()
        }
    }

    func dismissForToday(now: Date = Date()) {
        UserDefaults.standard.set(WakeLog.dayKey(now), forKey: Self.dismissedKey)
        objectWillChange.send()
    }
}

/// In the morning, until a wake-up is logged (here, on the iPhone, or anywhere else the logbook
/// syncs) or dismissed: "Woke up at 6:41?" with the time to adjust.
struct PopoverWakePrompt: View {
    @EnvironmentObject var logbook: LogbookStore
    @ObservedObject private var watcher = MacWakeWatcher.shared
    @State private var time = Date()
    @State private var edited = false

    /// Worth a place in the popover right now: asking, or confirming a wake-up just logged.
    @MainActor
    static func isRelevant(logbook: LogbookStore, now: Date = Date()) -> Bool {
        confirmation(logbook: logbook, now: now) != nil
            || WakeLog.shouldPrompt(contexts: logbook.contexts, now: now, dismissedOn: MacWakeWatcher.shared.dismissedOn)
    }

    /// The wake-up logged from here in the last 10 minutes, while it's still in the logbook.
    @MainActor
    private static func confirmation(logbook: LogbookStore, now: Date) -> ContextEvent? {
        guard let j = MacWakeWatcher.shared.justLogged, now.timeIntervalSince(j.at) < 10 * 60,
              logbook.contexts.contains(where: { $0.id == j.entry.id }) else { return nil }
        return j.entry
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let logged = Self.confirmation(logbook: logbook, now: now) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: ContextTag.wokeUp.systemImage).foregroundStyle(Palette.context)
                Text("Logged wake-up at \(ClockLabel.time(logged.timestamp))").dsFont(.callout)
                Spacer(minLength: 0)
                Button("Undo") {
                    logbook.delete(ids: [logged.id])
                    logbook.clearUndo()
                    watcher.justLogged = nil
                }
                .buttonStyle(.link)
            }
            .dsCard(.standard, padding: DS.Space.md)
        } else if WakeLog.shouldPrompt(contexts: logbook.contexts, now: now, dismissedOn: watcher.dismissedOn) {
            let suggested = WakeLog.suggestedTime(firstActive: watcher.firstActive, now: now)
            HStack(spacing: DS.Space.sm) {
                Image(systemName: ContextTag.wokeUp.systemImage).foregroundStyle(Palette.context)
                Text("Woke up at").dsFont(.callout)
                DatePicker("Woke up at", selection: Binding(get: { edited ? time : (suggested ?? now) },
                                                            set: { time = $0; edited = true }),
                           in: ...now, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                    .help(suggested == nil ? "When you woke up" : "Suggested from when you first used your Mac this morning")
                Spacer(minLength: 0)
                Button("Log") {
                    let e = WakeLog.entry(at: min(edited ? time : (suggested ?? now), Date()))
                    logbook.save(.context(e))
                    watcher.justLogged = (e, Date())
                    edited = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.context)
                .controlSize(.small)
                Button {
                    watcher.dismissForToday(now: now)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Not today")
                .accessibilityLabel("Not today")
            }
            .dsCard(.standard, padding: DS.Space.md)
        }
    }
}
