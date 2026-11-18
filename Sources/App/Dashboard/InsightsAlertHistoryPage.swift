import SwiftUI

/// Alert History inside the dashboard, opened from the Insights Alerts card
/// (docs/InsightsAlerts.md, "Opening Alert History"). The Insights page cross-fades to it in place
/// and "‹ Insights" (or Esc) cross-fades back, scrolled to the card. A row opens the Logbook around
/// its alert, as it does from Settings. The same list as Settings › Alerts › Alert History.
struct InsightsAlertHistoryPage: View {
    let back: () -> Void
    /// A row was clicked: the Logbook around that alert.
    let open: (LogbookLink) -> Void

    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Button(action: back) {
                    Label("Insights", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .dsFont(.label)
                .help("Back to the Alerts card in Insights")
                .accessibilityLabel("Back to Insights")
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.md)
            Text(AlertHistoryText.rowTitle)
                .dsFont(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
            List {
                AlertHistoryContent(records: logbook.alerts, readings: store.archive, unit: settings.unit,
                                    alertsOn: settings.alertsEnabled, open: open)
            }
            .listStyle(.inset)
            .alertHistoryAnnouncements(records: logbook.alerts, readings: store.archive, unit: settings.unit)
            // Each row's Add note, and "Added note · Undo" (⌘Z) after one (docs/AlertNotes.md).
            .alertNoteEditor()
            .overlay(alignment: .bottom) { LogbookUndoToast() }
            Divider()
            Text(AlertHistoryText.macFooter)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.md)
        }
        .onExitCommand(perform: back)
    }
}
