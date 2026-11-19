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
                    let unit = store.shownUnit
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
        .accessibilityHint("Opens time in range by day, week in review, lows, highs, alerts, overnight, weekdays and weekends, your usual day, time in range by hour, mornings, forecast accuracy and sensor coverage")
    }
}

/// How things have been going: time in range over 24 hours to 14 days, each of the last seven
/// days side by side, this week against last, lows and when they start, time above range and the longest high, how the nights go, weekdays against weekends, the usual day by time of day, time in range hour by hour, what GlucOS has learnt about mornings, and how its forecasts turned out.
struct PhoneInsightsView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings
    /// Opened from the evening recap notification: its Today card goes on top (docs/EveningRecap.md).
    var recapFiredAt: Date? = nil
    /// The person's order and hidden cards for the iPhone screen (docs/InsightsLayout.md). Kept in
    /// the logbook, so it syncs to their other iPhones and comes back after a reinstall.
    private var layout: InsightsLayout { logbook.insightsLayout(for: .phone) }
    private var layoutBinding: Binding<InsightsLayout> {
        Binding(get: { logbook.insightsLayout(for: .phone) },
                set: { logbook.saveInsightsLayout($0, for: .phone) })
    }
    @State private var editing = false
    /// Cards that have risen in on this visit, so going to Edit and back, or a re-sort, never
    /// plays them again.
    @State private var reveals = CardReveals()
    /// The card whose picture is being shared (docs/InsightsShare.md).
    @State private var sharing: InsightsCard?
    /// The card lifted on screen while its share sheet gets ready, until the sheet closes.
    @State private var lifted: InsightsCard?
    /// How many periods back the cards are (docs/InsightsPeriodStep.md). Latest each visit.
    @State private var step = InsightsStep.latest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let defaults = InsightsCard.phoneDefault

    var body: some View {
        ZStack {
            if editing {
                PhoneInsightsEditList(layout: layoutBinding, defaults: defaults, change: change)
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
        .sheet(item: $sharing, onDismiss: settle) { card in
            InsightsSharePreview(card: card,
                                 period: InsightsShare.period(for: card, firstReading: store.archive.first?.timestamp),
                                 content: AnyView(view(for: card)
                                    .environment(\.insightsStep, step)
                                    .environmentObject(store)
                                    .environmentObject(logbook)
                                    .environmentObject(settings)),
                                 periodEnd: card.stepEnd(step, newestReading: store.archive.last?.timestamp,
                                                         firstReading: store.archive.first?.timestamp))
                .presentationDetents([.large])
        }
    }

    private var cards: some View {
        let visible = layout.visible(defaults).filter(onScreen)
        return ScrollView {
            VStack(spacing: DS.Space.lg) {
                if let recapFiredAt {
                    EveningRecapCardView(readings: store.archive, unit: store.shownUnit,
                                         lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl,
                                         recapMinute: settings.eveningRecapMinute, firedAt: recapFiredAt,
                                         padding: DS.Space.lg)
                        .dsReveal("recap", in: reveals, when: .scrolledIntoView)
                }
                if !visible.isEmpty {
                    // Each card with a period shows how its figures moved from the period before
                    // (docs/InsightsCompare.md).
                    InsightsCompareToggle()
                        .dsFont(.callout)
                        .tint(Palette.brand)
                        .dsCard(.standard, padding: DS.Space.md)
                        .dsEntrance(0)
                    // Which period the cards show, with earlier and later; swiping the screen
                    // sideways does the same (docs/InsightsPeriodStep.md).
                    InsightsStepControl(step: step, canGoEarlier: canGoEarlier, move: move, toLatest: toLatest)
                        .padding(.horizontal, DS.Space.xs)
                        .dsCard(.standard, padding: DS.Space.sm)
                        .dsEntrance(0)
                }
                ForEach(Array(visible.enumerated()), id: \.element) { i, card in
                    // Each card rises in the first time it's scrolled into view on this visit,
                    // with any that come into view alongside it a step behind; its figures
                    // count up and its rings, bars and sparkline draw in as it rises.
                    view(for: card)
                        .dsReveal(card, in: reveals, when: .scrolledIntoView, order: i + (recapFiredAt == nil ? 0 : 1))
                        .insightsShareLift(lifted == card)
                        .contextMenu { menu(card, index: i, count: visible.count) }
                        .accessibilityAction(named: "Share card") { share(card) }
                }
                if visible.contains(.mornings) || visible.contains(.forecastAccuracy) {
                    Text("Mornings and forecast accuracy appear once GlucOS has enough wake-ups and forecasts to report on.")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DS.Space.xs)
                }
                if visible.isEmpty {
                    EmptyStateView(systemImage: "eye.slash", title: "Every card is hidden",
                                   message: "Bring back the cards you want to see, in your own order.",
                                   actionTitle: "Edit Cards", action: { setEditing(true) })
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
        // Cards with a period show the one `step` periods back; their figures roll to it.
        .environment(\.insightsStep, step)
        // A figure that a new reading or a synced entry changes gives one soft pulse as it rolls
        // (`InsightsFigurePulse`); a picker or a period step only rolls it.
        .environment(\.insightsPeriodBack, step.back)
        .environment(\.insightsDataRevision, .init(
            newestReading: store.archive.last?.timestamp, readingCount: store.archive.count,
            loggedCount: logbook.doses.count + logbook.meals.count + logbook.contexts.count + logbook.siteChanges.count))
        // A sideways swipe steps: right for the period before, left for the one after. Clearly
        // sideways only, so scrolling up and down never steps, and not from the screen's left
        // edge, which goes back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard value.startLocation.x > 28,
                          let direction = InsightsPeriodStep.swipeDirection(dx: value.translation.width,
                                                                            dy: value.translation.height)
                    else { return }
                    move(direction)
                }
        )
    }

    private var canGoEarlier: Bool {
        InsightsPeriodStep.canGoEarlier(back: step.back, firstReading: store.archive.first?.timestamp,
                                        latest: store.archive.last?.timestamp)
    }

    /// One period earlier (-1) or later (+1). The figures roll and the captions slide in from the
    /// side the period came from; a light tick each time it moves, nothing at either end.
    private func move(_ direction: Int) {
        let back = InsightsPeriodStep.step(step.back, by: direction, firstReading: store.archive.first?.timestamp,
                                           latest: store.archive.last?.timestamp)
        guard back != step.back else { return }
        Haptics.play(.choice)
        DS.animate(.standard, reduceMotion: reduceMotion) { step = InsightsStep(back: back, direction: direction) }
    }

    private func toLatest() {
        guard step.back > 0 else { return }
        Haptics.play(.choice)
        DS.animate(.standard, reduceMotion: reduceMotion) { step = InsightsStep(back: 0, direction: 1) }
    }

    /// Whether a showing card is on screen now. The Tags card stays out until something carries a
    /// tag, and Alerts until an alert has been recorded; their places in the order are kept.
    private func onScreen(_ card: InsightsCard) -> Bool {
        switch card {
        case .tags: return TagInsightsCardView.shows(logbook.entries)
        case .alerts: return AlertsSummary.shows(logbook.alerts)
        case .sensorCoverage:
            return SensorCoverageCache.shared.shows(readings: store.archive, context: store.gapContext, back: step.back)
        default: return true
        }
    }

    @ViewBuilder
    private func view(for card: InsightsCard) -> some View {
        switch card {
        case .glance: PhoneGlanceCard()
        case .days: PhoneDaysCard()
        case .weekInReview: PhoneWeekInReviewCard()
        case .lows: PhoneLowsCard()
        case .highs: PhoneHighsCard()
        case .alerts: PhoneAlertsCard()
        case .overnight: PhoneOvernightCard()
        case .weekdayWeekend: PhoneWeekdayWeekendCard()
        case .streaks: PhoneInRangeStreaksCard()
        case .bestDays: PhoneBestToughestDaysCard()
        case .tags: PhoneTagInsightsCard()
        case .dayPattern: PhoneDayPatternCard()
        case .hourlyInRange: PhoneHourlyInRangeCard()
        case .mornings: PhoneMorningCard(outlook: store.outlook)
        case .forecastAccuracy: PhoneForecastAccuracyCard(outlook: store.outlook)
        case .sensorCoverage: PhoneSensorCoverageCard()
        }
    }

    /// Lifts the card, then brings up its share sheet a beat later (docs/InsightsShare.md).
    private func share(_ card: InsightsCard) {
        guard sharing == nil else { return }
        withAnimation(InsightsShareLiftMotion.animation(reduceMotion: reduceMotion)) { lifted = card }
        let delay = InsightsShareLift.presentDelay(reduceMotion: reduceMotion)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard lifted == card else { return }
            sharing = card
        }
    }

    /// The sheet closed: the card settles back into the list.
    private func settle() {
        withAnimation(InsightsShareLiftMotion.animation(reduceMotion: reduceMotion)) { lifted = nil }
    }

    /// Touch and hold a card: share it as a picture, move it a place, hide it, or open the full
    /// edit list.
    @ViewBuilder
    private func menu(_ card: InsightsCard, index: Int, count: Int) -> some View {
        Button { share(card) } label: {
            Label("Share Card…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button { change { $0.move(card, by: -1, defaults: defaults, onScreen: onScreen) } } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(index == 0)
        Button { change { $0.move(card, by: 1, defaults: defaults, onScreen: onScreen) } } label: {
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
        var next = layout
        edit(&next)
        withAnimation(InsightsMotion.reorder(reduceMotion: reduceMotion)) {
            logbook.saveInsightsLayout(next, for: .phone)
        }
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

/// This week beside last week, with the best and hardest part of the day (`WeekInReviewView`).
/// Tapping a week zooms the card into the Logbook on that week's 7 days; Back shrinks it home. Both
/// weeks register the card as their zoom source, so whichever was tapped grows from the card.
struct PhoneWeekInReviewCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = WeekInReviewView(readings: store.archive, unit: store.shownUnit,
                                    lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                    openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .thisWeek)), in: navigator.zoom)
                .matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .lastWeek)), in: navigator.zoom)
        } else {
            card
        }
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
                                answers: logbook.lowAnswers, unit: store.shownUnit,
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
        let card = HighsCardView(readings: store.archive, unit: store.shownUnit,
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

/// Low and high alerts over the last 7, 14 or 30 days, by kind and how each ended
/// (`AlertsCardView`). Tapping it zooms the card into Alert History (`PhoneRoute.alertHistory`);
/// Back shrinks it home. A plain push under Reduce Motion. Without the home stack (never expected)
/// it opens Settings on Alerts › Alert History as before.
struct PhoneAlertsCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = AlertsCardView(records: logbook.alerts, readings: store.archive) {
            Haptics.play(.choice)
            if let navigator { navigator.push(.alertHistory) } else { AlertHistoryOpenRequest.shared.open() }
        }
        .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(AlertsCardMotion.sourceID), in: navigator.zoom)
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
        let card = OvernightCardView(readings: store.archive, unit: store.shownUnit,
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
        let card = WeekdayWeekendCardView(readings: store.archive, unit: store.shownUnit,
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

/// Days in a row at 70% or more in range: the run going now, the longest kept, and the last 14 days
/// as dots (`InRangeStreaksCardView`). Tapping it zooms the card into the Logbook on what was logged
/// over the longest run's days; Back shrinks it home.
struct PhoneInRangeStreaksCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = InRangeStreaksCardView(readings: store.archive, unit: store.shownUnit,
                                          lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                          openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .bestStreak)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// The period's best and toughest days by time in range, each a small day chart
/// (`BestToughestDaysCardView`). Tapping either zooms the card into the Logbook on that day; Back
/// shrinks it home.
struct PhoneBestToughestDaysCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = BestToughestDaysCardView(readings: store.archive, entries: logbook.entries, dayNotes: logbook.dayNotes,
                                            unit: store.shownUnit,
                                            lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                            openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card
                .matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .bestDay)), in: navigator.zoom)
                .matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .toughestDay)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// Time in range and the average in the 4 hours after each tag, against every reading over the same
/// days (`TagInsightsCardView`). Tapping a tag zooms the card into the Logbook on that tag's chip;
/// Back shrinks it home. Every tag registers the card as its zoom source.
struct PhoneTagInsightsCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = TagInsightsCardView(readings: store.archive, entries: logbook.entries, unit: store.shownUnit,
                                       lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                       openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } },
                                       // Not in a shared picture, which has no navigator.
                                       log: navigator.map { _ in { PhoneLogRouter.shared.open() } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .tagged)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// Time in range for each hour of the clock as a strip of cells (`HourlyInRangeCardView`). Tapping an
/// hour zooms the card into the Logbook on that hour across the card's days; Back shrinks it home.
struct PhoneHourlyInRangeCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = HourlyInRangeCardView(readings: store.archive, unit: store.snapshot.unit,
                                         lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                         openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .hourOfDay)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// How much of the last 7, 14 or 30 days has readings, and the longest gaps with their reasons
/// (`SensorCoverageCardView`). Shown only while some of the period is missing. Tapping it zooms the
/// card into the Logbook around the longest gap; Back shrinks it home.
struct PhoneSensorCoverageCard: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.phoneNavigator) private var navigator

    var body: some View {
        let card = SensorCoverageCardView(readings: store.archive, context: store.gapContext,
                                          openLogbook: navigator.map { nav in { (link: LogbookLink) in nav.push(.logbookLink(link)) } })
            .dsCard(.standard, padding: DS.Space.lg)
        if let navigator {
            card.matchedTransitionSource(id: AnyHashable(LogbookLink.sourceID(for: .aroundGap)), in: navigator.zoom)
        } else {
            card
        }
    }
}

/// The usual day over the last 14 or 30 days, by time of day (`DayPatternView`).
struct PhoneDayPatternCard: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        DayPatternView(readings: store.archive, unit: store.shownUnit,
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
                .onEntrance {
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
