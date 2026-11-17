import SwiftUI

/// A ⌘? list of keyboard shortcuts (`ShortcutCatalog`), grouped, keys on the left. Shown as a
/// sheet in the dashboard and the log sheet, and as a card over the menu bar popover.
struct ShortcutListView: View {
    let groups: [ShortcutGroup]
    /// Narrow and tighter, to fit the menu bar popover.
    var compact = false
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Keyboard Shortcuts")
                .dsFont(.title)
                .accessibilityAddTraits(.isHeader)
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if groups.count > 1 {
                        Text(group.title)
                            .dsFont(.sectionTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        ForEach(group.rows, id: \.keys) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.action).dsFont(.body)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.ds(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(compact ? DS.Space.lg : DS.Space.xxl)
        .frame(minWidth: compact ? nil : 380, alignment: .leading)
        // Esc closes the list: the sheet, or the card over the popover (then Esc again closes
        // the popover).
        .closesOnEscape(onDone)
    }
}
