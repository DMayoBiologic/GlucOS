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

    private struct CountKey: Equatable {
        let generation: Int
        let limits: Limits
        let prefs: AlertPreferences
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
        .task(id: AlertPreviewSourceKey(readings: readings, records: records)) {
            let r = readings, a = records
            let gathered = await Task.detached(priority: .userInitiated) {
                AlertCountPreview.make(readings: r, records: a)
            }.value
            // A newer gather replaced this one: leave its result alone.
            guard !Task.isCancelled else { return }
            preview = gathered
            generation += 1
        }
        .task(id: CountKey(generation: generation, limits: limits, prefs: prefs)) {
            guard let preview else { now = nil; was = nil; return }
            let l = limits, start = startLimits ?? limits, p = prefs
            // Both sides with the same switches, so turning one off never reads as a change of limit.
            let counts = await Task.detached(priority: .userInitiated) {
                (now: preview.counts(lowMgdl: l.low, highMgdl: l.high, prefs: p),
                 was: start == l ? nil : preview.counts(lowMgdl: start.low, highMgdl: start.high, prefs: p))
            }.value
            guard !Task.isCancelled else { return }
            now = counts.now
            was = counts.was ?? counts.now
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

/// Under "Repeat no more than every" in Settings › Alerts (iPhone and Mac, round 98): how many
/// low, high, very high and rapid-change alerts the last 7 days of readings would have sent at the
/// repeat as set, "Last 7 days: this would have sent 12 alerts (was 20)". The same replay as the
/// range lines (`AlertCountPreview.repeatCount`), with the range, switches and snooze taps as
/// they are. "Was" is the count for the repeat as it was when Settings opened. Urgent lows keep
/// their fixed 5-minute repeat and are left out, as the section's footer says. The figure rolls
/// (`RollingFigure`), instant under Reduce Motion; hidden until 6 hours of readings and while
/// alerts are off. VoiceOver hears one line with the change in words.
struct AlertRepeatPreviewLine: View {
    let readings: [GlucoseReading]
    let records: [AlertRecord]
    let prefs: AlertPreferences
    let lowMgdl: Double
    let highMgdl: Double

    @State private var preview: AlertCountPreview?
    /// The repeat when the line appeared: what "was" counts against.
    @State private var startMinutes: Int?
    @State private var shown: (now: Int, was: Int?)?
    @State private var generation = 0

    private struct CountKey: Equatable {
        let generation: Int
        let low: Double
        let high: Double
        let prefs: AlertPreferences
    }

    var body: some View {
        Group {
            if prefs.enabled, let preview, let shown {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.badge")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    RollingFigure(Double(shown.now)) { figure in
                        AlertRepeatLine.text(days: preview.days, count: Int(figure.rounded()), was: shown.was)
                    }
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AlertRepeatLine.spoken(days: preview.days, count: shown.now, was: shown.was))
            }
        }
        .onAppear { if startMinutes == nil { startMinutes = prefs.cooldownMinutes } }
        .task(id: AlertPreviewSourceKey(readings: readings, records: records)) {
            let r = readings, a = records
            let gathered = await Task.detached(priority: .userInitiated) {
                AlertCountPreview.make(readings: r, records: a)
            }.value
            guard !Task.isCancelled else { return }
            preview = gathered
            generation += 1
        }
        .task(id: CountKey(generation: generation, low: lowMgdl, high: highMgdl, prefs: prefs)) {
            guard let preview else { shown = nil; return }
            let l = lowMgdl, h = highMgdl, p = prefs
            var before = p
            before.cooldownMinutes = startMinutes ?? p.cooldownMinutes
            let changed = before.cooldownMinutes != p.cooldownMinutes
            let counts = await Task.detached(priority: .userInitiated) {
                (now: preview.repeatCount(lowMgdl: l, highMgdl: h, prefs: p),
                 was: changed ? preview.repeatCount(lowMgdl: l, highMgdl: h, prefs: before) : nil)
            }.value
            guard !Task.isCancelled else { return }
            shown = (counts.now, counts.was ?? counts.now)
        }
    }
}

/// New readings or new snooze taps gather a preview's window again; a new setting never does.
struct AlertPreviewSourceKey: Equatable {
    let count: Int
    let newest: Date?
    /// Every answered tap's time and length, so an answer replaced in place counts as new.
    let taps: Int

    init(readings: [GlucoseReading], records: [AlertRecord]) {
        count = readings.count
        newest = readings.last?.timestamp
        taps = records.reduce(into: Hasher()) { h, r in
            guard let at = r.respondedAt else { return }
            h.combine(r.id); h.combine(at); h.combine(r.snoozeMinutes); h.combine(r.response)
        }.finalize()
    }
}
