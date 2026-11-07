import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if s.current != nil {
                header
                chartCard
                statsCard
                if let sensor = s.sensor { sensorCard(sensor) }
            } else {
                emptyState
            }
            if let err = s.lastError { errorBanner(err) }
            if store.notificationsBlocked { notificationsBanner }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: s.current)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: s.lastError)
        .task { await store.checkNotificationPermission() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let cur = s.current {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.unit.format(mgdl: cur.mgdl))
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(s.isStale() ? Color.secondary : (s.range?.valueColor ?? .primary))
                            .contentTransition(.numericText(value: cur.mgdl))
                        Text(s.unit.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        TrendSymbol(trend: cur.trend)
                            .font(.title3)
                            .foregroundStyle(cur.trend.isRapid ? (s.range?.color ?? .primary) : .primary)
                        Text(cur.trend.description)
                            .font(.callout.weight(.medium))
                        if let d = s.deltaMgdl {
                            Text(s.unit.formatDelta(mgdl: d))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: d))
                        }
                    }
                    Text("\(Format.age(cur.age())) · \(cur.timestamp.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(s.isStale() ? Color.orange : Color.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(s.accessibilitySummary())

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                if let range = s.range { RangeBadge(range: range, stale: s.isStale()) }
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last \(settings.chartHours) hours").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("Chart range", selection: $settings.chartHours) {
                    Text("3h").tag(3)
                    Text("6h").tag(6)
                    Text("12h").tag(12)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                iconButton("Open in Dashboard", systemImage: "arrow.up.left.and.arrow.down.right") { showDashboard() }
            }
            GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                         hours: Double(settings.chartHours), interactive: true)
                .frame(height: 140)
                .help("Hover to see individual readings")
        }
        .card()
    }

    // MARK: Stats

    private var statsCard: some View {
        let st = s.stats(hours: 12)
        let st24 = s.stats()
        return VStack(alignment: .leading, spacing: 10) {
            if let st {
                HStack(alignment: .firstTextBaseline) {
                    Text("Time in range").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("12 h").font(.caption2).foregroundStyle(.tertiary)
                }
                TimeInRangeBar(stats: st)
            }
            HStack(alignment: .top, spacing: 12) {
                stat("In range", st.map { Format.percent($0.timeInRange) } ?? "–", dot: .green)
                stat("Below", st.map { Format.percent($0.timeBelowRange) } ?? "–", dot: .red)
                stat("Above", st.map { Format.percent($0.timeAboveRange) } ?? "–", dot: .orange)
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                stat("Average", st24.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–",
                     sub: st24.map { String(format: "%.0f h span", $0.spanHours) })
                stat("Range", st24.map { "\(s.unit.format(mgdl: $0.minMgdl))–\(s.unit.format(mgdl: $0.maxMgdl))" } ?? "–",
                     sub: "min–max")
                stat("CV", st24.map { Format.percent($0.coefficientOfVariation) } ?? "–", sub: "variability")
            }
        }
        .card()
    }

    private func stat(_ title: String, _ value: String, sub: String? = nil, dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sensor

    private func sensorCard(_ sensor: SensorInfo) -> some View {
        let remaining = sensor.daysRemaining()
        let fraction = sensor.lifetimeDays > 0 ? min(1, max(0, remaining / Double(sensor.lifetimeDays))) : 0
        let expiringSoon = remaining < 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sensor", systemImage: "sensor.tag.radiowaves.forward")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.days(remaining)) left")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(expiringSoon ? Color.orange : Color.primary)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(expiringSoon ? .orange : .accentColor)
            Text("\(sensor.serial) · expires \(sensor.expires.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .card()
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
        .padding(.vertical, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .padding(10)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                iconButton("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
                    .keyboardShortcut("r")
                iconButton("Open Dashboard (⌘D)", systemImage: "macwindow") { showDashboard() }
                    .keyboardShortcut("d")
                iconButton("Settings…", systemImage: "gearshape") { showSettings() }
                    .keyboardShortcut(",")
                iconButton("Check for Updates (v\(updater.version))", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                if s.lastError == nil {
                    Text(store.statusLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 4)
                        .help(store.statusLine)
                }
                Spacer(minLength: 4)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
            Text("Not a medical device. Confirm on your phone before treating.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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
}

// MARK: - Card style

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }
}
