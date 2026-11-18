import SwiftUI

// How an alert row looks in the Logbook, on the iPhone and the Mac (docs/AlertLog.md). Quiet on
// purpose: a small bell in the range's colour and secondary text, so the entries the user logged
// stay what the eye goes to.

extension AlertLogRow {
    /// The range the alert was about, for its colour.
    var range: GlucoseRange {
        switch kind {
        case .urgentLow, .predictedUrgentLow: return .urgentLow
        case .low, .predictedLow: return .low
        case .veryHigh, .predictedVeryHigh: return .veryHigh
        default: return .high
        }
    }

    var tint: Color { range.color }

    var systemImage: String { "bell" }

    /// "Snoozed 30 min at 10:06 · Went off 3 times, last at 10:35".
    var detail: String {
        var parts: [String] = []
        if response != nil && response != .other, let at = respondedAt {
            parts.append("\(responseText) at \(ClockLabel.time(at))")
        } else {
            parts.append(responseText)
        }
        if let repeatText { parts.append("\(repeatText), last at \(ClockLabel.time(last))") }
        return parts.joined(separator: " · ")
    }

    /// The setting that hides alert rows, shared by the iPhone and Mac Logbooks (each device keeps
    /// its own choice).
    static let showsKey = "logbookShowsAlerts"
}

/// One alert row, for lists (the iPhone Logbook).
struct AlertLogRowView: View {
    let row: AlertLogRow
    /// The Logbook search's words, picked out in the title.
    var highlight: [String] = []
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: row.systemImage)
                .imageScale(.small)
                .foregroundStyle(row.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                SearchHighlightText(row.title, terms: highlight, tint: row.tint)
                    .dsFont(.caption).foregroundStyle(.secondary)
                Text(row.detail).dsFont(.caption).foregroundStyle(.tertiary)
                if typeSize.dsLargeText { time }
            }
            Spacer(minLength: DS.Space.sm)
            if !typeSize.dsLargeText { time }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(ClockLabel.time(row.timestamp))
            .dsFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}

/// A line with the Logbook search's words picked out: bold, on a faint wash of the row's colour, so
/// "pizza" stands out in "45 g · Pizza, ham and pineapple". Plain when nothing is being searched.
enum SearchHighlight {
    static func attributed(_ text: String, terms: [String], tint: Color) -> AttributedString {
        var out = AttributedString(text)
        guard !terms.isEmpty else { return out }
        for r in LogbookSearch.highlights(in: text, terms: terms) {
            guard let range = Range(r, in: out) else { continue }
            out[range].inlinePresentationIntent = .stronglyEmphasized
            // Spelled out: on the Mac, AppKit has a background colour attribute of its own.
            out[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = tint.opacity(0.2)
        }
        return out
    }

    /// A line part way from one search to the next (`LogbookSearchMotion.spans`): what's still found
    /// stays lit, what's newly found fades in, and what's no longer found fades out, `progress` of
    /// the way through.
    static func attributed(_ text: String, from old: [String], to new: [String], tint: Color,
                           progress: Double) -> AttributedString {
        var out = AttributedString(text)
        for span in LogbookSearchMotion.spans(in: text, from: old, to: new) {
            guard let range = Range(span.range, in: out) else { continue }
            let wash = LogbookSearchMotion.wash(span.phase, progress: progress)
            if LogbookSearchMotion.isBold(span.phase) { out[range].inlinePresentationIntent = .stronglyEmphasized }
            if wash > 0 {
                out[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = tint.opacity(0.2 * wash)
            }
        }
        return out
    }
}

/// A Logbook line with the search's words picked out, which follows the typing (docs/LogbookSearch.md
/// "While you type"): as the words change, newly found letters fade into their wash and letters no
/// longer found fade out of it, while the rest of the highlight holds still. Bold switches at once,
/// so the line never reflows mid-fade. Instant under Reduce Motion. Used by the iPhone and Mac
/// Logbook rows; VoiceOver reads the plain text, as before.
struct SearchHighlightText: View {
    let text: String
    let terms: [String]
    let tint: Color
    /// The words before the latest change, which the fade starts from.
    @State private var from: [String]?
    /// Bumped on every change of words; the fade runs from the last count to this one.
    @State private var generation = 0
    @State private var faded = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, terms: [String], tint: Color) {
        self.text = text
        self.terms = terms
        self.tint = tint
    }

    var body: some View {
        SearchHighlightFrame(text: text, from: from ?? terms, to: terms, tint: tint,
                             generation: generation, faded: faded)
            .onChange(of: terms) { old, _ in
                generation += 1
                if reduceMotion {
                    from = nil
                    faded = Double(generation)
                } else {
                    from = old
                    withAnimation(.easeOut(duration: LogbookSearchMotion.highlightFade)) { faded = Double(generation) }
                }
            }
    }
}

/// Draws the line `progress` of the way through the fade. `faded` animates from the last
/// generation to this one, so the fade needs no reset frame and a change mid-fade starts clean.
private struct SearchHighlightFrame: View, Animatable {
    let text: String
    let from: [String]
    let to: [String]
    let tint: Color
    let generation: Int
    var faded: Double

    var animatableData: Double {
        get { faded }
        set { faded = newValue }
    }

    var body: some View {
        let progress = min(max(faded - Double(generation - 1), 0), 1)
        if progress >= 1 || from == to {
            Text(SearchHighlight.attributed(text, terms: to, tint: tint))
        } else {
            Text(SearchHighlight.attributed(text, from: from, to: to, tint: tint, progress: progress))
        }
    }
}

extension View {
    /// A Logbook row the latest typing left out, shrinking out before the list closes up behind it
    /// (docs/LogbookSearch.md "While you type"). The caller animates the change, and never sets it
    /// under Reduce Motion, where the row simply goes.
    func searchLeaving(_ leaving: Bool) -> some View {
        scaleEffect(leaving ? LogbookSearchMotion.leavingScale : 1, anchor: .leading)
            .opacity(leaving ? 0 : 1)
    }

    /// A Logbook row in a cascade of several leaving or coming back (`LogbookCascade`, docs/
    /// LogbookSearch.md "Deleting several entries"): it shrinks out on its own delay, or grows back
    /// in on its own delay after an Undo. Rows outside the cascade, and every row when there is
    /// none, are untouched. Callers never start a cascade under Reduce Motion, so there is nothing
    /// to tone down here.
    func logbookCascade(_ cascade: LogbookCascade?, entries: [UUID]) -> some View {
        let hidden = cascade?.hides(entries) ?? false
        let delay = cascade?.delay(entries) ?? 0
        let leaving = cascade?.direction == .leaving
        let curve: Animation = leaving ? .easeIn(duration: LogbookCascade.rowDuration)
                                       : .easeOut(duration: LogbookCascade.rowDuration)
        // Only the move the cascade is about animates: shrinking out while leaving, growing back
        // while arriving. Rows hidden ahead of arriving vanish at once, before they're seen.
        let moves = cascade != nil && hidden == leaving
        return scaleEffect(hidden ? LogbookCascade.scale : 1, anchor: .leading)
            .opacity(hidden ? 0 : 1)
            .animation(moves ? curve.delay(delay) : nil, value: hidden)
    }
}

/// How the Logbook's quick filter chips look, on the iPhone and the Mac.
extension LogbookFilter {
    var symbol: String {
        switch self {
        case .meals: return "fork.knife"
        case .insulin: return "syringe"
        case .lows: return "arrow.down.circle"
        case .highs: return "arrow.up.circle"
        case .overnight: return "moon"
        case .weekdays: return "briefcase"
        case .weekends: return "sun.max"
        case .thisWeek, .lastWeek: return "calendar"
        case .bestStreak: return "flame"
        case .bestDay: return "rosette"
        case .toughestDay: return "mountain.2"
        case .tagged: return "tag"
        case .hourOfDay: return "clock"
        case .whileAway: return "clock.arrow.circlepath"
        case .aroundAlert: return "bell.badge"
        case .aroundGap: return "line.diagonal"
        case .notes: return "text.alignleft"
        case .sites: return "bandage"
        case .moments: return "tag"
        case .alerts: return "bell"
        }
    }

    var tint: Color {
        switch self {
        case .meals: return Palette.food
        case .insulin: return Palette.insulin
        case .lows: return Tone.critical.color
        // The text shade: the chip label is amber on a faint wash until picked.
        case .highs: return GlucoseRange.high.textTint
        case .overnight, .weekdays, .weekends, .thisWeek, .lastWeek, .bestStreak, .bestDay, .toughestDay, .tagged, .hourOfDay, .whileAway, .aroundAlert, .aroundGap:
            return Palette.brand
        case .notes: return Palette.brand
        case .sites: return Palette.site
        case .moments: return Palette.context
        case .alerts: return .secondary
        }
    }
}
