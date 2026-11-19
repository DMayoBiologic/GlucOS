import AppIntents
import Foundation

// "How was my day" for Siri, Shortcuts and Spotlight on iPhone and Mac (docs/iOS.md "Siri and
// Shortcuts"). It answers out loud and on screen without opening the app: today's time in range,
// average, lows and highs from midnight to the newest reading, in `SpokenDay`'s words (the evening
// recap's figures). Observations only, never advice.
//
// The phrases live in each app's one shortcuts provider: `GlucOSAppShortcuts` on iPhone and
// `GlucOSMacShortcuts` on the Mac.

struct DaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "How Was My Day"
    static let description = IntentDescription("Says today's time in range, average glucose, and how many lows and highs there have been since midnight, up to your latest reading.")
    static let openAppWhenRun = false

    /// How long to wait for a new reading when the saved one isn't fresh.
    static let refreshWait: TimeInterval = 8

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = GlucoseStore.live
        if let store, SpokenGlucose.wantsRefresh(store.snapshot, at: Date()) {
            // The iPhone doesn't keep fetching in the background, so today may be missing its last
            // stretch: try once for a new reading, briefly, and answer from whatever is there then.
            let before = store.snapshot.fetchedAt
            Task { await store.refresh() }
            let deadline = Date().addingTimeInterval(Self.refreshWait)
            while store.snapshot.fetchedAt <= before, Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let settings = AppSettings.shared
        // Signed out (or follower-only): the archive on disk may still hold an earlier account's
        // readings, so say nothing about them, as the evening recap does.
        guard settings.hasCredentials else {
            return .result(value: SpokenDay.signedOut, dialog: IntentDialog(stringLiteral: SpokenDay.signedOut))
        }
        let readings = store?.archive ?? HistoryArchive.load().readings
        let text = SpokenDay.answer(readings: readings, low: settings.lowMgdl, high: settings.highMgdl,
                                    unit: settings.unit, now: Date())
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
