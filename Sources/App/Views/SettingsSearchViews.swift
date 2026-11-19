import SwiftUI

/// What Settings search is doing right now: the query, a jump waiting to happen (on the Mac it can
/// cross tabs), and which row is lit. One per Settings screen, shared by its rows through the
/// environment (docs/SettingsSearch.md).
@MainActor
final class SettingsSearchModel: ObservableObject {
    @Published var query = "" {
        didSet { noteResults() }
    }
    /// The row a picked result is heading to, until a page scrolls to it.
    @Published var pendingJump: SettingsItem?
    /// The row lit up after a jump, for `SettingsSearch.highlightSeconds`.
    @Published private(set) var highlighted: SettingsAnchor?

    /// Bumped on every landing, so the landed row springs and its section's icon bounces even when
    /// the same row is picked twice in a row.
    @Published private(set) var landings = 0
    /// How many times each section's header icon has bounced, by the section's title.
    @Published private(set) var sectionBounces: [String: Int] = [:]

    /// The Settings rows this screen searches (`SettingsCatalog.phone` or `.mac`).
    let catalog: [SettingsItem]
    private var clearTask: Task<Void, Never>?
    /// What the query found last time, so only rows the latest typing adds come in.
    private var listed: [SettingsAnchor] = []
    /// When each newly found row starts coming in (`SettingsSearchMotion.entranceDelays`). A row
    /// takes its delay as it appears, so scrolling it out and back never plays it again. Not
    /// published: it's read as rows appear, never drawn.
    private var entranceDelays: [SettingsAnchor: Double] = [:]

    init(catalog: [SettingsItem]) {
        self.catalog = catalog
    }

    var isSearching: Bool { !SettingsSearch.queryWords(query).isEmpty }

    /// What the current query finds, best first.
    var found: [SettingsItem] { SettingsSearch.results(for: query, in: catalog) }

    private func noteResults() {
        let now = found.map(\.anchor)
        entranceDelays = SettingsSearchMotion.entranceDelays(from: listed, to: now)
        listed = now
    }

    /// The delay before a row newly found by the latest typing comes in, once; nil for a row that
    /// was already listed, or that has already come in.
    func takeEntranceDelay(_ anchor: SettingsAnchor) -> Double? {
        entranceDelays.removeValue(forKey: anchor)
    }

    /// Whether `anchor` is waiting to come in, so its first frame starts hidden.
    func isEntering(_ anchor: SettingsAnchor) -> Bool { entranceDelays[anchor] != nil }

    /// A landed row's section: bounce its header icon once.
    func bounceSection(_ title: String) {
        sectionBounces[title, default: 0] += 1
    }

    /// Light `anchor` briefly. A second jump restarts the clock.
    func flash(_ anchor: SettingsAnchor) {
        clearTask?.cancel()
        highlighted = anchor
        landings += 1
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearch.highlightSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlighted = nil
        }
    }

    /// Scroll to `target` once the full list is back, then light it. The scroll springs, so the row
    /// settles into view; instant under Reduce Motion.
    func jump(to target: SettingsAnchor, proxy: ScrollViewProxy, reduceMotion: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearch.jumpDelay * 1_000_000_000))
            DS.animate(.emphasized, reduceMotion: reduceMotion) { proxy.scrollTo(target, anchor: .center) }
            self.flash(target)
        }
    }
}

private struct SettingsSearchKey: EnvironmentKey {
    static let defaultValue: SettingsSearchModel? = nil
}

private struct SettingsSectionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The Settings screen's search, if this view is inside one. Optional, so a section shared with
    /// another screen (Diagnostics in follower mode) works without it.
    var settingsSearch: SettingsSearchModel? {
        get { self[SettingsSearchKey.self] }
        set { self[SettingsSearchKey.self] = newValue }
    }

    /// The title of the Settings section this row is in (`.settingsSection(_:)`), so a jump that
    /// lands here can bounce that section's header icon.
    var settingsSection: String? {
        get { self[SettingsSectionKey.self] }
        set { self[SettingsSectionKey.self] = newValue }
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
    @Environment(\.settingsSection) private var section
    /// Grown for a moment as a jump lands here, then sprung back.
    @State private var popped = false

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
            // The row and its wash grow together.
            .scaleEffect(popped ? SettingsSearchMotion.landingScale : 1)
            .onChange(of: search.landings) { _, _ in
                guard search.highlighted == anchor else { return }
                landed()
            }
            .id(anchor)
    }

    /// The row springs once as it settles into view, and its section's icon bounces. Under Reduce
    /// Motion the row holds still (the icon's bounce is removed by `symbolBounce` too).
    /// Both wait for the scroll's spring to bring the row on screen.
    private func landed() {
        guard !reduceMotion else {
            if let section { search.bounceSection(section) }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearchMotion.landingDelay * 1_000_000_000))
            if let section { search.bounceSection(section) }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { popped = true }
            try? await Task.sleep(nanoseconds: UInt64(SettingsSearchMotion.landingHold * 1_000_000_000))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { popped = false }
        }
    }
}

extension View {
    /// A row Settings search can scroll to and light up. Apply it to a row, never a Section.
    /// Does nothing outside a Settings screen that set `\.settingsSearch`.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }

    /// Names the Settings section for its rows: apply it to a Section whose header is a
    /// `SettingsSectionHeader` with the same title, so a jump to one of its rows bounces the icon.
    func settingsSection(_ title: String) -> some View {
        environment(\.settingsSection, title)
    }

    /// A search result coming in: fades and rises into place on its turn as the typing finds it.
    /// Rows that were already listed hold still. Instant under Reduce Motion.
    func settingsResultEntrance(_ anchor: SettingsAnchor, search: SettingsSearchModel) -> some View {
        modifier(SettingsResultEntrance(anchor: anchor, search: search))
    }
}

/// A Settings section's header: its icon and title. The icon bounces once when a search jump lands
/// in the section (`.settingsSection` with the same title), and never otherwise.
struct SettingsSectionHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let trailing: Trailing

    init(_ title: String, systemImage: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    @Environment(\.settingsSearch) private var search

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                if let search {
                    SettingsSectionIcon(systemImage: systemImage, title: title, search: search)
                } else {
                    Image(systemName: systemImage)
                }
            }
            trailing
        }
    }
}

extension SettingsSectionHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

private struct SettingsSectionIcon: View {
    let systemImage: String
    let title: String
    @ObservedObject var search: SettingsSearchModel

    var body: some View {
        Image(systemName: systemImage)
            .symbolBounce(on: search.sectionBounces[title, default: 0])
            .accessibilityHidden(true)
    }
}

private struct SettingsResultEntrance: ViewModifier {
    let anchor: SettingsAnchor
    let search: SettingsSearchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until the row has appeared: until then, a row waiting to come in starts hidden.
    @State private var shown: Bool?

    func body(content: Content) -> some View {
        let visible = shown ?? (reduceMotion || !search.isEntering(anchor))
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : SettingsSearchMotion.rowRise)
            .onAppear {
                guard shown == nil else { return }
                guard let delay = search.takeEntranceDelay(anchor), !reduceMotion else {
                    shown = true
                    return
                }
                shown = false
                withAnimation(.smooth(duration: SettingsSearchMotion.rowEntrance).delay(delay)) { shown = true }
            }
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
                    // Newly matched words glint once as you type (docs/SettingsSearch.md "Motion").
                    SearchHighlightText(item.title, terms: SettingsSearch.queryWords(query), tint: Palette.brand, flare: true)
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
