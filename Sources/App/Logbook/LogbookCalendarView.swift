import SwiftUI

/// The compact month calendar the Logbook jumps from: a day header tapped on iPhone, ⌘J or the
/// calendar button on the Mac. Days with nothing logged are dimmed and can't be picked; today is
/// ringed; the day the list is on is filled. Months step with the chevrons (a slide, or a fade under
/// Reduce Motion), from the first month with an entry up to this one. Rules in `LogbookCalendar`.
///
/// With `compare`, the footer also offers Compare: the grid then lights the days with readings
/// instead (`DayCompare.readingDays`), the day it was opened from is filled and can't be picked,
/// and picking another day opens the two days compared (`DayCompareView`). The switch cross-fades,
/// at once under Reduce Motion, and VoiceOver hears the prompt.
struct LogbookCalendarView: View {
    /// Entries per local day (`LogbookCalendar.counts`).
    let counts: [Date: Int]
    /// The day the list is on, filled in the grid.
    let current: Date?
    /// A day was picked (always one with entries).
    let pick: (Date) -> Void
    /// Offers comparing the day it was opened from with another (`DayCompare`).
    var compare: LogbookCalendarCompare?

    @State private var comparing = false
    /// Days with readings, worked out the first time compare mode opens.
    @State private var readingDays: [Date: Int]?

    @State private var month: Date
    /// +1 when stepping later, −1 earlier, so the grid slides the way the chevron points.
    @State private var direction = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    private let cellSize: CGFloat = 40
    #else
    private let cellSize: CGFloat = 30
    #endif

    init(counts: [Date: Int], current: Date?, compare: LogbookCalendarCompare? = nil, pick: @escaping (Date) -> Void) {
        self.counts = counts
        self.current = current
        self.pick = pick
        self.compare = compare
        _month = State(initialValue: LogbookCalendar.monthStart(of: compare?.from ?? current ?? Date()))
        if let compare, compare.startsComparing {
            _comparing = State(initialValue: true)
            _readingDays = State(initialValue: compare.days())
        }
    }

    private var shownCounts: [Date: Int] { comparing ? (readingDays ?? [:]) : counts }

    private var selectedDay: Date? {
        let d = comparing ? compare?.from : current
        return d.map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
    }

    var body: some View {
        let now = Date()
        let grid = LogbookCalendar.month(month, counts: shownCounts, now: now)
        let currentDay = selectedDay
        VStack(spacing: DS.Space.sm) {
            if comparing, let compare {
                Text(DayCompareText.prompt(spokenDay: compare.spokenDay))
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: cellSize * 7, alignment: .leading)
                    .transition(.opacity)
            }
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
            .id("\(grid.month.timeIntervalSince1970)-\(comparing)")
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
            Text(comparing ? DayCompareText.calendarFootnote : "Dimmed days have nothing logged")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.md)
            if compare != nil {
                Button(comparing ? "Back" : DayCompareText.calendarButton) { toggleComparing() }
                    .dsFont(.label)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.brand)
                    .accessibilityLabel(comparing ? "Back to Jump to a Date" : DayCompareText.menuName)
                    .accessibilityHint(comparing ? "Picks a day to jump to" : "Picks a second day to compare with this one")
            }
            if !comparing, let latest = LogbookCalendar.latestDay(counts) {
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
        // Comparing, the day it was opened from is shown filled but can't be picked against itself.
        let canPick = cell.canPick && !(comparing && selected)
        return Button { choose(cell.day) } label: {
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
        .disabled(!canPick)
        .accessibilityLabel(LogbookJump.spoken(cell, now: now))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ day: Date) {
        if comparing, let compare { compare.pick(day) } else { pick(day) }
    }

    /// Switches between jumping and comparing: the grid cross-fades to the other days lit, at once
    /// under Reduce Motion, and VoiceOver hears what to pick.
    private func toggleComparing() {
        if readingDays == nil, let compare { readingDays = compare.days() }
        direction = 0
        let turnOn = !comparing
        if reduceMotion { comparing = turnOn } else {
            withAnimation(DSMotion.standard.animation) { comparing = turnOn }
        }
        if turnOn, let compare {
            LoggedElsewhere.announce(DayCompareText.prompt(spokenDay: compare.spokenDay))
        }
    }

    private func step(_ by: Int) {
        direction = by
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.standard.animation) {
            month = LogbookCalendar.shifted(month, by: by)
        }
    }
}

/// What the calendar needs to offer comparing two days (`DayCompare`).
struct LogbookCalendarCompare {
    /// The day the calendar was opened from, compared with the day picked.
    let from: Date
    /// That day as VoiceOver says it ("Today", "Tuesday 12 November").
    let spokenDay: String
    /// Days with enough readings (`DayCompare.readingDays`), worked out only if compare mode opens.
    let days: () -> [Date: Int]
    /// The second day was picked.
    let pick: (Date) -> Void
    /// Opens straight into compare mode (from a day's Compare with Another Day menu item).
    var startsComparing = false
}
