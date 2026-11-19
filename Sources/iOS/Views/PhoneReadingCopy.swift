import SwiftUI
import UIKit

// Copy or share the reading on iPhone Today and on a followed person's stage (round 84). Long-press
// the reading for Copy and Share…, or use the VoiceOver actions of the same names. The words come
// from `ReadingCopy` (one line, the unit on screen, "No readings for 12 min · …" during a gap, the
// person's name in front on a follower's stage). Copying plays a light tap (`copied`), shows a
// small "Copied" capsule over the reading for 1.4 s and says "Copied" to VoiceOver once. Share opens
// the system share sheet with the same line. Nothing logs, sends or changes anything by itself.

enum PhoneReadingCopy {
    /// Copies `text`, taps once and tells VoiceOver. The caller bumps its toast trigger.
    @MainActor
    static func copy(_ text: String) {
        ReadingClipboard.copy(text)
        Haptics.play(.copied)
        AccessibilityNotification.Announcement(ReadingCopy.copiedToast).post()
    }
}

/// The system share sheet for one line of text: Messages, Mail, Notes, AirDrop.
struct TextActivitySheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What Share… hands the share sheet. Identifiable so `.sheet(item:)` opens with the line as it
/// was at the tap, not as it reads a few seconds later.
struct SharedReadingText: Identifiable {
    let id = UUID()
    let text: String
}

extension View {
    /// The "Copied" capsule over the reading's top edge each time `trigger` changes. Slides down
    /// and fades; fades only under Reduce Motion. Hidden from VoiceOver, which hears the announce.
    func copiedToast(trigger: Int) -> some View {
        modifier(CopiedToastModifier(trigger: trigger))
    }

    /// Share… for the reading: the system share sheet with `item`'s line.
    func readingShareSheet(_ item: Binding<SharedReadingText?>) -> some View {
        sheet(item: item) { shared in
            TextActivitySheet(text: shared.text)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

private struct CopiedToastModifier: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if visible {
                    Label(ReadingCopy.copiedToast, systemImage: "checkmark.circle.fill")
                        .dsFont(.label)
                        .fontWeight(.semibold)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.xs)
                        .background(.regularMaterial, in: Capsule())
                        .transition(DS.Transition.banner(reduceMotion: reduceMotion))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dsAnimation(.standard, value: visible)
            .onChange(of: trigger) { _, _ in
                visible = true
                hide?.cancel()
                hide = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ReadingCopy.toastSeconds))
                    guard !Task.isCancelled else { return }
                    visible = false
                }
            }
            .onDisappear {
                hide?.cancel()
                visible = false
            }
    }
}
