import SwiftUI

// The "Signal" pieces from docs/Redesign.md: the range field behind a reading, the range rail that
// shows where a value sits between urgent low and very high, the freshness meter that fills over a
// reading's life, and the one-line forecast note. Compiled into every target (app, widgets, Live
// Activity), so each one draws a complete still frame: nothing here needs onAppear or a timer of its
// own. What moves on its own in a widget uses the system's live views (`ProgressView(timerInterval:)`,
// `Text(timerInterval:)`).

// MARK: - Range scale

/// Where a value sits on the rail, 0...1. Logarithmic from 40 to 300 mg/dL, so the lows (where a
/// few mg/dL matter most) get room: urgent low ≈ 0–15 %, in range (3.9–10) ≈ 28–75 %.
enum RangeScale {
    static let floorMgdl: Double = 40
    static let ceilingMgdl: Double = 300
    /// The fixed edges of the urgent-low and very-high ranges (see `GlucoseRange.classify`).
    static let urgentLowMgdl: Double = 54
    static let veryHighMgdl: Double = 250

    static func position(_ mgdl: Double) -> Double {
        let v = min(max(mgdl, floorMgdl), ceilingMgdl)
        return (log(v) - log(floorMgdl)) / (log(ceilingMgdl) - log(floorMgdl))
    }

    /// The five segments' edges for these thresholds, left to right, each 0...1.
    static func edges(lowMgdl: Double, highMgdl: Double) -> [Double] {
        let a = position(urgentLowMgdl)
        let b = max(a, position(lowMgdl))
        let c = max(b, position(highMgdl))
        let d = max(c, position(veryHighMgdl))
        return [0, a, b, c, d, 1]
    }
}

// MARK: - Range rail

/// A capsule split into the five ranges with a marker at the reading, and optionally a hollow grey
/// marker where the forecast ends. The marker glides to a new reading (`.arrival`), which the
/// system also plays between two Live Activity states.
struct RangeRail: View {
    let mgdl: Double
    let lowMgdl: Double
    let highMgdl: Double
    var stale: Bool = false
    /// Where the forecast ends, if there's a current one. Never drawn for a stale reading.
    var forecastMgdl: Double? = nil
    /// Track thickness. The marker is twice this, at least 8 pt.
    var thickness: CGFloat = 6
    /// Widgets in accented / vibrant rendering: one ink, segments told apart by opacity.
    var monochrome: Bool = false
    var unit: GlucoseUnit = .mmol

    @Environment(\.colorSchemeContrast) private var contrast

    private static let ranges: [GlucoseRange] = [.urgentLow, .low, .inRange, .high, .veryHigh]

    private var markerSize: CGFloat { max(8, thickness * 2) }
    private var range: GlucoseRange { GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl) }

    private func segmentColor(_ r: GlucoseRange) -> Color {
        let strong = contrast == .increased
        if monochrome { return Color.primary.opacity(r == .inRange ? 0.75 : 0.3) }
        return r.tint.opacity(r == .inRange ? (strong ? 1 : 0.8) : (strong ? 0.85 : 0.5))
    }

    var body: some View {
        let edges = RangeScale.edges(lowMgdl: lowMgdl, highMgdl: highMgdl)
        let position = RangeScale.position(mgdl)
        let marker = markerSize
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: contrast == .increased ? 1 : 0) {
                    ForEach(Array(Self.ranges.enumerated()), id: \.offset) { i, r in
                        Rectangle()
                            .fill(stale ? Palette.stale.opacity(r == .inRange ? 0.55 : 0.3) : segmentColor(r))
                            .frame(width: max(0, (edges[i + 1] - edges[i]) * w))
                    }
                }
                .frame(width: w, height: thickness)
                .clipShape(Capsule())

                if !stale, let forecastMgdl {
                    Circle()
                        .strokeBorder(Palette.stale, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                        .frame(width: marker * 0.85, height: marker * 0.85)
                        .offset(x: RangeScale.position(forecastMgdl) * w - marker * 0.425)
                }

                Circle()
                    .fill(stale ? AnyShapeStyle(.background) : AnyShapeStyle(monochrome ? Color.primary : range.tint))
                    .overlay {
                        Circle().strokeBorder(stale ? AnyShapeStyle(Palette.stale) : AnyShapeStyle(.background),
                                              lineWidth: contrast == .increased ? 3 : 2)
                    }
                    .frame(width: marker, height: marker)
                    .offset(x: position * w - marker / 2)
            }
            .frame(height: marker)
        }
        .frame(height: marker)
        .dsAnimation(.arrival, value: mgdl)
        .dsAnimation(.ambient, value: stale)
        .accessibilityElement()
        .accessibilityLabel("Range")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let value = unit.format(mgdl: mgdl)
        let band = "between \(unit.format(mgdl: lowMgdl)) and \(unit.format(mgdl: highMgdl))"
        if stale { return "Last reading \(value), stale" }
        var s = "Reading \(value), \(range.label), target \(band)"
        if let forecastMgdl { s += ", forecast about \(unit.format(mgdl: forecastMgdl))" }
        return s
    }
}

// MARK: - Freshness

/// A thin capsule that fills from the moment of the reading to the moment it goes stale. It fills
/// live in widgets and the Live Activity (the system draws `ProgressView(timerInterval:)`), and is
/// drawn full and amber once the reading is stale.
struct FreshnessMeter: View {
    let readingDate: Date
    var stale: Bool
    var tint: Color = Palette.neutral
    var width: CGFloat? = 44

    var body: some View {
        Group {
            if stale {
                Capsule().fill(Tone.warning.color).frame(height: 4)
            } else {
                ProgressView(timerInterval: readingDate...readingDate.addingTimeInterval(GlucoseSnapshot.staleAfter),
                             countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .labelsHidden()
                .tint(tint)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

/// How old the reading is, as a count-up timer ("0:42"), with a clock. Ticks live in widgets and the
/// Live Activity. Amber with a warning clock once stale.
struct ReadingAge: View {
    let readingDate: Date
    var stale: Bool
    /// Room for the timer. Widgets size timer text for its widest value, so it gets a fixed width.
    var timerWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
            Text(timerInterval: readingDate...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.leading)
                .frame(width: timerWidth, alignment: .leading)
        }
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "Reading is stale" : "Reading age")
        .accessibilityValue(Text(readingDate, style: .relative))
    }
}

// MARK: - Forecast note

/// "≈ 6.8 in 30 min", or "Low ≈ 20 min" with an amber triangle when the forecast goes low. Times are
/// rounded to 5 minutes: a forecast is never more precise than that.
struct ForecastNote: View {
    let unit: GlucoseUnit
    /// The forecast's headline point, minutes after the reading and its value.
    let headline: (minutes: Int, mgdl: Double)?
    var lowExpectedAt: Date? = nil
    let readingDate: Date
    /// Shorter text, for the Dynamic Island and small widgets.
    var compact: Bool = false

    static func roundedMinutes(_ seconds: TimeInterval) -> Int {
        max(5, Int((seconds / 300).rounded()) * 5)
    }

    var body: some View {
        if let lowExpectedAt {
            let minutes = Self.roundedMinutes(lowExpectedAt.timeIntervalSince(readingDate))
            Label {
                Text(compact ? "Low ≈ \(minutes) min" : "Low expected ≈ \(minutes) min")
                    .foregroundStyle(Tone.warning.textColor)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color)
            }
            .lineLimit(1)
            .accessibilityLabel("Low expected in about \(minutes) minutes")
        } else if let headline {
            Label {
                Text("\(OutlookFormat.approx(headline.mgdl, unit: unit)) in \(headline.minutes) min")
            } icon: {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Palette.stale)
            }
            .lineLimit(1)
            .accessibilityLabel("Forecast about \(unit.format(mgdl: headline.mgdl)) in \(headline.minutes) minutes")
        }
    }
}

// MARK: - Range field

/// The living colour behind a reading. A soft 3×3 mesh in the range's hue (macOS 15 / iOS 18), with
/// its middle nodes drifting slowly when `live`: on screens being looked at, while data is fresh,
/// never under Reduce Motion or Low Power Mode. A rapid trend drifts a little faster. Stale data is a
/// still grey field. Earlier systems get `AmbientGlow`; Reduce Transparency a flat wash.
struct RangeField: View {
    var tone: Tone
    var rapid: Bool = false
    var live: Bool = false
    var intensity: Double = 1

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                tone.color.opacity(0.18 * intensity)
            } else if #available(iOS 18.0, macOS 15.0, *) {
                MeshField(tint: tone.color, stale: tone == .stale, rapid: rapid, live: live, intensity: intensity)
            } else {
                AmbientGlow(tint: tone.color, intensity: intensity)
            }
        }
        .dsAnimation(.sweep, value: tone)
        .accessibilityHidden(true)
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct MeshField: View {
    let tint: Color
    let stale: Bool
    let rapid: Bool
    let live: Bool
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var drifts: Bool {
        live && !stale && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        if drifts {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                mesh(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            mesh(phase: 0)
        }
    }

    private func mesh(phase t: Double) -> some View {
        let period = rapid ? 9.0 : 14.0
        let p = Float(t / period * 2 * .pi)
        let d: Float = drifts ? 0.06 : 0
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + d * sin(p * 0.7), 0], [1, 0],
            [0, 0.5 + d * sin(p)], [0.5 + d * cos(p * 0.8), 0.5 + d * sin(p * 1.3)], [1, 0.5 + d * cos(p)],
            [0, 1], [0.5 + d * cos(p * 0.6), 1], [1, 1],
        ]
        let k = (stale ? 0.45 : 1) * (colorScheme == .dark ? 1 : 0.7) * intensity
        let o: [Double] = [0.42, 0.30, 0.18, 0.30, 0.20, 0.10, 0.12, 0.06, 0.0]
        return MeshGradient(width: 3, height: 3, points: points,
                            colors: o.map { tint.opacity($0 * k) })
    }
}

// MARK: - Sliding segments

/// A compact segmented control whose selection slides between options (docs/Redesign.md §4.5),
/// for chart hours and similar small choices. App screens only.
struct SlidingSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    DS.animate(.emphasized, reduceMotion: reduceMotion) { selection = option }
                } label: {
                    Text(title(option))
                        .fontWeight(.semibold)
                        .dsFont(.label)
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.sm + 2)
                        .padding(.vertical, DS.Space.xs + 1)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
