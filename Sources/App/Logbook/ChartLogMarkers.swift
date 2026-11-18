import SwiftUI

extension ChartLogMarker {
    /// Doses, wake-ups, food and plain notes after `cutoff`, as chart markers. Food tagged as a hypo
    /// treatment is still drawn as food, but VoiceOver calls it a treatment when it pops in
    /// (`MarkerPop`). Plain notes (`ChartNote`), alert notes among them, only with `notes`: the
    /// follower view leaves them out. Shared by iPhone Today, the follower view, the Mac popover
    /// and the Mac Outlook chart.
    static func logbook(doses: [InsulinDose], meals: [MealEntry], contexts: [ContextEvent],
                        since cutoff: Date, notes: Bool = true) -> [ChartLogMarker] {
        var out: [ChartLogMarker] = []
        for d in doses where d.timestamp >= cutoff {
            out.append(ChartLogMarker(id: d.id, date: d.timestamp, systemImage: d.viaPump ? "cross.vial.fill" : "syringe.fill",
                                      tint: Palette.insulin,
                                      label: "\(LogFormat.units(d.units)) \(d.displayName) at \(ClockLabel.time(d.timestamp))",
                                      kind: .insulin,
                                      callout: .init(title: "Insulin",
                                                     amount: MarkerCallout.doseAmount(units: LogFormat.units(d.units),
                                                                                      name: d.displayName, viaPump: d.viaPump),
                                                     note: d.note)))
        }
        for c in contexts where c.isWake && c.timestamp >= cutoff {
            out.append(ChartLogMarker(id: c.id, date: c.timestamp, systemImage: ContextTag.wokeUp.systemImage,
                                      tint: Palette.context, lane: 2,
                                      label: "Woke up at \(ClockLabel.time(c.timestamp))", kind: .wake,
                                      callout: .init(title: "Woke up", note: c.note)))
        }
        if notes {
            let wakes = contexts.filter(\.isWake).map(\.timestamp)
            for c in contexts where c.timestamp >= cutoff && AlertNote.isNote(c) {
                guard let label = ChartNote.label(c.note, at: c.timestamp) else { continue }
                out.append(ChartLogMarker(id: c.id, date: c.timestamp, systemImage: ChartNote.systemImage,
                                          tint: Palette.context, lane: ChartNote.lane(at: c.timestamp, wakes: wakes),
                                          label: label, kind: .note,
                                          callout: .init(title: "Note", note: c.note, readsNote: true)))
            }
        }
        let treatments = contexts.filter { $0.tags.contains(.hypoTreatment) }.map(\.timestamp)
        for m in meals where m.timestamp >= cutoff {
            let treats = MarkerPop.isTreatment(mealAt: m.timestamp, treatmentTags: treatments)
            out.append(ChartLogMarker(id: m.id, date: m.timestamp, systemImage: "fork.knife", tint: Palette.food, lane: 1,
                                      label: m.carbs > 0 ? "\(LogFormat.grams(m.carbs)) carbs at \(ClockLabel.time(m.timestamp))"
                                                         : "Food at \(ClockLabel.time(m.timestamp))",
                                      kind: treats ? .treatment : .meal,
                                      callout: .init(title: treats ? "Treatment" : "Meal",
                                                     amount: MarkerCallout.mealAmount(grams: m.carbs > 0 ? LogFormat.grams(m.carbs) : nil,
                                                                                      food: m.food),
                                                     note: m.note)))
        }
        return out
    }
}
