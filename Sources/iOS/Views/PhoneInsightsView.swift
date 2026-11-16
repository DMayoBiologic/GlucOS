import SwiftUI

/// The home screen's one line about how things have been going: today's time in range with the
/// average, and the way into Insights. Replaces the At a glance, Mornings and Forecast accuracy
/// cards that used to sit in the home stack, so the logbook stays near the top.
struct PhoneInsightsRow: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        NavigationLink(value: PhoneRoute.insights) {
            HStack(spacing: DS.Space.md) {
                if let stats = store.glanceStats(.day) {
                    let unit = store.snapshot.unit
                    TimeInRangeRing(stats: stats, lineWidth: 5, showsLabel: false, drawsIn: true)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Insights").dsFont(.label).foregroundStyle(.secondary)
                        // The share rolls to a new figure, such as after the target range changes.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            RollingFigure(stats.timeInRange) { Format.percent($0) }
                            Text(" in range · avg \(unit.format(mgdl: stats.meanMgdl)) \(unit.label)")
                        }
                        .dsFont(.headline)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .dsLineLimit(1)
                        .minimumScaleFactor(0.8)
                        Text("Last 24 hours").dsFont(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Insights").dsFont(.headline).foregroundStyle(.primary)
                        Text("Time in range, week in review, lows, your usual day, mornings and forecast accuracy")
                            .dsFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Space.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(.standard, padding: DS.Space.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityHint("Opens time in range by day, week in review, lows, highs, overnight, weekdays and weekends, your usual day, mornings and forecast accuracy")
    }
}

/// How things have been going: time in range over 24 hours to 14 days, each of the last seven
/// days side by side, this week against last, lows and when they start, time above range and the longest high, how the nights go, weekdays against weekends, the usual day by time of day, what GlucOS has learnt about mornings, and how its forecasts turned out.
struct PhoneInsightsView: View {
    @EnvironmentObject var store: GlucoseStore
    /// The person's order and hidden cards, kept on this iPhone (docs/InsightsLayout.md). Held in
    /// state so a change animates, and written back on every change.
    @State private var layout = InsightsLayout(stored: UserDefaults.standard.string(forKey: InsightsLayout.phoneKey) ?? "")
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let defaults = InsightsCard.phoneDefault

    var body: some View {
        ZStack {
            if editing {
                PhoneInsightsEditList(layout: $layout, defaults: defaults, change: change)
                    .transition(.opacity)
            } else {
                cards.transition(.opacity)
            }
        }
        .background { PhoneBackdrop(tone: .neutral) }
        .navigationTitle(editing ? "Edit Insights" : "Insights")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { setEditing(!editing) } label: {
                    Text(editing ? "Done" : "Edit").fontWeight(editing ? .semibold : .regular)
                }
                .accessibilityHint(editing ? "Goes back to your cards" : "Reorder or hide the Insights cards")
            }
        }
        .onChange(of: layout) { _, new in
            UserDefaults.standard.set(new.stored, forKey: InsightsLayout.phoneKey)
        }
    }

    private var cards: some View {
        let visible = layout.visible(defaults)
        return ScrollView {
            VStack(spacing: DS.Space.lg) {
                ForEach(Array(visible.enumerated()), id: \.element) { i, card in
                    view(for: card)
                        .dsEntrance(i)
                        .contextMenu { menu(card, index: i, count: visible.count) }
                }
                if visible.contains(.mornings) || visible.contains(.forecastAccuracy) {
                    Text("Mornings and forecast accuracy appear once GlucOS has enough wake-ups and forecasts to report on.")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DS.Space.xs)
                }
                if visible.isEmpty {
                    Text("Every card is hidden. Tap Edit to bring some back.")
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DS.Space.xl)
                }
            }
            // Under Reduce Motion the stack cross-fades to the new order instead of the cards
            // springing past each other.
            .id(reduceMotion ? visible.map(\.rawValue).joined(separator: ",") : "")
            .transition(.opacity)
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.lg)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        // Each card's figures count up as it assembles, with its rings and bars drawing in, and roll
        // from the old figure to the new one when a period changes. Once per appearance, never a
        // loop; still under Reduce Motion.
        .environment(\.figuresCountUp, true)
    }

    @ViewBuilder
    private func view(for card: InsightsCard) -> some View {
        switch card {
        case .glance: PhoneGlanceCard()
        case .days: PhoneDaysCard()
        case .weekInReview: PhoneWeekInReviewCard()
        case .lows: PhoneLowsCard()
        case .highs: PhoneHighsCard()
        case .overnight: PhoneOvernightCard()
        case .weekdayWeekend: PhoneWeekdayWeekendCard()
        case .dayPattern: PhoneDayPatternCard()
        case .mornings: PhoneMorningCard(outlook: store.outlook)
        case .forecastAccuracy: PhoneForecastAccuracyCard(outlook: store.outlook)
        }
    }

    /// Touch and hold a card: move it a place, hide it, or open the full edit list.
    @ViewBuilder
    private func menu(_ card: InsightsCard, index: Int, count: Int) -> some View {
        Button { change { $0.move(card, by: -1, defaults: defaults) } } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(index == 0)
        Button { change { $0.move(card, by: 1, defaults: defaults) } } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(index >= count - 1)
        Button { change { $0.hide(card, defaults: defaults) } } label: {
            Label("Hide \(card.title)", systemImage: "eye.slash")
        }
        Divider()
        Button { setEditing(true) } label: {
            Label("Edit Cards…", systemImage: "slider.horizontal.3")
        }
    }

    /// Springs the cards into their new places; a cross-fade under Reduce Motion.
    private func change(_ edit: (inout InsightsLayout) -> Void) {
        withAnimation(InsightsMotion.reorder(reduceMotion: reduceMotion)) { edit(&layout) }
    }

    private func setEditing(_ on: Bool) {
        withAnimation(InsightsMotion.swap(reduceMotion: reduceMotion)) { editing = on }
    }
}

/// How Insights cards move when they're reordered, hidden or brought back.
enum InsightsMotion {
    /// A spring into the new place; a short cross-fade under Reduce Motion.
    static func reorder(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation
    }

    /// The cards and the edit list swapping.
    static func swap(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.standard.animation
    }
}

/// Edit mode for iPhone Insights: drag handles to reorder the showing cards, a button to hide each,
/// and a Hidden section to bring them back from.
struct PhoneInsightsEditList: View {
    @Binding var layout: InsightsLayout
    let defaults: [InsightsCard]
    let change: ((inout InsightsLayout) -> Void) -> Void

    var body: some View {
        let shown = layout.visible(defaults)
        let hidden = layout.hiddenCards(defaults)
        List {
            Section {
                ForEach(shown) { card in
                    row(card, hidden: false)
                }
                .onMove { from, to in
                    change { $0.moveVisible(fromOffsets: from, toOffset: to, defaults: defaults) }
                }
            } header: {
                Text("Shown")
            } footer: {
                Text("Drag a card by its handle to move it. New cards show here when they arrive.")
            }
            Section {
                if hidden.isEmpty {
                    Text("Cards you hide wait here, ready to bring back.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hidden) { card in
                        row(card, hidden: true)
                    }
                }
            } header: {
                Text("Hidden")
            }
            Section {
                Button("Restore Standard Order") { change { $0 = .standard } }
                    .disabled(layout.isStandard)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private func row(_ card: InsightsCard, hidden: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            Button {
                change { layout in
                    if hidden {
                        layout.restore(card, defaults: defaults)
                    } else {
                        layout.hide(card, defaults: defaults)
                    }
                }
            } label: {
                Image(systemName: hidden ? "plus.circle.fill" : "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, hidden ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(hidden ? "Show \(card.title)" : "Hide \(card.title)")
            Image(systemName: card.systemImage)
                .foregroundStyle(hidden ? Color.secondary : Palette.brand)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(card.title)
                .foregroundStyle(hidden ? .secondary : .primary)
        }
    }
}

/// The last 7 days against the 7 before, with the best and hardest part of the day (`WeekInReviewView`).
struct PhoneWeekInReviewCard: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        WeekInReviewView(readings: store.archive, unit: store.snapshot.unit,
                         lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl)
            .dsCard(.standard, padding: DS.Space.lg)
    }
}

/// Lows over the last 7, 14 or 30 days: how many, how long, treated or not, and when (`LowsCardView`).
/// Tapping it zooms the card into the Logbook on Lows over the same days; Back shrinks it home.
struct PhoneLowsCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = LowsCardView(readings: store.archive, meals: logbook.meals, contexts: logbook.contexts,
                                answers: logbook.lowAnswers, unit: store.snapshot.unit,
                                lowMgdl: store.snapshot.lowMgdl,
                                openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .lows)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// Highs over the last 7, 14 or 30 days: time above range, how many, and the longest (`HighsCardView`).
/// Tapping it zooms the card into the Logbook on Highs over the same days; Back shrinks it home.
struct PhoneHighsCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = HighsCardView(readings: store.archive, unit: store.snapshot.unit,
                                 highMgdl: store.snapshot.highMgdl,
                                 openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .highs)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// Nights over the last 7, 14 or 30 days, midnight to 6 am: time in range, lows, and the usual
/// change across the night (`OvernightCardView`). Tapping it zooms the card into the Logbook on
/// what was logged overnight over the same days; Back shrinks it home.
struct PhoneOvernightCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = OvernightCardView(readings: store.archive, unit: store.snapshot.unit,
                                     lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                     openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .overnight)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// Weekdays beside weekend days over the last 7, 14 or 30 days: time in range, the average and lows
/// (`WeekdayWeekendCardView`). Tapping a side zooms the card into the Logbook on what was logged on
/// those days of the week over the same days; Back shrinks it home. Both sides register the card as
/// their zoom source, so whichever was tapped grows from (and lands back in) the card.
struct PhoneWeekdayWeekendCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = WeekdayWeekendCardView(readings: store.archive, unit: store.snapshot.unit,
                                          lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                          openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .weekdays)), in: navigator.zoom)
                .matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .weekends)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// The usual day over the last 14 or 30 days, by time of day (`DayPatternView`).
struct PhoneDayPatternCard: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        DayPatternView(readings: store.archive, unit: store.snapshot.unit,
                       lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl)
            .dsCard(.standard, padding: DS.Space.lg)
    }
}

/// Each of the last seven days as a column: the share of time below, in and above range stacked
/// to 100%, with the day's time in range under it. Shows at a glance which days went well.
struct PhoneDaysCard: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        DayColumnsCard(days: PhoneDayStats.lastDays(7, readings: store.readings(lastHours: 7 * 24),
                                                    low: store.snapshot.lowMgdl, high: store.snapshot.highMgdl))
    }
}

/// The Day by day columns for any readings: the owner's own, or someone they follow.
struct DayColumnsCard: View {
    let days: [PhoneDayStats]
    var emptyText = "Each day's time in range shows here once GlucOS has a day of readings."
    /// The columns have grown from the baseline (docs/Redesign.md §7.2). App screen only; drawn
    /// grown at once under Reduce Motion.
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: "Day by day", systemImage: "calendar", trailing: "Time in range")
            if days.contains(where: { $0.stats != nil }) {
                HStack(alignment: .bottom, spacing: DS.Space.sm) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { i, day in column(day, order: i) }
                }
                .frame(height: 150)
                .onAppear {
                    guard !grown else { return }
                    if reduceMotion { grown = true } else {
                        // Next frame, so the columns are laid out at the baseline first.
                        DispatchQueue.main.async { grown = true }
                    }
                }
            } else {
                Text(emptyText)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private func column(_ day: PhoneDayStats, order: Int) -> some View {
        VStack(spacing: DS.Space.xs) {
            GeometryReader { geo in
                let h = geo.size.height
                VStack(spacing: 1) {
                    if let s = day.stats {
                        segment(s.timeAboveRange, h: h, color: GlucoseRange.high.tint)
                        segment(s.timeInRange, h: h, color: GlucoseRange.inRange.tint)
                        segment(s.timeBelowRange, h: h, color: GlucoseRange.low.tint)
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
                // New readings (today's column) or a new day: the shares glide to their new
                // heights instead of jumping. Once per change; instant under Reduce Motion.
                .dsAnimation(.emphasized, value: day.stats.map { [$0.timeBelowRange, $0.timeInRange, $0.timeAboveRange] })
                .scaleEffect(y: grown ? 1 : 0.001, anchor: .bottom)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
                    .delay(0.15 + Double(order) * 0.045), value: grown)
            }
            Group {
                if let s = day.stats {
                    // Counts up as its column grows.
                    RollingFigure(s.timeInRange, order: order) { Format.percent($0) }
                } else {
                    Text("–")
                }
            }
            .dsFont(.caption)
            .fontWeight(day.isToday ? .semibold : .regular)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(day.label)
                .dsFont(.caption)
                .foregroundStyle(day.isToday ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                .lineLimit(1)
                // Seven columns of "Mon" at AX5: shrink rather than cut to "M…".
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibility)
    }

    private func segment(_ fraction: Double, h: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(height: max(0, h * fraction - 1))
    }
}

/// One calendar day's readings, for the Day by day card.
struct PhoneDayStats: Identifiable {
    let id: Date
    let label: String
    let isToday: Bool
    let stats: GlucoseStats?

    var accessibility: String {
        let day = isToday ? "Today" : id.formatted(.dateTime.weekday(.wide))
        guard let s = stats else { return "\(day): no readings" }
        return "\(day): \(Format.percent(s.timeInRange)) in range, \(Format.percent(s.timeBelowRange)) below, \(Format.percent(s.timeAboveRange)) above"
    }

    /// The last `count` days, oldest first, ending today. A day with under two hours of readings has
    /// no stats, so a sensor change or a gap doesn't show as a perfect or terrible day.
    static func lastDays(_ count: Int, readings: [GlucoseReading], low: Double, high: Double,
                         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [PhoneDayStats] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [GlucoseReading]] = [:]
        for r in readings { byDay[calendar.startOfDay(for: r.timestamp), default: []].append(r) }
        return (0..<count).reversed().compactMap { back -> PhoneDayStats? in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let rs = byDay[start] ?? []
            let stats = coveredHours(rs) >= 2 ? GlucoseStats.compute(rs, low: low, high: high) : nil
            return PhoneDayStats(id: start, label: back == 0 ? "Today" : start.formatted(.dateTime.weekday(.narrow)),
                                 isToday: back == 0, stats: stats)
        }
    }

    /// Hours actually covered by readings: the time between consecutive readings, skipping any gap
    /// over 30 minutes, so scattered readings hours apart don't count as coverage.
    static func coveredHours(_ readings: [GlucoseReading]) -> Double {
        let times = readings.map(\.timestamp).sorted()
        guard times.count > 1 else { return 0 }
        var covered: TimeInterval = 0
        for (a, b) in zip(times, times.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            if gap <= 30 * 60 { covered += gap }
        }
        return covered / 3600
    }
}
