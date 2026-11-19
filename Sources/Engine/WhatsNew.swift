import Foundation

// What's New (docs/WhatsNew.md). Updates install on their own (Sparkle on the Mac, TestFlight on
// iPhone), so the first time the app opens on a new version it shows that release's highlights
// once: a sheet on iPhone, a card over the menu bar popover on the Mac. Never on a fresh install,
// never twice for one version, and Settings › About › What's New opens it again any time.
//
// The list of highlights is bundled here, newest first. Each release PR adds its version's entry.

/// One line of a release: a symbol, a short title, and a sentence on what it does.
struct WhatsNewHighlight: Hashable, Sendable, Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { title }
}

/// One release's highlights.
struct WhatsNewRelease: Hashable, Sendable, Identifiable {
    /// "1.73.0": the version that shipped them.
    let version: String
    let highlights: [WhatsNewHighlight]

    var id: String { version }

    /// "1.73": how the sheet names the release. Patch releases share their minor's entry.
    var shortVersion: String {
        guard let v = AppVersion(version) else { return version }
        return v.patch == 0 ? "\(v.major).\(v.minor)" : "\(v.major).\(v.minor).\(v.patch)"
    }
}

/// A dotted version number, compared part by part ("1.10.0" is after "1.9.3").
struct AppVersion: Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Reads "1.73", "1.73.0" or "v1.73.0". Nil for anything else ("?", "", "1.x").
    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

enum WhatsNew {
    /// UserDefaults key: the version whose What's New was last shown (or skipped on a fresh install).
    static let lastSeenKey = "whatsNewLastSeenVersion"
    /// After skipping several updates, only the newest few releases are shown.
    static let maxReleasesShown = 3
    /// How long after launch the sheet waits, so the app's own screen is up first.
    static let launchDelay: TimeInterval = 1.0
    /// Rows rise in one after another, this far apart, each over `riseDuration`. Reduce Motion: no rise.
    static let rowStagger: TimeInterval = 0.06
    static let riseDuration: TimeInterval = 0.35
    static let riseDistance: Double = 12
    /// The stagger stops growing after this many rows, so a long list doesn't keep you waiting.
    static let maxStaggerSteps = 8
    /// Each row's symbol plays its one-shot effect this far into the row's rise, as it settles.
    static let symbolLead: TimeInterval = 0.2
    /// Continue fades in this long after the last row has finished rising, over `continueFade`.
    static let continueGap: TimeInterval = 0.1
    static let continueFade: TimeInterval = 0.25
    /// Under Reduce Motion the rows and Continue simply fade in together, over this.
    static let reduceMotionFade: TimeInterval = 0.25

    enum Decision: Equatable {
        /// Show these releases, newest first, then remember the current version.
        case show([WhatsNewRelease])
        /// Nothing to show (a fresh install, or no highlights for this update): just remember the
        /// current version, so it never comes up for it later.
        case record
        /// Already shown for this version (or a downgrade): leave everything as it is.
        case nothing
    }

    /// What to do on opening the app on `current`.
    ///
    /// - `lastSeen`: the stored version, nil if this install has never stored one.
    /// - `hasUsedBefore`: signed in, following someone, or set up. With no stored version, that
    ///   tells an update from an earlier build (which never stored one) from a fresh install.
    static func decide(current: String, lastSeen: String?, hasUsedBefore: Bool,
                       catalog: [WhatsNewRelease] = WhatsNewCatalog.releases) -> Decision {
        guard let now = AppVersion(current) else { return .nothing }
        if let lastSeen, let seen = AppVersion(lastSeen) {
            guard seen < now else { return .nothing }
            let new = releases(in: catalog, after: seen, upTo: now)
            return new.isEmpty ? .record : .show(Array(new.prefix(maxReleasesShown)))
        }
        // No stored version: a fresh install, or the first update since What's New shipped.
        guard hasUsedBefore, let latest = releases(in: catalog, after: nil, upTo: now).first else { return .record }
        return .show([latest])
    }

    /// What Settings › About › What's New shows: every release up to this version, newest first.
    /// A build whose version isn't in the list (a development build) shows the whole list.
    static func all(current: String, catalog: [WhatsNewRelease] = WhatsNewCatalog.releases) -> [WhatsNewRelease] {
        let sorted = newestFirst(catalog).filter { !$0.highlights.isEmpty }
        guard let now = AppVersion(current) else { return sorted }
        let upTo = releases(in: catalog, after: nil, upTo: now)
        return upTo.isEmpty ? sorted : upTo
    }

    /// The sheet's title: "What's New in GlucOS 1.73", or plain "What's New" for several releases.
    static func title(for releases: [WhatsNewRelease]) -> String {
        releases.count == 1 ? "What's New in GlucOS \(releases[0].shortVersion)" : "What's New in GlucOS"
    }

    /// Delay before row `index` (counting across releases) starts to rise. Zero under Reduce Motion.
    static func riseDelay(row index: Int, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : rowStagger * Double(min(max(index, 0), maxStaggerSteps))
    }

    /// When row `index`'s symbol plays its one-shot effect, or nil under Reduce Motion (no effect).
    static func symbolDelay(row index: Int, reduceMotion: Bool) -> TimeInterval? {
        reduceMotion ? nil : riseDelay(row: index, reduceMotion: false) + symbolLead
    }

    /// When Continue starts to fade in: last, once every row of `rows` has risen. Under Reduce
    /// Motion it fades in with the rows, straight away.
    static func continueDelay(rows: Int, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion, rows > 0 else { return 0 }
        return riseDelay(row: rows - 1, reduceMotion: false) + riseDuration + continueGap
    }

    /// VoiceOver focus moves to the title once the sheet or card has settled on screen.
    static func titleFocusDelay(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.25 : 0.55 }

    /// True while a reading would be hidden behind the sheet when it matters: the automatic sheet
    /// waits for the next opening instead. Settings › About still opens it.
    static func holdsFor(_ range: GlucoseRange?) -> Bool {
        switch range {
        case .urgentLow?, .low?: return true
        default: return false
        }
    }

    /// Releases with a readable version, newest first.
    private static func newestFirst(_ catalog: [WhatsNewRelease]) -> [WhatsNewRelease] {
        var dated: [(release: WhatsNewRelease, version: AppVersion)] = []
        for release in catalog {
            if let version = AppVersion(release.version) { dated.append((release, version)) }
        }
        return dated.sorted { a, b in a.version > b.version }.map { item in item.release }
    }

    /// Releases after `seen` (any, if nil) and no later than `now`, with highlights, newest first.
    private static func releases(in catalog: [WhatsNewRelease], after seen: AppVersion?, upTo now: AppVersion) -> [WhatsNewRelease] {
        newestFirst(catalog).filter { release in
            guard let version = AppVersion(release.version), version <= now, !release.highlights.isEmpty else { return false }
            if let seen { return version > seen }
            return true
        }
    }
}

/// Reads and writes the stored version. Kept apart from the views so the once-per-version rule is
/// tested against a real UserDefaults suite.
struct WhatsNewLaunch {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastSeen: String? { defaults.string(forKey: WhatsNew.lastSeenKey) }

    /// Decides for this opening. A fresh install or an update with nothing to show is remembered
    /// straight away; releases to show come back, and stay unremembered until `markSeen`, so a
    /// sheet that never made it on screen comes back next time.
    func check(current: String, hasUsedBefore: Bool,
               catalog: [WhatsNewRelease] = WhatsNewCatalog.releases) -> [WhatsNewRelease]? {
        switch WhatsNew.decide(current: current, lastSeen: lastSeen, hasUsedBefore: hasUsedBefore, catalog: catalog) {
        case .show(let releases): return releases
        case .record: markSeen(current); return nil
        case .nothing: return nil
        }
    }

    /// Called once the sheet is on screen. Never moves the stored version backwards.
    func markSeen(_ current: String) {
        guard let now = AppVersion(current) else { return }
        if let stored = lastSeen.flatMap({ AppVersion($0) }), stored >= now { return }
        defaults.set(current, forKey: WhatsNew.lastSeenKey)
    }
}

/// The bundled highlights, newest first. Add the new version's entry in each release PR: two or
/// three things people will notice, in plain words, no dosing advice.
enum WhatsNewCatalog {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.91.0", highlights: [
            .init(symbol: "syringe",
                  title: "Forecasts by insulin amount",
                  detail: "We checked how the forecast does after small and larger amounts of rapid insulin, with and without a meal, and kept it as it is for now."),
            .init(symbol: "clock.arrow.circlepath",
                  title: "A note when it looks logged already",
                  detail: "If you logged a similar meal or insulin in the last 10 minutes, say from Siri, the log sheet says so in one line above Log, and View shows that entry. It never stops you logging."),
        ]),
        WhatsNewRelease(version: "1.90.0", highlights: [
            .init(symbol: "list.bullet.below.rectangle",
                  title: "Alert History rows glide",
                  detail: "In Alert History, a new alert slides in at the top and one leaving the last 7 days shrinks away while the rows close up. With Reduce Motion on, rows simply fade in and out."),
            .init(symbol: "chart.bar.xaxis",
                  title: "Your last 7 days, one press away",
                  detail: "Long-press time in range on iPhone Today, or click it in the Mac popover, to see each of the last 7 days as a bar. Tap a day to open it in the Logbook."),
            .init(symbol: "fork.knife",
                  title: "Forecasts on meals logged alone",
                  detail: "We checked how the forecast does after a meal logged on its own, without insulin logged close to it, and kept it as it is for now."),
        ]),
        WhatsNewRelease(version: "1.89.0", highlights: [
            .init(symbol: "clock.badge.questionmark",
                  title: "Honest hours on days with gaps",
                  detail: "When readings cover only part of a Logbook day, its hours in range show as estimates, and under half a day only the percentages show."),
            .init(symbol: "hand.draw",
                  title: "Swipe actions follow your finger",
                  detail: "On iPhone, swipe a Logbook entry and its Log Again or Delete icon grows in as you drag, with a soft tick where letting go deletes or leaves Log Again open to tap. Log Again only logs when you tap it. With Reduce Motion on, the icon simply appears."),
            .init(symbol: "arrow.down.right",
                  title: "Forecasts on fast falls in range",
                  detail: "We checked how the forecast and low warnings do when glucose falls fast inside your range, and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.88.0", highlights: [
            .init(symbol: "cursorarrow.motionlines",
                  title: "Insights cards lift under the pointer",
                  detail: "On the Mac, an Insights card rises a touch with a soft shadow while the pointer rests on it. With Reduce Motion on, only the shadow fades in."),
            .init(symbol: "chart.bar.doc.horizontal",
                  title: "Each day's time in range, in hours",
                  detail: "Open a Logbook day to see how long it spent below, in and above range. On the Mac, hover over the day to see it."),
            .init(symbol: "scope",
                  title: "How often the range holds",
                  detail: "We checked how often readings land inside the forecast's likely range from 5 minutes to an hour ahead, and kept it as it is for now."),
        ]),
        WhatsNewRelease(version: "1.87.0", highlights: [
            .init(symbol: "contextualmenu.and.cursorarrow",
                  title: "Quick menu picks fill in as shown",
                  detail: "On the Mac, a usual meal picked from the menu bar quick menu now fills the log window with exactly what the menu showed, even if the time of day moved on to the next meal as you picked it."),
            .init(symbol: "hand.draw",
                  title: "Drag the forecast card away",
                  detail: "On iPhone, drag the forecast details card down and it follows your finger, then drops away or springs back. With Reduce Motion on, it simply fades."),
            .init(symbol: "chart.bar.xaxis",
                  title: "Forecasts from low and high readings",
                  detail: "We checked how forecasts do when they start low, in range, high or very high, and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.86.0", highlights: [
            .init(symbol: "contextualmenu.and.cursorarrow",
                  title: "A quick menu in the menu bar",
                  detail: "On the Mac, right-click or Control-click your reading in the menu bar for your usual entries, Log Something, Open Logbook and Settings. A usual opens the log window filled in, ready to check and log."),
            .init(symbol: "moon",
                  title: "A livelier Overnight card",
                  detail: "In Insights, the Overnight card's figures count up and a new bar of time below, in and above range fills in as the card comes into view. Pick another period and they glide to the new nights; with Reduce Motion on, the card simply fades."),
            .init(symbol: "calendar",
                  title: "Forecasts on weekends",
                  detail: "We checked forecasts on weekends against weekdays at each time of day and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.85.0", highlights: [
            .init(symbol: "arrow.up.to.line",
                  title: "Back to today in the Logbook",
                  detail: "Scroll back through the Logbook and a Today button appears at the top of the list on iPhone; tap it to spring back to today. On the Mac, use the Today button in the toolbar or press Command-T."),
            .init(symbol: "number",
                  title: "Averages roll to new readings",
                  detail: "On iPhone Today and in the Mac menu bar, your average and the other summary figures now roll to their new values as each reading arrives, alongside time in range."),
            .init(symbol: "moon.stars",
                  title: "Forecasts after late-evening snacks",
                  detail: "We checked forecasts after carbs logged between 8 pm and midnight and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.84.0", highlights: [
            .init(symbol: "tag",
                  title: "A livelier Tags card",
                  detail: "In Insights, each tag now has a small bar for its time in range that grows in, and tags glide to their new places when you change the period."),
            .init(symbol: "sun.max",
                  title: "Ask Siri how your day went",
                  detail: "Say \u{201C}How was my day in GlucOS\u{201D} on iPhone, or use it in Shortcuts on Mac, to hear today's time in range, average, lows and highs since midnight."),
            .init(symbol: "fork.knife.circle",
                  title: "Forecasts after large meals",
                  detail: "We checked forecasts after meals of 60 grams of carbs or more and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.83.0", highlights: [
            .init(symbol: "clock.badge.questionmark",
                  title: "Forecasts when insulin is logged late",
                  detail: "We checked forecasts after meals where rapid insulin is logged a while after eating and kept them as they are for now."),
            .init(symbol: "checkmark.circle",
                  title: "A moment for back in range",
                  detail: "After 15 minutes or more out of range, your reading gets one soft ring of the in-range colour as it comes back, with a light tap on iPhone."),
            .init(symbol: "chart.xyaxis.line",
                  title: "A chart inside each past alert",
                  detail: "In Alert History, tap an alert to open a small chart of the two hours around it, with the moment it went off and anything you logged then."),
        ]),
        WhatsNewRelease(version: "1.82.0", highlights: [
            .init(symbol: "hand.draw",
                  title: "Scrub through your usual day",
                  detail: "In Insights, hold and drag across Your usual day, or point at it on the Mac, to see that half-hour's middle reading and middle half."),
            .init(symbol: "magnifyingglass",
                  title: "Settings search that moves with you",
                  detail: "Results come in one after another as you type, the words you typed glint, and picking one springs that setting into view with a bounce of its section's icon."),
            .init(symbol: "fork.knife",
                  title: "Forecasts on meals logged early",
                  detail: "We checked forecasts after meals logged before you start eating and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.81.0", highlights: [
            .init(symbol: "arrow.left.and.right",
                  title: "One cursor across compared days",
                  detail: "When comparing two days, drag across the chart or point at it on the Mac to see both days at the same time and how far apart they are."),
            .init(symbol: "chart.line.downtrend.xyaxis",
                  title: "Forecasts on slow, steady drifts",
                  detail: "We checked forecasts when glucose eases gently up or down for an hour and kept them as they are for now."),
            .init(symbol: "chart.xyaxis.line",
                  title: "The last hour in the Dynamic Island",
                  detail: "Turn it on in Settings › Lock Screen and a small line of the last hour sits beside the trend arrow, gliding along with each new reading."),
        ]),
        WhatsNewRelease(version: "1.80.0", highlights: [
            .init(symbol: "calendar",
                  title: "A livelier jump-to-date calendar",
                  detail: "Swipe between months in the Logbook calendar, and each day is tinted by its time in range."),
            .init(symbol: "clock",
                  title: "See when you've scrolled back to",
                  detail: "Panned back, the chart shows the day and time at its right edge. On the Mac, Option with an arrow moves an hour and Command-Right returns to now."),
            .init(symbol: "chart.line.flattrend.xyaxis",
                  title: "Forecasts on long high stretches",
                  detail: "We checked forecasts when glucose stays high and level for 45 minutes or more and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.79.0", highlights: [
            .init(symbol: "waveform.path.ecg",
                  title: "Insights figures catch your eye",
                  detail: "When a new reading changes a figure on Insights, it gives a small pulse as it rolls, so you can see what just moved."),
            .init(symbol: "arrow.left.and.right",
                  title: "Look back along the chart",
                  detail: "Drag along the times under the iPhone chart, or swipe sideways on the Mac trackpad, to see earlier hours. Now brings you back."),
            .init(symbol: "arrow.up.forward",
                  title: "Forecasts on rebounds after lows",
                  detail: "We checked forecasts in the 2 hours after a low as glucose climbs back and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.78.0", highlights: [
            .init(symbol: "sparkles",
                  title: "A livelier What's New",
                  detail: "Highlights now rise in one after another, each icon gives a little bounce, and Continue appears once you've seen them."),
            .init(symbol: "doc.on.doc",
                  title: "Copy or share your reading",
                  detail: "Long-press the reading on iPhone for Copy and Share, or press Command-C on the Mac, to send it as one line of text."),
            .init(symbol: "fork.knife",
                  title: "Forecasts on late rises after meals",
                  detail: "We checked forecasts when glucose climbs again 3 to 5 hours after eating and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.77.0", highlights: [
            .init(symbol: "clock.arrow.circlepath",
                  title: "Smoother missing-readings widgets",
                  detail: "Widgets and the Live Activity now fade gently into the no-readings state and back, with the minutes rolling as they pass."),
            .init(symbol: "sensor.tag.radiowaves.forward",
                  title: "New sensors in your Logbook",
                  detail: "When you start a new sensor, GlucOS adds Sensor started to your Logbook and chart at the time it began."),
            .init(symbol: "sunrise",
                  title: "Forecasts on early-morning rises",
                  detail: "We checked forecasts when glucose climbs before 8 am with nothing logged and kept them as they are for now."),
        ]),
        WhatsNewRelease(version: "1.76.0", highlights: [
            .init(symbol: "chart.line.downtrend.xyaxis",
                  title: "Forecasts after correction insulin",
                  detail: "We checked forecasts after rapid insulin taken while high with no meal nearby and kept the range as it is for now."),
            .init(symbol: "arrow.clockwise",
                  title: "Check now when readings stop",
                  detail: "When a gap in readings says no signal or can't connect, Check Now asks LibreLinkUp again and shows what came back."),
            .init(symbol: "dot.radiowaves.left.and.right",
                  title: "Sensor coverage comes alive",
                  detail: "The coverage meter fills and each gap's bar grows in, with the period before marked when you compare."),
        ]),
        WhatsNewRelease(version: "1.75.0", highlights: [
            .init(symbol: "dot.radiowaves.left.and.right",
                  title: "Sensor coverage in Insights",
                  detail: "A new card shows how much of the period has readings and the longest gaps, with why each happened."),
            .init(symbol: "chart.line.uptrend.xyaxis",
                  title: "Forecasts after gaps in readings",
                  detail: "We checked forecasts in the hour after readings come back from a gap and kept the range as it is for now."),
            .init(symbol: "clock",
                  title: "Missing readings on widgets",
                  detail: "When readings stop, widgets, StandBy, the Lock Screen and the Live Activity calmly say for how long, and why where GlucOS knows."),
        ]),
        WhatsNewRelease(version: "1.74.0", highlights: [
            .init(symbol: "syringe",
                  title: "Forecasts after stacked insulin",
                  detail: "We checked forecasts when rapid insulin is logged twice within an hour and kept the range as it is for now."),
            .init(symbol: "line.diagonal",
                  title: "Gaps in readings explained",
                  detail: "Where readings are missing, a dashed line bridges the gap. Tap or hover it to see why."),
            .init(symbol: "square.on.square",
                  title: "Catch entries logged twice",
                  detail: "Log the same meal or insulin twice within a few minutes and GlucOS asks \"Logged twice?\" with an Undo."),
        ]),
        WhatsNewRelease(version: "1.73.0", highlights: [
            .init(symbol: "note.text",
                  title: "Notes on the chart",
                  detail: "Notes from your Logbook and your alerts now show as small markers on the chart. Hold one to read it."),
            .init(symbol: "sparkles",
                  title: "What's New after updates",
                  detail: "Each update shows its highlights once, and Settings › About opens them again any time."),
            .init(symbol: "square.and.arrow.up",
                  title: "Export your alert history",
                  detail: "Share the alerts you're looking at as a PDF or CSV, straight from Alert History."),
            .init(symbol: "chart.bar.xaxis",
                  title: "Livelier Alerts card",
                  detail: "The Insights Alerts card's bars grow in, and tapping it zooms into Alert History."),
        ]),
        WhatsNewRelease(version: "1.72.0", highlights: [
            .init(symbol: "line.3.horizontal.decrease.circle",
                  title: "Filter Alert History",
                  detail: "Show only lows, highs or predicted alerts, or only the ones you snoozed or dismissed."),
            .init(symbol: "bell.badge",
                  title: "Alerts card in Insights",
                  detail: "See how many alerts went off over a period, of which kind, and what you did with them."),
        ]),
        WhatsNewRelease(version: "1.71.0", highlights: [
            .init(symbol: "square.and.pencil",
                  title: "Add a note to an alert",
                  detail: "Type a note straight from a low or high alert, or later in Alert History. It's saved to your Logbook at the alert's time."),
            .init(symbol: "dot.radiowaves.left.and.right",
                  title: "Alert History stays live",
                  detail: "New alerts slide in and outcomes update while Alert History is open."),
        ]),
        WhatsNewRelease(version: "1.70.0", highlights: [
            .init(symbol: "clock.arrow.circlepath",
                  title: "Alert History",
                  detail: "Settings › Alerts lists the last 7 days of alerts with the reading and what happened. Tap one to see it in the Logbook."),
            .init(symbol: "arrow.left.arrow.right",
                  title: "Smoother day comparisons",
                  detail: "When comparing two days, the second line draws in and a new Swap Days button switches them."),
        ]),
    ]
}
