import SwiftUI

/// What Settings search is doing right now: the query, a jump waiting to happen (on the Mac it can
/// cross tabs), and which row is lit. One per Settings screen, shared by its rows through the
/// environment (docs/SettingsSearch.md).
@MainActor
final class SettingsSearchModel: ObservableObject {
    @Published var query = ""
    /// The row a picked result is heading to, until a page scrolls to it.
    @Published var pendingJump: SettingsItem?
    /// The row lit up after a jump, for `SettingsSearch.highlightSeconds`.
    @Published private(set) var highlighted: SettingsAnchor?

    private var clearTask: Task<Void, Never>?

    var isSearching: Bool { !SettingsSearch.queryWords(query).isEmpty }

    func results(in items: [SettingsItem]) -> [SettingsItem] {
        SettingsSearch.results(for: query, in: items)
    }

    /// Light `anchor` briefly. A second jump restarts the clock.
    func flash(_ anchor: SettingsAnchor) {
        clearTask?.cancel()
        highlighted = anchor
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearch.highlightSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlighted = nil
        }
    }

    /// Scroll to `target` once the full list is back, then light it. Instant under Reduce Motion.
    func jump(to target: SettingsAnchor, proxy: ScrollViewProxy, reduceMotion: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearch.jumpDelay * 1_000_000_000))
            DS.animate(.standard, reduceMotion: reduceMotion) { proxy.scrollTo(target, anchor: .center) }
            self.flash(target)
        }
    }
}

private struct SettingsSearchKey: EnvironmentKey {
    static let defaultValue: SettingsSearchModel? = nil
}

extension EnvironmentValues {
    /// The Settings screen's search, if this view is inside one. Optional, so a section shared with
    /// another screen (Diagnostics in follower mode) works without it.
    var settingsSearch: SettingsSearchModel? {
        get { self[SettingsSearchKey.self] }
        set { self[SettingsSearchKey.self] = newValue }
    }
}

/// Marks a Settings row as somewhere search can land: its scroll id, and the brief highlight.
private struct SettingsAnchorModifier: ViewModifier {
    let anchor: SettingsAnchor
    @Environment(\.settingsSearch) private var search

    func body(content: Content) -> some View {
        if let search {
            content.modifier(SettingsAnchorHighlight(anchor: anchor, search: search))
        } else {
            content
        }
    }
}

private struct SettingsAnchorHighlight: ViewModifier {
    let anchor: SettingsAnchor
    @ObservedObject var search: SettingsSearchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lit = search.highlighted == anchor
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.brand.opacity(lit ? 0.18 : 0))
                    .padding(.horizontal, -DS.Space.sm)
                    .padding(.vertical, -DS.Space.xs)
                    .allowsHitTesting(false)
            }
            // Lights quickly, fades slowly. Reduce Motion: on and off with no fade.
            .animation(reduceMotion ? nil : (lit ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.8)), value: lit)
            .id(anchor)
    }
}

extension View {
    /// A row Settings search can scroll to and light up. Apply it to a row, never a Section.
    /// Does nothing outside a Settings screen that set `\.settingsSearch`.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

/// One result: the setting's name with the typed words picked out, and where it lives.
struct SettingsSearchResultRow: View {
    let item: SettingsItem
    let query: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SearchHighlight.attributed(item.title, terms: SettingsSearch.queryWords(query), tint: Palette.brand))
                        .foregroundStyle(.primary)
                    Text(item.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), in \(item.place)")
        .accessibilityHint("Goes to this setting")
    }
}

/// The plain "nothing found" state.
struct SettingsSearchEmptyView: View {
    let query: String

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Matching Settings")
                .font(.headline)
            Text(SettingsSearch.noResultsMessage(for: query))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.lg)
        .accessibilityElement(children: .combine)
    }
}
