import SwiftUI

/// What an Insights card shows in place of its figures when it has nothing to show: why, in a
/// sentence, and the one thing that helps (`InsightsEmptyState`, docs/EmptyStates.md). Used by
/// every Insights card on the iPhone and the Mac.
///
/// `decide` runs off the main thread once per `id`, and only while the card is empty. Until it
/// answers, the card's own `waiting` line shows, so nothing blanks or jumps. The words cross-fade
/// to the answer; Reduce Motion swaps them at once. A shared picture of the card leaves the
/// button out.
struct InsightsEmptyNote: View {
    let id: AnyHashable
    /// The card's own `emptyLine`, shown until `decide` answers.
    let waiting: String
    let decide: @Sendable () -> InsightsEmptyState
    /// What the button does. Nil leaves the button out.
    var act: ((InsightsEmptyState.Action) -> Void)?

    @State private var state: InsightsEmptyState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot

    var body: some View {
        Group {
            if let state {
                EmptyStateView(systemImage: state.systemImage, title: state.title, message: state.message,
                               actionTitle: shareSnapshot || act == nil ? nil : state.actionTitle,
                               action: state.action.map { action in { act?(action) } })
                    .environment(\.dsDensity, .compact)
                    .transition(.opacity)
            } else {
                Text(waiting)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .task(id: id) {
            let decide = decide
            let new = await Task.detached(priority: .utility) { decide() }.value
            guard !Task.isCancelled else { return }
            DS.animate(.standard, reduceMotion: reduceMotion) { state = new }
        }
    }
}
