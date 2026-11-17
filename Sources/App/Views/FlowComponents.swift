import SwiftUI

// Small building blocks shared by the log sheet, Settings and onboarding. Additive to the design
// system in Shared/Theme.swift: they reuse its palette and never restyle existing components.

// MARK: - Chip

/// A capsule toggle/button used for quick picks: time offsets, presets, carb amounts, tags.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false
    var tint: Color = Palette.brand
    /// When set, the picked chip's fill and border are one view that slides between the chips
    /// sharing this namespace (matched geometry) instead of each chip swapping its own. Animate the
    /// pick for it to slide.
    var highlight: Namespace.ID? = nil

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected, tint: tint, highlight: highlight)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let tint: Color
        let highlight: Namespace.ID?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
                .background {
                    if selected, let highlight {
                        Capsule().fill(tint.opacity(0.16))
                            .overlay { Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 0.75) }
                            .matchedGeometryEffect(id: "chip.highlight", in: highlight)
                    }
                }
                .background {
                    if !(selected && highlight != nil) {
                        Capsule().fill(selected ? tint.opacity(0.16) : Color.primary.opacity(hovering ? 0.10 : 0.05))
                    }
                }
                .overlay {
                    if !(selected && highlight != nil) {
                        Capsule().strokeBorder(selected ? tint.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 0.75)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A larger rounded tile that toggles a whole part of the log sheet on or off.
struct TileToggleStyle: ToggleStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary))
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(configuration.isOn ? tint.opacity(0.15) : Color.primary.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(configuration.isOn ? tint.opacity(0.6) : Color.primary.opacity(0.08),
                                      lineWidth: configuration.isOn ? 1.25 : 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Panel

/// A quiet grouped panel for forms that aren't `Form`s (the log sheet, onboarding).
struct FlowPanel<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .labelStyle(PanelTitleLabelStyle(showsIcon: systemImage != nil, tint: tint))
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75))
    }
}

private struct PanelTitleLabelStyle: LabelStyle {
    let showsIcon: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if showsIcon { configuration.icon.foregroundStyle(tint) }
            configuration.title
        }
        .dsFont(.sectionTitle)
    }
}

/// Inline warning under a field: the design system's warning tint, an icon, and words that say
/// what to change. Never colour alone.
struct FieldProblem: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: BannerSeverity.warning.defaultSymbol)
                .imageScale(.small)
                .foregroundStyle(Tone.warning.color)
            Text(text)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Tone.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(text)")
    }
}

/// A number field with − and + buttons either side, e.g. units or grams.
struct NumberStepperField: View {
    let title: String
    @Binding var text: String
    let unitLabel: String
    let step: Double
    let range: ClosedRange<Double>
    var focus: FocusState<LogFieldFocus?>.Binding
    var focusValue: LogFieldFocus

    var body: some View {
        HStack(spacing: 6) {
            stepButton("minus", delta: -step)
            TextField(title, text: $text, prompt: Text("0"))
                .rollingDigits(text, style: .primary)
                .labelsHidden()
                .textFieldStyle(.plain)
                .dsFont(.metricValueLarge)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 92)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .focused(focus, equals: focusValue)
                .accessibilityLabel(title)
            stepButton("plus", delta: step)
            Text(unitLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let current = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
            let next = min(range.upperBound, max(range.lowerBound, ((current + delta) / step).rounded() * step))
            text = LogFormat.number(next)
        } label: {
            Image(systemName: symbol).frame(width: 14, height: 14)
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel(delta > 0 ? "Increase \(title)" : "Decrease \(title)")
    }
}

// MARK: - Rolling digits

extension View {
    /// Rolls a typed amount's digits into place as it changes (`TypedAmountRoll`). Apply it
    /// straight to the `TextField`, before its font and colour, so the rolling figure drawn over
    /// the field picks up the same font. The field's own glyphs go clear while it holds text, so
    /// its caret, selection and editing are untouched; when empty its prompt shows as before.
    /// The figure on top is hidden from VoiceOver, which reads the field's final value.
    func rollingDigits(_ text: String, style: some ShapeStyle,
                       alignment: Alignment = .center) -> some View {
        modifier(RollingDigits(text: text, style: AnyShapeStyle(style), alignment: alignment))
    }
}

private struct RollingDigits: ViewModifier {
    let text: String
    let style: AnyShapeStyle
    let alignment: Alignment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The figure on screen; nil until the text first changes.
    @State private var shown: String?
    @State private var countsDown = false

    func body(content: Content) -> some View {
        let figure = shown ?? text
        content
            .foregroundStyle(text.isEmpty ? style : AnyShapeStyle(Color.clear))
            .overlay(alignment: alignment) {
                Text(figure)
                    .foregroundStyle(style)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: countsDown))
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: text) { old, new in
                switch TypedAmountRoll.between(old, new, reduceMotion: reduceMotion) {
                case .none:
                    break
                case .roll(let down):
                    countsDown = down
                    withAnimation(DSMotion.arrival.animation) { shown = new }
                case .instant:
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { shown = new }
                }
            }
    }
}

/// Fields in the log sheet that take keyboard focus.
enum LogFieldFocus: Hashable { case units, carbs, food, presetName }

// MARK: - Target range

/// Common target ranges, so most people never type a threshold.
struct TargetRangePreset: Identifiable {
    let name: String
    let detail: String
    let lowMgdl: Double
    let highMgdl: Double
    var id: String { name }

    static let all: [TargetRangePreset] = [
        .init(name: "Standard", detail: "International consensus for most adults with diabetes.", lowMgdl: 70, highMgdl: 180),
        .init(name: "Tight", detail: "A narrower range some people aim for, often called time in tight range.", lowMgdl: 70, highMgdl: 140),
        .init(name: "Pregnancy", detail: "The range commonly used in pregnancy with type 1 diabetes.", lowMgdl: 63, highMgdl: 140),
        .init(name: "Older adults", detail: "A wider range sometimes used to reduce the risk of lows.", lowMgdl: 70, highMgdl: 200),
    ]

    func matches(low: Double, high: Double) -> Bool {
        abs(low - lowMgdl) < 1 && abs(high - highMgdl) < 1
    }
}

enum TargetRangeLimits {
    static let low: ClosedRange<Double> = 54...120     // 3.0–6.7 mmol/L
    static let high: ClosedRange<Double> = 110...300   // 6.1–16.7 mmol/L
    static let minimumGap: Double = 18                 // 1.0 mmol/L

    /// `lower...upper`, or a single value when settings from an older build leave them crossed.
    static func safe(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        lower...max(lower, upper)
    }
}

/// The glucose scale with each band in its range colour and the user's thresholds marked, drawn as
/// the Signal range rail (docs/Redesign.md §5.3): the same log scale from 40 to 300 mg/dL and the
/// same segment colours, so the range set here looks exactly like the rail under every reading.
/// Updates live as the thresholds change. With `readingMgdl`, a marker shows where the latest
/// reading sits, and takes the colour of the range it would count as under these thresholds.
struct RangeBar: View {
    let lowMgdl: Double
    let highMgdl: Double
    let unit: GlucoseUnit
    /// The latest reading, only while it's fresh. Nil hides the marker.
    var readingMgdl: Double? = nil

    @Environment(\.colorSchemeContrast) private var contrast

    private static let ranges: [GlucoseRange] = [.urgentLow, .low, .inRange, .high, .veryHigh]
    private let thickness: CGFloat = 10
    private let marker: CGFloat = 16
    /// Fixed edge labels (3.0, 13.9) closer than this to a threshold label are left out, so the
    /// labels never overprint.
    private let labelGap: CGFloat = 30

    private func segmentColor(_ r: GlucoseRange) -> Color {
        let strong = contrast == .increased
        return r.tint.opacity(r == .inRange ? (strong ? 1 : 0.8) : (strong ? 0.85 : 0.5))
    }

    var body: some View {
        let edges = RangeScale.edges(lowMgdl: lowMgdl, highMgdl: highMgdl)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: contrast == .increased ? 1 : 0) {
                        ForEach(Array(Self.ranges.enumerated()), id: \.offset) { i, r in
                            Rectangle()
                                .fill(segmentColor(r))
                                .frame(width: max(0, (edges[i + 1] - edges[i]) * w))
                        }
                    }
                    .frame(width: w, height: thickness)
                    .clipShape(Capsule())

                    if let readingMgdl {
                        let r = GlucoseRange.classify(mgdl: readingMgdl, low: lowMgdl, high: highMgdl)
                        Circle()
                            .fill(r.tint)
                            .overlay {
                                Circle().strokeBorder(.background, lineWidth: contrast == .increased ? 3 : 2)
                            }
                            .frame(width: marker, height: marker)
                            .offset(x: RangeScale.position(readingMgdl) * w - marker / 2)
                    }
                }
                .frame(height: marker)
            }
            .frame(height: marker)
            GeometryReader { geo in
                let w = geo.size.width
                let lowX = x(lowMgdl, w), highX = x(highMgdl, w)
                ZStack(alignment: .topLeading) {
                    if abs(x(RangeScale.urgentLowMgdl, w) - lowX) >= labelGap {
                        tick(RangeScale.urgentLowMgdl, width: w)
                    }
                    tick(lowMgdl, width: w, bold: true)
                    tick(highMgdl, width: w, bold: true)
                    if abs(x(RangeScale.veryHighMgdl, w) - highX) >= labelGap {
                        tick(RangeScale.veryHighMgdl, width: w)
                    }
                }
            }
            .frame(height: 16)
            if let readingMgdl {
                readingLine(readingMgdl)
            }
        }
        .dsAnimation(.emphasized, value: lowMgdl)
        .dsAnimation(.emphasized, value: highMgdl)
        .dsAnimation(.arrival, value: readingMgdl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target range \(unit.format(mgdl: lowMgdl)) to \(unit.format(mgdl: highMgdl, withUnit: true))")
        .accessibilityValue(readingMgdl.map { readingText($0) } ?? "")
    }

    private func x(_ mgdl: Double, _ width: CGFloat) -> CGFloat {
        RangeScale.position(mgdl) * width
    }

    private func tick(_ mgdl: Double, width: CGFloat, bold: Bool = false) -> some View {
        Text(unit.format(mgdl: mgdl))
            .font(.caption2.weight(bold ? .bold : .regular))
            .monospacedDigit()
            .contentTransition(.numericText(value: mgdl))
            .foregroundStyle(bold ? Color.primary : Color.secondary)
            .fixedSize()
            .frame(width: 40)
            .offset(x: x(mgdl, width) - 20)
    }

    private func readingText(_ mgdl: Double) -> String {
        let r = GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl)
        return "Your latest reading, \(unit.format(mgdl: mgdl)), would count as \(r.label.lowercased())"
    }

    /// "Your latest reading, 6.2, would count as in range": the marker in words, with the range's symbol
    /// so it never relies on colour alone.
    private func readingLine(_ mgdl: Double) -> some View {
        let r = GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl)
        return Label {
            Text(readingText(mgdl))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: r.systemImage)
                .foregroundStyle(r.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Presets, two thresholds with steppers, and the live range bar. Used by Settings and onboarding.
/// Pass `readingMgdl` (the latest reading, only while fresh) to show it on the bar.
struct TargetRangeEditor: View {
    @ObservedObject var settings: AppSettings
    var readingMgdl: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(TargetRangePreset.all) { p in
                    Button(p.name) {
                        settings.lowMgdl = p.lowMgdl
                        settings.highMgdl = p.highMgdl
                    }
                    .buttonStyle(ChipButtonStyle(selected: p.matches(low: settings.lowMgdl, high: settings.highMgdl)))
                    .help("\(p.detail) \(settings.unit.format(mgdl: p.lowMgdl))–\(settings.unit.format(mgdl: p.highMgdl, withUnit: true)).")
                }
                Spacer(minLength: 0)
            }
            RangeBar(lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl, unit: settings.unit,
                     readingMgdl: readingMgdl)
            HStack(spacing: 18) {
                ThresholdStepper(title: "Low below", mgdl: $settings.lowMgdl, unit: settings.unit,
                                 range: TargetRangeLimits.safe(TargetRangeLimits.low.lowerBound,
                                                              min(TargetRangeLimits.low.upperBound,
                                                                  settings.highMgdl - TargetRangeLimits.minimumGap)),
                                 tint: GlucoseRange.low.tint)
                ThresholdStepper(title: "High above", mgdl: $settings.highMgdl, unit: settings.unit,
                                 range: TargetRangeLimits.safe(max(TargetRangeLimits.high.lowerBound,
                                                                  settings.lowMgdl + TargetRangeLimits.minimumGap),
                                                              TargetRangeLimits.high.upperBound),
                                 tint: GlucoseRange.high.tint)
                Spacer(minLength: 0)
            }
        }
    }
}

/// One threshold: a value in the display unit with a stepper, clamped to a safe range.
struct ThresholdStepper: View {
    let title: String
    @Binding var mgdl: Double
    let unit: GlucoseUnit
    let range: ClosedRange<Double>
    let tint: Color

    var body: some View {
        let display = Binding<Double>(
            get: { unit.value(fromMgdl: mgdl) },
            set: { mgdl = min(range.upperBound, max(range.lowerBound, unit.mgdl(fromDisplay: $0))) }
        )
        let step = unit == .mmol ? 0.1 : 1
        let displayRange = unit.value(fromMgdl: range.lowerBound)...unit.value(fromMgdl: range.upperBound)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Capsule().fill(tint.gradient).frame(width: 4, height: 12)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField(title, value: display, format: .number.precision(.fractionLength(unit == .mmol ? 1 : 0)))
                    .labelsHidden()
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Stepper(title, value: display, in: displayRange, step: step)
                    .labelsHidden()
                Text(unit.label).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Connection problems

/// A LibreLinkUp failure explained in plain words, with what to do about it.
struct ConnectionProblem: Equatable {
    enum Fix: Equatable {
        /// Re-enter the email or password.
        case checkCredentials
        /// Something to do in the LibreLinkUp phone app.
        case useLibreLinkUpApp
        /// Abbott raised the minimum client version; GlucOS can adopt it.
        case updateClientVersion(String)
        case checkNetwork
        case waitAndRetry
        case retry
    }

    let title: String
    let advice: String
    let fix: Fix
    let systemImage: String
    /// How the problem is shown. Anything that stops readings until the user acts is critical;
    /// a blip GlucOS recovers from by itself is a warning; "not signed in yet" is just info.
    let severity: BannerSeverity

    init(title: String, advice: String, fix: Fix, systemImage: String = "exclamationmark.triangle.fill",
         severity: BannerSeverity? = nil) {
        self.title = title
        self.advice = advice
        self.fix = fix
        self.systemImage = systemImage
        self.severity = severity ?? {
            switch fix {
            case .checkCredentials, .useLibreLinkUpApp, .updateClientVersion: return .critical
            case .checkNetwork, .waitAndRetry, .retry: return .warning
            }
        }()
    }

    init(_ error: Error) {
        if let e = error as? LibreLinkUpClient.ClientError {
            switch e {
            case .notConfigured:
                self.init(title: "Not signed in", advice: "Enter your LibreLinkUp follower email and password.",
                          fix: .checkCredentials, systemImage: "person.crop.circle.badge.questionmark", severity: .info)
            case .badCredentials:
                self.init(title: "Email or password not accepted",
                          advice: "Use the LibreLinkUp follower account (the one that accepted the invitation), not your LibreLink login. Check for typos and Caps Lock.",
                          fix: .checkCredentials, systemImage: "key.slash")
            case .termsAcceptanceRequired:
                self.init(title: "Accept LibreLinkUp's updated terms",
                          advice: "Open the LibreLinkUp app on your phone, sign in with this account and accept the prompt. Then try again.",
                          fix: .useLibreLinkUpApp, systemImage: "doc.text.magnifyingglass")
            case .versionTooOld(let minimum):
                self.init(title: "LibreLinkUp wants a newer client version",
                          advice: "Abbott now requires version \(minimum). GlucOS can switch to it and reconnect.",
                          fix: .updateClientVersion(minimum), systemImage: "arrow.up.circle")
            case .noConnections:
                self.init(title: "This account isn't following anyone yet",
                          advice: "In LibreLink on the phone that wears the sensor, open Connected Apps → LibreLinkUp and invite this email. Then accept the invitation in the LibreLinkUp app.",
                          fix: .useLibreLinkUpApp, systemImage: "person.2.slash")
            case .http(let code, _) where code == 429:
                self.init(title: "Too many attempts",
                          advice: "LibreLinkUp is limiting requests. Wait a few minutes before trying again.",
                          fix: .waitAndRetry, systemImage: "hourglass")
            case .http(let code, _) where code == 401 || code == 403:
                self.init(title: "LibreLinkUp refused the session",
                          advice: "Sign in again. If it keeps happening, check the account in the LibreLinkUp app.",
                          fix: .checkCredentials, systemImage: "lock.trianglebadge.exclamationmark")
            case .http(let code, _) where code >= 500:
                self.init(title: "LibreLinkUp is having problems",
                          advice: "Abbott's servers returned an error (\(code)). GlucOS will keep retrying.",
                          fix: .waitAndRetry, systemImage: "server.rack")
            case .http(let code, _):
                self.init(title: "Unexpected reply from LibreLinkUp",
                          advice: "The server returned HTTP \(code). Try again shortly.", fix: .retry)
            case .decoding:
                self.init(title: "LibreLinkUp's response has changed",
                          advice: "\(e.localizedDescription) GlucOS may need an update; it updates itself automatically when one is out.",
                          fix: .retry, systemImage: "questionmark.diamond")
            case .unexpectedStatus(let s):
                self.init(title: "LibreLinkUp returned status \(s)",
                          advice: "Open the LibreLinkUp app on your phone to check for any prompts, then try again.",
                          fix: .useLibreLinkUpApp)
            }
            return
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                self.init(title: "You're offline", advice: "GlucOS will reconnect as soon as you're back online.",
                          fix: .checkNetwork, systemImage: "wifi.slash")
                return
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                self.init(title: "Can't reach LibreLinkUp",
                          advice: "The server didn't respond. Check your connection, or try another region in Settings → Account.",
                          fix: .checkNetwork, systemImage: "antenna.radiowaves.left.and.right.slash")
                return
            default: break
            }
        }
        self.init(title: "Couldn't connect", advice: error.localizedDescription, fix: .retry)
    }
}

extension ConnectionProblem {
    static let diagnosticFeature = "linkup.fetch"

    /// Sent as an error report automatically: problems that may be GlucOS's to fix (an unexpected
    /// reply, a changed response, a new client version), not a wrong password or being offline.
    var isWorthReporting: Bool {
        switch fix {
        case .retry, .updateClientVersion: return true
        case .checkCredentials, .useLibreLinkUpApp, .checkNetwork, .waitAndRetry: return false
        }
    }
}

/// A connection problem as a themed status banner: what's wrong, what to do, and where GlucOS
/// can fix it, a one-click button.
struct ConnectionProblemView: View {
    let problem: ConnectionProblem
    var compact = false
    /// Called with the fix the user chose; the host decides what each one does.
    var onFix: ((ConnectionProblem.Fix) -> Void)?

    var body: some View {
        StatusBanner(severity: problem.severity,
                     systemImage: problem.systemImage,
                     title: problem.title,
                     message: problem.advice,
                     action: action,
                     density: compact ? .compact : .regular)
    }

    private var action: BannerAction? {
        guard let onFix, let label = fixLabel else { return nil }
        return BannerAction(title: label, systemImage: fixSymbol) { onFix(problem.fix) }
    }

    private var fixLabel: String? {
        switch problem.fix {
        case .updateClientVersion: return "Update & Reconnect"
        case .retry, .waitAndRetry, .checkNetwork: return "Try Again"
        case .checkCredentials, .useLibreLinkUpApp: return nil
        }
    }

    private var fixSymbol: String? {
        switch problem.fix {
        case .updateClientVersion: return "arrow.up.circle"
        case .retry, .waitAndRetry, .checkNetwork: return "arrow.clockwise"
        case .checkCredentials, .useLibreLinkUpApp: return nil
        }
    }
}
