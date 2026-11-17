import Foundation

// Settings search (docs/SettingsSearch.md): one field at the top of Settings on iPhone and Mac
// that finds a setting by its title or by the words people use for it ("mmol" finds Units,
// "quiet" finds how often alerts repeat). Picking a result scrolls to the row and lights it up
// briefly. The catalogue and the matching live here, free of SwiftUI, so they're unit-tested;
// the views only attach `SettingsAnchor`s to their rows.

/// A row in Settings that a search can land on. The raw value doubles as the row's scroll id.
enum SettingsAnchor: String, CaseIterable, Hashable, Sendable {
    // Account
    case account, readSensor
    // Display / menu bar
    case units, targetRange, showForecast, showYesterday
    case menuBarDelta, menuBarColour, menuBarSparkline, popoverChart, textSize
    case launchAtLogin, desktopWidget, setupAssistant
    // Logging
    case therapy, insulins, bolus, presets, syncLogbook, keyboardShortcut, shortcutList
    // Alerts
    case alerts, notifications, lowAlerts, highAlert, rapidAlert, staleAlert, sensorEndingAlert
    case predictedLows, predictedHighs, warnAhead, alertRepeat, testAlert
    case eveningRecap
    // Lock Screen, sharing, relay
    case liveActivity, shareLive, following, relay
    // Advanced
    case pollInterval, sensorLifetime, clientVersion, updates, diagnostics, dataFolder, version
}

/// One searchable setting: what the row is called, where it lives, and other words for it.
struct SettingsItem: Identifiable, Hashable, Sendable {
    let anchor: SettingsAnchor
    /// The row's title, as it reads on screen.
    let title: String
    /// Where it is: the section ("Alerts"), or on the Mac the tab and section ("Alerts › Forecast").
    let place: String
    /// Mac only: the Settings tab holding the row (`SettingsView.Tab` raw value).
    var tab: String?
    /// Other words people search with. Phrases are fine; they're split into words.
    var keywords: [String] = []
    /// The row to land on instead when this one is hidden (e.g. "Warn me ahead by" only shows once
    /// a predicted alert is on, so it falls back to Predicted lows).
    var parent: SettingsAnchor?

    var id: SettingsAnchor { anchor }
}

enum SettingsSearch {
    /// How long a row stays lit after a jump.
    static let highlightSeconds: TimeInterval = 1.6
    /// Wait before scrolling, so the keyboard and search UI have gone and the full list is back.
    static let jumpDelay: TimeInterval = 0.35

    /// Words that say what to do rather than which setting ("turn off alerts"). Dropped from a
    /// query unless they're all it has.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "of", "on", "off", "my", "me", "i", "how", "do", "can", "where",
        "is", "turn", "change", "set", "setting", "settings", "in", "for", "and", "with",
    ]

    /// Lowercased, accent-free words: letters and digits only, so "mmol/L" is "mmol", "l".
    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        var out: [String] = []
        var current = ""
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                current.unicodeScalars.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The words of a query that count, fillers dropped (unless that would leave nothing).
    static func queryWords(_ query: String) -> [String] {
        let all = words(query)
        let kept = all.filter { !fillerWords.contains($0) }
        return kept.isEmpty ? all : kept
    }

    /// Settings matching every word of `query`, best first. Each query word has to start a word of
    /// the title, a keyword or the place. Title hits rank above keyword hits above place hits; an
    /// exact word beats a prefix; ties keep the catalogue's order (the order on screen).
    static func results(for query: String, in items: [SettingsItem]) -> [SettingsItem] {
        let q = queryWords(query)
        guard !q.isEmpty else { return [] }
        let wholeQuery = q.joined(separator: " ")
        var scored: [(item: SettingsItem, score: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            let title = words(item.title)
            let keywords = item.keywords.flatMap(words)
            let place = words(item.place)
            var total = 0
            var matchedAll = true
            for w in q {
                let s = max(score(w, in: title, weight: 6), score(w, in: keywords, weight: 4), score(w, in: place, weight: 2))
                if s == 0 { matchedAll = false; break }
                total += s
            }
            guard matchedAll else { continue }
            if title.joined(separator: " ").hasPrefix(wholeQuery) { total += 3 }
            scored.append((item, total, index))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }

    private static func score(_ word: String, in candidates: [String], weight: Int) -> Int {
        if candidates.contains(word) { return weight + 1 }
        return candidates.contains { $0.hasPrefix(word) } ? weight : 0
    }

    /// The row to scroll to for `item`: itself if it's on screen, or the nearest shown parent.
    static func target(for item: SettingsItem, in items: [SettingsItem], isShown: (SettingsAnchor) -> Bool) -> SettingsAnchor {
        var anchor = item.anchor
        var parent = item.parent
        var seen: Set<SettingsAnchor> = []
        while !isShown(anchor), let next = parent, seen.insert(anchor).inserted {
            anchor = next
            parent = items.first { $0.anchor == next }?.parent
        }
        return anchor
    }

    /// The empty state, in plain words.
    static func noResultsMessage(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "No settings match “\(trimmed)”. Try a word like alerts, units, sync or widget."
    }

    /// "1 setting", "4 settings": the results header, and what VoiceOver says.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 setting" : "\(count) settings"
    }
}

// MARK: - Catalogue

/// Every searchable row, in on-screen order. The keyword lists are shared, so iPhone and Mac answer
/// the same words the same way.
enum SettingsCatalog {
    private enum K {
        static let account = ["librelinkup", "libre", "login", "log in", "sign in", "sign out", "email", "password",
                              "region", "follower", "account", "abbott"]
        static let units = ["mmol", "mmol/l", "mg/dl", "mgdl", "mg", "unit", "measurement"]
        static let targetRange = ["target", "range", "low", "high", "limits", "time in range", "tir", "bounds", "colours", "colors"]
        static let forecast = ["prediction", "predict", "forecast", "outlook", "projection"]
        static let yesterday = ["yesterday", "compare", "previous day", "line", "overlay"]
        static let therapy = ["therapy", "injections", "mdi", "pens", "pump", "no insulin", "type"]
        static let insulins = ["insulin", "novorapid", "fiasp", "humalog", "lantus", "basal", "bolus", "rapid", "long acting", "brand"]
        static let bolus = ["bolus", "calculator", "dose", "carb ratio", "ratio", "sensitivity", "correction", "icr", "isf"]
        static let presets = ["preset", "quick add", "favourite", "favorite", "usual", "shortcut"]
        static let sync = ["sync", "cloud", "logbook", "backup", "other devices", "iphone", "mac", "share"]
        static let alerts = ["alerts", "alarm", "notification", "notify", "warn", "mute", "silence", "quiet", "sound"]
        static let notifications = ["notification", "permission", "allow", "system settings", "banner"]
        static let lows = ["low", "hypo", "urgent", "always on"]
        static let high = ["high", "hyper", "above"]
        static let rapid = ["rapid", "fast", "rising", "falling", "trend", "quickly", "rate"]
        static let stale = ["stale", "no data", "missing", "signal", "lost", "gap", "connection"]
        static let sensorEnding = ["sensor", "expiry", "expiring", "ending", "replace", "change sensor"]
        static let predictedLow = ["predicted", "forecast", "low", "ahead", "early warning", "heads up"]
        static let predictedHigh = ["predicted", "forecast", "high", "ahead", "early warning", "heads up"]
        static let warnAhead = ["minutes", "ahead", "lead", "early", "how soon", "warning"]
        static let repeatAlerts = ["repeat", "quiet", "quiet hours", "cooldown", "snooze", "nag", "how often",
                                   "frequency", "interval", "mute", "silence", "again"]
        static let testAlert = ["test", "try", "check", "sample"]
        static let recap = ["evening", "recap", "summary", "daily", "night", "digest", "report"]
        static let liveActivity = ["live activity", "lock screen", "dynamic island", "standby", "widget"]
        static let share = ["share", "family", "follower", "messages", "imessage", "link", "carer", "parent"]
        static let following = ["follow", "following", "someone", "family", "check in", "carer"]
        static let relay = ["relay", "push", "server", "supabase", "background", "secret", "closed"]
        static let diagnostics = ["diagnostics", "error", "report", "crash", "logs", "problem", "privacy"]
        static let version = ["version", "about", "build", "medical"]
        static let readSensor = ["nfc", "scan", "sensor", "libre 2", "bluetooth", "read", "start sensor"]
    }

    /// iPhone Settings, top to bottom.
    static let phone: [SettingsItem] = [
        .init(anchor: .account, title: "LibreLinkUp account", place: "LibreLinkUp", keywords: K.account),
        .init(anchor: .readSensor, title: "Read sensor", place: "LibreLinkUp", keywords: K.readSensor),
        .init(anchor: .units, title: "Units", place: "Display", keywords: K.units),
        .init(anchor: .targetRange, title: "Target range", place: "Display", keywords: K.targetRange),
        .init(anchor: .showForecast, title: "Show forecast on the chart", place: "Display", keywords: K.forecast + ["chart"]),
        .init(anchor: .showYesterday, title: "Show yesterday on the chart", place: "Display", keywords: K.yesterday + ["chart"]),
        .init(anchor: .therapy, title: "How you take insulin", place: "Logging", keywords: K.therapy + ["insulin"]),
        .init(anchor: .insulins, title: "Your insulins", place: "Logging", keywords: K.insulins, parent: .therapy),
        .init(anchor: .bolus, title: "Bolus calculator", place: "Logging", keywords: K.bolus, parent: .therapy),
        .init(anchor: .presets, title: "Presets", place: "Presets", keywords: K.presets, parent: .therapy),
        .init(anchor: .syncLogbook, title: "Sync logbook", place: "Logbook", keywords: K.sync),
        .init(anchor: .alerts, title: "Glucose alerts", place: "Alerts", keywords: K.alerts),
        .init(anchor: .highAlert, title: "High alerts", place: "Alerts", keywords: K.high, parent: .alerts),
        .init(anchor: .rapidAlert, title: "Rising or falling quickly", place: "Alerts", keywords: K.rapid, parent: .alerts),
        .init(anchor: .staleAlert, title: "No recent data", place: "Alerts", keywords: K.stale, parent: .alerts),
        .init(anchor: .sensorEndingAlert, title: "Sensor ending", place: "Alerts", keywords: K.sensorEnding, parent: .alerts),
        .init(anchor: .predictedLows, title: "Predicted lows", place: "Alerts", keywords: K.predictedLow, parent: .alerts),
        .init(anchor: .predictedHighs, title: "Predicted highs", place: "Alerts", keywords: K.predictedHigh, parent: .alerts),
        .init(anchor: .warnAhead, title: "Warn me ahead by", place: "Alerts", keywords: K.warnAhead, parent: .predictedLows),
        .init(anchor: .alertRepeat, title: "Repeat alerts no more than every", place: "Alerts", keywords: K.repeatAlerts, parent: .alerts),
        .init(anchor: .testAlert, title: "Send test alert", place: "Alerts", keywords: K.testAlert, parent: .alerts),
        .init(anchor: .eveningRecap, title: "Evening recap", place: "Daily recap", keywords: K.recap),
        .init(anchor: .liveActivity, title: "Live Activity", place: "Lock Screen", keywords: K.liveActivity),
        .init(anchor: .shareLive, title: "Share live readings", place: "Sharing", keywords: K.share),
        .init(anchor: .following, title: "Following", place: "Following", keywords: K.following),
        .init(anchor: .relay, title: "Push relay", place: "Push relay", keywords: K.relay),
        .init(anchor: .diagnostics, title: "Automatic error reports", place: "Diagnostics", keywords: K.diagnostics),
        .init(anchor: .version, title: "Version", place: "About", keywords: K.version),
    ]

    /// Mac Settings, tab by tab in toolbar order.
    static let mac: [SettingsItem] = [
        .init(anchor: .menuBarDelta, title: "Show change since last reading", place: "General › Menu Bar", tab: "general",
              keywords: ["delta", "change", "difference", "menu bar"]),
        .init(anchor: .menuBarColour, title: "Colour the reading by range", place: "General › Menu Bar", tab: "general",
              keywords: ["color", "colour", "tint", "menu bar"]),
        .init(anchor: .menuBarSparkline, title: "Show the last hour as a sparkline", place: "General › Menu Bar", tab: "general",
              keywords: ["sparkline", "mini chart", "graph", "menu bar"]),
        .init(anchor: .popoverChart, title: "Popover chart", place: "General › Menu Bar", tab: "general",
              keywords: ["hours", "chart", "time window", "zoom", "3", "6", "12", "24"]),
        .init(anchor: .showForecast, title: "Show the forecast on the popover chart", place: "General › Menu Bar", tab: "general",
              keywords: K.forecast + ["chart"]),
        .init(anchor: .showYesterday, title: "Show yesterday's line on the popover chart", place: "General › Menu Bar", tab: "general",
              keywords: K.yesterday + ["chart"]),
        .init(anchor: .textSize, title: "Text size", place: "General › Appearance", tab: "general",
              keywords: ["font", "bigger", "larger", "smaller", "accessibility", "zoom"]),
        .init(anchor: .launchAtLogin, title: "Launch at login", place: "General › Startup", tab: "general",
              keywords: ["startup", "start", "boot", "login item", "open automatically"]),
        .init(anchor: .desktopWidget, title: "Desktop widget", place: "General › Getting Started", tab: "general",
              keywords: ["widget", "desktop", "notification centre"]),
        .init(anchor: .setupAssistant, title: "Run setup again", place: "General › Getting Started", tab: "general",
              keywords: ["onboarding", "setup", "assistant", "welcome", "start over"]),
        .init(anchor: .account, title: "LibreLinkUp follower account", place: "Account", tab: "account", keywords: K.account),
        .init(anchor: .units, title: "Glucose units", place: "Glucose › Units", tab: "glucose", keywords: K.units),
        .init(anchor: .targetRange, title: "Target range", place: "Glucose › Target Range", tab: "glucose", keywords: K.targetRange),
        .init(anchor: .alerts, title: "Glucose alerts", place: "Alerts", tab: "alerts", keywords: K.alerts),
        .init(anchor: .notifications, title: "macOS notifications", place: "Alerts", tab: "alerts", keywords: K.notifications),
        .init(anchor: .testAlert, title: "Send test alert", place: "Alerts", tab: "alerts", keywords: K.testAlert),
        .init(anchor: .lowAlerts, title: "Low and urgent low", place: "Alerts › Glucose", tab: "alerts", keywords: K.lows),
        .init(anchor: .highAlert, title: "High alerts", place: "Alerts › Glucose", tab: "alerts", keywords: K.high),
        .init(anchor: .predictedLows, title: "Low predicted", place: "Alerts › Forecast", tab: "alerts", keywords: K.predictedLow),
        .init(anchor: .predictedHighs, title: "High predicted", place: "Alerts › Forecast", tab: "alerts", keywords: K.predictedHigh),
        .init(anchor: .warnAhead, title: "Warn me up to", place: "Alerts › Forecast", tab: "alerts", keywords: K.warnAhead),
        .init(anchor: .rapidAlert, title: "Rising or falling quickly", place: "Alerts › Also Notify Me About", tab: "alerts", keywords: K.rapid),
        .init(anchor: .staleAlert, title: "No recent data", place: "Alerts › Also Notify Me About", tab: "alerts", keywords: K.stale),
        .init(anchor: .sensorEndingAlert, title: "Sensor expiring", place: "Alerts › Also Notify Me About", tab: "alerts", keywords: K.sensorEnding),
        .init(anchor: .alertRepeat, title: "Repeat an ongoing alert every", place: "Alerts › Also Notify Me About", tab: "alerts",
              keywords: K.repeatAlerts),
        .init(anchor: .eveningRecap, title: "Evening recap", place: "Alerts › Daily Recap", tab: "alerts", keywords: K.recap),
        .init(anchor: .syncLogbook, title: "Sync logbook with your other devices", place: "Logging › Sync", tab: "logging", keywords: K.sync),
        .init(anchor: .therapy, title: "How you take insulin", place: "Logging", tab: "logging", keywords: K.therapy + ["insulin"]),
        .init(anchor: .insulins, title: "Your insulins", place: "Logging › Insulins", tab: "logging", keywords: K.insulins, parent: .therapy),
        .init(anchor: .keyboardShortcut, title: "Open the log window from any app", place: "Logging › Keyboard", tab: "logging",
              keywords: ["keyboard", "shortcut", "hotkey", "hot key", "global", "command"]),
        .init(anchor: .shortcutList, title: "Keyboard shortcuts", place: "Logging › Keyboard", tab: "logging",
              keywords: ["tab", "focus", "focus ring", "arrow keys", "navigation", "navigate", "escape", "esc",
                         "keys", "list", "help", "full keyboard access"]),
        .init(anchor: .bolus, title: "Bolus calculator", place: "Logging", tab: "logging", keywords: K.bolus, parent: .therapy),
        .init(anchor: .presets, title: "Quick-add presets", place: "Logging", tab: "logging", keywords: K.presets),
        .init(anchor: .pollInterval, title: "Check for new readings", place: "Advanced › Connection", tab: "advanced",
              keywords: ["poll", "refresh", "interval", "how often", "fetch", "seconds", "minute"]),
        .init(anchor: .sensorLifetime, title: "Sensor lifetime", place: "Advanced › Connection", tab: "advanced",
              keywords: ["sensor", "days", "14", "15", "libre 3", "plus"]),
        .init(anchor: .clientVersion, title: "Client version", place: "Advanced › Connection", tab: "advanced",
              keywords: ["librelinkup", "version", "abbott", "minimum", "app version"]),
        .init(anchor: .updates, title: "Check for updates", place: "Advanced › Updates", tab: "advanced",
              keywords: ["update", "sparkle", "version", "upgrade", "new version", "install"]),
        .init(anchor: .diagnostics, title: "Automatic error reports", place: "Advanced › Diagnostics", tab: "advanced", keywords: K.diagnostics),
        .init(anchor: .dataFolder, title: "Data folder", place: "Advanced › Diagnostics", tab: "advanced",
              keywords: ["finder", "files", "storage", "history", "folder", "path"]),
    ]
}
