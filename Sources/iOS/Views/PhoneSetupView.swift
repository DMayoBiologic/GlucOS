import SwiftUI

/// A short setup right after the first sign-in on this iPhone: target range, alerts (with the
/// notification permission asked here, where it makes sense, rather than cold at launch) and how
/// the user takes insulin. Everything is already saved as it's chosen, so closing early loses
/// nothing; it's all in Settings afterwards.
struct PhoneSetupView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable {
        case range, alerts, insulin, done

        var title: String {
            switch self {
            case .range: return "Target range"
            case .alerts: return "Alerts"
            case .insulin: return "Insulin"
            case .done: return "Done"
            }
        }
    }

    @State private var step: Step = .range
    /// The way the last step change went, so Back slides the other way.
    @State private var forward = true
    @State private var notificationsAllowed: Bool?
    @State private var asking = false

    /// UserDefaults key: set by the first sign-in, cleared when this closes.
    static let pendingKey = "phoneSetupPending"
    /// Set once the setup has been seen, so signing in again later doesn't repeat it.
    private static let seenKey = "phoneSetupSeen"

    static func markPendingIfNew() {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    progress
                    // Steps push horizontally in the direction of travel (docs/Redesign.md §7.2).
                    content
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.lg)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { PhoneBackdrop(tone: backdropTone) }
            .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Later") { close() }
                    }
                }
            }
        }
        // Closed only by its buttons, so finishing is always recorded.
        .interactiveDismissDisabled()
        .task(id: step) {
            if step == .alerts { notificationsAllowed = await AlertManager.notificationsAllowed() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { notificationsAllowed = await AlertManager.notificationsAllowed() }
        }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                // Each segment fills left to right as its step is reached.
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .overlay {
                        Capsule()
                            .fill(Palette.brandGradient)
                            .scaleEffect(x: s.rawValue <= step.rawValue ? 1 : 0.001, anchor: .leading)
                            .opacity(s.rawValue <= step.rawValue ? 1 : 0)
                    }
                    .clipShape(Capsule())
                    .frame(height: 4)
            }
        }
        .dsAnimation(.emphasized, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.md) {
            if step != .range && step != .done {
                Button("Back") { go(-1) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Button {
                if step == .done { close() } else { go(1) }
            } label: {
                Text(primaryTitle)
                    .dsFont(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var primaryTitle: String {
        switch step {
        case .insulin where settings.therapy == .notSet: return "Skip"
        case .done: return "Start Using GlucOS"
        default: return "Continue"
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        Haptics.tap()
        guard forward == (delta > 0) else {
            // The outgoing step has to be drawn once with the new direction before it leaves,
            // or it would slide out the old way.
            forward = delta > 0
            DispatchQueue.main.async { DS.animate(.standard, reduceMotion: reduceMotion) { step = next } }
            return
        }
        DS.animate(.standard, reduceMotion: reduceMotion) { step = next }
    }

    /// The field behind the steps. On the range step it follows the range being set: the colour the
    /// current reading would have with it (docs/Redesign.md §7.2). Mint otherwise.
    private var backdropTone: Tone {
        guard step == .range, let mgdl = currentMgdl else { return .glucose(.inRange) }
        return .glucose(GlucoseRange.classify(mgdl: mgdl, low: settings.lowMgdl, high: settings.highMgdl))
    }

    /// The latest reading, while it's fresh.
    private var currentMgdl: Double? {
        let s = store.snapshot
        guard let cur = s.current, !s.isStale() else { return nil }
        return cur.mgdl
    }

    private func close() {
        UserDefaults.standard.set(false, forKey: Self.pendingKey)
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .range: range
        case .alerts: alerts
        case .insulin: PhoneTherapyPicker()
        case .done: done
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).dsFont(.title)
            Text(detail)
                .dsFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var range: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            heading("Your target range",
                    "Readings inside it show green, and it sets when low and high alerts fire. Use the range your diabetes team gave you.")
            Picker("Units", selection: $settings.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TargetRangeEditor(settings: settings)
                .dsCard(.standard, padding: DS.Space.lg)
            if let mgdl = currentMgdl { rangePreview(mgdl) }
            Text("Urgent low (below \(settings.unit.format(mgdl: 54, withUnit: true))) and very high (above \(settings.unit.format(mgdl: 250, withUnit: true))) are fixed.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the reading right now sits with the range as set, so moving a limit shows what it does.
    private func rangePreview(_ mgdl: Double) -> some View {
        let range = GlucoseRange.classify(mgdl: mgdl, low: settings.lowMgdl, high: settings.highMgdl)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your reading now").dsFont(.label).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.sm)
                Text("\(settings.unit.format(mgdl: mgdl, withUnit: true)) · \(range.label)")
                    .dsFont(.label)
                    .monospacedDigit()
                    .foregroundStyle(Tone.glucose(range).textColor)
                    .contentTransition(.interpolate)
            }
            RangeRail(mgdl: mgdl, lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl, unit: settings.unit)
        }
        .dsAnimation(.standard, value: settings.lowMgdl)
        .dsAnimation(.standard, value: settings.highMgdl)
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            heading("Alerts",
                    "Lows, highs, fast changes and missing data, as notifications. They add to your sensor app's alarms, never replace them.")
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Toggle("Glucose alerts", isOn: $settings.alertsEnabled.animation())
                    .dsFont(.headline)
                if settings.alertsEnabled {
                    Toggle("Also when above \(settings.unit.format(mgdl: settings.highMgdl, withUnit: true))", isOn: $settings.alertOnHigh)
                    Toggle("Predicted lows, before they happen", isOn: $settings.alertOnPredictedLow)
                    Toggle("Rising or falling quickly", isOn: $settings.alertOnRapidChange)
                    Toggle("No recent data", isOn: $settings.alertOnStale)
                }
            }
            .dsCard(.standard, padding: DS.Space.lg)
            if settings.alertsEnabled { permission }
            Text("Lows and very highs always alert while alerts are on.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permission: some View {
        switch notificationsAllowed {
        case .some(true):
            HStack {
                Label("Notifications are allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
                Spacer()
                Button("Send Test") { store.alerts.sendTest() }
            }
            .dsFont(.callout)
        case .some(false):
            StatusBanner(severity: .critical, systemImage: "bell.slash.fill",
                         title: "Notifications are off for GlucOS",
                         message: "Alerts can't reach you until you allow them in Settings.",
                         action: BannerAction(title: "Turn On") { openURL(AlertManager.notificationSettingsURL) },
                         density: .compact)
        case .none:
            Button {
                asking = true
                store.alerts.requestAuthorization()
                Task {
                    // The system prompt answers asynchronously.
                    for _ in 0..<40 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if let allowed = await AlertManager.notificationsAllowed() { notificationsAllowed = allowed; break }
                    }
                    asking = false
                }
            } label: {
                HStack {
                    Label("Allow Notifications", systemImage: "bell.badge.fill")
                    Spacer()
                    if asking { ProgressView() }
                }
                .dsFont(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(asking)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            heading("You're all set", "A few things worth knowing.")
            tip("plus.circle.fill", "Log from the bar at the bottom",
                "Eating, a bolus, basal, waking up or going to sleep. Or say \u{201C}Log in GlucOS\u{201D} to Siri.")
            tip("lock.iphone", "Your glucose on the Lock Screen",
                "The Live Activity shows your reading, trend and the last 3 hours. Turn it on or off in Settings.")
            tip("person.2.wave.2.fill", "Share with family",
                "The people button at the top left sends a live link in Messages.")
            tip("chart.bar.xaxis", "Insights one tap away",
                "Time in range, your mornings and forecast accuracy, under the logbook.")
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.brandGradient)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dsFont(.headline)
                Text(detail).dsFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
