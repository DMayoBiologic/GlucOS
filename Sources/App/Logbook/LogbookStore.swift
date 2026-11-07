import Foundation
import Combine

/// Insulin, food and site-change entries, kept in
/// `~/Library/Application Support/GlucOS/logbook.json`. Entries are kept until the user deletes
/// them. Independent of fetching, the widget snapshot and alerts.
@MainActor
final class LogbookStore: ObservableObject {
    /// Each oldest → newest.
    @Published private(set) var doses: [InsulinDose] = []
    @Published private(set) var meals: [MealEntry] = []
    @Published private(set) var siteChanges: [SiteChange] = []
    @Published private(set) var contexts: [ContextEvent] = []

    /// Set by the menu bar popover to have the dashboard open the log sheet.
    @Published var logSheetRequested = false

    private struct File: Codable {
        var version = 1
        var doses: [InsulinDose] = []
        var meals: [MealEntry] = []
        var siteChanges: [SiteChange] = []
        var contexts: [ContextEvent]? = []
    }

    private static var url: URL? {
        SharedStore.containerURL?.appendingPathComponent("logbook.json")
    }

    private static let writeQueue = DispatchQueue(label: "au.com.declanmayo.glucos.logbook", qos: .utility)

    init() {
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
        switch entry {
        case .dose(let d): Self.upsert(d, into: &doses)
        case .meal(let m): Self.upsert(m, into: &meals)
        case .siteChange(let s): Self.upsert(s, into: &siteChanges)
        case .context(let c): Self.upsert(c, into: &contexts)
        }
        persist()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        doses.removeAll { ids.contains($0.id) }
        meals.removeAll { ids.contains($0.id) }
        siteChanges.removeAll { ids.contains($0.id) }
        contexts.removeAll { ids.contains($0.id) }
        persist()
    }

    private static func upsert<T: Identifiable>(_ item: T, into list: inout [T]) where T.ID == UUID, T: Timestamped {
        list.removeAll { $0.id == item.id }
        let i = list.firstIndex { $0.timestamp > item.timestamp } ?? list.endIndex
        list.insert(item, at: i)
    }

    private func persist() {
        guard let url = Self.url else { return }
        let file = File(doses: doses, meals: meals, siteChanges: siteChanges, contexts: contexts)
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(file) else { return }
            try? data.write(to: url, options: .atomic)
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
}

protocol Timestamped {
    var timestamp: Date { get }
}

extension InsulinDose: Timestamped {}
extension MealEntry: Timestamped {}
extension SiteChange: Timestamped {}
extension ContextEvent: Timestamped {}

// MARK: - Chart events

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
