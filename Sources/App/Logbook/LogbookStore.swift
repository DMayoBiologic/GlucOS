import Foundation
import Combine

/// Insulin, food and site-change entries, kept in
/// `~/Library/Application Support/GlucOS/logbook.json` (the app group on iPhone). Entries are kept
/// until the user deletes them. Independent of fetching, the widget snapshot and alerts.
///
/// Synced between devices by `LogbookSyncService`: every local change is noted in `syncState`
/// (logbook-sync.json) until it has been pushed, and `applyRemote` takes in other devices' changes.
@MainActor
final class LogbookStore: ObservableObject {
    /// Each oldest → newest.
    @Published private(set) var doses: [InsulinDose] = []
    @Published private(set) var meals: [MealEntry] = []
    @Published private(set) var siteChanges: [SiteChange] = []
    @Published private(set) var contexts: [ContextEvent] = []
    /// Saved quick-log combinations, in the user's order.
    @Published private(set) var presets: [LogPreset] = []
    /// The entries removed by the last delete, kept in memory so it can be undone.
    @Published private(set) var lastDeleted: [LogEntry] = []

    /// Set by the menu bar popover to have the dashboard open the log sheet.
    @Published var logSheetRequested = false

    /// What's been synced and what's waiting to be pushed.
    private(set) var syncState = LogbookSyncState()
    /// Fires after every change made on this device (not ones pulled from another).
    let localChanges = PassthroughSubject<Void, Never>()

    private struct File: Codable {
        var version = 1
        var doses: [InsulinDose] = []
        var meals: [MealEntry] = []
        var siteChanges: [SiteChange] = []
        var contexts: [ContextEvent]? = []
        var presets: [LogPreset]? = []
    }

    private static var url: URL? {
        SharedStore.containerURL?.appendingPathComponent("logbook.json")
    }

    private static var syncURL: URL? {
        SharedStore.containerURL?.appendingPathComponent("logbook-sync.json")
    }

    private static let writeQueue = DispatchQueue(label: "au.com.declanmayo.glucos.logbook", qos: .utility)

    init() {
        if let url = Self.syncURL, let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(LogbookSyncState.self, from: data) {
            syncState = state
        }
        guard let url = Self.url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(File.self, from: data) else {
            // Keep an unreadable file rather than overwrite it with an empty logbook.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("logbook-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return
        }
        doses = file.doses.sorted { $0.timestamp < $1.timestamp }
        meals = file.meals.sorted { $0.timestamp < $1.timestamp }
        siteChanges = file.siteChanges.sorted { $0.timestamp < $1.timestamp }
        contexts = (file.contexts ?? []).sorted { $0.timestamp < $1.timestamp }
        presets = file.presets ?? []
    }

    var isEmpty: Bool { doses.isEmpty && meals.isEmpty && siteChanges.isEmpty && contexts.isEmpty }

    /// Every entry, newest first.
    var entries: [LogEntry] {
        (doses.map(LogEntry.dose) + meals.map(LogEntry.meal) + siteChanges.map(LogEntry.siteChange)
            + contexts.map(LogEntry.context))
            .sorted { $0.timestamp > $1.timestamp }
    }

    func entry(id: UUID) -> LogEntry? {
        if let d = doses.first(where: { $0.id == id }) { return .dose(d) }
        if let m = meals.first(where: { $0.id == id }) { return .meal(m) }
        if let s = siteChanges.first(where: { $0.id == id }) { return .siteChange(s) }
        if let c = contexts.first(where: { $0.id == id }) { return .context(c) }
        return nil
    }

    // MARK: Editing

    /// Adds the entry, or replaces the one with the same id.
    func save(_ entry: LogEntry) {
        upsert(entry)
        touch(entry.id, kind: entry.recordKind)
        persist()
    }

    private func upsert(_ entry: LogEntry) {
        switch entry {
        case .dose(let d): LogbookMerge.insertSorted(d, into: &doses)
        case .meal(let m): LogbookMerge.insertSorted(m, into: &meals)
        case .siteChange(let s): LogbookMerge.insertSorted(s, into: &siteChanges)
        case .context(let c): LogbookMerge.insertSorted(c, into: &contexts)
        }
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = ids.compactMap { self.entry(id: $0) }
        guard !removed.isEmpty else { return }
        // Accumulate while the undo banner is up, so Undo restores every delete since.
        lastDeleted += removed
        doses.removeAll { ids.contains($0.id) }
        meals.removeAll { ids.contains($0.id) }
        siteChanges.removeAll { ids.contains($0.id) }
        contexts.removeAll { ids.contains($0.id) }
        for e in removed { touch(e.id, kind: e.recordKind, deleted: true) }
        persist()
    }

    /// Puts back what the last delete removed.
    func undoDelete() {
        let restore = lastDeleted
        guard !restore.isEmpty else { return }
        lastDeleted = []
        for e in restore {
            upsert(e)
            touch(e.id, kind: e.recordKind)
        }
        persist()
    }

    /// Forgets the undo buffer, e.g. once its banner has been dismissed.
    func clearUndo() { lastDeleted = [] }

    /// A copy of `entry` at `time` with a fresh id ("Log again now").
    func duplicate(_ entry: LogEntry, at time: Date = Date()) {
        switch entry {
        case .dose(var d): d.id = UUID(); d.timestamp = time; save(.dose(d))
        case .meal(var m): m.id = UUID(); m.timestamp = time; save(.meal(m))
        case .siteChange(var s): s.id = UUID(); s.timestamp = time; save(.siteChange(s))
        case .context(var c): c.id = UUID(); c.timestamp = time; save(.context(c))
        }
    }

    // MARK: Presets

    func savePreset(_ preset: LogPreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        touch(preset.id, kind: .preset)
        persist()
    }

    func deletePreset(id: UUID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        presets.removeAll { $0.id == id }
        touch(id, kind: .preset, deleted: true)
        persist()
    }

    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        // Positions are part of each preset's record, so every one that moved is pushed.
        for p in presets { touch(p.id, kind: .preset) }
        persist()
    }

    // MARK: Sync

    var contents: LogbookContents {
        LogbookContents(doses: doses, meals: meals, siteChanges: siteChanges, contexts: contexts, presets: presets)
    }

    private func touch(_ id: UUID, kind: LogbookRecordKind, deleted: Bool = false) {
        LogbookMerge.touch(id, kind: kind, deleted: deleted, now: Date(), state: &syncState)
    }

    /// Replaces the sync bookkeeping (after a push, or when starting with an account).
    func updateSyncState(_ change: (inout LogbookSyncState, LogbookContents) -> Void) {
        let before = syncState
        change(&syncState, contents)
        if syncState != before { persistSyncState() }
    }

    /// Takes in changes pulled from the server.
    func applyRemote(_ records: [LogbookRecord]) {
        guard !records.isEmpty else { return }
        var c = contents
        let changed = LogbookMerge.apply(records, to: &c, state: &syncState)
        if changed {
            if c.doses != doses { doses = c.doses }
            if c.meals != meals { meals = c.meals }
            if c.siteChanges != siteChanges { siteChanges = c.siteChanges }
            if c.contexts != contexts { contexts = c.contexts }
            if c.presets != presets { presets = c.presets }
            // An entry deleted elsewhere can't be undone here any more.
            let ids = Set(records.filter(\.deleted).map(\.id))
            if !ids.isEmpty { lastDeleted.removeAll { ids.contains($0.id) } }
            persist(notify: false)
        } else {
            persistSyncState()
        }
    }

    private func persistSyncState() {
        guard let url = Self.syncURL else { return }
        let state = syncState
        Self.writeQueue.async {
            do {
                try JSONEncoder().encode(state).write(to: url, options: .atomic)
            } catch {
                NSLog("GlucOS: failed to save logbook sync state: \(error)")
            }
        }
    }

    private func persist(notify: Bool = true) {
        persistSyncState()
        if notify { localChanges.send() }
        guard let url = Self.url else { return }
        let file = File(doses: doses, meals: meals, siteChanges: siteChanges, contexts: contexts, presets: presets)
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("GlucOS: failed to save logbook: \(error)")
            }
        }
    }

    // MARK: Lookups

    /// The infusion site in use at `date`: the latest site change at or before it.
    func infusionSite(at date: Date) -> SiteChange? {
        siteChanges.last { $0.timestamp <= date }
    }

    /// Where a dose went in: its injection site, or for a pump bolus the infusion site in use.
    func site(of dose: InsulinDose) -> InjectionSite? {
        if let s = dose.site { return s }
        return dose.viaPump ? infusionSite(at: dose.timestamp)?.site : nil
    }

    /// Most recent injection at each site (injections only), for rotation.
    var lastInjectionBySite: [InjectionSite: Date] {
        var out: [InjectionSite: Date] = [:]
        for d in doses where !d.viaPump {
            if let s = d.site { out[s] = d.timestamp }
        }
        return out
    }

    var lastInjectionSite: InjectionSite? {
        doses.last { !$0.viaPump && $0.site != nil }?.site
    }

    /// The injection site used longest ago (never-used sites first), within the areas the user
    /// has used before. A rotation hint only; nil until there are injections with a site.
    var leastRecentInjectionSite: InjectionSite? {
        let last = lastInjectionBySite
        guard !last.isEmpty else { return nil }
        let usedAreas = Set(last.keys.map(\.area))
        let candidates = InjectionSite.allCases.filter { $0 != .other && usedAreas.contains($0.area) }
        return candidates.min { (last[$0] ?? .distantPast) < (last[$1] ?? .distantPast) }
    }

    /// The most recent bolus (pump or injection), for "same as last time".
    var lastBolus: InsulinDose? { doses.last { $0.kind.isBolus } }

    /// Foods logged before, most recently used first, one per name. Carbs are from the latest
    /// time it was logged.
    func recentFoods(matching query: String = "", limit: Int = 8) -> [RecentFood] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var latest: [String: MealEntry] = [:]
        var counts: [String: Int] = [:]
        for m in meals.reversed() where !m.food.isEmpty {
            let key = m.food.lowercased()
            if !q.isEmpty && !key.contains(q) { continue }
            if latest[key] == nil { latest[key] = m; order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.prefix(limit).compactMap { key in
            latest[key].map { RecentFood(food: $0.food, carbs: $0.carbs, count: counts[key] ?? 1) }
        }
    }
}

extension LogEntry {
    var recordKind: LogbookRecordKind {
        switch self {
        case .dose: return .dose
        case .meal: return .meal
        case .siteChange: return .siteChange
        case .context: return .context
        }
    }
}

// MARK: - Chart events

#if os(macOS)
// ChartEvent lives in the Mac dashboard, which the iPhone target doesn't compile.
extension LogbookStore {
    /// Logged entries inside `domain`, to mark on the dashboard chart.
    func chartEvents(in domain: ClosedRange<Date>) -> [ChartEvent] {
        var out: [ChartEvent] = []
        for d in doses where domain.contains(d.timestamp) {
            var detail = "\(LogFormat.units(d.units)) \(d.displayName)"
            if let site = site(of: d) { detail += " · \(site.title)" }
            out.append(ChartEvent(id: d.id, date: d.timestamp, kind: d.kind.isBolus ? .bolus : .basal,
                                  label: "\(LogFormat.number(d.units))u", detail: detail))
        }
        for m in meals where domain.contains(m.timestamp) {
            let what = m.food.isEmpty ? "Food" : m.food
            let detail = m.carbs > 0 ? "\(LogFormat.grams(m.carbs)) carbs · \(what)" : what
            out.append(ChartEvent(id: m.id, date: m.timestamp, kind: .food,
                                  label: m.carbs > 0 ? "\(LogFormat.number(m.carbs))g" : "•", detail: detail))
        }
        for c in contexts where domain.contains(c.timestamp) && !c.tags.isEmpty {
            let titles = c.sortedTags.map(\.title).joined(separator: ", ")
            out.append(ChartEvent(id: c.id, date: c.timestamp, kind: .context,
                                  label: c.sortedTags.first?.title ?? "", detail: titles))
        }
        for s in siteChanges where domain.contains(s.timestamp) {
            out.append(ChartEvent(id: s.id, date: s.timestamp, kind: .siteChange,
                                  label: "Site", detail: "New site: \(s.site.title)"))
        }
        return out.sorted { $0.date < $1.date }
    }
}
#endif
