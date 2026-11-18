import Foundation

// Logbook sync between the Mac and the iPhone, through Supabase (supabase/migrations, the
// `logbook_push` / `logbook_pull` functions). Plain Foundation so `swift test` covers it.
//
// Each device keeps the whole logbook locally and works offline. Every entry (dose, meal, site
// change, context, preset) is one record on the server, keyed by its id. A device remembers
// which entries it changed since its last push ("pending"), pushes those, and pulls whatever
// changed on the server since the last change counter it saw.
//
// Conflicts: the later edit wins, by the editing device's clock (the server caps it at a few
// minutes ahead of its own). A delete is an edit too: it's pushed as a tombstone, so it reaches
// the other devices and an older edit of the same entry can't bring it back.

/// Any JSON value. Entry payloads are kept as JSON so an entry a newer app wrote with extra fields
/// passes through the server unchanged.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

/// What a record is. Stored as text on the server, so a newer app can add kinds; this app leaves
/// kinds it doesn't know alone.
enum LogbookRecordKind: String, CaseIterable {
    /// One of the user's insulins (`SavedInsulin`).
    case insulin
    case dose, meal, siteChange, context, preset
    /// A favourite or the user's own food (`SavedFood`).
    case food
    /// The bolus calculator settings: one record, id `BolusSettings.recordID`.
    case bolusSettings
    /// "No" or a dismissal for "Did you treat this low?" (`LowAnswer`), so no device asks again.
    case lowAnswer
    /// A low or high alert that went off and what was tapped on it (`AlertRecord`). Shown in the
    /// Logbook only: never a treatment, and not one of the kinds a follower sees.
    case alert
    /// One Insights screen's card order and hidden cards (`SyncedInsightsLayout`): one record per
    /// screen, id `InsightsScreen.recordID`. A screen back on the shipped order is a delete.
    case insightsLayout
    /// A few words about one whole day (`DayNote`): one record per date, id `DayNotes.recordID`.
    /// An empty note is a delete.
    case dayNote
}

/// One entry as the server keeps it.
struct LogbookRecord: Codable, Equatable {
    var id: UUID
    var kind: String
    /// The entry, encoded like logbook.json. Nil for a deleted entry.
    var payload: JSONValue?
    var deleted: Bool
    /// When the entry was last changed, Unix seconds. Decides which edit wins.
    var modified: Double
    /// Which kind of device made the change ("Mac", "iPhone"). Informational.
    var device: String?
    /// The server's change counter. Only on records pulled from the server.
    var rev: Int64?
}

/// A local change not yet pushed.
struct LogbookPendingChange: Codable, Equatable {
    var kind: String
    var modified: Double
    var deleted: Bool
}

/// What a device remembers about syncing, kept next to logbook.json.
struct LogbookSyncState: Codable, Equatable {
    /// The Supabase user this logbook syncs with. A different user starts over (see `adopt`).
    var userID: String?
    /// The highest change counter pulled so far.
    var cursor: Int64 = 0
    /// Last time everything was pulled from the start, which also catches a change that was
    /// committed out of counter order. Unix seconds.
    var lastFullPull: Double?
    /// Entries changed here since the last push.
    var pending: [UUID: LogbookPendingChange] = [:]
    /// Last successful sync, Unix seconds.
    var lastSynced: Double?

    /// Pulls start from the beginning this often.
    static let fullPullInterval: TimeInterval = 12 * 3600

    func needsFullPull(now: Date) -> Bool {
        guard let last = lastFullPull else { return true }
        return now.timeIntervalSince1970 - last >= Self.fullPullInterval
    }
}

/// Everything in the logbook that syncs.
struct LogbookContents: Equatable {
    /// The user's insulins, in their order.
    var insulins: [SavedInsulin] = []
    var doses: [InsulinDose] = []
    var meals: [MealEntry] = []
    var siteChanges: [SiteChange] = []
    var contexts: [ContextEvent] = []
    /// In the user's order.
    var presets: [LogPreset] = []
    var foods: [SavedFood] = []
    var bolusSettings: BolusSettings?
    var lowAnswers: [LowAnswer] = []
    var alerts: [AlertRecord] = []
    /// Each Insights screen's layout. A screen without one shows the shipped order.
    var insightsLayouts: [InsightsScreen: InsightsLayout] = [:]
    /// Day notes by date key ("2026-11-18", `DayNotes.key`). Never holds an empty note.
    var dayNotes: [String: String] = [:]

    var allIDs: [(UUID, LogbookRecordKind)] {
        insulins.map { ($0.id, LogbookRecordKind.insulin) } +
        doses.map { ($0.id, .dose) } + meals.map { ($0.id, .meal) } + siteChanges.map { ($0.id, .siteChange) }
            + contexts.map { ($0.id, .context) } + presets.map { ($0.id, .preset) } + foods.map { ($0.id, .food) }
            + (bolusSettings == nil ? [] : [(BolusSettings.recordID, .bolusSettings)])
            + lowAnswers.map { ($0.id, .lowAnswer) }
            + alerts.map { ($0.id, .alert) }
            + InsightsScreen.allCases.filter { insightsLayouts[$0] != nil }.map { ($0.recordID, .insightsLayout) }
            + dayNoteIDs
    }

    private var dayNoteIDs: [(UUID, LogbookRecordKind)] {
        var out: [(UUID, LogbookRecordKind)] = []
        for key in dayNotes.keys.sorted() {
            if let id = DayNotes.recordID(for: key) { out.append((id, LogbookRecordKind.dayNote)) }
        }
        return out
    }
}

enum LogbookMerge {
    /// The edit time the first upload gives a device's existing entries. Anything already on the
    /// server (including a delete from another device) is newer, so it wins; anything the server
    /// hasn't got is added.
    static let adoptedModified: Double = 1

    // MARK: Local changes

    /// Notes a local change to `id`. Edit times only move forward, even if the clock steps back.
    static func touch(_ id: UUID, kind: LogbookRecordKind, deleted: Bool, now: Date, state: inout LogbookSyncState) {
        var t = now.timeIntervalSince1970
        if let p = state.pending[id], p.modified >= t { t = p.modified + 0.001 }
        state.pending[id] = LogbookPendingChange(kind: kind.rawValue, modified: t, deleted: deleted)
    }

    /// Starts syncing this logbook with `userID`. The first time (or after a switch to another
    /// account) every local entry is queued for upload, as older than anything on the server.
    /// Returns whether it started over.
    @discardableResult
    static func adopt(userID: String, contents: LogbookContents, state: inout LogbookSyncState) -> Bool {
        guard state.userID != userID else { return false }
        var fresh = LogbookSyncState(userID: userID)
        for (id, kind) in contents.allIDs {
            fresh.pending[id] = LogbookPendingChange(kind: kind.rawValue, modified: adoptedModified, deleted: false)
        }
        // Local edits made before this user's first sync are newer than the server copy.
        for (id, p) in state.pending where p.modified > adoptedModified { fresh.pending[id] = p }
        state = fresh
        return true
    }

    // MARK: Push

    /// The records to push: one per pending change, at most `limit`.
    static func outgoing(_ contents: LogbookContents, state: LogbookSyncState, device: String, limit: Int = 500) -> [LogbookRecord] {
        state.pending.sorted { $0.value.modified < $1.value.modified }.prefix(limit).map { id, p in
            let payload = p.deleted ? nil : self.payload(for: id, kind: p.kind, in: contents)
            // A pending edit whose entry is gone was deleted since; send the delete.
            return LogbookRecord(id: id, kind: p.kind, payload: payload, deleted: payload == nil,
                                 modified: p.modified, device: device)
        }
    }

    /// Forgets the pending changes that `sent` pushed, unless they changed again meanwhile.
    static func pushed(_ sent: [LogbookRecord], state: inout LogbookSyncState) {
        for r in sent where state.pending[r.id]?.modified == r.modified {
            state.pending[r.id] = nil
        }
    }

    // MARK: Pull

    /// Applies records pulled from the server. A record loses only to a pending local change
    /// that's at least as new. Returns whether the logbook changed.
    @discardableResult
    static func apply(_ remote: [LogbookRecord], to contents: inout LogbookContents, state: inout LogbookSyncState) -> Bool {
        var changed = false
        var presetPositions: [UUID: Double] = [:]
        var insulinPositions: [UUID: Double] = [:]
        for r in remote {
            if let rev = r.rev { state.cursor = max(state.cursor, rev) }
            if let p = state.pending[r.id], p.modified >= r.modified { continue }
            guard let kind = LogbookRecordKind(rawValue: r.kind) else { continue }
            if r.deleted || r.payload == nil {
                state.pending[r.id] = nil
                changed = remove(r.id, kind: kind, from: &contents) || changed
                continue
            }
            guard let payload = r.payload, upsert(payload, kind: kind, into: &contents) else {
                // Written by a newer app in a shape this one can't read. Leave it for that app,
                // and keep any local change pending.
                continue
            }
            state.pending[r.id] = nil
            if kind == .preset { presetPositions[r.id] = payload["position"]?.number ?? .infinity }
            if kind == .insulin { insulinPositions[r.id] = payload["position"]?.number ?? .infinity }
            changed = true
        }
        if !presetPositions.isEmpty {
            // Presets keep the order their positions say; ones that didn't change keep their place.
            contents.presets = ordered(contents.presets, by: presetPositions)
        }
        if !insulinPositions.isEmpty { contents.insulins = ordered(contents.insulins, by: insulinPositions) }
        return changed
    }

    /// `list` sorted by the positions given; items without one keep their place.
    private static func ordered<T: Identifiable>(_ list: [T], by positions: [UUID: Double]) -> [T] where T.ID == UUID {
        list.enumerated().map { i, item in (item, positions[item.id] ?? Double(i)) }
            .enumerated()
            .sorted { a, b in a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1 }
            .map { $0.element.0 }
    }

    // MARK: Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func json<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? decoder.decode(JSONValue.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func payload(for id: UUID, kind: String, in c: LogbookContents) -> JSONValue? {
        switch LogbookRecordKind(rawValue: kind) {
        case .insulin:
            guard let i = c.insulins.firstIndex(where: { $0.id == id }),
                  case .object(var o)? = json(c.insulins[i]) else { return nil }
            o["position"] = .number(Double(i))
            return .object(o)
        case .dose: return c.doses.first { $0.id == id }.flatMap(json)
        case .meal: return c.meals.first { $0.id == id }.flatMap(json)
        case .siteChange: return c.siteChanges.first { $0.id == id }.flatMap(json)
        case .context: return c.contexts.first { $0.id == id }.flatMap(json)
        case .preset:
            guard let i = c.presets.firstIndex(where: { $0.id == id }),
                  case .object(var o)? = json(c.presets[i]) else { return nil }
            o["position"] = .number(Double(i))
            return .object(o)
        case .food: return c.foods.first { $0.id == id }.flatMap(json)
        case .bolusSettings: return id == BolusSettings.recordID ? c.bolusSettings.flatMap(json) : nil
        case .lowAnswer: return c.lowAnswers.first { $0.id == id }.flatMap(json)
        case .alert: return c.alerts.first { $0.id == id }.flatMap(json)
        case .insightsLayout:
            guard let screen = InsightsScreen(recordID: id), let layout = c.insightsLayouts[screen],
                  !layout.isStandard else { return nil }
            return json(SyncedInsightsLayout(screen: screen, layout: layout))
        case .dayNote:
            guard let key = DayNotes.key(recordID: id), let text = c.dayNotes[key], !text.isEmpty else { return nil }
            return json(DayNote(day: key, text: text))
        case nil: return nil
        }
    }

    private static func upsert(_ payload: JSONValue, kind: LogbookRecordKind, into c: inout LogbookContents) -> Bool {
        switch kind {
        case .insulin:
            guard let i = decode(SavedInsulin.self, from: payload) else { return false }
            if let at = c.insulins.firstIndex(where: { $0.id == i.id }) {
                c.insulins[at] = i
            } else {
                c.insulins.append(i)
            }
            // The same insulin saved under two ids (e.g. renamed on one device while the other
            // added the new name). Every device keeps only the one with the smallest id, in the
            // place of the first, so all devices settle on the same entry without extra writes.
            let same = c.insulins.indices.filter { c.insulins[$0].key == i.key }
            if same.count > 1, let keep = same.min(by: { c.insulins[$0].id.uuidString < c.insulins[$1].id.uuidString }) {
                let winner = c.insulins[keep]
                c.insulins[same[0]] = winner
                for at in same.dropFirst().reversed() { c.insulins.remove(at: at) }
            }
        case .dose:
            guard let d = decode(InsulinDose.self, from: payload) else { return false }
            insertSorted(d, into: &c.doses)
        case .meal:
            guard let m = decode(MealEntry.self, from: payload) else { return false }
            insertSorted(m, into: &c.meals)
        case .siteChange:
            guard let s = decode(SiteChange.self, from: payload) else { return false }
            insertSorted(s, into: &c.siteChanges)
        case .context:
            guard let e = decode(ContextEvent.self, from: payload) else { return false }
            insertSorted(e, into: &c.contexts)
        case .preset:
            guard let p = decode(LogPreset.self, from: payload) else { return false }
            if let i = c.presets.firstIndex(where: { $0.id == p.id }) { c.presets[i] = p } else { c.presets.append(p) }
        case .food:
            guard let f = decode(SavedFood.self, from: payload) else { return false }
            if let i = c.foods.firstIndex(where: { $0.id == f.id }) { c.foods[i] = f } else { c.foods.append(f) }
        case .bolusSettings:
            guard let b = decode(BolusSettings.self, from: payload) else { return false }
            c.bolusSettings = b
        case .lowAnswer:
            guard let a = decode(LowAnswer.self, from: payload) else { return false }
            if let i = c.lowAnswers.firstIndex(where: { $0.id == a.id }) { c.lowAnswers[i] = a } else { c.lowAnswers.append(a) }
        case .alert:
            guard let a = decode(AlertRecord.self, from: payload) else { return false }
            if let i = c.alerts.firstIndex(where: { $0.id == a.id }) { c.alerts[i] = a } else { c.alerts.append(a) }
        case .insightsLayout:
            // A screen this build doesn't have (a newer app's) is left for that app.
            guard let synced = decode(SyncedInsightsLayout.self, from: payload),
                  let screen = InsightsScreen(rawValue: synced.screen) else { return false }
            let layout = synced.layout
            c.insightsLayouts[screen] = layout.isStandard ? nil : layout
        case .dayNote:
            guard let note = decode(DayNote.self, from: payload), DayNotes.isValid(note.day) else { return false }
            let text = DayNotes.cleaned(note.text)
            c.dayNotes[note.day] = text.isEmpty ? nil : text
        }
        return true
    }

    private static func remove(_ id: UUID, kind: LogbookRecordKind, from c: inout LogbookContents) -> Bool {
        if kind == .bolusSettings {
            guard c.bolusSettings != nil, id == BolusSettings.recordID else { return false }
            c.bolusSettings = nil
            return true
        }
        if kind == .insightsLayout {
            guard let screen = InsightsScreen(recordID: id), c.insightsLayouts[screen] != nil else { return false }
            c.insightsLayouts[screen] = nil
            return true
        }
        if kind == .dayNote {
            guard let key = DayNotes.key(recordID: id), c.dayNotes[key] != nil else { return false }
            c.dayNotes[key] = nil
            return true
        }
        let before = c.doses.count + c.meals.count + c.siteChanges.count + c.contexts.count + c.presets.count + c.foods.count
            + c.lowAnswers.count + c.alerts.count
        switch kind {
        case .insulin:
            let had = c.insulins.count
            c.insulins.removeAll { $0.id == id }
            return had != c.insulins.count
        case .dose: c.doses.removeAll { $0.id == id }
        case .meal: c.meals.removeAll { $0.id == id }
        case .siteChange: c.siteChanges.removeAll { $0.id == id }
        case .context: c.contexts.removeAll { $0.id == id }
        case .preset: c.presets.removeAll { $0.id == id }
        case .food: c.foods.removeAll { $0.id == id }
        case .lowAnswer: c.lowAnswers.removeAll { $0.id == id }
        case .alert: c.alerts.removeAll { $0.id == id }
        case .bolusSettings, .insightsLayout, .dayNote: break
        }
        return before != c.doses.count + c.meals.count + c.siteChanges.count + c.contexts.count + c.presets.count + c.foods.count
            + c.lowAnswers.count + c.alerts.count
    }

    /// Replaces the entry with the same id, keeping the list oldest → newest.
    static func insertSorted<T: Identifiable & LogbookTimestamped>(_ item: T, into list: inout [T]) where T.ID == UUID {
        list.removeAll { $0.id == item.id }
        let i = list.firstIndex { $0.timestamp > item.timestamp } ?? list.endIndex
        list.insert(item, at: i)
    }
}

/// Logbook entries with a time, kept in time order.
protocol LogbookTimestamped {
    var timestamp: Date { get }
}

extension InsulinDose: LogbookTimestamped {}
extension MealEntry: LogbookTimestamped {}
extension SiteChange: LogbookTimestamped {}
extension ContextEvent: LogbookTimestamped {}

// MARK: - Undo

/// Which deletes can still be undone once sync has run. A delete is pushed a couple of seconds
/// after it's made, and the next pull brings this device's own tombstone back from the server.
/// That echo mustn't cancel the Undo. Only a change made after the delete (an edit or a delete on
/// another device) does, because undoing then would overwrite something newer.
enum LogbookUndo {
    /// How long the undo toast stays up (iPhone and Mac) after the last delete, in seconds.
    static let toastSeconds: Double = 5
    /// Under VoiceOver, long enough to hear the announcement and reach the button.
    static let toastSecondsVoiceOver: Double = 20

    /// What the undo toast says, on iPhone and Mac: "Deleted 4 u NovoRapid", or "3 entries deleted".
    static func title(_ deleted: [LogEntry]) -> String {
        if deleted.count == 1, let e = deleted.first {
            let what = e.shortTitle
            return what.isEmpty ? "Entry deleted" : "Deleted \(what)"
        }
        return "\(deleted.count) entries deleted"
    }

    /// Leeway for the server's timestamp storing the edit time to the microsecond.
    static let echoTolerance: Double = 0.001

    /// The buffered deletes that `remote` supersedes. `deletedAt` is each buffered entry's delete
    /// time, as pushed (`LogbookPendingChange.modified`).
    static func superseded(by remote: [LogbookRecord], deletedAt: [UUID: Double]) -> Set<UUID> {
        var out: Set<UUID> = []
        for r in remote {
            guard let t = deletedAt[r.id] else { continue }
            if r.modified > t + echoTolerance { out.insert(r.id) }
        }
        return out
    }
}

/// One saved edit that can still be taken back with the undo toast ("Edited meal · Undo"). It
/// holds the entry exactly as it was before the edit, and Undo saves that back under the same id,
/// so it syncs like any other edit and never touches a different entry. GlucOS never works out a
/// value here: a dose's units, a meal's carbs and everything else come back only as they were saved.
struct LogbookEditUndo: Equatable {
    /// Fresh for every edit, so a second edit to the same entry restarts the toast's countdown.
    let token: UUID
    /// The entry before the edit, restored exactly.
    let before: LogEntry
    /// The entry as the edit saved it.
    let after: LogEntry
    /// The edit's time, as pushed (`LogbookPendingChange.modified`), so the server echoing this
    /// edit back keeps Undo, and only a newer change made elsewhere ends it.
    var editedAt: Double?

    /// An Undo for an edit, or nil when there's nothing to take back: no entry before or after, a
    /// different entry (another id or another kind), or nothing changed.
    static func offer(before: LogEntry?, after: LogEntry?, editedAt: Double?, token: UUID = UUID()) -> LogbookEditUndo? {
        guard let before, let after, before.id == after.id, before.sameKind(as: after), before != after else { return nil }
        return LogbookEditUndo(token: token, before: before, after: after, editedAt: editedAt)
    }

    /// What Undo saves: the entry as it was before the edit, and only while the entry the edit
    /// saved is still there under the same id and kind. Nil once it's gone (deleted since).
    func restore(current: LogEntry?) -> LogEntry? {
        guard let current, current.id == before.id, current.sameKind(as: before) else { return nil }
        return before
    }

    /// True when `remote` holds a change to this entry made after the edit (an edit or delete on
    /// another device): undoing then would overwrite something newer. This device's own edit
    /// coming back from the server doesn't count.
    func superseded(by remote: [LogbookRecord]) -> Bool {
        guard let editedAt else { return false }
        return remote.contains { $0.id == before.id && $0.modified > editedAt + LogbookUndo.echoTolerance }
    }

    /// "Edited meal", "Edited dose", "Edited site change", "Edited event".
    var title: String { "Edited \(after.kindNoun)" }
}

/// A new entry added outside a log sheet that can still be taken back with the undo toast ("Added
/// note · Undo"): so far, a note typed in Settings › Alerts › Alert History (docs/AlertNotes.md).
/// Undo deletes it on every device, like any delete, but offers no Undo of its own.
struct LogbookAddUndo: Equatable {
    /// Fresh for every add, so a second one restarts the toast's countdown.
    let token: UUID
    /// The entry as it was added.
    let entry: LogEntry
    /// The add's time, as pushed (`LogbookPendingChange.modified`), so the server echoing it back
    /// keeps Undo, and only a newer change made elsewhere ends it.
    var addedAt: Double?

    init(entry: LogEntry, addedAt: Double?, token: UUID = UUID()) {
        self.token = token
        self.entry = entry
        self.addedAt = addedAt
    }

    /// The id Undo deletes: only while the added entry is still there, under the same id and kind.
    func removal(current: LogEntry?) -> UUID? {
        guard let current, current.id == entry.id, current.sameKind(as: entry) else { return nil }
        return entry.id
    }

    /// True when `remote` holds a change to the entry made after it was added (an edit or a delete
    /// on another device). This device's own add coming back from the server doesn't count.
    func superseded(by remote: [LogbookRecord]) -> Bool {
        guard let addedAt else { return false }
        return remote.contains { $0.id == entry.id && $0.modified > addedAt + LogbookUndo.echoTolerance }
    }

    /// "Added note".
    var title: String { "Added \(entry.kindNoun)" }
}

/// New meals or doses that look like a second copy of ones logged a few minutes before
/// (`DoubleLog`), offered on the undo toast as "Logged twice? 4 u NovoRapid · Undo". Nothing is
/// taken off unless the user taps Undo, which deletes only the new entries, on every device, and
/// only while the earlier twin is still there, so Undo can never leave the user with neither. If
/// another device deleted the twin before this one heard of it, the copy is put back when that
/// delete arrives (`restorations`).
struct LogbookRepeatUndo: Equatable {
    /// Fresh for every offer, so a second one restarts the toast's countdown.
    let token: UUID
    /// Each new entry with the earlier one it looks like.
    let pairs: [Pair]
    /// Each new entry's add time, as pushed (`LogbookPendingChange.modified`).
    var addedAt: [UUID: Double]

    struct Pair: Equatable {
        let entry: LogEntry
        let earlier: LogEntry
    }

    init(pairs: [Pair], addedAt: [UUID: Double], token: UUID = UUID()) {
        self.token = token
        self.pairs = pairs
        self.addedAt = addedAt
    }

    /// The offer for the entries just saved (`saved`), checked against everything else in
    /// `entries`, or nil when none looks logged twice. Entries saved together are never each
    /// other's twins.
    static func offer(saved: [LogEntry], in entries: [LogEntry], addedAt: [UUID: Double],
                      token: UUID = UUID()) -> LogbookRepeatUndo? {
        let ids = Set(saved.map(\.id))
        let pairs = saved.compactMap { e in
            DoubleLog.earlier(for: e, in: entries, excluding: ids).map { Pair(entry: e, earlier: $0) }
        }
        guard !pairs.isEmpty else { return nil }
        return LogbookRepeatUndo(pairs: pairs, addedAt: addedAt.filter { id, _ in pairs.contains { $0.entry.id == id } },
                                 token: token)
    }

    var ids: [UUID] { pairs.map(\.entry.id) }
    var entries: [LogEntry] { pairs.map(\.entry) }

    /// The ids Undo deletes: each new entry still there under the same id and kind, whose earlier
    /// twin is also still there. Never the earlier one.
    func removals(current: (UUID) -> LogEntry?) -> [UUID] {
        pairs.compactMap { p in
            guard let now = current(p.entry.id), now.sameKind(as: p.entry),
                  current(p.earlier.id) != nil else { return nil }
            return p.entry.id
        }
    }

    /// True when `remote` holds a later change to a new entry, or an edit or delete of an earlier
    /// twin on another device. This device's own adds echoing back, and an earlier twin coming back
    /// unchanged, don't count.
    func superseded(by remote: [LogbookRecord]) -> Bool {
        remote.contains { r in
            if let p = pairs.first(where: { $0.earlier.id == r.id }) { return Self.changes(p.earlier, r) }
            guard let t = addedAt[r.id] else { return false }
            return r.modified > t + LogbookUndo.echoTolerance
        }
    }

    /// Whether `record` deletes `entry` or holds something other than it.
    static func changes(_ entry: LogEntry, _ record: LogbookRecord) -> Bool {
        guard !record.deleted, let payload = record.payload else { return true }
        switch entry {
        case .dose(let d): return LogbookMerge.decode(InsulinDose.self, from: payload) != d
        case .meal(let m): return LogbookMerge.decode(MealEntry.self, from: payload) != m
        case .siteChange(let s): return LogbookMerge.decode(SiteChange.self, from: payload) != s
        case .context(let c): return LogbookMerge.decode(ContextEvent.self, from: payload) != c
        }
    }

    /// After Undo has taken new copies off: the ones to put back because `remote` deletes their
    /// earlier twin (deleted on another device before this one heard of it), so the user is never
    /// left with neither. Only copies still gone (`current` nil) whose twin is gone too.
    static func restorations(undone: [Pair], remote: [LogbookRecord], current: (UUID) -> LogEntry?) -> [LogEntry] {
        let deleted = Set(remote.filter { $0.deleted || $0.payload == nil }.map(\.id))
        return undone.filter { p in
            deleted.contains(p.earlier.id) && current(p.earlier.id) == nil && current(p.entry.id) == nil
        }.map(\.entry)
    }

    var title: String { DoubleLog.title(entries) }
    var hint: String { DoubleLog.hint(earlier: pairs.map(\.earlier)) }
}

/// One change made to several entries at once (tagging the Logbook's selection) that can still be
/// taken back with the undo toast ("Added Exercise to 3 entries · Undo"). It holds each entry
/// exactly as it was before, and Undo saves those back under the same ids, so they sync like any
/// other edit. As with a single edit, GlucOS never works out a value here.
struct LogbookBatchEditUndo: Equatable {
    /// Fresh for every change, so a second one restarts the toast's countdown.
    let token: UUID
    /// The changed entries before the change, restored exactly. Shrinks as sync or a later local
    /// change ends Undo for some of them.
    private(set) var before: [LogEntry]
    /// Each entry's edit time, as pushed (`LogbookPendingChange.modified`).
    private(set) var editedAt: [UUID: Double]
    /// The toast's text.
    let title: String

    /// An Undo for the change, or nil when nothing changed. Pairs `before` and `after` by id and
    /// keeps only entries that are the same kind and really differ.
    static func offer(before: [LogEntry], after: [LogEntry], editedAt: [UUID: Double], title: String,
                      token: UUID = UUID()) -> LogbookBatchEditUndo? {
        let saved = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let changed = before.filter { b in saved[b.id].map { $0.sameKind(as: b) && $0 != b } ?? false }
        guard !changed.isEmpty else { return nil }
        let times = editedAt.filter { id, _ in changed.contains { $0.id == id } }
        return LogbookBatchEditUndo(token: token, before: changed, editedAt: times, title: title)
    }

    var ids: [UUID] { before.map(\.id) }

    var count: Int { before.count }

    /// What Undo saves: each entry as it was, for the entries still there under the same id and
    /// kind. One deleted since is left deleted.
    func restore(current: (UUID) -> LogEntry?) -> [LogEntry] {
        before.filter { b in current(b.id).map { $0.sameKind(as: b) } ?? false }
    }

    /// The entries `remote` changed after this change was made (an edit or delete on another
    /// device). This device's own change coming back from the server doesn't count.
    func superseded(by remote: [LogbookRecord]) -> Set<UUID> {
        var out: Set<UUID> = []
        for r in remote {
            guard let t = editedAt[r.id] else { continue }
            if r.modified > t + LogbookUndo.echoTolerance { out.insert(r.id) }
        }
        return out
    }

    /// The same Undo without these entries (changed since, so Undo mustn't overwrite them), or nil
    /// when none are left.
    func dropping(_ ids: Set<UUID>) -> LogbookBatchEditUndo? {
        guard !ids.isEmpty else { return self }
        var out = self
        out.before.removeAll { ids.contains($0.id) }
        for id in ids { out.editedAt[id] = nil }
        return out.before.isEmpty ? nil : out
    }
}

/// What the undo toast offers, on iPhone and Mac: the last delete (which may hold several
/// entries) or the last edit. Only one at a time: a new edit replaces a pending delete's Undo,
/// and a new delete replaces a pending edit's.
enum LogbookUndoOffer: Equatable {
    case deleted([LogEntry])
    case edited(LogbookEditUndo)
    /// Several entries changed at once (tags added or removed from the Logbook's selection).
    case batch(LogbookBatchEditUndo)
    /// A new entry added outside a log sheet (a note from Alert History).
    case added(LogbookAddUndo)
    /// A meal or dose that looks logged twice (`DoubleLog`).
    case repeated(LogbookRepeatUndo)

    /// The toast's text.
    var title: String {
        switch self {
        case .deleted(let entries): return LogbookUndo.title(entries)
        case .edited(let edit): return edit.title
        case .batch(let b): return b.title
        case .added(let a): return a.title
        case .repeated(let r): return r.title
        }
    }

    /// What `UndoCountdown.restarts` watches: a new id here restarts the bar and is announced.
    var ids: [UUID] {
        switch self {
        case .deleted(let entries): return entries.map(\.id)
        case .edited(let edit): return [edit.token]
        case .batch(let b): return [b.token]
        case .added(let a): return [a.token]
        case .repeated(let r): return [r.token]
        }
    }

    /// The toast's leading symbol.
    var symbol: String {
        switch self {
        case .deleted: return "trash"
        case .edited: return "pencil"
        case .batch: return "tag"
        case .added: return "square.and.pencil"
        case .repeated: return "square.on.square"
        }
    }

    /// What Undo does, for VoiceOver and the Mac's help tag.
    var hint: String {
        switch self {
        case .deleted: return "Puts back what you deleted, on all your devices"
        case .edited: return "Puts back the entry as it was before your edit, on all your devices"
        case .batch: return "Puts back the entries as they were before, on all your devices"
        case .added: return "Takes the note off again, on all your devices"
        case .repeated(let r): return r.hint
        }
    }

    /// "Logged twice?", which the Mac also shows over the menu bar popover and the dashboard's
    /// other pages, where a quick log or Log Again Now lands.
    var isRepeat: Bool {
        if case .repeated = self { return true }
        return false
    }

    /// Changes as the deletes pile up, for the title's number roll.
    var count: Int {
        switch self {
        case .deleted(let entries): return entries.count
        case .edited: return 1
        case .batch(let b): return b.count
        case .added: return 1
        case .repeated(let r): return r.pairs.count
        }
    }
}

extension LogEntry {
    /// The same kind of entry (dose, meal, site change or event), whatever it holds.
    func sameKind(as other: LogEntry) -> Bool {
        switch (self, other) {
        case (.dose, .dose), (.meal, .meal), (.siteChange, .siteChange), (.context, .context): return true
        default: return false
        }
    }

    /// "dose", "meal", "site change", "event", or "note" for a plain note (an event with no tags, only text):
    /// what the edit Undo toast calls the entry.
    var kindNoun: String {
        switch self {
        case .dose: return "dose"
        case .meal: return "meal"
        case .siteChange: return "site change"
        case .context(let c): return AlertNote.isNote(c) ? "note" : "event"
        }
    }
}
