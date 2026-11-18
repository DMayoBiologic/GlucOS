import SwiftUI

/// The note behind a Glance figure's info button (docs/InsightsExplainers.md): what the figure
/// means, how it was worked out for the period on screen, and its caveat. It grows out of the
/// figure it explains (`InsightsExplainerEntrance`): on the iPhone the sheet does the zooming, on
/// the Mac the note scales up from the edge nearest the figure. Only a fade under Reduce Motion.
/// The title is a heading VoiceOver lands on once the note has arrived; the rest reads as one
/// element after it.
struct InsightsExplainerCard: View {
    let explainer: InsightsExplainer
    var style: InsightsExplainerEntrance.Style = .scale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(explainer.title)
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(explainer.meaning)
                    .dsFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(InsightsExplainer.workedOutHeading)
                        .dsFont(.label)
                        .foregroundStyle(.secondary)
                    Text(explainer.workedOut)
                        .dsFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = explainer.note {
                    Text(note)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(explainer.spokenBody)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(InsightsExplainerEntrance.scale(shown: shown, style: style), anchor: .top)
        .opacity(InsightsExplainerEntrance.opacity(shown: shown, style: style))
        .onAppear {
            switch style {
            case .zoom: shown = true
            case .scale: withAnimation(DSMotion.emphasized.animation) { shown = true }
            case .crossFade: withAnimation(.easeOut(duration: InsightsExplainerEntrance.fadeDuration)) { shown = true }
            }
            guard voiceOver else { return }
            let delay = InsightsExplainerEntrance.titleFocusDelay(reduceMotion: style == .crossFade)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { titleFocused = true }
        }
    }
}

extension View {
    /// Puts a small ⓘ in this figure's corner that opens its note, grown out of the figure: a
    /// sheet that zooms out of it on iPhone, a popover hanging off it on the Mac. Nothing shows
    /// without a period (no readings yet), or while the card is drawn into a shared picture
    /// (`hidden`). The figure itself is left exactly as it was, so its count-ups never restart.
    /// `beside` puts the ⓘ just after the figure instead of in its corner, for one-line figures.
    func insightsExplainer(_ figure: InsightsFigure, context: InsightsExplainer.Context?,
                           hidden: Bool = false, buttonOffset: CGSize = .zero,
                           beside: Bool = false) -> some View {
        modifier(InsightsExplainerSource(figure: figure, context: context, hidden: hidden,
                                         buttonOffset: buttonOffset, beside: beside))
    }
}

private struct InsightsExplainerSource: ViewModifier {
    let figure: InsightsFigure
    let context: InsightsExplainer.Context?
    let hidden: Bool
    let buttonOffset: CGSize
    let beside: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    #if os(iOS)
    @Namespace private var zoom
    #endif

    private var shows: Bool { context != nil && !hidden }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, beside && shows ? InsightsInfoButton.size + DS.Space.xxs : 0)
            .overlay(alignment: beside ? .trailing : .topTrailing) {
                if shows {
                    InsightsInfoButton(figure: figure) { setOpen(true) }
                        .offset(buttonOffset)
                }
            }
            #if os(iOS)
            .matchedTransitionSource(id: InsightsExplainerEntrance.sourceID(figure), in: zoom)
            .sheet(isPresented: $open) {
                if let context {
                    let style = InsightsExplainerEntrance.Style(reduceMotion: reduceMotion, zooms: true)
                    InsightsExplainerSheet(explainer: .make(figure, context), style: style) { setOpen(false) }
                        .modifier(InsightsExplainerZoom(style: style, sourceID: InsightsExplainerEntrance.sourceID(figure),
                                                        namespace: zoom))
                }
            }
            #else
            .popover(isPresented: $open, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                if let context {
                    InsightsExplainerCard(explainer: .make(figure, context),
                                          style: .init(reduceMotion: reduceMotion, zooms: false))
                        .frame(width: 320)
                }
            }
            #endif
    }

    /// Under Reduce Motion the sheet opens and closes without its slide, and the note fades in
    /// where it sits instead.
    private func setOpen(_ value: Bool) {
        #if os(iOS)
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { open = value }
            return
        }
        #endif
        open = value
    }
}

/// The ⓘ itself.
private struct InsightsInfoButton: View {
    let figure: InsightsFigure
    let action: () -> Void
    static let size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(minWidth: Self.size, minHeight: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(figure.buttonLabel)
        .accessibilityHint("Explains what this figure means and how it's worked out.")
        .help(figure.buttonLabel)
    }
}

#if os(iOS)
/// The zoom out of the figure, and back into it on dismiss. Nothing extra under Reduce Motion.
private struct InsightsExplainerZoom: ViewModifier {
    let style: InsightsExplainerEntrance.Style
    let sourceID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if style == .zoom {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

/// The iPhone sheet around the note, with a Done button.
private struct InsightsExplainerSheet: View {
    let explainer: InsightsExplainer
    let style: InsightsExplainerEntrance.Style
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                InsightsExplainerCard(explainer: explainer, style: style)
            }
            .navigationTitle("About this figure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
