import Foundation

/// Which alerts carry a chart (`AlertChart`), and the chart for a snapshot. The low, high and
/// forecast alerts do: the ones with Log treatment and Snooze buttons. The relay's push alerts go
/// by the same rule (`alertChart` in core.ts).
enum AlertChartSource {
    /// The last 3 hours and the forecast, from the same card the Live Activity shows. Nil for other
    /// alerts, and while there are too few readings to draw.
    static func chart(for kind: AlertNotice.Kind, snapshot: GlucoseSnapshot, now: Date = Date()) -> AlertChart? {
        guard kind.treatment != nil else { return nil }
        return GlucoseActivityState.make(from: snapshot, now: now).flatMap(AlertChart.init(state:))
    }
}
