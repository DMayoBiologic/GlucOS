import SwiftUI

// "You logged a similar meal 3 min ago · View" above Log in the iPhone and Mac log sheets
// (`SimilarEntry`, docs/SimilarEntry.md). View shows the earlier entry in place, so nothing typed
// into the sheet is lost. Only a note: Log stays as it is, and nothing here changes an amount.

/// The line, or nothing when nothing similar was logged in the last 10 minutes. Redraws every 15
/// seconds so the minutes keep up and the line goes once the earlier entry is 10 minutes old.
struct SimilarEntryLine: View {
    /// The meal and dose as the sheet would save them now.
    let drafts: [LogEntry]
    let entries: [LogEntry]
    /// The entry being edited, if any, is never its own match.
    var excluding: Set<UUID> = []
    var isFollower = false
    /// Space around the line when it shows, so nothing is reserved when it doesn't.
    var padding = EdgeInsets()
    @State private var showsEarlier = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 15)) { ctx in
            let found = SimilarEntry.match(for: drafts, in: entries, now: max(ctx.date, Date()),
                                           excluding: excluding, isFollower: isFollower)
            Group {
                if let found { content(found) }
            }
            .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: found?.entry.id)
            .onChange(of: found?.entry.id) { _, _ in showsEarlier = false }
        }
    }

    private var icon: some View {
        Image(systemName: "clock.arrow.circlepath")
            .imageScale(.small)
            .accessibilityHidden(true)
    }

    private func note(_ found: SimilarEntry.Match) -> some View {
        Text(found.line)
            .monospacedDigit()
            .accessibilityLabel(found.spoken)
    }

    private var viewButton: some View {
        Button(showsEarlier ? "Hide" : "View") {
            DS.animate(.quick, reduceMotion: reduceMotion) { showsEarlier.toggle() }
        }
        .buttonStyle(.plain)
        .fontWeight(.semibold)
        .foregroundStyle(Palette.brandText)
        .accessibilityHint(showsEarlier ? "Hides the earlier entry" : "Shows the earlier entry")
    }

    private func content(_ found: SimilarEntry.Match) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // One row when it fits; at large text sizes the note wraps and View drops below it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    icon
                    note(found).lineLimit(1)
                    Text("·").accessibilityHidden(true)
                    viewButton
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        icon
                        note(found).fixedSize(horizontal: false, vertical: true)
                    }
                    viewButton.padding(.leading, DS.Space.lg)
                }
            }
            if showsEarlier {
                Text(SimilarEntry.detail(found.entry))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Space.lg)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
    }
}
