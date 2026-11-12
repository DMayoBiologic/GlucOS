import Foundation

// The insulins a user takes, set up once (Settings → Insulin, or simply by logging one) and then
// picked with one tap whenever they log a dose, so names never have to be typed again and the
// logbook spells each one the same way. Synced between devices with the logbook (record kind
// `insulin`). Plain Foundation so `swift test` covers the rules.

/// One of the user's insulins.
struct SavedInsulin: Codable, Identifiable, Hashable {
    var id: UUID
    /// Brand name as the user wants it written, e.g. "NovoRapid".
    var name: String
    var kind: InsulinKind
    /// How far − / + move the dose, in units: 0.5 for a half-unit pen, for example. Nil uses the
    /// usual step (1 u for a pen or syringe, 0.5 u for a pump).
    var doseStep: Double?

    /// A new insulin. Without an `id` it gets one worked out from the name, so two devices that
    /// each save "NovoRapid" before they've synced end up with one entry, not two.
    init(id: UUID? = nil, name: String, kind: InsulinKind, doseStep: Double? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? InsulinLibrary.stableID(for: trimmed)
        self.name = trimmed
        self.kind = kind
        self.doseStep = doseStep
    }

    /// Names that only differ in case, spaces or punctuation are the same insulin.
    var key: String { InsulinLibrary.key(name) }

    /// "NovoRapid · Rapid-acting".
    var summary: String {
        var s = kind.title
        if let doseStep { s += " · steps of \(LogFormat.units(doseStep))" }
        return s
    }
}

enum InsulinLibrary {
    /// Steps offered in Settings. Pens dial in 1 u or 0.5 u; pumps go down to 0.05 u.
    static let doseSteps: [Double] = [0.05, 0.1, 0.5, 1, 2]

    /// The usual − / + step when an insulin doesn't set its own.
    static func defaultStep(viaPump: Bool) -> Double { viaPump ? 0.5 : 1 }

    static func step(for insulin: SavedInsulin?, viaPump: Bool) -> Double {
        guard let s = insulin?.doseStep, s > 0 else { return defaultStep(viaPump: viaPump) }
        return s
    }

    /// Lower-cased letters and digits only: "Novo Rapid", "novorapid" and "NovoRapid" match.
    static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The saved insulin `name` refers to, however it's spelled.
    static func match(_ name: String, in library: [SavedInsulin]) -> SavedInsulin? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return library.first { $0.key == k }
    }

    /// The insulins a dose can be logged with: a pump only delivers rapid or ultra-rapid insulin.
    static func choices(_ library: [SavedInsulin], viaPump: Bool) -> [SavedInsulin] {
        viaPump ? library.filter { InsulinKind.pumpKinds.contains($0.kind) } : library
    }

    /// The insulin a new dose starts with: the mealtime insulin logged most recently, otherwise
    /// the first mealtime insulin saved, otherwise the first one that fits at all.
    static func preferred(in library: [SavedInsulin], doses: [InsulinDose], viaPump: Bool) -> SavedInsulin? {
        let options = choices(library, viaPump: viaPump)
        guard !options.isEmpty else { return nil }
        for d in doses.reversed() where d.kind.isBolus && d.viaPump == viaPump {
            if let m = match(d.name, in: options) { return m }
        }
        return options.first { $0.kind.isBolus } ?? options.first
    }

    /// The background insulin a basal dose starts with: the one logged most recently, otherwise
    /// the first long-acting (or other non-mealtime) insulin saved. Pumps don't log basal doses.
    static func preferredBasal(in library: [SavedInsulin], doses: [InsulinDose]) -> SavedInsulin? {
        let options = library.filter { !$0.kind.isBolus }
        guard !options.isEmpty else { return nil }
        for d in doses.reversed() where !d.kind.isBolus && !d.viaPump {
            if let m = match(d.name, in: options) { return m }
        }
        return options.first { $0.kind == .long } ?? options.first
    }

    /// Insulins the user has already logged (or named in the old Settings fields) that aren't
    /// saved yet, each with its most used spelling and kind. Used to fill the list the first time.
    static func discovered(from doses: [InsulinDose], named extra: [(name: String, kind: InsulinKind)] = [],
                           excluding library: [SavedInsulin]) -> [SavedInsulin] {
        struct Tally { var spellings: [String: Int] = [:]; var kinds: [InsulinKind: Int] = [:] }
        var tallies: [String: Tally] = [:]
        var order: [String] = []
        let known = Set(library.map(\.key))
        let named = extra.map { (name: $0.name, kind: $0.kind, viaPump: false) }
        let logged = doses.map { (name: $0.name, kind: $0.kind, viaPump: $0.viaPump) }
        for item in named + logged {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(name)
            guard !k.isEmpty, !known.contains(k) else { continue }
            if tallies[k] == nil { order.append(k) }
            tallies[k, default: Tally()].spellings[name, default: 0] += 1
            tallies[k, default: Tally()].kinds[item.kind, default: 0] += 1
        }
        var found: [SavedInsulin] = []
        for k in order {
            guard let t = tallies[k],
                  let name = commonest(t.spellings, tieBreak: { $0 < $1 }),
                  let kind = commonest(t.kinds, tieBreak: { $0.rawValue < $1.rawValue })
            else { continue }
            found.append(SavedInsulin(name: name, kind: kind))
        }
        // Mealtime insulins first, then in the order they were first seen.
        return found.filter { $0.kind.isBolus } + found.filter { !$0.kind.isBolus }
    }

    /// The key counted most often; ties go to the one `tieBreak` orders first.
    private static func commonest<K>(_ counts: [K: Int], tieBreak: (K, K) -> Bool) -> K? {
        var best: (key: K, count: Int)?
        for (key, count) in counts {
            if let b = best, count < b.count || (count == b.count && !tieBreak(key, b.key)) { continue }
            best = (key, count)
        }
        return best?.key
    }

    /// Doses whose insulin name matches a saved insulin but is written differently, with the
    /// saved spelling to use instead.
    static func respellings(_ doses: [InsulinDose], library: [SavedInsulin]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for d in doses {
            if let m = match(d.name, in: library), m.name != d.name { out[d.id] = m.name }
        }
        return out
    }

    /// Same for presets.
    static func respellings(_ presets: [LogPreset], library: [SavedInsulin]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for p in presets {
            if let m = match(p.insulinName, in: library), m.name != p.insulinName { out[p.id] = m.name }
        }
        return out
    }

    // MARK: Stable ids

    /// An id that's the same on every device for the same name (two 64-bit FNV-1a hashes of the
    /// matching key, as a version 8 UUID).
    static func stableID(for name: String) -> UUID {
        let bytes = Array(("glucos.insulin:" + key(name)).utf8)
        func fnv(_ basis: UInt64) -> UInt64 {
            var h = basis
            for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var u = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { u[i] = UInt8(truncatingIfNeeded: a >> (56 - 8 * UInt64(i))) }
        for i in 0..<8 { u[8 + i] = UInt8(truncatingIfNeeded: b >> (56 - 8 * UInt64(i))) }
        u[6] = (u[6] & 0x0f) | 0x80   // version 8
        u[8] = (u[8] & 0x3f) | 0x80   // RFC 4122 variant
        return UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                           u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]))
    }
}
