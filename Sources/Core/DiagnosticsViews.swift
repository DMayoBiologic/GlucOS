#if canImport(SwiftUI)
import SwiftUI

/// "Send Report" under an error: sends the problem with an optional note, even when automatic
/// reports are off (the person chose to send this one).
struct SendReportButton: View {
    private let makeEvent: () -> DiagnosticEvent
    @State private var state = SendState.idle
    @State private var asking = false
    @State private var note = ""

    private enum SendState { case idle, sending, sent, queued }

    init(event: DiagnosticEvent) {
        makeEvent = { event }
    }

    /// Sends the latest problem reported in `feature`, or a plain one with `message` if there isn't one.
    init(feature: String, step: String, message: String) {
        makeEvent = {
            Diagnostics.shared.latest(feature: feature)
                ?? DiagnosticEvent(feature: feature, step: step, code: nil, message: message)
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                Button("Send Report", systemImage: "paperplane") { asking = true }
            case .sending:
                Label("Sending…", systemImage: "paperplane")
                    .foregroundStyle(.secondary)
            case .sent:
                Label("Report sent. Thanks.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .queued:
                Label("Saved. It'll be sent when you're back online.", systemImage: "tray.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Send a report?", isPresented: $asking) {
            TextField("What were you doing? (optional)", text: $note)
            Button("Send") { send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GlucOS sends what went wrong, the app version and your device model. No glucose readings or account details.")
        }
    }

    private func send() {
        state = .sending
        let event = makeEvent()
        let text = note
        Task {
            let ok = await Diagnostics.shared.send(event, note: text)
            state = ok ? .sent : .queued
        }
    }
}

/// Settings: automatic error reports on or off, and what they contain.
struct DiagnosticsToggle: View {
    @AppStorage(Diagnostics.enabledKey) private var enabled = true

    var body: some View {
        Toggle("Send error reports automatically", isOn: $enabled)
            .onChange(of: enabled) { _, on in Diagnostics.shared.isEnabled = on }
    }

    static let privacyNote = "When something fails, like a sensor read or a sync, GlucOS sends the error, the app version, your device model and OS version to its developer so it can be fixed. Reports never include glucose readings, logbook entries, your login or your sensor's serial number."
}
#endif
