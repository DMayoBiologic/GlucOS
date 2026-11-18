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
    /// The user's insulins, in their order, picked from when logging a dose. Kept in
    /// insulins.json next to logbook.json.
    @Published private(set) var insulins: [SavedInsulin] = []
    /// Each oldest → newest.
    @Published private(set) var doses: [InsulinDose] = []
    @Published private(set) var meals: [MealEntry] = []
    @Published private(set) var siteChanges: [SiteChange] = []
    @Published private(set) var contexts: [ContextEvent] = []
    /// Saved quick-log combinations, in the user's order.
    @Published private(set) var presets: [LogPreset] = []
    /// Favourite and user-made foods.
    @Published private(set) var foods: [SavedFood] = []
    /// The bolus calculator settings, shared by the user's devices. Nil until set up.
    @Published private(set) var bolusSettings: BolusSettings?
    /// "No" and dismissals for "Did you treat this low?" (`LowTreatmentCheck`). Synced.
    @Published private(set) var lowAnswers: [LowAnswer] = []
    /// Low and high alerts that went off, and what was tapped on them (`AlertLog`). Synced, and
    /// shown in the Logbook, but never entries: nothing that reads `entries` sees them.
    @Published private(set) var alerts: [AlertRecord] = []
    /// Each Insights screen's card order and hidden cards (docs/InsightsLayout.md). Synced, one
    /// record per screen; a screen missing here shows the shipped order.
    @Published private(set) var insightsLayouts: [InsightsScreen: InsightsLayout] = [:]
    /// A few words about a whole day, by date key ("2026-11-18", `DayNotes`). Synced, one record per
    /// day; shown under the Logbook's day headers and on the Best and toughest days charts.
    @Published private(set) var dayNotes: [String: String] = [:]
    /// The entries removed by the last delete, kept in memory so it can be undone.
    @Published private(set) var lastDeleted: [LogEntry] = []
    /// When each entry in `lastDeleted` was deleted, as pushed, so sync can tell this device's own
    /// tombstone coming back from a newer change made elsewhere (`LogbookUndo`).
    private var deletedAt: [UUID: Double] = [:]
    /// The last edit saved from a log sheet, kept in memory so it can be undone (`LogbookEditUndo`).
    /// Never set at the same time as `lastDeleted`: the toast offers one Undo at a time.
    @Published private(set) var lastEdit: LogbookEditUndo?
    /// The last change made to several entries at once (tags on the Logbook's selection), kept in
    /// memory so it can be undone (`LogbookBatchEditUndo`). Also one Undo at a time.
    @Published private(set) var lastBatch: LogbookBatchEditUndo?

    /// What the undo toast offers, if anything.
    var undoOffer: LogbookUndoOffer? {
        if let lastEdit { return .edited(lastEdit) }
        if let lastBatch { return .batch(lastBatch) }
        return lastDeleted.isEmpty ? nil : .deleted(lastDeleted)
    }

    /// Set by the menu bar popover to have the dashboard open the log sheet.
    @Published var logSheetRequested = false

    /// What's been synced and what's waiting to be pushed.
    private(set) var syncState = LogbookSyncState()
    /// Fires after every change made on this device (not ones pulled from another).
    let localChanges = PassthroughSubject<Void, Never>()
    /// A dose newly logged on this device (not an edit, and not one pulled from another device),
    /// so only the device it was logged on schedules "Was it for a meal?" (`DoseQuestion`).
    let newLocalDose = PassthroughSubject<InsulinDose, Never>()

    private struct File: Codable {
        var version = 1
        var doses: [InsulinDose] = []
        var meals: [MealEntry] = []
        var siteChanges: [SiteChange] = []
        var contexts: [ContextEvent]? = []
        var presets: [LogPreset]? = []
        var foods: [SavedFood]? = []
        var bolusSettings: BolusSettings?
        var lowAnswers: [LowAnswer]? = []
        var alerts: [AlertRecord]? = []
        /// Keyed by `InsightsScreen` raw value.
        var insightsLayouts: [String: InsightsLayout]? = [:]
        /// Keyed by `DayNotes.key`.
        var dayNotes: [String: String]? = [:]
    }

    private static var url: URL? {
        SharedStore.containerURL?.appendingPathComponent("logbook.json")
    }

    private static var syncURL: URL? {
        SharedStore.containerURL?.appendingPathComponent("logbook-sync.json")
    }

    private static let writeQueue = DispatchQueue(label: "au.com.declanmayo.glucos.logbook", qos: .utility)

    init() {
        loadInsulins()
        defer {
            discoverInsulins()
            adoptLegacyInsightsLayouts()
        }
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
        foods = file.foods ?? []
        bolusSettings = file.bolusSettings
        lowAnswers = file.lowAnswers ?? []
        alerts = file.alerts ?? []
        for (raw, layout) in file.insightsLayouts ?? [:] {
            if let screen = InsightsScreen(rawValue: raw), !layout.isStandard { insightsLayouts[screen] = layout }
        }
        for (key, text) in file.dayNotes ?? [:] where DayNotes.isValid(key) && !text.isEmpty { dayNotes[key] = text }
        pruneExpiredAlerts()
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
        var entry = entry
        // A later change to the edited entry (another edit, an answer to "Was it for a meal?")
        // ends its Undo, so Undo never throws that change away.
        if lastEdit?.before.id == entry.id { lastEdit = nil }
        if let batch = lastBatch, batch.ids.contains(entry.id) { lastBatch = batch.dropping([entry.id]) }
        if case .dose(let d) = entry {
            // Only a new name is added to the list: editing an old dose's note mustn't bring back
            // an insulin the user deleted.
            let before = doses.first { $0.id == d.id }
            entry = .dose(rememberInsulin(of: d, addIfMissing: before.map { InsulinLibrary.key($0.name) != InsulinLibrary.key(d.name) } ?? true))
            upsert(entry)
            touch(entry.id, kind: entry.recordKind)
            persist()
            if before == nil, case .dose(let saved) = entry { newLocalDose.send(saved) }
            return
        }
        upsert(entry)
        touch(entry.id, kind: entry.recordKind)
        persist()
    }

    // MARK: Alerts

    /// Notes a low or high alert that just went off on this device. Syncs like any edit.
    func alertFired(_ kind: AlertNotice.Kind, at time: Date = Date()) {
        guard let r = AlertLog.fired(kind, at: time, in: alerts) else { return }
        alerts.append(r)
        touch(r.id, kind: .alert)
        pruneAlerts(now: Date())
        persist()
    }

    /// Notes a button tapped on an alert that went off at `firedAt`.
    func alertAnswered(_ kind: AlertNotice.Kind, _ response: AlertRecord.Response, snoozeMinutes: Int?,
                       firedAt: Date, now: Date = Date()) {
        guard let r = AlertLog.responded(kind, response, snoozeMinutes: snoozeMinutes, firedAt: firedAt, at: now,
                                         in: alerts) else { return }
        if let i = alerts.firstIndex(where: { $0.id == r.id }) { alerts[i] = r } else { alerts.append(r) }
        touch(r.id, kind: .alert)
        pruneAlerts(now: now)
        persist()
    }

    /// Notes an alert that went off at `firedAt` being swiped away or closed with no button tapped.
    /// Nothing changes when a button was already tapped on it (`AlertLog.dismissed`).
    func alertDismissed(_ kind: AlertNotice.Kind, firedAt: Date, now: Date = Date()) {
        guard let r = AlertLog.dismissed(kind, firedAt: firedAt, at: now, in: alerts) else { return }
        if let i = alerts.firstIndex(where: { $0.id == r.id }) { alerts[i] = r } else { alerts.append(r) }
        touch(r.id, kind: .alert)
        pruneAlerts(now: now)
        persist()
    }

    /// Lets go of alert records older than 90 days, on every device they synced to.
    func pruneExpiredAlerts(now: Date = Date()) {
        guard !AlertLog.expired(alerts, now: now).isEmpty else { return }
        pruneAlerts(now: now)
        persist()
    }

    private func pruneAlerts(now: Date) {
        let old = AlertLog.expired(alerts, now: now)
        guard !old.isEmpty else { return }
        for r in old { touch(r.id, kind: .alert, deleted: true) }
        alerts.removeAll { r in old.contains { $0.id == r.id } }
    }

    /// Records "No" or a dismissal for "Did you treat this low?". Syncs like any edit.
    func answerLow(_ low: LowEpisode, _ answer: LowAnswer.Answer, now: Date = Date()) {
        guard let end = low.end, !lowAnswers.contains(where: { $0.covers(low) }) else { return }
        let a = LowAnswer(lowStart: low.start, lowEnd: end, answer: answer, answeredAt: now)
        lowAnswers.append(a)
        // Only the last 90 days are kept: older lows are never asked about.
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        for old in lowAnswers where old.answeredAt < cutoff { touch(old.id, kind: .lowAnswer, deleted: true) }
        lowAnswers.removeAll { $0.answeredAt < cutoff }
        touch(a.id, kind: .lowAnswer)
        persist()
    }

    /// Takes back a low answer (Undo).
    func removeLowAnswer(id: UUID) {
        guard lowAnswers.contains(where: { $0.id == id }) else { return }
        lowAnswers.removeAll { $0.id == id }
        touch(id, kind: .lowAnswer, deleted: true)
        persist()
    }

    /// Records the answer to "Was it for a meal?" (or clears it, for Undo). Syncs like any edit.
    func setPurpose(_ purpose: DosePurpose?, forDose id: UUID) {
        guard var d = doses.first(where: { $0.id == id }), d.purpose != purpose else { return }
        d.purpose = purpose
        save(.dose(d))
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
        // One Undo at a time: the delete's replaces a pending edit's.
        lastEdit = nil
        lastBatch = nil
        // Accumulate while the undo banner is up, so Undo restores every delete since.
        lastDeleted += removed
        doses.removeAll { ids.contains($0.id) }
        meals.removeAll { ids.contains($0.id) }
        siteChanges.removeAll { ids.contains($0.id) }
        contexts.removeAll { ids.contains($0.id) }
        for e in removed {
            touch(e.id, kind: e.recordKind, deleted: true)
            deletedAt[e.id] = syncState.pending[e.id]?.modified
        }
        persist()
    }

    /// Puts back what the last delete removed.
    func undoDelete() {
        let restore = lastDeleted
        guard !restore.isEmpty else { return }
        lastDeleted = []
        deletedAt = [:]
        for e in restore {
            upsert(e)
            // A fresh edit time, later than the delete's tombstone, so the server takes the entry
            // back and the other devices get it again (rather than it vanishing on the Mac).
            touch(e.id, kind: e.recordKind)
        }
        persist()
    }

    /// Forgets the undo buffer, e.g. once its banner has been dismissed.
    func clearUndo() {
        lastDeleted = []
        deletedAt = [:]
        lastEdit = nil
        lastBatch = nil
    }

    /// After a log sheet saves an edit: offers Undo for it, if the entry changed. `before` is the
    /// entry as the sheet found it, read just before saving. Replaces a pending delete's Undo.
    func offerEditUndo(before: LogEntry?) {
        guard let before,
              let offer = LogbookEditUndo.offer(before: before, after: entry(id: before.id),
                                                editedAt: syncState.pending[before.id]?.modified)
        else { return }
        lastDeleted = []
        deletedAt = [:]
        lastBatch = nil
        lastEdit = offer
    }

    /// Puts the last edited entry back exactly as it was before the edit, under the same id, with a
    /// fresh edit time so it syncs to the other devices like any edit. Does nothing if the entry
    /// has gone since.
    func undoEdit() {
        guard let edit = lastEdit else { return }
        lastEdit = nil
        guard let restored = edit.restore(current: entry(id: edit.before.id)) else { return }
        upsert(restored)
        touch(restored.id, kind: restored.recordKind)
        persist()
    }

    /// Adds `tag` to the entries with these ids, or takes it off them (the Logbook's selection),
    /// and offers one Undo for all of them. Only their tags change (`LogbookBulkTag`); entries that
    /// wouldn't change aren't saved again. Returns how many changed.
    @discardableResult
    func setTag(_ tag: String, adding: Bool, ids: [UUID]) -> Int {
        let picked = ids.compactMap { entry(id: $0) }
        let changed = adding ? LogbookBulkTag.adding(tag, to: picked) : LogbookBulkTag.removing(tag, from: picked)
        guard !changed.isEmpty else { return 0 }
        let before = picked.filter { p in changed.contains { $0.id == p.id } }
        for e in changed {
            upsert(e)
            touch(e.id, kind: e.recordKind)
        }
        persist()
        let shown = LogbookTags.cleaned(tag) ?? tag
        let times = Dictionary(changed.compactMap { e in syncState.pending[e.id].map { (e.id, $0.modified) } },
                               uniquingKeysWith: { a, _ in a })
        if let offer = LogbookBatchEditUndo.offer(before: before, after: changed, editedAt: times,
                                                  title: LogbookBulkTag.title(shown, adding: adding, changed: changed)) {
            // One Undo at a time: this replaces a pending delete's or edit's.
            lastDeleted = []
            deletedAt = [:]
            lastEdit = nil
            lastBatch = offer
        }
        return changed.count
    }

    /// Puts back every entry the last batch change touched, exactly as it was, under the same ids,
    /// with fresh edit times so they sync to the other devices like any edit. Entries deleted since
    /// stay deleted.
    func undoBatch() {
        guard let batch = lastBatch else { return }
        lastBatch = nil
        let restored = batch.restore(current: { self.entry(id: $0) })
        guard !restored.isEmpty else { return }
        for e in restored {
            upsert(e)
            touch(e.id, kind: e.recordKind)
        }
        persist()
    }

    /// Undo on the toast: the last edit, the last batch change, or the last delete.
    func undo() {
        if lastEdit != nil { undoEdit() } else if lastBatch != nil { undoBatch() } else { undoDelete() }
    }

    /// A copy of `entry` at `time` with a fresh id ("Log again now", `LogEntry.copied`). Returns the
    /// copy's id.
    @discardableResult
    func duplicate(_ entry: LogEntry, at time: Date = Date()) -> UUID {
        let copy = entry.copied(at: time)
        save(copy)
        return copy.id
    }

    // MARK: Insulins

    /// What syncs: the logbook plus the user's insulins.
    var syncContents: LogbookContents {
        var c = contents
        c.insulins = insulins
        return c
    }

    /// Adds the insulin, or replaces the one with the same id.
    func saveInsulin(_ insulin: SavedInsulin) {
        var i = insulin
        i.name = i.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !i.name.isEmpty else { return }
        if let at = insulins.firstIndex(where: { $0.id == i.id }) { insulins[at] = i } else { insulins.append(i) }
        UserDefaults.standard.set(true, forKey: Self.insulinsSetUpKey)
        touch(i.id, kind: .insulin)
        persistInsulins()
        persistSyncState()
        localChanges.send()
    }

    func deleteInsulin(id: UUID) {
        guard insulins.contains(where: { $0.id == id }) else { return }
        insulins.removeAll { $0.id == id }
        touch(id, kind: .insulin, deleted: true)
        persistInsulins()
        persistSyncState()
        localChanges.send()
    }

    func moveInsulins(from source: IndexSet, to destination: Int) {
        insulins.move(fromOffsets: source, toOffset: destination)
        // Order is kept by position in the list, so push them all.
        for i in insulins { touch(i.id, kind: .insulin) }
        persistInsulins()
        persistSyncState()
        localChanges.send()
    }

    /// The saved insulin a new dose starts with (see `InsulinLibrary.preferred`).
    func preferredInsulin(viaPump: Bool) -> SavedInsulin? {
        InsulinLibrary.preferred(in: insulins, doses: doses, viaPump: viaPump)
    }

    /// The saved insulin `name` refers to, however it's spelled.
    func savedInsulin(named name: String) -> SavedInsulin? { InsulinLibrary.match(name, in: insulins) }

    /// Logged doses and presets whose insulin is spelled differently from the saved name.
    var insulinRespellingCount: Int {
        InsulinLibrary.respellings(doses, library: insulins).count
            + InsulinLibrary.respellings(presets, library: insulins).count
    }

    /// Writes every logged dose and preset with its insulin's saved spelling ("Novorapid" →
    /// "NovoRapid"). Only the name changes. Returns how many entries changed.
    @discardableResult
    func normaliseInsulinNames() -> Int {
        let doseNames = InsulinLibrary.respellings(doses, library: insulins)
        let presetNames = InsulinLibrary.respellings(presets, library: insulins)
        guard !doseNames.isEmpty || !presetNames.isEmpty else { return 0 }
        for (i, d) in doses.enumerated() {
            if let name = doseNames[d.id] { doses[i].name = name; touch(d.id, kind: .dose) }
        }
        for (i, p) in presets.enumerated() {
            if let name = presetNames[p.id] { presets[i].insulinName = name; touch(p.id, kind: .preset) }
        }
        persist()
        return doseNames.count + presetNames.count
    }

    /// A dose logged by hand: written with its insulin's saved spelling, and a name that isn't
    /// saved yet is added to the list so it's one tap next time.
    private func rememberInsulin(of dose: InsulinDose, addIfMissing: Bool) -> InsulinDose {
        var d = dose
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.name.isEmpty else { return d }
        if let saved = savedInsulin(named: d.name) {
            d.name = saved.name
        } else if addIfMissing {
            var new = SavedInsulin(name: d.name, kind: d.kind)
            // Renamed insulins keep their old id, so a new name can land on a taken one.
            if insulins.contains(where: { $0.id == new.id }) { new.id = UUID() }
            saveInsulin(new)
        }
        return d
    }

    /// Set once the list has had insulins in it on this device, after which nothing is added
    /// to it on its own (beyond names typed when logging).
    private static let insulinsSetUpKey = "insulinLibrarySetUp"

    /// The first time, fills the list from insulins already logged and the names from the old
    /// Settings fields. These go up as older than anything on the server, so an insulin the user
    /// already deleted on another device stays deleted.
    private func discoverInsulins() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.insulinsSetUpKey) else { return }
        guard insulins.isEmpty else { defaults.set(true, forKey: Self.insulinsSetUpKey); return }
        var named: [(name: String, kind: InsulinKind)] = []
        let bolusKind = InsulinKind(rawValue: defaults.string(forKey: "bolusInsulinKind") ?? "") ?? .rapid
        if let n = defaults.string(forKey: "bolusInsulinName") { named.append((n, bolusKind)) }
        if let n = defaults.string(forKey: "basalInsulinName") { named.append((n, .long)) }
        let found = InsulinLibrary.discovered(from: doses, named: named, excluding: insulins)
        guard !found.isEmpty else { return }
        insulins = found
        for i in found where syncState.pending[i.id] == nil {
            syncState.pending[i.id] = LogbookPendingChange(kind: LogbookRecordKind.insulin.rawValue,
                                                           modified: LogbookMerge.adoptedModified, deleted: false)
        }
        defaults.set(true, forKey: Self.insulinsSetUpKey)
        persistInsulins()
        persistSyncState()
        localChanges.send()
    }

    private static var insulinsURL: URL? {
        SharedStore.containerURL?.appendingPathComponent("insulins.json")
    }

    private func loadInsulins() {
        guard let url = Self.insulinsURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SavedInsulin].self, from: data) else { return }
        insulins = list
    }

    private func persistInsulins() {
        guard let url = Self.insulinsURL else { return }
        let list = insulins
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(list).write(to: url, options: .atomic)
            } catch {
                NSLog("GlucOS: failed to save insulins: \(error)")
            }
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

    // MARK: Foods

    func saveFood(_ food: SavedFood) {
        var f = food
        // Whole milliseconds, so the copy that comes back through sync compares equal.
        f.modified = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        if let i = foods.firstIndex(where: { $0.id == f.id }) { foods[i] = f } else { foods.append(f) }
        touch(f.id, kind: .food)
        persist()
    }

    func deleteFood(id: UUID) {
        guard foods.contains(where: { $0.id == id }) else { return }
        foods.removeAll { $0.id == id }
        touch(id, kind: .food, deleted: true)
        persist()
    }

    /// The saved entry for a food from the list, if the user has one.
    func savedFood(for foodID: String) -> SavedFood? { foods.first { $0.food.id == foodID } }

    /// Stars or un-stars a food. Un-starring a food from the list forgets it; the user's own
    /// foods are kept.
    func setFavourite(_ food: FoodItem, _ favourite: Bool) {
        if var saved = savedFood(for: food.id) {
            if !favourite && food.source != .custom {
                deleteFood(id: saved.id)
            } else {
                saved.favourite = favourite
                saveFood(saved)
            }
        } else if favourite {
            saveFood(SavedFood(id: SavedFood.stableID(for: food), food: food, favourite: true))
        }
    }

    /// Remembers the portion last used for a saved food.
    func notePortion(for foodID: String, grams: Double, portion: String?) {
        guard var saved = savedFood(for: foodID) else { return }
        saved.lastGrams = grams
        saved.lastPortion = portion
        saveFood(saved)
    }

    // MARK: Bolus settings

    func saveBolusSettings(_ settings: BolusSettings) {
        bolusSettings = settings.normalised
        touch(BolusSettings.recordID, kind: .bolusSettings)
        persist()
    }

    // MARK: Insights layout

    /// The screen's card order and hidden cards; the shipped order if nothing's been chosen.
    func insightsLayout(for screen: InsightsScreen) -> InsightsLayout {
        insightsLayouts[screen] ?? .standard
    }

    /// Keeps the screen's layout and syncs it. Back to the shipped order removes it everywhere.
    func saveInsightsLayout(_ layout: InsightsLayout, for screen: InsightsScreen) {
        guard layout != insightsLayout(for: screen) else { return }
        insightsLayouts[screen] = layout.isStandard ? nil : layout
        touch(screen.recordID, kind: .insightsLayout, deleted: layout.isStandard)
        persist()
    }

    /// Builds before syncing kept each screen's layout in this device's UserDefaults. Moves it into
    /// the logbook once, as older than anything on the server, so a layout another device already
    /// synced wins and this one only fills a gap.
    private func adoptLegacyInsightsLayouts() {
        let defaults = UserDefaults.standard
        var moved = false
        for screen in InsightsScreen.allCases {
            guard let text = defaults.string(forKey: screen.legacyKey) else { continue }
            defaults.removeObject(forKey: screen.legacyKey)
            let layout = InsightsLayout(stored: text)
            guard insightsLayouts[screen] == nil, !layout.isStandard else { continue }
            insightsLayouts[screen] = layout
            if syncState.pending[screen.recordID] == nil {
                syncState.pending[screen.recordID] = LogbookPendingChange(kind: LogbookRecordKind.insightsLayout.rawValue,
                                                                          modified: LogbookMerge.adoptedModified,
                                                                          deleted: false)
            }
            moved = true
        }
        if moved { persist(notify: false) }
    }

    // MARK: Day notes

    /// The note for the day `date` falls on, if any.
    func dayNote(on date: Date) -> String? {
        DayNotes.note(on: date, in: dayNotes)
    }

    /// Keeps the day's note (tidied by `DayNotes.cleaned`) and syncs it. An empty note removes the
    /// day's note everywhere. Returns the note as kept, nil when there's none now.
    @discardableResult
    func saveDayNote(_ text: String, on date: Date) -> String? {
        let key = DayNotes.key(for: date)
        guard let id = DayNotes.recordID(for: key) else { return dayNotes[key] }
        let kept = DayNotes.cleaned(text)
        guard kept != (dayNotes[key] ?? "") else { return dayNotes[key] }
        dayNotes[key] = kept.isEmpty ? nil : kept
        touch(id, kind: .dayNote, deleted: kept.isEmpty)
        persist()
        return dayNotes[key]
    }

    // MARK: Sync

    var contents: LogbookContents {
        LogbookContents(doses: doses, meals: meals, siteChanges: siteChanges, contexts: contexts, presets: presets,
                        foods: foods, bolusSettings: bolusSettings, lowAnswers: lowAnswers, alerts: alerts,
                        insightsLayouts: insightsLayouts, dayNotes: dayNotes)
    }

    private func touch(_ id: UUID, kind: LogbookRecordKind, deleted: Bool = false) {
        LogbookMerge.touch(id, kind: kind, deleted: deleted, now: Date(), state: &syncState)
    }

    /// Replaces the sync bookkeeping (after a push, or when starting with an account).
    func updateSyncState(_ change: (inout LogbookSyncState, LogbookContents) -> Void) {
        let before = syncState
        change(&syncState, syncContents)
        if syncState != before { persistSyncState() }
    }

    /// Takes in changes pulled from the server.
    func applyRemote(_ records: [LogbookRecord]) {
        guard !records.isEmpty else { return }
        var c = syncContents
        let changed = LogbookMerge.apply(records, to: &c, state: &syncState)
        if changed {
            if c.insulins != insulins { insulins = c.insulins; persistInsulins() }
            if c.doses != doses { doses = c.doses }
            if c.meals != meals { meals = c.meals }
            if c.siteChanges != siteChanges { siteChanges = c.siteChanges }
            if c.contexts != contexts { contexts = c.contexts }
            if c.presets != presets { presets = c.presets }
            if c.foods != foods { foods = c.foods }
            if c.bolusSettings != bolusSettings { bolusSettings = c.bolusSettings }
            if c.lowAnswers != lowAnswers { lowAnswers = c.lowAnswers }
            if c.alerts != alerts { alerts = c.alerts }
            if c.insightsLayouts != insightsLayouts { insightsLayouts = c.insightsLayouts }
            if c.dayNotes != dayNotes { dayNotes = c.dayNotes }
            // Another device may have sent records this one would already have let go.
            pruneAlerts(now: Date())
            persist(notify: false)
            discoverInsulins()
        } else {
            persistSyncState()
        }
        // An entry changed or deleted elsewhere after it was deleted here can't be undone any
        // more. Our own tombstone coming back from the server leaves Undo alone.
        if let edit = lastEdit, edit.superseded(by: records) { lastEdit = nil }
        if let batch = lastBatch { lastBatch = batch.dropping(batch.superseded(by: records)) }
        let gone = LogbookUndo.superseded(by: records, deletedAt: deletedAt)
        if !gone.isEmpty {
            lastDeleted.removeAll { gone.contains($0.id) }
            for id in gone { deletedAt[id] = nil }
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
        let file = File(doses: doses, meals: meals, siteChanges: siteChanges, contexts: contexts, presets: presets,
                        foods: foods, bolusSettings: bolusSettings, lowAnswers: lowAnswers, alerts: alerts,
                        insightsLayouts: Dictionary(uniqueKeysWithValues: insightsLayouts.map { ($0.key.rawValue, $0.value) }),
                        dayNotes: dayNotes)
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
    var lastInjectionBySite: [InjectionSite: Date] { lastInjectionBySite(before: .distantFuture) }

    /// Same, counting only injections before `date` (for a dose logged at an earlier time).
    func lastInjectionBySite(before date: Date) -> [InjectionSite: Date] {
        var out: [InjectionSite: Date] = [:]
        for d in doses where !d.viaPump && d.timestamp < date {
            if let s = d.site { out[s] = d.timestamp }
        }
        return out
    }

    /// The site to suggest for an injection at `date`.
    func suggestedInjectionSite(at date: Date) -> InjectionSite? {
        SiteRotation.suggestion(lastUse: lastInjectionBySite(before: date))
    }

    var lastInjectionSite: InjectionSite? {
        doses.last { !$0.viaPump && $0.site != nil }?.site
    }

    /// The injection site used longest ago (never-used sites first), within the areas the user
    /// has used before. A rotation hint only; nil until there are injections with a site.
    var leastRecentInjectionSite: InjectionSite? { SiteRotation.suggestion(lastUse: lastInjectionBySite) }

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
            out.append(ChartEvent(id: c.id, date: c.timestamp, kind: c.isWake ? .wake : .context,
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
