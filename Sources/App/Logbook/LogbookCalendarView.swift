import SwiftUI

/// The compact month calendar the Logbook jumps from: a day header tapped on iPhone, ⌘J or the
/// calendar button on the Mac. Days with nothing logged are dimmed and can't be picked; today is
/// ringed; the day the list is on is filled. Months step with the chevrons (a slide, or a fade under
/// Reduce Motion), from the first month with an entry up to this one. Rules in `LogbookCalendar`.
///
/// Round 86 motion (`LogbookCalendarMotion`): a sideways swipe or drag steps the month too, the grid
/// following the finger (a rubber band towards a month it can't show). Each day's circle washes in
/// tinted by that day's time in range, in the Logbook day bars' range colours, one after another
/// from the 1st; VoiceOver says the share, so the colour never carries it alone. The selected day's
/// mark springs in with a ring around it. Under Reduce Motion the grid cross-fades, tints simply
/// fade in together and the mark fades, nothing slides or springs.
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
    /// Each of the given days' time in range (`DayInRange.compute`), asked once per month shown.
    var ranges: (([Date]) -> [Date: DayInRange])?

    /// Time in range for the months worked out so far, by local midnight.
    @State private var figures: [Date: DayInRange] = [:]
    @State private var figuredMonths: Set<Date> = []
    /// Where the grid sits while being dragged sideways.
    @State private var dragOffset: CGFloat = 0

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

    init(counts: [Date: Int], current: Date?, compare: LogbookCalendarCompare? = nil,
         ranges: (([Date]) -> [Date: DayInRange])? = nil, pick: @escaping (Date) -> Void) {
        self.counts = counts
        self.current = current
        self.pick = pick
        self.compare = compare
        self.ranges = ranges
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
                ForEach(Array(grid.cells.enumerated()), id: \.element.id) { i, cell in
                    dayCell(cell, index: i, selected: cell.day == currentDay, now: now)
                }
            }
            .offset(x: dragOffset)
            .id("\(grid.month.timeIntervalSince1970)-\(comparing)")
            .transition(slide)
            .onAppear { figure(grid) }
            .contentShape(Rectangle())
            .gesture(swipe(grid))
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

    /// Works out the shown month's time in range once, so the tints wash in as it arrives.
    private func figure(_ grid: LogbookCalendar) {
        guard let ranges, !figuredMonths.contains(grid.month) else { return }
        figuredMonths.insert(grid.month)
        let found = ranges(grid.cells.filter { !$0.isFuture }.map(\.day))
        guard !found.isEmpty else { return }
        figures.merge(found) { _, new in new }
    }

    /// A sideways drag follows the finger and, let go far enough, steps the month the way it went.
    private func swipe(_ grid: LogbookCalendar) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !reduceMotion, abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = LogbookCalendarMotion.dragOffset(width: value.translation.width,
                                                              hasEarlier: grid.hasEarlier, hasLater: grid.hasLater)
            }
            .onEnded { value in
                let by = LogbookCalendarMotion.swipeStep(width: value.translation.width,
                                                         height: value.translation.height,
                                                         hasEarlier: grid.hasEarlier, hasLater: grid.hasLater)
                if by != 0 {
                    step(by)
                    #if os(iOS)
                    Haptics.play(.choice)
                    #endif
                } else if dragOffset != 0 {
                    withAnimation(DSMotion.emphasized.animation) { dragOffset = 0 }
                }
            }
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
            Text(comparing ? DayCompareText.calendarFootnote
                 : ranges == nil ? "Dimmed days have nothing logged" : LogbookCalendarText.footnote)
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
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

    private func dayCell(_ cell: LogbookCalendar.Cell, index: Int, selected: Bool, now: Date) -> some View {
        // Comparing, the day it was opened from is shown filled but can't be picked against itself.
        let canPick = cell.canPick && !(comparing && selected)
        let dayFigures = cell.isFuture ? nil : figures[cell.day]
        let tint = cell.canPick ? LogbookCalendarMotion.tint(dayFigures) : nil
        let wash: Animation = reduceMotion ? .easeInOut(duration: 0.2)
            : .easeOut(duration: 0.3).delay(LogbookCalendarMotion.revealDelay(index: index))
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
                        SelectedDayMark(size: cellSize - 4)
                    } else if cell.canPick {
                        ZStack {
                            Circle().fill(Palette.brand.opacity(0.12))
                                .opacity(tint == nil ? 1 : 0)
                            Circle().fill(Self.color(tint?.band ?? .inRange).opacity(tint?.strength ?? 0))
                                .opacity(tint == nil ? 0 : 1)
                        }
                        .animation(wash, value: tint)
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
        .accessibilityLabel(comparing ? DayCompareText.calendarSpoken(cell, isFrom: selected, now: now)
                                      : LogbookJump.spoken(cell, now: now, figures: dayFigures))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The Logbook day bars' range colours (`DayRangeBar`).
    static func color(_ band: LogbookCalendarMotion.Band) -> Color {
        switch band {
        case .below: return GlucoseRange.low.tint
        case .inRange: return GlucoseRange.inRange.tint
        case .above: return GlucoseRange.high.tint
        }
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
            dragOffset = 0
        }
    }
}

enum LogbookCalendarText {
    static let footnote = "Colour shows each day's time in range. Dimmed days have nothing logged"
}

/// The selected day: a filled circle with a ring around it that springs in when its month shows
/// (each month's grid is built afresh, so stepping back to it plays it again), and just fades in
/// under Reduce Motion.
private struct SelectedDayMark: View {
    let size: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Palette.brand)
                .padding(2.5)
            Circle().strokeBorder(Palette.brand, lineWidth: 1.5)
                .scaleEffect(shown || reduceMotion ? 1 : 1.45)
        }
        .frame(width: size, height: size)
        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2)
                          : .spring(response: 0.42, dampingFraction: 0.58).delay(0.08)) { shown = true }
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
