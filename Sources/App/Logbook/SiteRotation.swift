import Foundation

// Injection site rotation. Injecting into the same spot again and again can leave lumpy, scarred
// tissue (lipohypertrophy) where insulin absorbs unpredictably, so the log sheet suggests the
// site used longest ago and says when the one picked was used only recently.

enum SiteRotation {
    /// A site used more recently than this gets a gentle "used recently" note.
    static let recentWindow: TimeInterval = 3 * 24 * 3600

    /// The site to suggest: one never used yet, then the one used longest ago, within the body
    /// areas the user injects into (someone who only uses their abdomen and thighs isn't sent to
    /// their arms). Nil until a dose has been logged with a site.
    static func suggestion(lastUse: [InjectionSite: Date]) -> InjectionSite? {
        guard !lastUse.isEmpty else { return nil }
        let usedAreas = Set(lastUse.keys.map(\.area))
        let candidates = InjectionSite.allCases.filter { $0 != .other && usedAreas.contains($0.area) }
        return candidates.min { (lastUse[$0] ?? .distantPast) < (lastUse[$1] ?? .distantPast) }
    }

    /// When `site` was last used, if that's within `recentWindow` of `now`.
    static func recentUse(of site: InjectionSite?, lastUse: [InjectionSite: Date], now: Date = Date()) -> Date? {
        guard let site, site != .other, let last = lastUse[site], now.timeIntervalSince(last) < recentWindow else { return nil }
        return last
    }
}
