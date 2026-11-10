import AppIntents
import WidgetKit

// MARK: - Glucose widget configuration

/// How much history the Glucose widget's chart shows.
enum ChartWindow: String, AppEnum {
    case automatic, threeHours, sixHours, twelveHours

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chart window")
    static var caseDisplayRepresentations: [ChartWindow: DisplayRepresentation] = [
        .automatic: "Automatic",
        .threeHours: "3 hours",
        .sixHours: "6 hours",
        .twelveHours: "12 hours",
    ]

    /// LibreLinkUp only returns ~12 h, so that's the ceiling. Automatic gives the small and
    /// medium sizes a short, readable window and the bigger sizes the whole day so far.
    func hours(for family: WidgetFamily) -> Double {
        switch self {
        case .threeHours: return 3
        case .sixHours: return 6
        case .twelveHours: return 12
        case .automatic:
            switch family {
            case .systemSmall, .systemMedium: return 3
            default: return 12
            }
        }
    }
}

struct GlucoseWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Glucose"
    static var description = IntentDescription("Choose how much history the chart shows and which controls appear.")

    @Parameter(title: "Chart window", default: .automatic)
    var window: ChartWindow

    @Parameter(title: "Refresh button", default: true)
    var showsRefresh: Bool

    @Parameter(title: "Statistics", default: true)
    var showsStats: Bool

    init() {}
}

// MARK: - Time in range configuration

enum InsightPeriod: String, AppEnum {
    case last12Hours, last24Hours, last7Days, last14Days

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Period")
    static var caseDisplayRepresentations: [InsightPeriod: DisplayRepresentation] = [
        .last12Hours: "Last 12 hours",
        .last24Hours: "Last 24 hours",
        .last7Days: "Last 7 days",
        .last14Days: "Last 14 days",
    ]

    var seconds: TimeInterval {
        switch self {
        case .last12Hours: return 12 * 3600
        case .last24Hours: return 24 * 3600
        case .last7Days: return 7 * 86_400
        case .last14Days: return 14 * 86_400
        }
    }

    var shortLabel: String {
        switch self {
        case .last12Hours: return "12H"
        case .last24Hours: return "24H"
        case .last7Days: return "7D"
        case .last14Days: return "14D"
        }
    }
}

struct TimeInRangeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Time in Range"
    static var description = IntentDescription("Choose the period the summary covers.")

    @Parameter(title: "Period", default: .last24Hours)
    var period: InsightPeriod

    init() {}
}

// MARK: - Interactive refresh

/// The widget's refresh button. Asks the app for a new reading, then waits briefly for it so the
/// timeline WidgetKit reloads after this returns already shows the new value.
struct RefreshGlucoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Glucose"
    static var description = IntentDescription("Ask GlucOS to fetch a new reading now.")

    init() {}

    func perform() async throws -> some IntentResult {
        let before = SharedStore.load()?.fetchedAt ?? .distantPast
        WidgetBridge.requestRefresh()
        // Up to 4 s. If GlucOS isn't running nothing will change, and the widget says so.
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let fetched = SharedStore.load()?.fetchedAt, fetched > before { break }
        }
        return .result()
    }
}
