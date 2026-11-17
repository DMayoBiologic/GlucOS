import SwiftUI

/// Under the low and high limits in Settings (iPhone and Mac, round 66): how often each would have
/// alerted over the last 7 days of stored readings, "Last 7 days: this would have alerted 3 times
/// (was 5)", with the same rules, repeat timer and snoozes as the real alerts (`AlertCountPreview`).
/// "Was" is the count for the limits as they were when the editor opened. The figure rolls to its
/// new value (`RollingFigure`, numeric text) as a limit steps; instant under Reduce Motion. The
/// replay runs off the main thread: the readings are gathered once per new reading, and only the
/// count is replayed as a limit changes. Hidden until there are 6 hours of readings, and while
/// alerts are off. VoiceOver hears one line per side, with the change in words.
struct AlertCountPreviewLines: View {
    let readings: [GlucoseReading]
    let records: [AlertRecord]
    let prefs: AlertPreferences
    let lowMgdl: Double
    let highMgdl: Double

    @State private var preview: AlertCountPreview?
    /// The limits when the editor appeared: what "was" counts against.
    @State private var startLimits: Limits?
    @State private var was: AlertCountPreview.Counts?
    @State private var now: AlertCountPreview.Counts?
    /// Bumped each time the window is gathered again, so the count replays for it.
    @State private var generation = 0

    private struct Limits: Equatable {
        let low: Double
        let high: Double
    }

    /// New readings or new snooze taps gather the window again; a new limit never does.
    private struct SourceKey: Equatable {
        let count: Int
        let newest: Date?
        let taps: Int
    }

    private struct CountKey: Equatable {
        let generation: Int
        let limits: Limits
        let prefs: AlertPreferences
    }

    private var sourceKey: SourceKey {
        SourceKey(count: readings.count, newest: readings.last?.timestamp,
                  taps: records.filter { $0.respondedAt != nil }.count)
    }

    private var limits: Limits { Limits(low: lowMgdl, high: highMgdl) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if prefs.enabled, let preview, let now {
                line(.low, days: preview.days, count: now.low, was: was?.low)
                line(.high, days: preview.days, count: now.high, was: was?.high)
            }
        }
        .onAppear { if startLimits == nil { startLimits = limits } }
        .task(id: sourceKey) {
            let r = readings, a = records
            preview = await Task.detached(priority: .userInitiated) { AlertCountPreview.make(readings: r, records: a) }.value
            if let preview {
                let start = startLimits ?? limits, p = prefs
                was = await Task.detached(priority: .userInitiated) {
                    preview.counts(lowMgdl: start.low, highMgdl: start.high, prefs: p)
                }.value
            }
            generation += 1
        }
        .task(id: CountKey(generation: generation, limits: limits, prefs: prefs)) {
            guard let preview else { now = nil; return }
            let l = limits, p = prefs
            let counts = await Task.detached(priority: .userInitiated) {
                preview.counts(lowMgdl: l.low, highMgdl: l.high, prefs: p)
            }.value
            guard !Task.isCancelled else { return }
            now = counts
        }
    }

    private func line(_ side: AlertCountLine.Side, days: Int, count: Int, was: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Capsule()
                .fill((side == .low ? GlucoseRange.low.tint : GlucoseRange.high.tint).gradient)
                .frame(width: 4, height: 10)
            RollingFigure(Double(count)) { shown in
                AlertCountLine.text(days: days, count: Int(shown.rounded()), was: was)
            }
            .dsFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AlertCountLine.spoken(side, days: days, count: count, was: was))
    }
}
