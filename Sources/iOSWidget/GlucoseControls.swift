import AppIntents
import SwiftUI
import WidgetKit

// Control Center and Lock Screen controls (iOS 18). The system draws a control as a symbol and one
// short line, so the words (`ControlGlance`) carry freshness: stale says "Stale" with its age and
// no trend, a withdrawn reading shows no number. Neither control logs anything.

/// Your latest reading, trend and age. Tap opens Today. Reloaded by the app with the Glucose
/// widgets (`WidgetReload.Group.glucose.controlKinds`).
struct GlucoseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetReload.ControlKind.glucose, provider: GlucoseControlProvider()) { value in
            ControlWidgetButton(action: OpenTodayControlIntent()) {
                Label(value.title, systemImage: value.symbol)
                    .accessibilityLabel(value.spoken)
            }
        }
        .displayName("Glucose")
        .description("Your latest reading, trend and age. Opens Today.")
    }
}

struct GlucoseControlValue: Sendable {
    var title: String
    var symbol: String
    var spoken: String

    init(_ snapshot: GlucoseSnapshot, at now: Date) {
        title = ControlGlance.title(snapshot, at: now)
        symbol = ControlGlance.symbol(snapshot, at: now)
        spoken = ControlGlance.spoken(snapshot, at: now)
    }
}

struct GlucoseControlProvider: ControlValueProvider {
    var previewValue: GlucoseControlValue {
        var s = GlucoseSnapshot()
        s.current = GlucoseReading(timestamp: Date(), mgdl: 112, trend: .flat)
        return GlucoseControlValue(s, at: Date())
    }

    func currentValue() async throws -> GlucoseControlValue {
        GlucoseControlValue(SharedStore.load() ?? .empty, at: Date())
    }
}

/// Opens the log sheet for treating a low, as the alert's and Today's "Log treatment" buttons do.
/// A fixed button: nothing it draws depends on the reading, so it's never reloaded.
struct LowTreatmentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetReload.ControlKind.lowTreatment) {
            ControlWidgetButton(action: OpenLowTreatmentControlIntent()) {
                Label("Log treatment", systemImage: "cross.case.fill")
                    .accessibilityLabel(ControlGlance.treatmentSpoken)
            }
        }
        .displayName("Log Treatment")
        .description("Opens the log sheet for treating a low. Nothing is logged until you tap Log.")
    }
}
