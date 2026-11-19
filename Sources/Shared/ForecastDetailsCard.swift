import SwiftUI

/// The small card a tap (iPhone Today) or click (Mac popover) on the forecast opens
/// (`ForecastDetails`, round 73): the forecast at 30 and 60 minutes with its likely range, how often
/// that range held at each distance recently, and one line on what it was based on. Shown as a
/// popover from the chart, kept a popover on iPhone, like the reading's details card. VoiceOver
/// reads it as one element.
///
/// It grows out of the forecast (`ForecastCardEntrance`, round 74): the range band widens from a
/// line on the edge nearest the forecast into the card, the figures roll from where the forecast
/// starts to their value, and `closing` plays it backwards. A cross-fade under Reduce Motion. Only
/// ever shown in the app's popover, never in a widget, where onAppear wouldn't run.
///
/// On iPhone it can be dragged down to put it away (`ForecastCardDrag`, round 93): it follows the
/// finger, then drops out of the popover or springs back. Under Reduce Motion it only dims, and a
/// drag far enough closes it with the cross-fade.
struct ForecastDetailsCard: View {
    let details: ForecastDetails
    let unit: GlucoseUnit
    /// The card's edge nearest the forecast line, which the band widens from.
    var opensFromTop = true
    /// Set while the chart lets the card go: the band narrows back and the figures roll back.
    var closing = false
    /// VoiceOver's escape gesture and Close action, so it closes the same way.
    var close: (() -> Void)?
    /// Once the card has dropped out after a drag: the popover goes straight away, without the
    /// band narrowing again. Falls back to `close`.
    var dropped: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    /// The rows (by minutes) whose figure has rolled to its value.
    @State private var rolled: Set<Int> = []
    @State private var rollTask: Task<Void, Never>?
    /// How far the finger has dragged the card down (points; negative is up).
    @State private var dragY: Double = 0
    /// Let go far enough: dropping out, so nothing else should move it.
    @State private var dropping = false
    @State private var dropTask: Task<Void, Never>?
    /// The card's measured height, for how far it drops.
    @State private var height: Double = 0

    private var style: ForecastCardEntrance.Style { .init(reduceMotion: reduceMotion) }

    /// Fixed, so the wrapped lines set the height and the popover never grows sideways.
    static let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.xs) {
                Capsule().fill(Palette.stale).frame(width: 12, height: 2)
                Text(ForecastDetails.title)
                    .dsFont(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            ForEach(details.horizons, id: \.minutes) { h in
                row(h)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: details.driver.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(details.driver.line)
                    .dsFont(.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ForecastDetails.footnote)
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.lg)
        .frame(width: ForecastDetailsCard.width, alignment: .leading)
        .opacity(ForecastCardEntrance.contentOpacity(open: open, style: style))
        .background { band(Palette.stale.opacity(ForecastCardEntrance.bandTint(open: open, style: style))) }
        .mask { band(Color.black) }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { height = $0 }
        .scaleEffect(ForecastCardDrag.scale(dragY, style: style), anchor: opensFromTop ? .top : .bottom)
        .offset(y: ForecastCardDrag.offset(dragY, style: style))
        .opacity(dropping && style == .widen ? 0 : ForecastCardDrag.opacity(dragY))
        .modifier(ForecastCardDragGesture(onChanged: dragChanged, onEnded: dragEnded))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForecastDetails.spoken(details, unit: unit))
        .accessibilityAction(.escape) { close?() }
        .accessibilityAction(named: ForecastDetails.closeTitle) { close?() }
        .onAppear { dragY = 0; dropping = false; enter() }
        .onChange(of: closing) { _, isClosing in isClosing ? leave() : enter() }
        .onDisappear { rollTask?.cancel(); dropTask?.cancel() }
    }

    // MARK: Drag to put away (iPhone)

    private func dragChanged(_ dy: Double) {
        guard !dropping, !closing else { return }
        dragY = dy
    }

    /// Past the distance or a flick down: drop out (or cross-fade under Reduce Motion). Otherwise
    /// spring back to where it sat.
    private func dragEnded(_ dy: Double, predicted: Double) {
        guard !dropping, !closing else { return }
        guard ForecastCardDrag.dismisses(dy, predicted: predicted) else {
            withAnimation(style == .widen ? DSMotion.emphasized.animation
                                          : .easeInOut(duration: ForecastCardEntrance.fadeOutDuration)) { dragY = 0 }
            return
        }
        guard style == .widen else {
            close?()
            return
        }
        rollTask?.cancel()
        withAnimation(.easeIn(duration: ForecastCardDrag.dropDuration)) {
            dropping = true
            dragY = ForecastCardDrag.dropOffset(from: dy, height: height)
        }
        dropTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ForecastCardDrag.dropDuration))
            guard !Task.isCancelled else { return }
            if let dropped { dropped() } else { close?() }
        }
    }

    /// The band: the line on the edge nearest the forecast while closed, the whole card open.
    private func band(_ fill: some ShapeStyle) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(fill)
                .frame(height: ForecastCardEntrance.bandHeight(open: open, full: geo.size.height, style: style))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: opensFromTop ? .top : .bottom)
        }
        .allowsHitTesting(false)
    }

    /// The band widens into the card, then each figure rolls in after the last. Under Reduce
    /// Motion the contents fade in with their own figures. Also reopens a card caught closing.
    private func enter() {
        rollTask?.cancel()
        guard style == .widen else {
            withAnimation(.easeOut(duration: ForecastCardEntrance.fadeInDuration)) { open = true }
            return
        }
        withAnimation(.smooth(duration: ForecastCardEntrance.openDuration)) { open = true }
        let rows = details.horizons.map(\.minutes)
        rollTask = Task { @MainActor in
            var waited: TimeInterval = 0
            for (i, minutes) in rows.enumerated() where !rolled.contains(minutes) {
                let at = ForecastCardEntrance.figureDelay(index: i)
                try? await Task.sleep(for: .seconds(max(at - waited, 0)))
                waited = at
                guard !Task.isCancelled else { return }
                withAnimation(DSMotion.arrival.animation) { _ = rolled.insert(minutes) }
            }
        }
    }

    /// Backwards: the figures roll back as the band narrows to the line, or the contents fade.
    private func leave() {
        rollTask?.cancel()
        guard style == .widen else {
            withAnimation(.easeIn(duration: ForecastCardEntrance.fadeOutDuration)) { open = false }
            return
        }
        withAnimation(.smooth(duration: ForecastCardEntrance.closeDuration)) {
            open = false
            rolled = []
        }
    }

    private func row(_ h: ForecastDetails.Horizon) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(ForecastDetails.heading(h))
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)
                figure(h)
                Spacer(minLength: 0)
                Text(ForecastDetails.range(h, unit: unit))
                    .dsFont(.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(ForecastDetails.held(h))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The row's figure, rolling between where the forecast starts and its value.
    private func figure(_ h: ForecastDetails.Horizon) -> some View {
        let isIn = rolled.contains(h.minutes)
        let mgdl = ForecastCardEntrance.figure(h, start: details.startMgdl, rolledIn: isIn, style: style)
        return Text(unit.format(mgdl: mgdl, withUnit: true))
            .dsFont(.headline)
            .monospacedDigit()
            .contentTransition(style == .widen
                ? .numericText(countsDown: ForecastCardEntrance.countsDown(h, start: details.startMgdl, rollingIn: isIn))
                : .identity)
    }
}

/// The card's drag down, on iPhone only: the Mac's popover is clicked, not dragged. A simultaneous
/// gesture, so the popover's own touches still pass.
private struct ForecastCardDragGesture: ViewModifier {
    let onChanged: (Double) -> Void
    let onEnded: (_ dy: Double, _ predicted: Double) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.simultaneousGesture(
            DragGesture(minimumDistance: ForecastCardDrag.minimumDistance)
                .onChanged { onChanged($0.translation.height) }
                .onEnded { onEnded($0.translation.height, $0.predictedEndTranslation.height) }
        )
        #else
        content
        #endif
    }
}
