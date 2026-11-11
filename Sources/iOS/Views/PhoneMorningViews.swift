import SwiftUI

// Logging wake-ups on the iPhone, and what GlucOS has learnt about mornings. A wake-up is a
// logbook event (the "Woke up" tag), so it syncs to the Mac with the rest of the logbook.

/// Logs wake-ups from the log bar, the Lock Screen widget (`glucos://log/wake`) and the "I'm up"
/// App Shortcut, and remembers when the phone was first used this morning for the suggestion.
@MainActor
final class PhoneWakeLogger: ObservableObject {
    static let shared = PhoneWakeLogger()

    /// Set at launch.
    weak var logbook: LogbookStore?

    /// The wake-up just logged (or found already logged), shown in the log bar for a few seconds
    /// with Undo / Change.
    @Published private(set) var confirmation: Confirmation?

    struct Confirmation: Equatable {
        let entry: ContextEvent
        /// True when a one-tap log found one already logged and didn't add another.
        let alreadyLogged: Bool
    }

    private static let firstActiveKey = "wakeFirstActive"
    private static let dismissedKey = "wakePromptDismissed"
    private var clearTask: Task<Void, Never>?

    var firstActive: Date? {
        let t = UserDefaults.standard.double(forKey: Self.firstActiveKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var dismissedOn: String? { UserDefaults.standard.string(forKey: Self.dismissedKey) }

    /// The app came to the foreground.
    func noteActive(now: Date = Date()) {
        if let t = WakeLog.noteActive(previous: firstActive, now: now) {
            UserDefaults.standard.set(t.timeIntervalSince1970, forKey: Self.firstActiveKey)
        }
    }

    func dismissForToday(now: Date = Date()) {
        UserDefaults.standard.set(WakeLog.dayKey(now), forKey: Self.dismissedKey)
        objectWillChange.send()
    }

    /// One tap: logs "Woke up" now, unless one was logged in the last few hours.
    func quickLog(now: Date = Date()) {
        guard let logbook else { return }
        if let recent = WakeLog.recent(logbook.contexts, now: now) {
            show(Confirmation(entry: recent, alreadyLogged: true))
            return
        }
        log(at: now)
    }

    func log(at date: Date) {
        guard let logbook else { return }
        let e = WakeLog.entry(at: min(date, Date()))
        logbook.save(.context(e))
        Haptics.success()
        show(Confirmation(entry: e, alreadyLogged: false))
    }

    func undo() {
        guard let c = confirmation, !c.alreadyLogged else { return }
        logbook?.delete(ids: [c.entry.id])
        logbook?.clearUndo()
        confirmation = nil
    }

    func clearConfirmation() { confirmation = nil }

    private func show(_ c: Confirmation) {
        confirmation = c
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }
}

/// The strip above the log bar's buttons in the morning: "Woke up at 6:41?" with the time to
/// adjust, Log, and Not today. After logging it confirms, with Undo and Change.
struct PhoneWakeStrip: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var router: PhoneLogRouter
    @ObservedObject private var logger = PhoneWakeLogger.shared
    @State private var time = Date()
    @State private var edited = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .animation(DSMotion.quick.animation, value: logger.confirmation)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let c = logger.confirmation {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: ContextTag.wokeUp.systemImage).foregroundStyle(Palette.context)
                Text(c.alreadyLogged ? "Wake-up already logged at \(ClockLabel.time(c.entry.timestamp))"
                                     : "Logged wake-up at \(ClockLabel.time(c.entry.timestamp))")
                    .dsFont(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: DS.Space.xs)
                if !c.alreadyLogged {
                    Button("Undo") { logger.undo() }.dsFont(.headline)
                }
                Button("Change") {
                    logger.clearConfirmation()
                    router.edit(.context(c.entry))
                }
                .dsFont(.headline)
            }
            .padding(.bottom, DS.Space.sm)
            .transition(.opacity)
        } else if WakeLog.shouldPrompt(contexts: logbook.contexts, now: now, dismissedOn: logger.dismissedOn) {
            let suggested = WakeLog.suggestedTime(firstActive: logger.firstActive, now: now)
            HStack(spacing: DS.Space.sm) {
                Image(systemName: ContextTag.wokeUp.systemImage).foregroundStyle(Palette.context)
                Text("Woke up at").dsFont(.callout).lineLimit(1)
                DatePicker("Woke up at", selection: Binding(get: { edited ? time : (suggested ?? now) },
                                                            set: { time = $0; edited = true }),
                           in: ...now, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer(minLength: DS.Space.xs)
                Button {
                    logger.log(at: edited ? time : (suggested ?? now))
                    edited = false
                } label: {
                    Text("Log").dsFont(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.context)
                .controlSize(.small)
                Button {
                    logger.dismissForToday(now: now)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not today")
            }
            .padding(.bottom, DS.Space.sm)
            .accessibilityElement(children: .contain)
            .accessibilityHint(suggested == nil ? "" : "Suggested from when you first opened GlucOS this morning.")
            .transition(.opacity)
        }
    }
}

/// What GlucOS has learnt about mornings, and whether today's forecast includes it.
struct PhoneMorningCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @ObservedObject var outlook: OutlookStore

    var body: some View {
        let pattern = outlook.model.morning
        let hasWake = logbook.contexts.contains(where: \.isWake)
        if hasWake || pattern.loggedWakes > 0 {
            card(pattern)
        }
    }

    private func card(_ p: MorningPattern) -> some View {
        let unit = store.snapshot.unit
        let today = store.snapshot.currentOutlook()?.morning
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Eyebrow(title: "Mornings", systemImage: ContextTag.wokeUp.systemImage)
                Spacer(minLength: 0)
                if case .used(let c) = p.status {
                    TonePill(text: c.title, tone: c.tone)
                } else if p.mornings > 0 || p.loggedWakes > 0 {
                    TonePill(text: "Learning", tone: .neutral)
                }
            }
            if p.mornings >= MorningPatternLearner.minimumMornings {
                Text(p.summary(unit: unit)).dsFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(p.statusMessage).dsFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let check = p.checkSummary {
                Text(check).dsFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let today {
                Label(MorningFormat.todayLine(today, unit: unit), systemImage: "chart.line.uptrend.xyaxis")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Used only to shape the forecast. It's not a setting and never goes into dose maths.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
