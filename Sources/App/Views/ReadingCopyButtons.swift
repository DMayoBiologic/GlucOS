import SwiftUI

/// Copy and Share under the reading details card (improvement round 100), on iPhone Today and in
/// the Mac popover. Both hand over the same one line as the reading's long-press or right-click
/// menu and ⌘C (`ReadingCopy`, the unit on screen). Copy runs the caller's copy, which plays the
/// light `copied` tap on iPhone and says "Copied" to VoiceOver once; the button itself reads
/// "Copied" with a checkmark for `ReadingCopy.toastSeconds`, without a second announce. Share opens
/// the system share sheet (the sharing picker on the Mac). Nothing logs or sends by itself.
struct ReadingCopyButtons: View {
    /// The line as it reads now. Nil (no reading) shows nothing.
    let line: String?
    /// Copies the reading the platform's way.
    let onCopy: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        if let line {
            HStack(spacing: DS.Space.sm) {
                Button(action: copy) {
                    Label(copied ? ReadingCopy.copiedToast : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .accessibilityLabel("Copy Reading")
                ShareLink(item: line) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share Reading")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .dsFont(.label)
            .onDisappear {
                reset?.cancel()
                copied = false
            }
        }
    }

    private func copy() {
        onCopy()
        if reduceMotion { copied = true } else { withAnimation(.snappy) { copied = true } }
        reset?.cancel()
        reset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ReadingCopy.toastSeconds))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
