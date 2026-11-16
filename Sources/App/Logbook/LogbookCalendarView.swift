import SwiftUI

/// The compact month calendar the Logbook jumps from: a day header tapped on iPhone, ⌘J or the
/// calendar button on the Mac. Days with nothing logged are dimmed and can't be picked; today is
/// ringed; the day the list is on is filled. Months step with the chevrons (a slide, or a fade under
/// Reduce Motion), from the first month with an entry up to this one. Rules in `LogbookCalendar`.
struct LogbookCalendarView: View {
    /// Entries per local day (`LogbookCalendar.counts`).
    let counts: [Date: Int]
    /// The day the list is on, filled in the grid.
    let current: Date?
    /// A day was picked (always one with entries).
    let pick: (Date) -> Void

    @State private var month: Date
    /// +1 when stepping later, −1 earlier, so the grid slides the way the chevron points.
    @State private var direction = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    private let cellSize: CGFloat = 40
    #else
    private let cellSize: CGFloat = 30
    #endif

    init(counts: [Date: Int], current: Date?, pick: @escaping (Date) -> Void) {
        self.counts = counts
        self.current = current
        self.pick = pick
        _month = State(initialValue: LogbookCalendar.monthStart(of: current ?? Date()))
    }

    var body: some View {
        let now = Date()
        let grid = LogbookCalendar.month(month, counts: counts, now: now)
        let currentDay = current.map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
        VStack(spacing: DS.Space.sm) {
            header(grid)
            HStack(spacing: 0) {
                ForEach(Array(grid.weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: cellSize)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<grid.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: cellSize, height: cellSize)
                        .accessibilityHidden(true)
                }
                ForEach(grid.cells) { cell in
                    dayCell(cell, selected: cell.day == currentDay, now: now)
                }
            }
            .id(grid.month)
            .transition(slide)
            footer
        }
        .padding(DS.Space.md)
        .fixedSize()
    }

    private var slide: AnyTransition {
        guard !reduceMotion, direction != 0 else { return .opacity }
        let edge: Edge = direction > 0 ? .trailing : .leading
        return .asymmetric(insertion: .move(edge: edge).combined(with: .opacity),
                           removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity))
    }

    private func header(_ grid: LogbookCalendar) -> some View {
        HStack {
            Text(grid.title)
                .dsFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.md)
            Group {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .disabled(!grid.hasEarlier)
                    .accessibilityLabel("Previous month")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .disabled(!grid.hasLater)
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brand)
            .contentShape(Rectangle())
        }
    }

    private var footer: some View {
        HStack {
            Text("Dimmed days have nothing logged")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: DS.Space.md)
            if let latest = LogbookCalendar.latestDay(counts) {
                Button("Latest") { pick(latest) }
                    .dsFont(.label)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.brand)
                    .accessibilityHint("Goes to the newest day with entries")
            }
        }
        .frame(width: cellSize * 7)
    }

    private func dayCell(_ cell: LogbookCalendar.Cell, selected: Bool, now: Date) -> some View {
        Button { pick(cell.day) } label: {
            Text("\(cell.number)")
                .dsFont(.body)
                .monospacedDigit()
                .fontWeight(cell.canPick ? .semibold : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(Color.white)
                                 : cell.canPick ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                 : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                .frame(width: cellSize - 4, height: cellSize - 4)
                .background {
                    if selected {
                        Circle().fill(Palette.brand)
                    } else if cell.canPick {
                        Circle().fill(Palette.brand.opacity(0.12))
                    }
                }
                .overlay {
                    if cell.isToday && !selected { Circle().strokeBorder(Palette.brand, lineWidth: 1.5) }
                }
                .frame(width: cellSize, height: cellSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!cell.canPick)
        .accessibilityLabel(LogbookJump.spoken(cell, now: now))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func step(_ by: Int) {
        direction = by
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.standard.animation) {
            month = LogbookCalendar.shifted(month, by: by)
        }
    }
}
