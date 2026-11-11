import SwiftUI
import WidgetKit

/// The iPhone widget extension: the Lock Screen Live Activity, Lock Screen widgets, and the same
/// Home Screen widgets as the Mac.
@main
struct GlucOSPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLiveActivity()
        GlucoseAccessoryWidget()
        LogShortcutWidget()
        WakeShortcutWidget()
        GlucoseWidget()
        TimeInRangeWidget()
        SensorWidget()
    }
}
