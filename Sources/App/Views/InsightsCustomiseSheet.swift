import SwiftUI

/// The Mac Insights page's customise sheet: drag the showing cards into order, hide any, and bring
/// hidden ones back from the Hidden section (docs/InsightsLayout.md). Changes apply as they're
/// made, so the page behind springs into its new order while the sheet is open.
struct InsightsCustomiseSheet: View {
    @Binding var layout: InsightsLayout
    let defaults: [InsightsCard]
    let change: ((inout InsightsLayout) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown = layout.visible(defaults)
        let hidden = layout.hiddenCards(defaults)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Customise Insights").dsFont(.sectionTitle)
                Text("Drag cards into the order you want. New cards show when they arrive.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.xl)

            List {
                Section("Shown") {
                    ForEach(shown) { card in
                        row(card, hidden: false)
                    }
                    .onMove { from, to in
                        change { $0.moveVisible(fromOffsets: from, toOffset: to, defaults: defaults) }
                    }
                }
                Section("Hidden") {
                    if hidden.isEmpty {
                        Text("Cards you hide wait here, ready to bring back.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hidden) { card in
                            row(card, hidden: true)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 320)

            Divider()
            HStack {
                Button("Restore Standard Order") { change { $0 = .standard } }
                    .disabled(layout.isStandard)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 420, height: 520)
    }

    private func row(_ card: InsightsCard, hidden: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            if !hidden {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Image(systemName: card.systemImage)
                .foregroundStyle(hidden ? Color.secondary : Palette.brand)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(card.title)
                .foregroundStyle(hidden ? .secondary : .primary)
            Spacer()
            if hidden {
                Button("Show") { change { $0.restore(card, defaults: defaults) } }
                    .accessibilityLabel("Show \(card.title)")
            } else {
                Button("Hide") { change { $0.hide(card, defaults: defaults) } }
                    .accessibilityLabel("Hide \(card.title)")
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .contentShape(Rectangle())
        // Without a pointer: move by one with the VoiceOver actions.
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if !hidden {
                Button("Move up") { change { $0.move(card, by: -1, defaults: defaults) } }
                Button("Move down") { change { $0.move(card, by: 1, defaults: defaults) } }
            }
        }
    }
}
