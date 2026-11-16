import SwiftUI
import WidgetKit

/// The iPhone widget extension: the Lock Screen Live Activity, Lock Screen widgets, and the same
/// Home Screen widgets as the Mac, and the Control Center controls.
@main
struct GlucOSPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLiveActivity()
        GlucoseAccessoryWidget()
        LogShortcutWidget()
        WakeShortcutWidget()
        UsualWidget()
        GlucoseWidget()
        TimeInRangeWidget()
        SensorWidget()
        // Control Center and Lock Screen controls (iOS 18).
        GlucoseControl()
        LowTreatmentControl()
    }
}
