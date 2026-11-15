import SwiftUI

/// Which Logbook row is open, and how far open it is (docs/Redesign.md §7.2, rules in
/// `LogbookRowExpand`). Observable rather than view state so that only the card redraws while it
/// moves or follows a drag: the list reads `openID` and `style`, never `progress`.
@Observable @MainActor
final class LogbookRowOpener {
    private(set) var openID: UUID?
    /// 0 is the row, 1 the open card. Animated by a spring, so it can be turned round mid-flight.
    private(set) var progress: Double = 0
    private(set) var style: LogbookRowExpand.Style = .matched

    /// Where each visible row is on screen, in global coordinates. Not observed: rows move every
    /// frame while the list scrolls, and that must never redraw anything. Read when a row opens
    /// or closes.
    @ObservationIgnored var frames: [UUID: CGRect] = [:]
    /// Something to do once the card is back in its row (delete, log again), so the list only
    /// moves after the card has landed where the row was.
    @ObservationIgnored private var afterClose: (() -> Void)?
    /// Bumped on every open, close and reopen, so a close that was overtaken doesn't finish late.
    @ObservationIgnored private var generation = 0

    var isOpen: Bool { openID != nil }

    private var animation: Animation {
        switch style {
        case .matched: return .spring(response: 0.44, dampingFraction: 0.84)
        case .crossFade: return .easeInOut(duration: 0.25)
        }
    }

    func open(_ id: UUID, reduceMotion: Bool) {
        guard openID == nil else { return }
        let style = LogbookRowExpand.Style(reduceMotion: reduceMotion)
        // No frame yet (it hasn't been laid out): fade in place rather than grow from nowhere.
        self.style = frames[id] == nil ? .crossFade : style
        generation += 1
        progress = 0
        openID = id
        // On the next turn, once the card has been drawn over the row at 0, so it grows from there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openID == id else { return }
            withAnimation(self.animation) { self.progress = 1 }
        }
    }

    /// Shrinks the card back into its row, then runs `then`. Opening again before it lands cancels both.
    func close(then action: (() -> Void)? = nil) {
        guard openID != nil else { action?(); return }
        afterClose = action
        generation += 1
        let mine = generation
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            progress = 0
        } completion: { [weak self] in
            self?.finishClose(mine)
        }
    }

    /// Back to open, after a drag that didn't go far enough or a tap mid-close.
    func reopen() {
        guard openID != nil else { return }
        afterClose = nil
        generation += 1
        withAnimation(animation) { progress = 1 }
    }

    /// The card under the finger while it's dragged down. Only the matched style moves.
    func follow(_ value: Double) {
        guard openID != nil, style == .matched else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { progress = value }
    }

    /// The entry has gone (deleted on the Mac, undone) or its row is no longer listed: no row to
    /// shrink into, so the card just goes.
    func dismiss() {
        guard openID != nil else { return }
        generation += 1
        afterClose = nil
        withAnimation(.easeOut(duration: 0.2)) {
            openID = nil
            progress = 0
        }
    }

    private func finishClose(_ mine: Int) {
        guard mine == generation, progress <= 0 else { return }
        openID = nil
        let action = afterClose
        afterClose = nil
        action?()
    }
}

extension View {
    /// Keeps the opener told where this row is, without redrawing anything.
    func logbookRowFrame(_ id: UUID, in opener: LogbookRowOpener) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { opener.frames[id] = $0 }
    }
}

/// An opened Logbook row: the row's own line at the top, then everything the entry has, and Edit,
/// Log Again and Delete. Drawn over the list, growing out of the row and shrinking back into it.
struct PhoneLogbookDetail: View {
    let entry: LogEntry
    let site: InjectionSite?
    /// The Logbook search's words, picked out here as they are in the row.
    let terms: [String]
    let opener: LogbookRowOpener
    let onEdit: () -> Void
    let onLogAgain: () -> Void
    let onDelete: () -> Void

    /// The open card's natural height, from a hidden copy laid out at the open width.
    @State private var contentHeight: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            let size = proxy.size
            let matched = opener.style == .matched
            let rowGlobal = opener.frames[entry.id]
            let row = rowGlobal.map { $0.offsetBy(dx: -global.minX, dy: -global.minY) }
            // Without a row to grow from, the card opens where the row would have been: centred.
            let anchor = row ?? CGRect(x: LogbookRowExpand.margin, y: size.height / 3,
                                       width: max(0, size.width - 2 * LogbookRowExpand.margin), height: 44)
            let open = LogbookRowExpand.openFrame(row: anchor, contentHeight: contentHeight, in: size)
            let width = Double(open.width)
            let room = Double(size.height) - 2 * LogbookRowExpand.margin
            ZStack(alignment: .topLeading) {
                ExpandScrim(progress: opener.progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { opener.close() }
                    .accessibilityHidden(true)
                ExpandingCard(progress: opener.progress, row: matched && row != nil ? anchor : open,
                              open: open, fades: !matched || row == nil) { p in
                    card(progress: p, scrolls: contentHeight > room)
                }
                .gesture(drag)
                // The measuring copy: never seen, never touched, never read out.
                content(progress: 1, scrolls: false)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { contentHeight = $0 }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                opener.follow(LogbookRowExpand.dragProgress(translation: Double(v.translation.height)))
            }
            .onEnded { v in
                if LogbookRowExpand.closesOnRelease(translation: Double(v.translation.height),
                                                    predictedEnd: Double(v.predictedEndTranslation.height)) {
                    opener.close()
                } else {
                    opener.reopen()
                }
            }
    }

    private func card(progress p: Double, scrolls: Bool) -> some View {
        content(progress: p, scrolls: scrolls)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { opener.close() }
    }

    private var tint: Color { entry.part.logbookTint }

    @ViewBuilder
    private func content(progress p: Double, scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The row's own line, where it was in the list, with its chevron turning to point down.
            Button { opener.close() } label: {
                PhoneLogRow(entry: entry, site: site, highlight: terms, chevronTurn: p)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Close")
            if scrolls {
                ScrollView { details }
                    .scrollBounceBehavior(.basedOnSize)
                    .opacity(LogbookRowExpand.detailOpacity(progress: p))
            } else {
                details
                    .opacity(LogbookRowExpand.detailOpacity(progress: p))
            }
        }
        .padding(LogbookRowExpand.inset(progress: p))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(LogbookEntryDetail.when(entry.timestamp, now: ctx.date))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            let lines = LogbookEntryDetail.lines(entry, site: site)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in lineView(line) }
                }
            }
            actions
        }
        .padding(.top, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineView(_ line: LogbookEntryDetail.Line) -> some View {
        let words = line.searchable ? terms : []
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(SearchHighlight.attributed(line.label, terms: words, tint: tint))
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.md)
                Text(SearchHighlight.attributed(line.value, terms: words, tint: tint))
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(SearchHighlight.attributed(line.label, terms: words, tint: tint))
                    .foregroundStyle(.secondary)
                Text(SearchHighlight.attributed(line.value, terms: words, tint: tint))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsFont(.callout)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: DS.Space.sm) {
            action("Edit", systemImage: "pencil", tint: tint, action: onEdit)
            action("Log Again", systemImage: "arrow.clockwise", tint: tint, action: onLogAgain)
            action("Delete", systemImage: "trash", tint: Tone.critical.color, action: onDelete)
        }
        .padding(.top, DS.Space.xs)
    }

    private func action(_ title: String, systemImage: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .dsFont(.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.sm)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The list dimming behind the card. Its own view so it follows the animated progress too.
private struct ExpandScrim: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Color.black.opacity(LogbookRowExpand.scrim(progress: progress))
    }
}

/// The card at one frame of its way between the row and open. SwiftUI hands it each in-between
/// progress, so the frame, corners, padding and detail fade are worked out per frame from the
/// same value; turning the spring round mid-flight carries all of them round together.
private struct ExpandingCard<Content: View>: View, Animatable {
    var progress: Double
    let row: CGRect
    let open: CGRect
    /// Reduce Motion (or no row to grow from): sit at the open frame and fade.
    let fades: Bool
    @ViewBuilder let content: (Double) -> Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let shown = fades ? 1 : progress
        let clamped = LogbookRowExpand.clamped(shown)
        let f = LogbookRowExpand.frame(row: row, open: open, progress: shown)
        let shape = RoundedRectangle(cornerRadius: LogbookRowExpand.corner(progress: shown), style: .continuous)
        content(shown)
            .frame(width: f.width, height: f.height, alignment: .top)
            // The list row's colour at the row, the raised card's once open.
            .background {
                Color(uiColor: .systemBackground)
                    .overlay(Color(uiColor: .tertiarySystemBackground).opacity(clamped))
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.16 * clamped), radius: 22 * clamped, y: 8 * clamped)
            .opacity(fades ? LogbookRowExpand.clamped(progress) : 1)
            .offset(x: f.minX, y: f.minY)
    }
}
