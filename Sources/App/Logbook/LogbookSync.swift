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
    case dose, meal, siteChange, context, preset
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
    var doses: [InsulinDose] = []
    var meals: [MealEntry] = []
    var siteChanges: [SiteChange] = []
    var contexts: [ContextEvent] = []
    /// In the user's order.
    var presets: [LogPreset] = []

    var allIDs: [(UUID, LogbookRecordKind)] {
        doses.map { ($0.id, .dose) } + meals.map { ($0.id, .meal) } + siteChanges.map { ($0.id, .siteChange) }
            + contexts.map { ($0.id, .context) } + presets.map { ($0.id, .preset) }
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
            changed = true
        }
        if !presetPositions.isEmpty {
            // Presets keep the order their positions say; ones that didn't change keep their place.
            let indexed = contents.presets.enumerated().map { i, p in (p, presetPositions[p.id] ?? Double(i)) }
            contents.presets = indexed.enumerated()
                .sorted { a, b in a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1 }
                .map { $0.element.0 }
        }
        return changed
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
        case .dose: return c.doses.first { $0.id == id }.flatMap(json)
        case .meal: return c.meals.first { $0.id == id }.flatMap(json)
        case .siteChange: return c.siteChanges.first { $0.id == id }.flatMap(json)
        case .context: return c.contexts.first { $0.id == id }.flatMap(json)
        case .preset:
            guard let i = c.presets.firstIndex(where: { $0.id == id }),
                  case .object(var o)? = json(c.presets[i]) else { return nil }
            o["position"] = .number(Double(i))
            return .object(o)
        case nil: return nil
        }
    }

    private static func upsert(_ payload: JSONValue, kind: LogbookRecordKind, into c: inout LogbookContents) -> Bool {
        switch kind {
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
        }
        return true
    }

    private static func remove(_ id: UUID, kind: LogbookRecordKind, from c: inout LogbookContents) -> Bool {
        let before = c.doses.count + c.meals.count + c.siteChanges.count + c.contexts.count + c.presets.count
        switch kind {
        case .dose: c.doses.removeAll { $0.id == id }
        case .meal: c.meals.removeAll { $0.id == id }
        case .siteChange: c.siteChanges.removeAll { $0.id == id }
        case .context: c.contexts.removeAll { $0.id == id }
        case .preset: c.presets.removeAll { $0.id == id }
        }
        return before != c.doses.count + c.meals.count + c.siteChanges.count + c.contexts.count + c.presets.count
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
