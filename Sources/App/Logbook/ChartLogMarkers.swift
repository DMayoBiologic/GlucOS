import SwiftUI

extension ChartLogMarker {
    /// Doses, wake-ups and food after `cutoff`, as chart markers. Food tagged as a hypo treatment
    /// is still drawn as food, but VoiceOver calls it a treatment when it pops in (`MarkerPop`).
    /// Shared by iPhone Today, the follower view and the Mac popover.
    static func logbook(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                        since cutoff: Date) -> [ChartLogMarker] {
        var out: [ChartLogMarker] = []
        for d in doses where d.timestamp >= cutoff {
            out.append(ChartLogMarker(id: d.id, date: d.timestamp, systemImage: d.viaPump ? "cross.vial.fill" : "syringe.fill",
                                      tint: Palette.insulin,
                                      label: "\(LogFormat.units(d.units)) \(d.displayName) at \(ClockLabel.time(d.timestamp))",
                                      kind: .insulin))
        }
        for c in contexts where c.isWake && c.timestamp >= cutoff {
            out.append(ChartLogMarker(id: c.id, date: c.timestamp, systemImage: ContextTag.wokeUp.systemImage,
                                      tint: Palette.context, lane: 2,
                                      label: "Woke up at \(ClockLabel.time(c.timestamp))", kind: .wake))
        }
        let treatments = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        for m in meals where m.timestamp >= cutoff {
            let treats = MarkerPop.isTreatment(mealAt: m.timestamp, treatmentTags: treatments)
            out.append(ChartLogMarker(id: m.id, date: m.timestamp, systemImage: "fork.knife", tint: Palette.food, lane: 1,
                                      label: m.carbs > 0 ? "\(LogFormat.grams(m.carbs)) carbs at \(ClockLabel.time(m.timestamp))"
                                                         : "Food at \(ClockLabel.time(m.timestamp))",
                                      kind: treats ? .treatment : .meal))
        }
        return out
    }
}
