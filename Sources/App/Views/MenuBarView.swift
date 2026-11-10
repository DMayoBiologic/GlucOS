import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.current != nil {
                hero
                chartCard
                statsCard
                if let sensor = s.sensor { sensorCard(sensor) }
            } else {
                emptyState
            }
            if let err = s.lastError { errorBanner(err) }
            if store.notificationsBlocked { notificationsBanner }
            toolbar
            footer
        }
        .padding(12)
        .frame(width: 368)
        .background(alignment: .top) {
            // A wash of the current range colour at the top of the popover.
            AmbientGlow(tint: s.displayTint(), intensity: 0.45)
                .frame(height: 260)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: s.current)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: s.lastError)
        .task { await store.checkNotificationPermission() }
    }

    // MARK: Hero

    private var hero: some View {
        let stale = s.isStale()
        let tint = s.displayTint()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let range = s.range { RangeBadge(range: range, stale: stale) }
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                            .transition(.opacity)
                    }
                }
                if let cur = s.current {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(s.unit.format(mgdl: cur.mgdl))
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(heroNumberStyle(tint)))
                            .contentTransition(.numericText(value: cur.mgdl))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(s.unit.label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(cur.trend.description)
                            .font(.callout.weight(.semibold))
                        if let d = s.deltaMgdl {
                            Text(s.unit.formatDelta(mgdl: d))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: d))
                        }
                    }
                    HStack(spacing: 4) {
                        if stale { Image(systemName: "exclamationmark.triangle.fill") }
                        Text("\(Format.age(cur.age())) · \(cur.timestamp.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(s.accessibilitySummary())

            Spacer(minLength: 4)

            if let cur = s.current {
                TrendDial(trend: cur.trend, tint: tint, size: 72)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                AmbientGlow(tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.18), radius: 14, y: 6)
    }

    private func heroNumberStyle(_ tint: Color) -> LinearGradient {
        // In range reads as calm text; out of range takes the range colour.
        let base: Color = s.range == .inRange ? .primary : tint
        return LinearGradient(colors: [base, base.opacity(0.78)], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Eyebrow(title: "Last \(settings.chartHours) hours", systemImage: "waveform.path.ecg")
                Picker("Chart range", selection: $settings.chartHours) {
                    Text("3h").tag(3)
                    Text("6h").tag(6)
                    Text("12h").tag(12)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                Button { showDashboard() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(PillIconButtonStyle())
                .controlSize(.small)
                .help("Open in Dashboard")
                .accessibilityLabel("Open in Dashboard")
            }
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                         hours: Double(settings.chartHours), interactive: true)
                .frame(height: 150)
                .help("Hover to see individual readings")
        }
        .glassCard(padding: 12)
    }

    // MARK: Stats

    private var statsCard: some View {
        let st = s.stats(hours: 12)
        let st24 = s.stats()
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title: "Time in range", systemImage: "target", trailing: "12 h")
            HStack(alignment: .center, spacing: 14) {
                if let st {
                    TimeInRangeRing(stats: st, lineWidth: 9)
                        .frame(width: 86, height: 86)
                }
                VStack(alignment: .leading, spacing: 7) {
                    legendRow("In range", st.map { Format.percent($0.timeInRange) } ?? "–", GlucoseRange.inRange.tint)
                    legendRow("Below", st.map { Format.percent($0.timeBelowRange) } ?? "–", GlucoseRange.low.tint)
                    legendRow("Above", st.map { Format.percent($0.timeAboveRange) } ?? "–", GlucoseRange.high.tint)
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                tile("Average", st24.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–", systemImage: "chart.bar.fill")
                tile("Range", st24.map { "\(s.unit.format(mgdl: $0.minMgdl))–\(s.unit.format(mgdl: $0.maxMgdl))" } ?? "–",
                     systemImage: "arrow.up.and.down")
                tile("CV", st24.map { Format.percent($0.coefficientOfVariation) } ?? "–", systemImage: "waveform",
                     warn: (st24?.coefficientOfVariation ?? 0) > 0.36)
            }
        }
        .glassCard(padding: 12)
    }

    private func legendRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(color.gradient).frame(width: 4, height: 14)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func tile(_ title: String, _ value: String, systemImage: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help(title == "CV" ? "Variability over 24 h. 36% or less is considered stable." : "\(title) over 24 h")
        .accessibilityElement(children: .combine)
    }

    // MARK: Sensor

    private func sensorCard(_ sensor: SensorInfo) -> some View {
        let remaining = sensor.daysRemaining()
        let fraction = sensor.lifetimeDays > 0 ? min(1, max(0, remaining / Double(sensor.lifetimeDays))) : 0
        let expiringSoon = remaining < 1
        let tint: Color = expiringSoon ? .orange : Palette.brand
        return HStack(spacing: 12) {
            ZStack {
                ProgressRing(fraction: fraction, tint: tint, lineWidth: 4)
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sensor")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(Format.days(remaining)) left")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(expiringSoon ? Color.orange : Color.primary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Expires")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(sensor.expires.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .help(sensor.serial)
        }
        .glassCard(padding: 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty / error / footer

    private var emptyState: some View {
        Group {
            if settings.hasCredentials {
                ContentUnavailableView {
                    Label("Waiting for Data", systemImage: "drop")
                } description: {
                    Text("Fetching from LibreLinkUp. If this persists, check the message below.")
                } actions: {
                    Button("Refresh") { Task { await store.refresh() } }
                        .disabled(store.isRefreshing)
                }
            } else {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Sign in with your LibreLinkUp follower account to start.")
                } actions: {
                    Button("Open Settings…") { showSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassCard()
    }

    private func banner(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(banner(tint: .orange))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Alerts are on but macOS won't show them. Easy to miss otherwise, since nothing else breaks.
    private var notificationsBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text("Notifications are off for GlucOS, so glucose alerts can't reach you.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bell.slash.fill").foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            Button("Turn On…") { NSWorkspace.shared.open(AlertManager.notificationSettingsURL) }
                .controlSize(.small)
        }
        .font(.caption)
        .padding(11)
        .background(banner(tint: .red))
    }

    /// Floating pill toolbar.
    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { showLogSheet() } label: {
                Label("Log", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillIconButtonStyle(prominent: true))
            .keyboardShortcut("l")
            .help("Log insulin or food (⌘L)")

            pill("Refresh (⌘R)", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r")
            pill("Open Dashboard (⌘D)", systemImage: "macwindow") { showDashboard() }
                .keyboardShortcut("d")
            pill("Settings… (⌘,)", systemImage: "gearshape") { showSettings() }
                .keyboardShortcut(",")
            pill("Check for Updates (v\(updater.version))", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)

            Spacer(minLength: 4)

            pill("Quit GlucOS (⌘Q)", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if s.lastError == nil {
                Text(store.statusLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.statusLine)
                Text("·")
            }
            Text("Not a medical device. Confirm on your phone before treating.")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(PillIconButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    /// `LSUIElement` apps don't come forward on their own, so the Settings window would open
    /// behind whatever app was frontmost.
    private func showSettings() {
        openSettings()
        NSApp.activate()
    }

    private func showDashboard() {
        openWindow(id: DashboardView.windowID)
        NSApp.activate()
    }

    /// The log sheet lives in the dashboard window, since a sheet can't hang off the popover.
    private func showLogSheet() {
        logbook.logSheetRequested = true
        showDashboard()
    }
}
