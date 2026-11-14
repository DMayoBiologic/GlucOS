import SwiftUI
import AppKit
import ServiceManagement

/// First-run setup: what GlucOS is, signing in to LibreLinkUp, target range, alerts and how the
/// user takes insulin. Opens by itself the first time GlucOS runs without an account, and from
/// Settings → General → Run Setup Again.
struct OnboardingView: View {
    static let windowID = "onboarding"
    /// Text stays at a readable measure however wide the window is.
    private static let contentWidth: CGFloat = 600

    enum Step: Int, CaseIterable {
        case welcome, account, range, alerts, therapy, done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .account: return "Connect"
            case .range: return "Target range"
            case .alerts: return "Alerts"
            case .therapy: return "Insulin"
            case .done: return "Done"
            }
        }
    }

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step = .welcome
    @State private var forward = true

    // Account step
    @State private var email = ""
    @State private var password = ""
    @State private var region = "au"
    @State private var signingIn = false
    @State private var problem: ConnectionProblem?
    @State private var connected = false

    @FocusState private var focus: Field?
    private enum Field { case email, password }

    // Alerts step
    @State private var notificationsAllowed: Bool?

    // Done step
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        VStack(spacing: 0) {
            progress
                .frame(maxWidth: Self.contentWidth)
                .padding(.top, 18)
                .padding(.horizontal, 28)
            // Each step scrolls on its own, so a long step (sign-in with an error and the help
            // open) never pushes the buttons off a small window.
            ScrollView {
                // ZStack so the outgoing and incoming steps overlap during the slide rather than
                // stacking in the scroll view.
                ZStack(alignment: .topLeading) {
                    content
                        .frame(maxWidth: Self.contentWidth, alignment: .topLeading)
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            Divider()
            navigation
                .frame(maxWidth: Self.contentWidth + 32)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .background(alignment: .top) {
            AmbientGlow(tint: Palette.brand, intensity: 0.35)
                .frame(height: 240)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onAppear {
            email = settings.email
            password = settings.password
            region = settings.region
            connected = settings.hasCredentials && store.connectionProblem == nil && store.snapshot.current != nil
            NSApp.activate()
        }
        .task(id: step) {
            if step == .alerts { notificationsAllowed = await AlertManager.notificationsAllowed() }
        }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    .frame(height: 4)
                    .help(s.title)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    private var navigation: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }
            }
            if step == .welcome {
                Button("Set Up Later") { finish() }
                    .help("Skip setup. You can sign in any time from Settings.")
            }
            Spacer()
            switch step {
            case .account where !connected:
                Button("Skip for Now") { go(1) }
                Button("Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || signingIn)
            case .therapy where settings.therapy == .notSet:
                Button("Skip") { go(1) }
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start Using GlucOS") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            default:
                Button(step == .welcome ? "Get Started" : "Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { step = next }
    }

    private func finish() {
        settings.onboardingCompleted = true
        dismissWindow(id: Self.windowID)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .range: range
        case .alerts: alerts
        case .therapy: therapy
        case .done: done
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .dsFont(.title)
            Text(subtitle)
                .fontWeight(.regular)
                .dsFont(.sectionTitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            heading("Your glucose, in the menu bar",
                    "GlucOS shows your FreeStyle Libre readings from LibreLinkUp on your Mac, with alerts, a dashboard and widgets.")
            VStack(alignment: .leading, spacing: 14) {
                feature("drop.fill", Palette.mint, "Always in view", "The current reading and trend sit in your menu bar, colour-coded by range.")
                feature("bell.badge.fill", Palette.amber, "Alerts on your Mac", "Lows, highs, fast changes and missing data, as macOS notifications.")
                feature("book.fill", Palette.brand, "Log insulin and food", "Quick entry with presets, and patterns from your own data.")
            }
            Label("Not a medical device. Keep using your phone's alarms and confirm readings there before treating.",
                  systemImage: "stethoscope")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Connect LibreLinkUp", "Sign in with a LibreLinkUp follower account. GlucOS reads the same data your follower app sees.")
            if connected {
                connectedCard
            } else {
                VStack(spacing: 10) {
                    TextField("Email", text: $email, prompt: Text("Follower account email"))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password, prompt: Text("Password"))
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit {
                            if !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty { signIn() }
                        }
                    HStack {
                        RegionPicker(region: $region)
                            .fixedSize()
                        Spacer()
                        if signingIn {
                            ProgressView().controlSize(.small)
                            Text("Signing in…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(signingIn)
                if let problem, !signingIn {
                    ConnectionProblemView(problem: problem) { fix in
                        if case .updateClientVersion(let version) = fix { settings.clientVersion = version }
                        signIn()
                    }
                    .transition(.opacity)
                }
                FlowPanel {
                    FollowerAccountHelp()
                }
                Text("Your password is stored in the macOS Keychain. It goes to Abbott to sign in, and once to the GlucOS sync server so your logbook can sync with your iPhone, which doesn't keep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.2), value: problem)
        .animation(.smooth(duration: 0.2), value: connected)
        .task {
            // Straight into typing, at the field that's still empty.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !connected { focus = email.isEmpty ? .email : .password }
        }
    }

    private var connectedCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Palette.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connected").font(.headline)
                if let cur = store.snapshot.current {
                    Text("Latest reading \(store.snapshot.unit.format(mgdl: cur.mgdl, withUnit: true)), \(Format.age(cur.age()))")
                        .foregroundStyle(.secondary)
                } else {
                    Text(settings.email).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Use Another Account") {
                connected = false
                password = ""
            }
        }
        .glassCard()
    }

    private func signIn() {
        guard !signingIn else { return }
        signingIn = true
        problem = nil
        Task {
            let result = await store.signIn(email: email, password: password, region: region)
            signingIn = false
            problem = result
            if result == nil {
                connected = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                if step == .account { go(1) }
            }
        }
    }

    private var range: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Your target range", "Readings inside this range show green. It also sets when low and high alerts fire. Use the range your diabetes team gave you.")
            Picker("Units", selection: $settings.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            TargetRangeEditor(settings: settings)
                .glassCard()
            Text("Urgent low (below \(settings.unit.format(mgdl: 54, withUnit: true))) and very high (above \(settings.unit.format(mgdl: 250, withUnit: true))) are fixed. You can change all of this later in Settings → Glucose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Alerts on your Mac", "GlucOS can notify you about lows, highs, fast changes and missing data. They add to your phone's alarms, never replace them.")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Glucose alerts", isOn: $settings.alertsEnabled)
                    .toggleStyle(.switch)
                    .font(.headline)
                if settings.alertsEnabled {
                    Toggle("Also alert when above \(settings.unit.format(mgdl: settings.highMgdl, withUnit: true))", isOn: $settings.alertOnHigh)
                    Toggle("Predicted lows, up to \(settings.predictiveAlertMinutes) minutes ahead", isOn: $settings.alertOnPredictedLow)
                    Toggle("Rising or falling quickly", isOn: $settings.alertOnRapidChange)
                    Toggle("No data for more than 6 minutes", isOn: $settings.alertOnStale)
                    Toggle("Sensor expiring within 24 hours", isOn: $settings.alertOnSensorExpiry)
                }
            }
            .glassCard()
            if settings.alertsEnabled {
                HStack(spacing: 10) {
                    switch notificationsAllowed {
                    case .some(true):
                        Label("Notifications are allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                        Spacer()
                        Button("Send Test Alert") { store.alerts.sendTest() }
                    case .some(false):
                        StatusBanner(severity: .critical, systemImage: "bell.slash.fill",
                                     title: "Notifications are off for GlucOS",
                                     message: "Alerts can't appear on this Mac until you allow them in System Settings.",
                                     action: BannerAction(title: "Open Settings…", systemImage: "gearshape") {
                                         NSWorkspace.shared.open(AlertManager.notificationSettingsURL)
                                     },
                                     density: .compact)
                    case .none:
                        Label("macOS will ask to allow notifications", systemImage: "bell")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow Notifications") { requestNotifications() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .font(.callout)
            }
            Text("Lows and very highs always alert while glucose alerts are on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.smooth(duration: 0.2), value: settings.alertsEnabled)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationsAllowed = await AlertManager.notificationsAllowed() }
        }
    }

    private func requestNotifications() {
        store.alerts.requestAuthorization()
        // The system prompt answers asynchronously; check again shortly after.
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let allowed = await AlertManager.notificationsAllowed()
                if allowed != nil { notificationsAllowed = allowed; break }
            }
        }
    }

    private var therapy: some View {
        VStack(alignment: .leading, spacing: 18) {
            TherapySetupView()
            Text("Optional. GlucOS records what you log. Only the bolus calculator suggests a dose, and only from settings you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("You're all set", connected
                    ? "Readings will keep updating in your menu bar."
                    : "Sign in from Settings → Account whenever you're ready.")
            VStack(alignment: .leading, spacing: 14) {
                feature("cursorarrow.click", Palette.brand, "Click the reading in the menu bar",
                        "For the chart, time in range and sensor life. ⌘D opens the full dashboard.")
                feature("plus.circle.fill", Palette.brand, "Log with ⌘L",
                        "From the menu bar or dashboard. Tick “Save as preset” for things you log often.")
                feature("square.grid.2x2.fill", Palette.brand, "Add the widget",
                        "Right-click the desktop → Edit Widgets → search “GlucOS”.")
                feature("gearshape.fill", Palette.stale, "Change anything later",
                        "Settings (⌘,) has your account, target range, alerts and logging options.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open GlucOS when you log in", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .font(.headline)
                Text(loginNote ?? "Recommended, so readings and alerts carry on after a restart.")
                    .font(.callout)
                    .foregroundStyle(loginNote == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Tone.warning.textColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .glassCard()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin { loginNote = nil }
        }
    }

    /// Same rules as Settings → General → Launch at login.
    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    loginNote = "Allow GlucOS in System Settings → General → Login Items to finish turning this on."
                } else if service.status != .enabled {
                    try service.register()
                    loginNote = nil
                }
            } else if service.status != .notRegistered {
                try service.unregister()
                loginNote = nil
            }
        } catch {
            loginNote = error.localizedDescription
        }
        launchAtLogin = service.status == .enabled
    }
}
