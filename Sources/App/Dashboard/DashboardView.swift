import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The pop-out dashboard: a regular, resizable window with the full picture. Opened from the
/// menu bar popover. Reads only what `GlucoseStore` already has.
struct DashboardView: View {
    static let windowID = "dashboard"

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @StateObject private var windowState = DashboardWindowState()

    @State private var logSheet: LogSheetTarget?
    /// End of the period on screen. Nil follows the latest readings.
    @State private var periodEnd: Date?
    @State private var showShortcuts = false
    /// Notices closed this session. Keyed by content, so a new problem shows again.
    @State private var dismissedNotices: Set<String> = []
    @State private var toast: DashboardToast?
    /// Page padding for the detail column's width, so the notices and the table pages line up
    /// with the scrolling pages. Stored as the padding, not the width, so resizing the window
    /// only redraws when the padding actually changes.
    @State private var detailPadding: CGFloat = DashboardMetrics.padding(for: 900)

    @AppStorage("dashboardRange") private var range: DashboardRange = .h24
    @AppStorage("dashboardSection") private var section: DashboardSection = .overview
    @AppStorage("dashboardKeepOnTop") private var keepOnTop = false

    var body: some View {
        let data = DashboardData(archive: store.archive, range: range, snapshot: store.snapshot, endingAt: periodEnd)
        NavigationSplitView {
            sidebar(data)
        } detail: {
            // Notices sit in the layout above the section, not in a safe-area inset, so they always
            // get their full height and push the content down instead of hiding under the toolbar.
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    DashboardNoticeStack(notices: notices(data, now: ctx.date), dismissed: $dismissedNotices)
                }
                detail(data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.dashboardPadding, detailPadding)
            // Roomier cards and gutters when the window has the whole screen.
            .environment(\.dsDensity, windowState.isFullScreen ? .comfortable : .regular)
            .background(GeometryReader { geo in
                Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
            })
            .onPreferenceChange(WidthPreferenceKey.self) { width in
                let padding = DashboardMetrics.padding(for: DashboardMetrics.stepped(width))
                if width > 0 && padding != detailPadding { detailPadding = padding }
            }
            .overlay(alignment: .bottom) { toastView }
            .sheet(isPresented: $showShortcuts) { ShortcutsHelp() }
            .background(alignment: .top) {
                AmbientGlow(tint: store.snapshot.displayTint(), intensity: 0.35)
                    .frame(height: 320)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .navigationTitle(section.title)
            .navigationSubtitle(section.usesRange ? data.periodTitle : "All stored history")
        }
        .toolbar { toolbarContent(data) }
        .background(shortcutButtons)
        .sheet(item: $logSheet) { target in
            LogSheet(target: target)
                .environmentObject(logbook)
                .environmentObject(settings)
        }
        .onChange(of: logbook.logSheetRequested) { _, requested in
            if requested { openRequestedLogSheet() }
        }
        .background(WindowConfigurator(floating: keepOnTop && !windowState.isFullScreen, state: windowState))
        // Small enough for half a laptop screen; below this the sidebar, toolbar and cards collide.
        .frame(minWidth: 760, idealWidth: 1180, minHeight: 540, idealHeight: 800)
        // A menu bar app has no Dock icon, so a window it opens can get lost behind others and
        // can't be reached with ⌘-Tab. Behave like a normal app while the dashboard is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            if logbook.logSheetRequested { openRequestedLogSheet() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Sidebar

    private func sidebar(_ data: DashboardData) -> some View {
        List(selection: Binding<DashboardSection?>(get: { section }, set: { if let s = $0 { select(s) } })) {
            ForEach(DashboardSection.Group.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { s in
                        Label(s.title, systemImage: s.systemImage)
                            .badge(badge(for: s, data: data))
                            .tag(s)
                            .help("\(s.subtitle) (⌘\(s.shortcutDigit))")
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                CurrentReadingTile(snapshot: store.snapshot, recent: recentReadings(now: ctx.date), now: ctx.date)
            }
            .padding(DS.Space.sm + 2)
        }
    }

    private func badge(for s: DashboardSection, data: DashboardData) -> Int {
        switch s {
        case .logbook: return logbook.entries.filter { data.domain.contains($0.timestamp) }.count
        default: return 0
        }
    }

    /// The last three hours, for the sidebar sparkline.
    private func recentReadings(now: Date) -> [GlucoseReading] {
        GlucoseAnalytics.slice(store.archive, from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(60))
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ data: DashboardData) -> some View {
        sectionContent(data)
            .id(section)
            .transition(.opacity)
    }

    @ViewBuilder
    private func sectionContent(_ data: DashboardData) -> some View {
        switch section {
        case .logbook:
            LogbookSection(data: data) { logSheet = $0 }
        case .insights:
            InsightsSection(readings: store.archive, unit: data.unit, lowMgdl: data.lowMgdl, highMgdl: data.highMgdl) {
                logSheet = .new
            }
        default:
            if store.archive.isEmpty {
                if store.isRefreshing && settings.hasCredentials {
                    VStack(spacing: DS.Space.md) {
                        ProgressView().controlSize(.large)
                        Text("Fetching your readings…").dsFont(.sectionTitle)
                        Text("This usually takes a few seconds.").dsFont(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                } else if settings.hasCredentials {
                    EmptyStateView(systemImage: "drop", title: "No Readings Yet",
                                   message: "Readings appear here as soon as GlucOS fetches them from LibreLinkUp.",
                                   actionTitle: "Refresh Now", action: { Task { await store.refresh() } })
                        .frame(maxHeight: .infinity)
                } else {
                    EmptyStateView(systemImage: "person.crop.circle.badge.plus", title: "Connect LibreLinkUp",
                                   message: "Sign in with your LibreLinkUp follower account in Settings to start.",
                                   tone: .brand, actionTitle: "Open Settings…", action: { openSettings() })
                        .frame(maxHeight: .infinity)
                }
            } else {
                switch section {
                case .overview:
                    OverviewSection(data: data, snapshot: store.snapshot,
                                    events: logbook.chartEvents(in: data.domain),
                                    comparison: comparisonReadings(data))
                case .patterns:
                    PatternsSection(data: data)
                case .days:
                    DaysSection(data: data) { showDay($0) }
                case .readings:
                    ReadingsSection(data: data) { showMoment($0) }
                case .report:
                    ReportSection(model: reportModel(data), onExport: { exportPDF(data) })
                case .logbook, .insights:
                    EmptyView()
                }
            }
        }
    }

    /// Readings from the period just before the one on screen, for comparison.
    private func comparisonReadings(_ data: DashboardData) -> [GlucoseReading] {
        let start = data.domain.lowerBound
        return GlucoseAnalytics.slice(store.archive, from: start.addingTimeInterval(-range.duration), to: start)
    }

    private func reportModel(_ data: DashboardData) -> ReportModel {
        ReportModel(data: data, archive: store.archive, doses: logbook.doses, meals: logbook.meals)
    }

    // MARK: Notices

    /// Everything worth flagging right now, from the same checks as the menu bar popover.
    private func notices(_ data: DashboardData, now: Date) -> [DashboardNotice] {
        let snapshot = store.snapshot
        var out: [DashboardNotice] = []
        let refresh = BannerAction(title: store.isRefreshing ? "Checking…" : "Refresh", systemImage: "arrow.clockwise",
                                   isBusy: store.isRefreshing) { Task { await store.refresh() } }

        if !settings.hasCredentials {
            out.append(DashboardNotice(
                id: "signin", severity: .info, systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Sign in to LibreLinkUp",
                message: "GlucOS needs your LibreLinkUp follower login to fetch new readings.",
                action: BannerAction(title: "Open Settings…", systemImage: "gearshape") { openSettings() }))
        }
        if let cur = snapshot.current, snapshot.isStale(at: now) {
            out.append(DashboardNotice(
                id: "stale", severity: .warning, systemImage: "clock.badge.exclamationmark.fill",
                title: "No new reading for \(PopoverFormat.age(cur.age(at: now)))",
                message: "The latest reading is from \(cur.timestamp.formatted(date: .omitted, time: .shortened)). Don't treat from these numbers; check your sensor and phone.",
                action: refresh))
        }
        if let err = snapshot.lastError {
            out.append(DashboardNotice(
                id: "error:\(err)", severity: .warning, systemImage: "wifi.exclamationmark",
                title: "Couldn't reach LibreLinkUp",
                message: err,
                action: BannerAction(title: store.isRefreshing ? "Retrying…" : "Retry", systemImage: "arrow.clockwise",
                                     isBusy: store.isRefreshing) { Task { await store.refresh() } },
                secondaryAction: BannerAction(title: "Copy Error", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(err, forType: .string)
                },
                dismissible: true))
        }
        if store.notificationsBlocked {
            out.append(DashboardNotice(
                id: "notifications", severity: .critical, systemImage: "bell.slash.fill",
                title: "Glucose alerts can't reach you",
                message: "Notifications are off for GlucOS in System Settings, so low and high alerts won't appear.",
                action: BannerAction(title: "Turn On…", systemImage: "bell.badge") {
                    NSWorkspace.shared.open(AlertManager.notificationSettingsURL)
                }))
        }
        if let sensor = snapshot.sensor {
            let remaining = sensor.daysRemaining(at: now)
            if remaining <= 0 {
                out.append(DashboardNotice(
                    id: "sensor-ended", severity: .critical, systemImage: "sensor.tag.radiowaves.forward.fill",
                    title: "Sensor has ended",
                    message: "Readings stop until you start a new sensor."))
            } else if remaining < 1 {
                out.append(DashboardNotice(
                    id: "sensor-ending:\(sensor.serial):\(remaining < 0.25 ? "soon" : "today")", severity: remaining < 0.25 ? .warning : .info,
                    systemImage: "sensor.tag.radiowaves.forward.fill",
                    title: "Sensor ends in \(Format.days(remaining))",
                    message: "Have a replacement ready so you don't lose readings.",
                    dismissible: true))
            }
        }
        if !data.isLive && section.usesRange {
            out.append(DashboardNotice(
                id: "past", severity: .info, systemImage: "clock.arrow.circlepath",
                title: "Viewing earlier data",
                message: data.periodTitle,
                action: BannerAction(title: "Back to Now", systemImage: "forward.end.fill") { goToNow() }))
        }
        return out
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            StatusBanner(severity: toast.severity, title: toast.title, message: toast.message,
                         onDismiss: { DS.animate(.standard, reduceMotion: reduceMotion) { self.toast = nil } })
                .frame(maxWidth: 520)
                .padding(DS.Space.xl)
                .transition(DS.Transition.toast(reduceMotion: reduceMotion))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(8))
                    DS.animate(.standard, reduceMotion: reduceMotion) { if self.toast?.id == toast.id { self.toast = nil } }
                }
        }
    }

    private func showToast(_ t: DashboardToast) {
        DS.animate(.standard, reduceMotion: reduceMotion) { toast = t }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ data: DashboardData) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { step(-1, data) } label: {
                    Label("Earlier", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!section.usesRange || !data.canGoEarlier)
                .help("Show the previous \(range.periodNoun) (⌘[)")

                Button { step(1, data) } label: {
                    Label("Later", systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!section.usesRange || data.isLive)
                .help("Show the next \(range.periodNoun) (⌘])")
            }
            .controlGroupStyle(.navigation)

            if !data.isLive && section.usesRange {
                Button("Now") { goToNow() }
                    .keyboardShortcut("j", modifiers: .command)
                    .help("Jump back to the latest readings (⌘J)")
            }
        }

        ToolbarItem(placement: .principal) {
            RangePicker(range: rangeBinding)
                .disabled(!section.usesRange)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { logSheet = .new } label: {
                Label("Log Insulin or Food…", systemImage: "plus")
            }
            .keyboardShortcut("l")
            .help("Log insulin, food or a site change (⌘L)")

            Button { Task { await store.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolEffect(.pulse, isActive: store.isRefreshing)
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")

            Menu {
                Button("Readings as CSV…") { exportCSV(data.readings) }
                    .disabled(data.readings.isEmpty)
                Button("Report as PDF…") { exportPDF(data) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(data.readings.isEmpty)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the readings or a report for this period")

            Button { windowState.toggleFullScreen() } label: {
                Label(windowState.isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                      systemImage: windowState.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help(windowState.isFullScreen ? "Exit full screen (⌃⌘F)" : "Enter full screen (⌃⌘F)")

            // Less-used window options, out of the way so the toolbar doesn't crowd.
            Menu {
                Toggle("Keep on Top", isOn: $keepOnTop)
                    .disabled(windowState.isFullScreen)
                Divider()
                Button("Keyboard Shortcuts…", action: showShortcutsHelp)
            } label: {
                Label("More", systemImage: keepOnTop ? "pin.circle.fill" : "ellipsis.circle")
            }
            .help(keepOnTop ? "Window options. Keep on Top is on." : "Window options and keyboard shortcuts (⌘/)")
        }
    }

    /// Not over the log sheet: two sheets at once would stack.
    private func showShortcutsHelp() {
        if logSheet == nil { showShortcuts = true }
    }

    private var rangeBinding: Binding<DashboardRange> {
        Binding(get: { range }, set: { new in
            DS.animate(.standard, reduceMotion: reduceMotion) { range = new }
        })
    }

    /// ⌘1–⌘7 pick a section, ⌃1–⌃8 a range, ⌘/ lists the shortcuts. Invisible buttons, so the
    /// shortcuts work from anywhere in the window.
    private var shortcutButtons: some View {
        ZStack {
            ForEach(DashboardSection.allCases) { s in
                Button(s.title) { select(s) }
                    .keyboardShortcut(KeyEquivalent(Character(String(s.shortcutDigit))), modifiers: .command)
            }
            ForEach(Array(DashboardRange.allCases.enumerated()), id: \.element) { i, r in
                Button(r.title) { rangeBinding.wrappedValue = r }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .control)
            }
            Button("Keyboard Shortcuts", action: showShortcutsHelp)
                .keyboardShortcut("/", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Navigation

    private func select(_ s: DashboardSection) {
        DS.animate(.standard, reduceMotion: reduceMotion) { section = s }
    }

    /// Moves a whole period earlier or later.
    private func step(_ direction: Int, _ data: DashboardData) {
        let newEnd = data.domain.upperBound.addingTimeInterval(Double(direction) * range.duration)
        setPeriodEnd(newEnd)
    }

    private func setPeriodEnd(_ end: Date?) {
        DS.animate(.standard, reduceMotion: reduceMotion) {
            if let end, end < DashboardData.liveEnd(archive: store.archive) {
                periodEnd = end
            } else {
                periodEnd = nil
            }
        }
    }

    private func goToNow() { setPeriodEnd(nil) }

    /// Opens one whole day on the Overview chart.
    private func showDay(_ day: Date) {
        range = .h24
        setPeriodEnd(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
        select(.overview)
    }

    /// Opens the three hours around one reading on the Overview chart.
    private func showMoment(_ date: Date) {
        range = .h3
        setPeriodEnd(date.addingTimeInterval(DashboardRange.h3.duration / 2))
        select(.overview)
    }

    /// The menu bar popover asked for the log sheet.
    private func openRequestedLogSheet() {
        logbook.logSheetRequested = false
        if logSheet == nil { logSheet = .new }
    }

    // MARK: Export

    private func exportCSV(_ readings: [GlucoseReading]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "GlucOS \(range.shortLabel) \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GlucoseAnalytics.csv(readings).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showExportFailure(url)
        }
    }

    private func exportPDF(_ data: DashboardData) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "GlucOS Report \(data.domain.upperBound.formatted(.iso8601.year().month().day())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !ReportExporter.writePDF(model: reportModel(data), to: url) {
            showExportFailure(url)
        }
    }

    private func showExportFailure(_ url: URL) {
        showToast(DashboardToast(
            severity: .critical, title: "Couldn't save \(url.lastPathComponent)",
            message: "Check that the folder exists and you can save there, then try again."))
    }
}

// MARK: - Sections

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, patterns, days, readings, logbook, insights, report
    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case glucose, logs, share
        var id: String { rawValue }

        var title: String {
            switch self {
            case .glucose: return "Glucose"
            case .logs: return "Logs"
            case .share: return "Share"
            }
        }

        var sections: [DashboardSection] {
            DashboardSection.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .overview, .patterns, .days, .readings: return .glucose
        case .logbook, .insights: return .logs
        case .report: return .share
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .patterns: return "Daily Patterns"
        case .days: return "Days"
        case .readings: return "Readings"
        case .logbook: return "Logbook"
        case .insights: return "Insights"
        case .report: return "Report"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Chart and headline numbers"
        case .patterns: return "Glucose by time of day and weekday"
        case .days: return "Each day at a glance"
        case .readings: return "Every reading"
        case .logbook: return "Logged insulin, food and site changes"
        case .insights: return "What your logs show"
        case .report: return "A printable summary to share"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .patterns: return "clock"
        case .days: return "calendar"
        case .readings: return "list.bullet"
        case .logbook: return "book"
        case .insights: return "lightbulb"
        case .report: return "doc.richtext"
        }
    }

    /// Insights always uses all stored history; everything else follows the range picker.
    var usesRange: Bool { self != .insights }

    var shortcutDigit: Int { (DashboardSection.allCases.firstIndex(of: self) ?? 0) + 1 }
}

// MARK: - Range picker

/// Segmented when there's room in the toolbar, a pop-up menu when the window is narrow.
private struct RangePicker: View {
    @Binding var range: DashboardRange

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Range", selection: $range) {
                ForEach(DashboardRange.allCases) { r in Text(r.shortLabel).tag(r) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Range", selection: $range) {
                ForEach(DashboardRange.allCases) { r in Text(r.title).tag(r) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .labelsHidden()
        .help("Time range (⌃1–⌃8)")
    }
}

private struct ShortcutsHelp: View {
    private let rows: [(String, String)] = [
        ("⌘1 – ⌘7", "Switch section"),
        ("⌃1 – ⌃8", "Pick a time range"),
        ("⌘[  ⌘]", "Previous or next period"),
        ("⌘J", "Back to now"),
        ("⌘=  ⌘−  ⌘0", "Zoom chart in, out, reset"),
        ("⌥←  ⌥→", "Pan the zoomed chart"),
        ("Drag on chart", "Select a stretch to see its numbers"),
        ("Esc", "Clear the chart selection"),
        ("⌘L", "Log insulin or food"),
        ("⌘R", "Refresh"),
        ("⌃⌘F", "Enter or exit full screen"),
        ("⇧⌘P", "Export report as PDF"),
        ("⌘/", "Show this list"),
    ]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Keyboard Shortcuts")
                .dsFont(.title)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(rows[i].1).dsFont(.body)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.ds(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xxl)
        .frame(minWidth: 380)
    }
}

// MARK: - Sidebar reading

/// Current reading in the sidebar, so it stays visible whichever section is open.
private struct CurrentReadingTile: View {
    let snapshot: GlucoseSnapshot
    let recent: [GlucoseReading]
    let now: Date

    var body: some View {
        if let cur = snapshot.current {
            let stale = snapshot.isStale(at: now)
            let tint = snapshot.displayTint(at: now)
            VStack(alignment: .leading, spacing: DS.Space.sm - 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(snapshot.unit.format(mgdl: cur.mgdl))
                        .dsFont(.metricValueLarge)
                        .foregroundStyle(stale ? Palette.stale : (snapshot.range?.valueColor ?? .primary))
                        .contentTransition(.numericText(value: cur.mgdl))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    // An old trend arrow could be read as what's happening now.
                    TrendSymbol(trend: stale ? .unknown : cur.trend)
                        .font(.title3)
                        .foregroundStyle(stale ? Palette.stale : tint)
                    Spacer(minLength: 0)
                    if let range = snapshot.range { RangeBadge(range: range, stale: stale) }
                }
                HStack(spacing: DS.Space.xs) {
                    Text(snapshot.unit.label)
                    if let d = snapshot.deltaMgdl, !stale { Text("· \(snapshot.unit.formatDelta(mgdl: d))").monospacedDigit() }
                    Spacer(minLength: 0)
                    Text(Format.age(cur.age(at: now)))
                        .foregroundStyle(stale ? Tone.warning.textColor : Color.secondary)
                }
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if recent.count > 2 {
                    GlucoseSparkline(readings: recent, domain: now.addingTimeInterval(-3 * 3600)...now,
                                     lowMgdl: snapshot.lowMgdl, highMgdl: snapshot.highMgdl, stale: stale)
                        .frame(height: 34)
                }
                if stale {
                    Label("No new reading. Check your sensor.", systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.semibold).dsFont(.caption)
                        .foregroundStyle(Tone.warning.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dsCard(.hero(snapshot.displayTone(at: now)), padding: DS.Space.md, radius: DS.Radius.card - 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.accessibilitySummary(at: now))
        }
    }
}

// MARK: - Data for the selected period

/// Everything the sections need for one period, computed once per render.
struct DashboardData {
    let range: DashboardRange
    let domain: ClosedRange<Date>
    let readings: [GlucoseReading]      // oldest → newest, within `domain`
    let stats: GlucoseStats?
    let breakdown: RangeBreakdown?
    let coverage: Double
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// Oldest reading GlucOS has stored at all.
    let archiveStart: Date?
    /// True when the period ends at the latest readings rather than somewhere in the past.
    let isLive: Bool

    init(archive: [GlucoseReading], range: DashboardRange, snapshot: GlucoseSnapshot,
         endingAt anchor: Date? = nil, now: Date = Date()) {
        let live = Self.liveEnd(archive: archive, now: now)
        let end = anchor.map { min($0, live) } ?? live
        let start = end.addingTimeInterval(-range.duration)
        self.range = range
        isLive = end >= live
        domain = start...end
        readings = GlucoseAnalytics.slice(archive, from: start, to: end)
        unit = snapshot.unit
        lowMgdl = snapshot.lowMgdl
        highMgdl = snapshot.highMgdl
        stats = GlucoseStats.compute(readings, low: lowMgdl, high: highMgdl)
        breakdown = RangeBreakdown.compute(readings, low: lowMgdl, high: highMgdl)
        coverage = GlucoseAnalytics.coverage(readings, from: start, to: end)
        archiveStart = archive.first?.timestamp
    }

    /// The end of a live period: the next 5-minute boundary, so the axis doesn't creep every few
    /// seconds.
    static func liveEnd(archive: [GlucoseReading], now: Date = Date()) -> Date {
        let step: TimeInterval = 5 * 60
        let latest = max(now, archive.last?.timestamp ?? now)
        return Date(timeIntervalSince1970: (latest.timeIntervalSince1970 / step).rounded(.up) * step)
    }

    /// There are stored readings before this period.
    var canGoEarlier: Bool {
        guard let archiveStart else { return false }
        return archiveStart < domain.lowerBound
    }

    /// "Last 24 hours", or the dates when looking at the past.
    var periodTitle: String {
        if isLive { return range.title }
        let style: Date.FormatStyle = .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        let sameDay = Calendar.current.isDate(domain.lowerBound, inSameDayAs: domain.upperBound.addingTimeInterval(-1))
        if sameDay {
            return "\(domain.lowerBound.formatted(style)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))"
        }
        return "\(domain.lowerBound.formatted(style)) – \(domain.upperBound.formatted(style))"
    }

    /// True when GlucOS hasn't been collecting for the whole range yet.
    var historyIsShort: Bool {
        guard let archiveStart else { return true }
        return archiveStart > domain.lowerBound.addingTimeInterval(3600)
    }

    var historyNote: String? {
        guard historyIsShort, let archiveStart else { return nil }
        return "History starts \(archiveStart.formatted(date: .abbreviated, time: .shortened)). LibreLinkUp only provides the last 12 hours, so GlucOS builds up longer history while it runs."
    }
}

extension DashboardRange {
    /// "day", "3 days", "6 hours": what one step of ⌘[ moves by.
    var periodNoun: String {
        switch self {
        case .h3: return "3 hours"
        case .h6: return "6 hours"
        case .h12: return "12 hours"
        case .h24: return "day"
        case .d3: return "3 days"
        case .d7: return "week"
        case .d14: return "2 weeks"
        case .d30: return "30 days"
        }
    }
}
