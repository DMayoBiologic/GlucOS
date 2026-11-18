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
        WhatsNewRelease(version: "1.74.0", highlights: [
            .init(symbol: "square.on.square",
                  title: "Catch entries logged twice",
                  detail: "Log the same meal or dose twice within a few minutes and GlucOS asks \"Logged twice?\" with an Undo."),
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
