import Messages
import SwiftUI

struct MessagesRootView: View {
    @EnvironmentObject var model: MessagesModel

    var body: some View {
        Group {
            if model.style == .transcript {
                LiveBubbleView()
            } else if model.token != nil {
                // A live bubble was tapped: the same card, bigger, with a way to follow.
                ScrollView { SelectedShareView().padding(DS.Space.lg) }
            } else {
                ScrollView { ComposerView().padding(DS.Space.lg) }
            }
        }
        .modifier(PhoneTextScale())
    }
}

// MARK: - The drawer: send your glucose

struct ComposerView: View {
    @EnvironmentObject var model: MessagesModel
    // Shared with the app's New Share Link screen.
    @AppStorage("shareLabel", store: SharedStore.defaults) private var label = ""
    @AppStorage("shareDuration", store: SharedStore.defaults) private var duration: ShareDuration = .eightHours
    @FocusState private var nameFocused: Bool

    /// The lengths that make sense from a chat. A week or longer is for the app.
    private static let durations: [ShareDuration] = [.hour, .eightHours, .day, .untilStopped]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if !model.relay.isConfigured {
                Eyebrow(title: "Share your glucose", systemImage: "dot.radiowaves.left.and.right")
                Text("Sharing needs GlucOS's push relay, which keeps the reading live after you send it. Open GlucOS and sign in with the LibreLinkUp account your relay uses, or set it up in Settings. To follow someone, open the link they sent.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                Button("Open GlucOS") { model.openApp(URL(string: "glucos://open")) }
                    .buttonStyle(.ds(.primary, size: .large))
            } else {
                HStack(spacing: DS.Space.sm) {
                    Eyebrow(title: "Share your glucose, live", systemImage: "dot.radiowaves.left.and.right")
                    Spacer(minLength: 0)
                    if let card = model.localCard {
                        RangeBadgeSwap(range: card.range, stale: card.isStale())
                    }
                }
                if let card = model.localCard {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        ShareStage(card: card, now: context.date, size: .composer)
                    }
                }
                HStack(spacing: DS.Space.sm) {
                    Text("Your name").dsFont(.callout).foregroundStyle(.secondary)
                    TextField("Shown to them", text: $label)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .dsFont(.body)
                }
                // There's no keyboard in the compact drawer.
                .onChange(of: nameFocused) { _, focused in if focused { model.expand() } }

                DSChipPicker(selection: $duration, options: Self.durations, title: { $0.shortLabel },
                             accessibilityTitle: "Link lasts")

                Button {
                    nameFocused = false
                    Task { await model.send(label: label, duration: duration) }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        if model.isSending { ProgressView().tint(.white) }
                        Label("Send Live Glucose", systemImage: "paperplane.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .large))
                .disabled(model.isSending)

                if let error = model.sendError {
                    Text(error).dsFont(.callout).foregroundStyle(Tone.warning.textColor)
                }
                Text("Anyone with GlucOS sees your reading keep updating in the chat. Everyone else gets a link to a live web page. Stop a link any time in GlucOS → Sharing.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ShareDuration {
    var shortLabel: String {
        switch self {
        case .hour: return "1 hr"
        case .eightHours: return "8 hrs"
        case .day: return "24 hrs"
        case .week: return "7 days"
        case .untilStopped: return "Until I stop"
        }
    }
}

// MARK: - A tapped bubble

struct SelectedShareView: View {
    @EnvironmentObject var model: MessagesModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            LiveShareCard(layout: .expanded)
            if !model.ended && !model.isOwnShare {
                Button { model.follow() } label: {
                    Label("Follow on Lock Screen", systemImage: "lock.iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .large))
                Text("Opens GlucOS, which keeps their reading on your Lock Screen and in the Dynamic Island.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The live bubble in the chat

struct LiveBubbleView: View {
    @EnvironmentObject var model: MessagesModel
    static let height: CGFloat = 176

    var body: some View {
        LiveShareCard(layout: .bubble)
            .padding(DS.Space.xs)
            .frame(height: Self.height)
    }
}

/// A share's live card on its range field (docs/Redesign.md): whose it is, the reading with its
/// needle, the range rail, the forecast note and the freshness meter, and how long it lasts.
struct LiveShareCard: View {
    enum Layout { case bubble, expanded }

    @EnvironmentObject var model: MessagesModel
    var layout: Layout

    private var compact: Bool { layout == .bubble }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let card = model.snapshot?.card
            let stale = card?.isStale(at: now) ?? true
            let tone: Tone = model.ended || stale ? .stale : .glucose(card?.range ?? .inRange)
            let range: GlucoseRange? = model.ended || stale ? nil : card?.range
            let name = model.snapshot.map { ShareMessage.title(label: $0.label) } ?? "Glucose"
            let urgent = range == .urgentLow
            let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            VStack(alignment: .leading, spacing: compact ? DS.Space.xs : DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Eyebrow(title: name, systemImage: "person.fill")
                    Spacer(minLength: 0)
                    if let card, !model.ended { RangeBadgeSwap(range: card.range, stale: stale) }
                }
                if model.ended {
                    Spacer(minLength: 0)
                    Text("This share has ended.").dsFont(.headline)
                    Text("They stopped sharing, or the link ran out.").dsFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if let card {
                    ShareStage(card: card, now: now, size: compact ? .bubble : .expanded)
                } else {
                    Spacer(minLength: 0)
                    if let error = model.loadError {
                        Text(error).dsFont(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Spacer(minLength: 0)
                }
                if compact, !model.ended, let snapshot = model.snapshot {
                    HStack(spacing: DS.Space.xs) {
                        Text(MessagesModel.untilText(snapshot.expiresAt))
                        Spacer(minLength: 0)
                        if !model.isOwnShare {
                            Button("Follow") { model.follow() }
                                .buttonStyle(.ds(.secondary, size: .small))
                        }
                    }
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                } else if !model.ended, let snapshot = model.snapshot {
                    Label("Live · \(MessagesModel.untilText(snapshot.expiresAt).lowercasedFirst)",
                          systemImage: "dot.radiowaves.left.and.right")
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(compact ? DS.Space.md : DS.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
            .background {
                // Bubbles in a chat hold still (there can be several on screen); the tapped card is
                // being looked at, so its field drifts while the reading is fresh.
                ZStack {
                    DSSurface(style: .tinted(tone), radius: DS.Radius.card)
                    RangeField(tone: tone, rapid: !stale && (card?.glucoseTrend.isRapid ?? false),
                               live: !compact && range != nil, intensity: 0.9, range: range)
                        .clipShape(shape)
                }
            }
            // An urgent low gets a rim as well as its colour, so it reads without colour vision.
            .overlay {
                if urgent { shape.strokeBorder(Palette.crimson, lineWidth: 2) }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - The reading, Signal style

/// A shared reading in the Signal language (docs/Redesign.md §5): the value with its needle, the
/// range rail with the forecast's ghost marker, then the forecast note and the freshness meter.
/// Stale is grey and struck through with the needle at "?"; forecasts are grey and "≈", and gone
/// once the reading is stale.
struct ShareStage: View {
    enum Size { case bubble, composer, expanded, image }

    let card: GlucoseActivityState
    let now: Date
    var size: Size

    private var valueSize: CGFloat {
        switch size {
        case .bubble: return 34
        case .composer: return 36
        case .expanded: return 56
        case .image: return 40
        }
    }
    private var needleSize: CGFloat {
        switch size {
        case .bubble: return 36
        case .composer: return 40
        case .expanded: return 60
        case .image: return 44
        }
    }
    private var chartHeight: CGFloat { size == .expanded ? 90 : 0 }
    private var compact: Bool { size == .bubble || size == .image }

    var body: some View {
        let stale = card.isStale(at: now)
        let tone = card.range.tone(stale: stale)
        let headline = stale ? nil : card.forecastHeadline
        let low = stale ? nil : card.lowExpectedDate
        VStack(alignment: .leading, spacing: compact ? DS.Space.xs : DS.Space.sm) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(card.valueText)
                            .font(.system(size: valueSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                            // The line draws across as the data goes stale (docs/Redesign.md §4.3).
                            .staleStrike(stale, thickness: valueSize >= 48 ? 3 : 2)
                            .contentTransition(.numericText(value: card.mgdl))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(card.glucoseUnit.label).dsFont(.label).foregroundStyle(.secondary)
                        // The bubble has no room for a second line: the delta sits by the unit.
                        if compact, !stale, let delta = card.deltaText {
                            Text(delta).dsFont(.label).monospacedDigit().foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: card.deltaMgdl ?? 0))
                        }
                    }
                    if !compact { trendLine(stale: stale) }
                }
                Spacer(minLength: DS.Space.sm)
                TrendDial(trend: stale ? .unknown : card.glucoseTrend, tint: tone.color, size: needleSize)
                    .opacity(stale ? 0.6 : 1)
            }
            .dsAnimation(.arrival, value: card.mgdl)
            RangeRail(mgdl: card.mgdl, lowMgdl: card.lowMgdl, highMgdl: card.highMgdl, stale: stale,
                      forecastMgdl: headline?.mgdl, thickness: compact ? 4 : 6, unit: card.glucoseUnit)
                .padding(.vertical, DS.Space.xxs)
            if chartHeight > 0 {
                GlucoseChart(readings: card.historyReadings, unit: card.glucoseUnit, lowMgdl: card.lowMgdl,
                             highMgdl: card.highMgdl, hours: GlucoseActivityState.historyHours, showAxes: false,
                             latestIsStale: stale, forecast: stale ? [] : forecastSamples)
                    .frame(height: chartHeight)
            }
            HStack(spacing: DS.Space.sm) {
                freshness(stale: stale)
                Spacer(minLength: 0)
                if headline != nil || low != nil {
                    ForecastNote(unit: card.glucoseUnit, headline: headline, lowExpectedAt: low,
                                 readingDate: card.readingDate, compact: compact)
                }
            }
            .dsFont(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence(stale: stale, headline: headline, low: low))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func trendLine(stale: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            if stale {
                Text("Trend unavailable")
            } else {
                Text(card.glucoseTrend.description)
                if let delta = card.deltaText {
                    Text(delta).monospacedDigit().contentTransition(.numericText(value: card.deltaMgdl ?? 0))
                }
            }
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The meter fills over the reading's life; the age counts up beside it. Once stale: full,
    /// amber, and how long there's been no reading.
    @ViewBuilder
    private func freshness(stale: Bool) -> some View {
        if size == .image {
            // A picture of one moment: live timers would freeze at a wrong value, so it says when.
            Label(card.readingDate.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                .lineLimit(1)
        } else {
            meter(stale: stale)
        }
    }

    private func meter(stale: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            FreshnessMeter(readingDate: card.readingDate, stale: stale,
                           tint: stale ? Tone.warning.color : Palette.neutral, width: compact ? 28 : 36)
            if stale {
                Label {
                    Text("No reading for \(Self.minutes(now.timeIntervalSince(card.readingDate))) min")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .foregroundStyle(Tone.warning.textColor)
                .lineLimit(1)
            } else {
                ReadingAge(readingDate: card.readingDate, stale: false, timerWidth: 36)
            }
        }
        .monospacedDigit()
    }

    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int(seconds / 60)) }

    /// The forecast for the chart, its likely range widening from nothing at the reading.
    private var forecastSamples: [ForecastSample] {
        let points = card.forecastPoints
        guard let lastPoint = points.last else { return [] }
        let last = lastPoint.mgdl
        let lowerEnd = Double(card.forecastLower ?? Int(last))
        let upperEnd = Double(card.forecastUpper ?? Int(last))
        return points.enumerated().map { i, p in
            let f = Double(i + 1) / Double(points.count)
            return ForecastSample(date: p.date, mgdl: p.mgdl,
                                  lowerMgdl: p.mgdl - (last - lowerEnd) * f, upperMgdl: p.mgdl + (upperEnd - last) * f)
        }
    }

    /// One sentence for VoiceOver (docs/Redesign.md §6.6).
    private func sentence(stale: Bool, headline: (minutes: Int, mgdl: Double)?, low: Date?) -> String {
        let unit = card.glucoseUnit
        let value = unit.format(mgdl: card.mgdl)
        if stale {
            return "Glucose reading is \(Self.minutes(now.timeIntervalSince(card.readingDate))) minutes old, last \(value) \(unit.label)"
        }
        var s = "Glucose \(value) \(unit.label), \(card.range.label), \(card.glucoseTrend.description.lowercased())"
        if let delta = card.deltaText { s += ", \(delta)" }
        if let low {
            s += ". Low expected in about \(ForecastNote.roundedMinutes(low.timeIntervalSince(card.readingDate))) minutes"
        } else if let headline {
            s += ". Forecast about \(unit.format(mgdl: headline.mgdl)) in \(headline.minutes) minutes"
        }
        return s
    }
}

// MARK: - The picture for people without GlucOS

struct BubbleImageView: View {
    let card: GlucoseActivityState?
    let label: String

    var body: some View {
        let now = Date()
        let stale = card?.isStale(at: now) ?? true
        let tone: Tone = stale ? .stale : .glucose(card?.range ?? .inRange)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Eyebrow(title: ShareMessage.title(label: label), systemImage: "person.fill")
            if let card {
                ShareStage(card: card, now: now, size: .image)
            } else {
                Spacer(minLength: 0)
                Text("Live glucose").dsFont(.title)
                Spacer(minLength: 0)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { RangeField(tone: tone, intensity: 0.9) }
        .background { DSSurface(style: .tinted(tone), radius: 0) }
        .background(Color.white)
        .environment(\.dsTextScale, 1.3)
    }
}
