import SwiftUI

/// The note behind a Glance figure's info button (docs/InsightsExplainers.md): what the figure
/// means, how it was worked out for the period on screen, and its caveat. It scales in gently as
/// it opens, and only fades under Reduce Motion. VoiceOver reads the whole note as one element.
struct InsightsExplainerCard: View {
    let explainer: InsightsExplainer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(explainer.title)
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(explainer.spoken)
        .scaleEffect(InsightsExplainerEntrance.scale(shown: shown, reduceMotion: reduceMotion), anchor: .top)
        .opacity(InsightsExplainerEntrance.opacity(shown: shown))
        .onAppear {
            // A gentle scale-in with the fade; just the fade under Reduce Motion.
            withAnimation(reduceMotion ? .easeOut(duration: InsightsExplainerEntrance.fadeDuration)
                                       : DSMotion.emphasized.animation) {
                shown = true
            }
        }
    }
}

/// A small ⓘ beside a Glance figure. It opens the figure's note: a sheet on iPhone, a popover on
/// the Mac. Nothing shows without a period (no readings yet), or while the card is drawn into a
/// shared picture (`hidden`).
struct InsightsInfoButton: View {
    let figure: InsightsFigure
    let context: InsightsExplainer.Context?
    var hidden = false
    @State private var open = false

    var body: some View {
        if let context, !hidden {
            Button { open = true } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(figure.buttonLabel)
            .accessibilityHint("Explains what this figure means and how it's worked out.")
            .help(figure.buttonLabel)
            #if os(iOS)
            .sheet(isPresented: $open) {
                InsightsExplainerSheet(explainer: .make(figure, context)) { open = false }
            }
            #else
            .popover(isPresented: $open, arrowEdge: .bottom) {
                InsightsExplainerCard(explainer: .make(figure, context))
                    .frame(width: 320)
            }
            #endif
        }
    }
}

#if os(iOS)
/// The iPhone sheet around the note, with a Done button.
private struct InsightsExplainerSheet: View {
    let explainer: InsightsExplainer
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                InsightsExplainerCard(explainer: explainer)
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
