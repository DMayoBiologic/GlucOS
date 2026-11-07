import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @Environment(\.openSettings) private var openSettings

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if s.current != nil {
                GlucoseChart(readings: s.history, unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, hours: 12)
                    .frame(height: 140)
                statsGrid
            } else {
                emptyState
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let cur = s.current {
                Text(s.unit.format(mgdl: cur.mgdl))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rangeColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cur.trend.arrow).font(.title2.weight(.bold))
                        if let d = s.deltaMgdl {
                            Text(s.unit.formatDelta(mgdl: d)).font(.headline).monospacedDigit()
                        }
                    }
                    Text(cur.trend.description).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if s.isStale() { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Text("\(Format.age(cur.age())) · \(s.unit.label)")
                    }
                    .font(.caption)
                    .foregroundStyle(s.isStale() ? Color.orange : Color.secondary)
                }
            } else {
                Text("––").font(.system(size: 44, weight: .semibold, design: .rounded))
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
        }
    }

    private var rangeColor: Color {
        switch s.range {
        case .urgentLow, .low: return .red
        case .high: return .orange
        case .veryHigh: return .red
        case .inRange, .none: return .primary
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        let st = s.stats(hours: 12)
        let st24 = s.stats()
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                stat("In range", st.map { Format.percent($0.timeInRange) } ?? "–", sub: "12 h")
                stat("Below", st.map { Format.percent($0.timeBelowRange) } ?? "–", sub: "12 h")
                stat("Above", st.map { Format.percent($0.timeAboveRange) } ?? "–", sub: "12 h")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                stat("Average", st24.map { s.unit.format(mgdl: $0.meanMgdl) } ?? "–", sub: "span \(st24.map { String(format: "%.0f h", $0.spanHours) } ?? "–")")
                stat("Range", st24.map { "\(s.unit.format(mgdl: $0.minMgdl))–\(s.unit.format(mgdl: $0.maxMgdl))" } ?? "–", sub: "min–max")
                stat("CV", st24.map { Format.percent($0.coefficientOfVariation) } ?? "–", sub: "variability")
            }
            if let sensor = s.sensor {
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    stat("Sensor", Format.days(sensor.daysRemaining()), sub: "remaining")
                        .gridCellColumns(2)
                    stat("Serial", sensor.serial, sub: "activated \(sensor.activated.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.hasCredentials ? "Waiting for data…" : "Not connected")
                .font(.headline)
            Text(settings.hasCredentials
                 ? "Fetching from LibreLinkUp. If this persists, check the error below."
                 : "Open Settings and enter your LibreLinkUp follower account.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = s.lastError {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else {
                Text(store.statusLine).font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Button { Task { await store.refresh(userInitiated: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing)
                Button { openSettings() } label: { Label("Settings…", systemImage: "gear") }
                Button { updater.checkForUpdates() } label: { Label("Updates", systemImage: "arrow.down.circle") }
                    .disabled(!updater.canCheck)
                    .help("Check for updates (v\(updater.version))")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
            Text("Not a medical device — confirm on your phone before treating.")
                .font(.caption2).foregroundStyle(.quaternary)
        }
    }
}
