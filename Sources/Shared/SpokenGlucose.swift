import Foundation

// What Siri says for "What's my glucose" (the iPhone's ReadGlucoseIntent, docs/iOS.md "Siri and
// Shortcuts"). Worked out here, beside the widgets' spoken reading, so it can be tested and says
// exactly what the widgets say: a fresh reading with its range, trend, change and age, then the
// forecast's caveat line when there is one. A reading past `GlucoseSnapshot.staleAfter` is said to
// be stale and never spoken as the current glucose: no range, no trend, no forecast.

enum SpokenGlucose {
    /// The answer at `now`. `snapshot` is nil when this device has never had a reading.
    static func answer(_ snapshot: GlucoseSnapshot?, at now: Date) -> String {
        guard let s = snapshot else { return "GlucOS has no reading yet. Open GlucOS to connect." }
        let state = AccessoryGlance.state(s, at: now)
        let reading = WidgetSpeech.reading(s, state: state, at: now)
        guard state == .fresh, let line = caveat(s, at: now) else { return reading }
        return reading + " " + line
    }

    /// "About the forecast: Trend only: …", only while the forecast still starts from the reading
    /// being spoken (`OutlookSnapshot.isCurrent`).
    static func caveat(_ s: GlucoseSnapshot, at now: Date) -> String? {
        guard let outlook = s.outlook, outlook.isCurrent(at: now), let caveat = outlook.caveat else { return nil }
        let text = caveat.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return "About the forecast: " + (text.hasSuffix(".") ? text : text + ".")
    }

    /// Whether the answer would be stale or missing: the intent fetches once before answering.
    static func wantsRefresh(_ snapshot: GlucoseSnapshot?, at now: Date) -> Bool {
        guard let s = snapshot else { return true }
        return AccessoryGlance.state(s, at: now) != .fresh
    }
}
